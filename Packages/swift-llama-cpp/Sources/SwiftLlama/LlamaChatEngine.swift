// LlamaChatEngine.swift
// SwiftLlama — jinja chat templates and reply parsing
//
// `llama_chat_apply_template` (the C API) is a heuristic formatter over a fixed
// template list: no kwargs, so no `enable_thinking`, and no reasoning split.
// Upstream's real engine is `common/chat.cpp` (minja + the PEG reply parsers),
// which the pinned runtime now links in. This file is the only Swift surface
// over it: two owned handles, no formatting logic.
//
// Ownership rules that matter here:
//   - `LlamaChatTemplates` must outlive every session created from it.
//   - A session borrows its strings from the native handle; read `content` and
//     `reasoning` immediately, never store the returned `String`'s source.

import Foundation
import llama

// MARK: - Templates

/// A parsed chat template set: the model's embedded `tokenizer.chat_template`.
///
/// Nil at construction means the GGUF carries no template minja can parse. That
/// is a refusal, not a reason to fall back to a heuristic formatter — the caller
/// reports it as `chat-template-missing`.
final class LlamaChatTemplates {
    fileprivate let handle: OpaquePointer

    init?(model: OpaquePointer) {
        guard let handle = ziro_chat_templates_create(model) else { return nil }
        self.handle = handle
    }

    deinit {
        ziro_chat_templates_destroy(handle)
    }

    /// Whether the template reads `enable_thinking`. A row that asks for a
    /// thinking policy on a template that ignores it is unblockable.
    var supportsThinking: Bool {
        ziro_chat_templates_supports_thinking(handle) != 0
    }

    /// Whether the template came from the GGUF rather than upstream's ChatML
    /// fallback. A fallback is not the model's own syntax, so it never counts
    /// as a usable template.
    var cameFromArtefact: Bool {
        ziro_chat_templates_was_explicit(handle) != 0
    }

    /// The template source, for diagnostics only.
    var source: String {
        String(cString: ziro_chat_templates_source(handle))
    }
}

// MARK: - Session

/// One rendered prompt plus the reply parser that matches it.
///
/// Feed generated text as it decodes; `content` and `reasoning` are the
/// runtime's own split of the reply. Reasoning is never part of `content`, so a
/// caller that shows only `content` never renders `<think>` markup.
final class LlamaChatSession {
    fileprivate let handle: OpaquePointer

    init?(
        templates: LlamaChatTemplates,
        model: OpaquePointer,
        messages: [(role: String, content: String)],
        addGenerationPrompt: Bool,
        thinking: ChatThinkingPolicy
    ) {
        // Native call borrows these for its duration only.
        var owned: [UnsafeMutablePointer<CChar>] = []
        owned.reserveCapacity(messages.count * 2)
        for message in messages {
            guard let role = strdup(message.role),
                  let content = strdup(message.content) else {
                owned.forEach { free($0) }
                return nil
            }
            owned.append(role)
            owned.append(content)
        }
        defer { owned.forEach { free($0) } }

        var turns: [ziro_chat_turn] = []
        turns.reserveCapacity(messages.count)
        for index in messages.indices {
            turns.append(
                ziro_chat_turn(
                    role: UnsafePointer(owned[index * 2]),
                    content: UnsafePointer(owned[index * 2 + 1])
                )
            )
        }

        let created = turns.withUnsafeBufferPointer { buffer in
            ziro_chat_session_create(
                templates.handle,
                model,
                buffer.baseAddress,
                buffer.count,
                addGenerationPrompt ? 1 : 0,
                thinking.nativeValue
            )
        }
        guard let created else { return nil }
        handle = created
    }

    deinit {
        ziro_chat_session_destroy(handle)
    }

    /// The rendered prompt, ready for tokenization.
    var prompt: String {
        String(cString: ziro_chat_session_prompt(handle))
    }

    /// Stops the template itself declares for this prompt. Adding them is what
    /// makes a turn end where the template says it should.
    var stops: [String] {
        let count = ziro_chat_session_stop_count(handle)
        guard count > 0 else { return [] }
        return (0..<count).map { String(cString: ziro_chat_session_stop(handle, $0)) }
    }

    /// Parser family name, for diagnostics only.
    var format: String {
        String(cString: ziro_chat_session_format(handle))
    }

    /// Append one decoded piece and re-parse. False when the parser threw, in
    /// which case the caller must stop trusting `content` and emit raw text.
    @discardableResult
    func feed(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        return text.withCString { pointer in
            ziro_chat_session_feed(handle, pointer, text.utf8.count)
        } == 0
    }

    /// Close the reply so a trailing open block is resolved.
    @discardableResult
    func finish() -> Bool {
        ziro_chat_session_finish(handle, nil, 0) == 0
    }

    /// Reply body with reasoning removed.
    var content: String {
        String(cString: ziro_chat_session_content(handle))
    }

    /// The reasoning the model produced, split out by the parser.
    var reasoning: String {
        String(cString: ziro_chat_session_reasoning(handle))
    }
}

// MARK: - Reply Splitting

/// Turns raw decoded text into visible content, using the runtime's own reply
/// parser instead of slicing markup out of the reply.
///
/// The parser reports `content` and `reasoning_content` separately, so a caller
/// that only ever emits `content` never renders a thinking block. While the model
/// is still reasoning the visible delta is legitimately empty — the chat surface
/// already reads that as "still thinking" and keeps its indicator up.
///
/// If the parser throws, the splitter degrades to raw text rather than losing the
/// reply: a broken parser must not swallow an answer.
final class ReplySplitter {
    private let session: LlamaChatSession
    private var emittedBytes = 0
    private var parserFailed = false

    /// Reasoning the parser attributed to the model. Read after `finish()`.
    private(set) var reasoningCharacters = 0

    init(session: LlamaChatSession) {
        self.session = session
    }

    /// Feed one decoded piece; returns the newly visible content, if any.
    func append(_ raw: String) -> String? {
        guard !parserFailed else { return raw }
        guard session.feed(raw) else {
            parserFailed = true
            return raw
        }
        return drain()
    }

    /// Close the reply and return any trailing visible content.
    func finish() -> String? {
        guard !parserFailed else { return nil }
        _ = session.finish()
        reasoningCharacters = session.reasoning.count
        return drain()
    }

    /// New bytes of `content` since the last call. The parser's output is
    /// append-only, so a byte-offset prefix is exact even mid-grapheme.
    private func drain() -> String? {
        let content = session.content
        let total = content.utf8.count
        guard total > emittedBytes else { return nil }
        let delta = String(decoding: content.utf8.dropFirst(emittedBytes), as: UTF8.self)
        emittedBytes = total
        return delta
    }
}
