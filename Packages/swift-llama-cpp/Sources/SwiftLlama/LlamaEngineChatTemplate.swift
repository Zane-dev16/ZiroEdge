// LlamaEngineChatTemplate.swift
// SwiftLlama — chat-template formatting for llama.cpp b12000
//
// Kept beside the engine, not inside it: template rendering is the app's
// only prompt path and is worth reading on its own.

import Foundation
import llama

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
