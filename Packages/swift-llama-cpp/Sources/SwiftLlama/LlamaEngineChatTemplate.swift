// LlamaEngineChatTemplate.swift
// SwiftLlama — chat-template formatting for llama.cpp b12000
//
// Kept beside the engine, not inside it: template rendering is the app's
// only prompt path and is worth reading on its own.

import Foundation
import llama
import os

extension LlamaEngine {
    // MARK: - Chat Template Formatting

    /// Apply a chat template to format messages.
    /// The GGUF's own template is the default. `templateName` selects one of the
    /// runtime's built-in family templates for a GGUF that carries none (Gemma 4
    /// E2B ships without `tokenizer.chat_template`). Both paths render through
    /// `llama_chat_apply_template`; there is no hand-built prompt path.
    public func applyChatTemplate(
        messages: [(role: String, content: String)],
        model: OpaquePointer?,
        addAssistant: Bool = true,
        templateName: String? = nil
    ) -> String {
        guard let model else { return "" }

        // A declared built-in name wins over an absent embedded template. The
        // duplicate is owned here so the pointer outlives every early return.
        let declared = templateName.flatMap { $0.isEmpty ? nil : strdup($0) }
        defer { declared.map { free($0) } }
        let template: UnsafePointer<CChar>?
        if let declared {
            template = UnsafePointer(declared)
        } else {
            template = llama_model_chat_template(model, nil)
        }
        guard let template else { return "" }

        // Own every C string for the complete native call. Passing Swift String
        // conversions directly would leave dangling pointers in this array.
        let roles = messages.map { strdup($0.role) }
        let contents = messages.map { strdup($0.content) }
        defer {
            roles.forEach { free($0) }
            contents.forEach { free($0) }
        }
        guard !roles.contains(where: { $0 == nil }),
              !contents.contains(where: { $0 == nil }) else { return "" }
        let chatMessages = messages.indices.map { index in
            llama_chat_message(role: roles[index], content: contents[index])
        }

        // Calculate buffer size: 2x total characters of all messages.
        let totalChars = messages.reduce(0) { $0 + $1.content.count + $1.role.count + 10 }
        let bufferSize = max(totalChars * 2, 1024)

        let formatted = chatMessages.withUnsafeBufferPointer { ptr -> String in
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let nBytes = llama_chat_apply_template(
                template, ptr.baseAddress, chatMessages.count,
                addAssistant, &buffer, Int32(bufferSize)
            )
            if nBytes > 0 && nBytes <= Int32(bufferSize) {
                return String(
                    decoding: buffer.prefix(Int(nBytes)).map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
            }
            // If buffer too small, retry with larger buffer.
            if nBytes > Int32(bufferSize) {
                let largerSize = Int(nBytes) + 1
                var largerBuffer = [CChar](repeating: 0, count: largerSize)
                let nBytes2 = llama_chat_apply_template(
                    template, ptr.baseAddress, chatMessages.count,
                    addAssistant, &largerBuffer, Int32(largerSize)
                )
                if nBytes2 > 0 && nBytes2 <= Int32(largerSize) {
                    return String(
                        decoding: largerBuffer.prefix(Int(nBytes2)).map { UInt8(bitPattern: $0) },
                        as: UTF8.self
                    )
                }
            }
            // Fallback: empty string (will cause tokenization to fail).
            return ""
        }

        return formatted
    }
}

// MARK: - Prompt path selection and chat streaming

extension LlamaEngine {
    // MARK: - Streaming Chat Completion (with template)

