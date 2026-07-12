// TitleGenerator.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Generates short conversation titles from the first user+assistant exchange.
// Uses the loaded model with greedy decoding for deterministic output.
// Falls back to the first ~40 characters of the user's message on failure.

import Foundation
import os

// MARK: - Title Generator Protocol

/// Protocol for title generation. Enables testability.
protocol TitleGeneratorProtocol: Sendable {
    func generateTitle(
        userMessage: String,
        assistantResponse: String
    ) async -> String
}

// MARK: - Title Generator

/// Generates short (3-6 word) conversation titles using the loaded LLM.
/// Runs greedily (temperature 0.0) for deterministic output.
actor TitleGenerator: TitleGeneratorProtocol {

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "title-gen")
    private let inferenceService: InferenceService

    /// System prompt that instructs the model to generate a short title.
    private static let systemPrompt =
        "Generate a short title (3-6 words) for this conversation. Output ONLY the title, nothing else."

    /// Sampling config for deterministic title generation.
    private static let sampling = SamplingConfig(
        temperature: 0.0,
        topP: 1.0,
        topK: 1,
        maxTokens: 50,
        repeatPenalty: 1.0
    )

    /// Maximum length for the fallback title (first N chars of user message).
    static let fallbackMaxLength = 40

    // MARK: - Initialization

    init(inferenceService: InferenceService) {
        self.inferenceService = inferenceService
    }

    // MARK: - Title Generation

    /// Generate a short title for a conversation based on the first exchange.
    ///
    /// - Parameters:
    ///   - userMessage: The user's first message.
    ///   - assistantResponse: The assistant's first response.
    /// - Returns: A 3-6 word title, or a fallback derived from the user message.
    func generateTitle(
        userMessage: String,
        assistantResponse: String
    ) async -> String {
        guard await inferenceService.isModelLoaded else {
            logger.warning("Model not loaded, using fallback title")
            return fallbackTitle(from: userMessage)
        }

        do {
            // Build the messages for the title generation prompt.
            let context = "User: \(userMessage)\nAssistant: \(assistantResponse)"
            let messages = [ChatMessagePayload(role: .user, content: context)]

            let stream = try await inferenceService.streamChat(
                messages: messages,
                systemPrompt: Self.systemPrompt,
                sampling: Self.sampling
            )

            // Collect the full response.
            var rawTitle = ""
            for try await token in stream {
                rawTitle += token
            }

            // Clean and validate the title.
            let title = cleanTitle(rawTitle)

            if title.isEmpty || title.count < 2 {
                logger.warning("LLM returned empty or too-short title, using fallback")
                return fallbackTitle(from: userMessage)
            }

            logger.info("Generated title: \(title, privacy: .public)")
            return title

        } catch {
            logger.error("Title generation failed: \(error.localizedDescription, privacy: .public)")
            return fallbackTitle(from: userMessage)
        }
    }

    // MARK: - Helpers

    /// Clean up raw LLM output into a usable title.
    /// Strips quotes, whitespace, newlines, and limits length.
    func cleanTitle(_ raw: String) -> String {
        var title = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        // Remove surrounding quotes if present.
        if (title.hasPrefix("\"") && title.hasSuffix("\"")) ||
           (title.hasPrefix("'") && title.hasSuffix("'")) {
            title = String(title.dropFirst().dropLast())
        }

        // Collapse multiple spaces.
        while title.contains("  ") {
            title = title.replacingOccurrences(of: "  ", with: " ")
        }

        // Truncate if unreasonably long (LLM might ignore the instruction).
        if title.count > 60 {
            title = String(title.prefix(57)) + "..."
        }

        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Generate a fallback title from the user's first message.
    /// Uses the first ~40 characters, truncated at a word boundary if possible.
    static func fallbackTitle(from userMessage: String) -> String {
        let trimmed = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "New Conversation"
        }

        if trimmed.count <= fallbackMaxLength {
            return trimmed
        }

        // Try to cut at a word boundary.
        let prefix = String(trimmed.prefix(fallbackMaxLength))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return prefix + "…"
    }

    /// Instance method wrapper for the static fallback (for protocol conformance).
    private func fallbackTitle(from userMessage: String) -> String {
        Self.fallbackTitle(from: userMessage)
    }
}