    /// Stream a chat completion through this row's prompt path.
    /// Takes raw messages (role + content) instead of a pre-formatted prompt.
    ///
    /// An artefact-declared template renders through the jinja engine, which is
    /// the only path that can pass `enable_thinking` and the only path that can
    /// split reasoning out of the reply. A row that declares a built-in family
    /// name keeps the heuristic formatter: those families exist upstream only as
    /// C++ builders, so there is no template string to hand the jinja engine.
    public func streamChatCompletion(
        messages: [(role: String, content: String)],
        addBos: Bool?,
        stopStrings: [String],
        sampling: SamplingConfigSwift
    ) throws -> AsyncThrowingStream<String, Error> {
        if let chatTemplates {
            guard let model else { throw LlamaError.modelNotLoaded }
            guard let session = LlamaChatSession(
                templates: chatTemplates,
                model: model,
                messages: messages,
                addGenerationPrompt: true,
                thinking: config.thinking
            ) else {
                throw LlamaError.chatTemplateUnrenderable
            }
            let prompt = session.prompt
            guard !prompt.isEmpty else { throw LlamaError.tokenizationFailed }
            logger.info("Jinja template applied prompt=\(prompt.count, privacy: .public) format=\(session.format, privacy: .public) thinking=\(self.config.thinking.rawValue, privacy: .public)")
            // The template's own stops are part of its contract: without them a
            // turn can run past the point the model meant to stop.
            return try streamCompletion(
                prompt: prompt,
                splitter: ReplySplitter(session: session),
                addBos: addBos,
                parseSpecial: true,
                stopStrings: Self.merging(stopStrings, with: session.stops),
                sampling: sampling
            )
        }

        // Declared built-in family template: heuristic formatter, no kwargs.
        let prompt = applyChatTemplate(
            messages: messages,
            model: model,
            addAssistant: true,
            templateName: config.chatTemplateName
        )
        guard !prompt.isEmpty else {
            throw LlamaError.tokenizationFailed
        }
        logger.info("Built-in template applied, prompt length: \(prompt.count, privacy: .public)")
        return try streamCompletion(
            prompt: prompt,
            addBos: addBos,
            parseSpecial: true,
            stopStrings: stopStrings,
            sampling: sampling
        )
    }

    /// Union of caller stops and template stops, first occurrence wins.
    /// Order matters only for which stop matches first; duplicates are free.
    static func merging(_ caller: [String], with template: [String]) -> [String] {
        guard !template.isEmpty else { return caller }
        var merged = caller
        for stop in template where !stop.isEmpty && !merged.contains(stop) {
            merged.append(stop)
        }
        return merged
    }

    // MARK: - Prompt path selection

    /// Whether this row can be prompted at all, and whether its declared thinking
    /// policy is honorable.
    ///
    /// Two refusals live here, and both are load-time on purpose:
    /// - an artefact with no template the runtime can render has no prompt path;
    ///   upstream's ChatML fallback is not the model's own syntax, so it does not
    ///   count as one;
    /// - a row that asks to switch reasoning off on a template that ignores
    ///   `enable_thinking` would reason forever, which is a blocked row.
    public func chatTemplateGate() -> ChatTemplateGate {
        templateGate(thinking: config.thinking)
    }

    /// Boolean shape of the gate, kept for callers that only need yes/no.
    public func hasUsableChatTemplate() -> Bool {
        chatTemplateGate() == .ready
    }

    /// The gate's decision, parameterised so the tests can drive every policy
    /// against one loaded engine.
    func templateGate(thinking: ChatThinkingPolicy) -> ChatTemplateGate {
        if let chatTemplates {
            guard chatTemplates.cameFromArtefact else { return .missing }
            if thinking.requiresTemplateSupport, !chatTemplates.supportsThinking {
                return .thinkingUnsupported
            }
            return .ready
        }
        // Declared built-in family template: the heuristic formatter renders it
        // but takes no kwargs, so no thinking policy can be honored.
        if thinking.requiresTemplateSupport { return .thinkingUnsupported }
        return hasHeuristicTemplate() ? .ready : .missing
    }

    /// Whether the declared built-in family renders at all. Only the named-
    /// template path reaches this; artefact templates are proven by the jinja
    /// branch of `templateGate`.
    private func hasHeuristicTemplate() -> Bool {
        guard let model else { return false }
        let rendered = applyChatTemplate(
            messages: [(role: "user", content: Self.preflightPrompt)],
            model: model,
            templateName: config.chatTemplateName
        )
        return !rendered.isEmpty
    }

    // MARK: - Split evidence

    /// One line of evidence that the split happened. The console capture in the
    /// verification lane reads it; reply text is never logged.
    static func logReasoning(
        _ splitter: ReplySplitter?,
        termination: String,
        logger: Logger
    ) {
        guard let splitter else { return }
        let reasoning = splitter.reasoningCharacters
        guard reasoning > 0 else { return }
        logger.info("Reply split reasoningCharacters=\(reasoning, privacy: .public) termination=\(termination, privacy: .public)")
    }
}
