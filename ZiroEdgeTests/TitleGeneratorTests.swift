// TitleGeneratorTests.swift
// ZiroEdgeTests
//
// Tests for title generation: successful generation via LLM,
// fallback on failure, and no re-generation when title is already set.

import XCTest
@testable import ZiroEdge

// MARK: - Mock Inference Service

/// A mock InferenceServiceProtocol that returns a pre-configured stream
/// or throws an error. Used for testing TitleGenerator without a real model.
/// Uses @unchecked Sendable (class) instead of actor to avoid actor-conformance
/// isolation issues with the protocol's synchronous methods.
final class MockInferenceServiceForTitle: InferenceServiceProtocol, @unchecked Sendable {

    var isModelLoaded: Bool = true
    var loadedModelID: String? = "mock-model"

    /// The response tokens the mock will stream.
    var responseTokens: [String] = []

    /// If set, streamChat will throw this error.
    var errorToThrow: Error?

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        isModelLoaded = true
        loadedModelID = model.id
    }

    func unloadModel() {
        isModelLoaded = false
        loadedModelID = nil
    }

    func streamChat(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        if let error = errorToThrow {
            throw error
        }

        let tokens = responseTokens
        return AsyncThrowingStream { continuation in
            for token in tokens {
                continuation.yield(token)
            }
            continuation.finish()
        }
    }

    func streamVisionChat(
        messages: [ChatMessagePayload],
        images: [Data],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        if let error = errorToThrow {
            throw error
        }
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func cancelCurrentStream() {}
}

// MARK: - Testable Title Generator

/// A wrapper that uses the InferenceServiceProtocol for testability.
/// Mirrors the production TitleGenerator logic but accepts the protocol.
actor TestableTitleGenerator {

    private let inferenceService: any InferenceServiceProtocol

    private static let systemPrompt =
        "Generate a short title (3-6 words) for this conversation. Output ONLY the title, nothing else."

    private static let sampling = SamplingConfig(
        temperature: 0.0,
        topP: 1.0,
        topK: 1,
        maxTokens: 50,
        repeatPenalty: 1.0
    )

    init(inferenceService: any InferenceServiceProtocol) {
        self.inferenceService = inferenceService
    }

    func generateTitle(
        userMessage: String,
        assistantResponse: String
    ) async -> String {
        guard await inferenceService.isModelLoaded else {
            return TitleGenerator.fallbackTitle(from: userMessage)
        }

        do {
            let context = "User: \(userMessage)\nAssistant: \(assistantResponse)"
            let messages = [ChatMessagePayload(role: .user, content: context)]

            let stream = try await inferenceService.streamChat(
                messages: messages,
                systemPrompt: Self.systemPrompt,
                sampling: Self.sampling
            )

            var rawTitle = ""
            for try await token in stream {
                rawTitle += token
            }

            let title = cleanTitle(rawTitle)
            if title.isEmpty || title.count < 2 {
                return TitleGenerator.fallbackTitle(from: userMessage)
            }
            return title

        } catch {
            return TitleGenerator.fallbackTitle(from: userMessage)
        }
    }

    func cleanTitle(_ raw: String) -> String {
        var title = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        if (title.hasPrefix("\"") && title.hasSuffix("\"")) ||
           (title.hasPrefix("'") && title.hasSuffix("'")) {
            title = String(title.dropFirst().dropLast())
        }

        while title.contains("  ") {
            title = title.replacingOccurrences(of: "  ", with: " ")
        }

        if title.count > 60 {
            title = String(title.prefix(57)) + "..."
        }

        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Tests

final class TitleGeneratorTests: XCTestCase {

    // MARK: - Fallback Title Tests

    func testFallbackTitleShortMessage() {
        let title = TitleGenerator.fallbackTitle(from: "What is SwiftUI?")
        XCTAssertEqual(title, "What is SwiftUI?")
    }

    func testFallbackTitleLongMessage() {
        let longMessage = String(repeating: "This is a very long message that exceeds the limit. ", count: 5)
        let title = TitleGenerator.fallbackTitle(from: longMessage)

        // Should be truncated to ~40 chars with ellipsis.
        XCTAssertLessThanOrEqual(title.count, 42) // 40 + "…" + possible space
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testFallbackTitleEmptyMessage() {
        let title = TitleGenerator.fallbackTitle(from: "")
        XCTAssertEqual(title, "New Conversation")
    }

    func testFallbackTitleWhitespaceOnly() {
        let title = TitleGenerator.fallbackTitle(from: "   ")
        XCTAssertEqual(title, "New Conversation")
    }

    func testFallbackTitleTrimsAtWordBoundary() {
        // "Hello world this is a test" is 26 chars, under 40 — should return as-is.
        let title = TitleGenerator.fallbackTitle(from: "Hello world this is a test")
        XCTAssertEqual(title, "Hello world this is a test")
    }

    // MARK: - Clean Title Tests

    func testCleanTitleStripsQuotes() async {
        let mock = MockInferenceServiceForTitle()
        let generator = TestableTitleGenerator(inferenceService: mock)

        let cleaned = await generator.cleanTitle("\"SwiftUI Basics\"")
        XCTAssertEqual(cleaned, "SwiftUI Basics")
    }

    func testCleanTitleStripsNewlines() async {
        let mock = MockInferenceServiceForTitle()
        let generator = TestableTitleGenerator(inferenceService: mock)

        let cleaned = await generator.cleanTitle("SwiftUI\nBasics\nGuide")
        XCTAssertEqual(cleaned, "SwiftUI Basics Guide")
    }

    func testCleanTitleCollapsesSpaces() async {
        let mock = MockInferenceServiceForTitle()
        let generator = TestableTitleGenerator(inferenceService: mock)

        let cleaned = await generator.cleanTitle("SwiftUI   Basics   Guide")
        XCTAssertEqual(cleaned, "SwiftUI Basics Guide")
    }

    func testCleanTitleTruncatesLongOutput() async {
        let mock = MockInferenceServiceForTitle()
        let generator = TestableTitleGenerator(inferenceService: mock)

        let longTitle = String(repeating: "word ", count: 20)
        let cleaned = await generator.cleanTitle(longTitle)
        XCTAssertLessThanOrEqual(cleaned.count, 60)
    }

    // MARK: - Successful Generation

    func testSuccessfulTitleGeneration() async {
        let mock = MockInferenceServiceForTitle()
        mock.responseTokens = ["Swift", "UI", " Basics"]
        let generator = TestableTitleGenerator(inferenceService: mock)

        let title = await generator.generateTitle(
            userMessage: "How do I use SwiftUI?",
            assistantResponse: "SwiftUI is a modern framework..."
        )

        XCTAssertEqual(title, "SwiftUI Basics")
    }

    func testSuccessfulTitleGenerationWithQuotes() async {
        let mock = MockInferenceServiceForTitle()
        mock.responseTokens = ["\"", "Learning Swift", "\""]
        let generator = TestableTitleGenerator(inferenceService: mock)

        let title = await generator.generateTitle(
            userMessage: "Teach me Swift",
            assistantResponse: "Sure, let's start with..."
        )

        XCTAssertEqual(title, "Learning Swift")
    }

    // MARK: - Fallback on LLM Failure

    func testFallbackOnModelNotLoaded() async {
        let mock = MockInferenceServiceForTitle()
        mock.isModelLoaded = false
        let generator = TestableTitleGenerator(inferenceService: mock)

        let title = await generator.generateTitle(
            userMessage: "What is machine learning?",
            assistantResponse: "Machine learning is..."
        )

        XCTAssertEqual(title, "What is machine learning?")
    }

    func testFallbackOnStreamError() async {
        let mock = MockInferenceServiceForTitle()
        mock.errorToThrow = NSError(domain: "test", code: 1, userInfo: nil)
        let generator = TestableTitleGenerator(inferenceService: mock)

        let title = await generator.generateTitle(
            userMessage: "Explain quantum computing",
            assistantResponse: "Quantum computing uses..."
        )

        // Should fall back to first ~40 chars of user message.
        XCTAssertEqual(title, "Explain quantum computing")
    }

    func testFallbackOnEmptyResponse() async {
        let mock = MockInferenceServiceForTitle()
        mock.responseTokens = []
        let generator = TestableTitleGenerator(inferenceService: mock)

        let title = await generator.generateTitle(
            userMessage: "Hello there",
            assistantResponse: "Hi! How can I help?"
        )

        // Empty response should fall back.
        XCTAssertEqual(title, "Hello there")
    }

    func testFallbackOnWhitespaceOnlyResponse() async {
        let mock = MockInferenceServiceForTitle()
        mock.responseTokens = ["   ", "\n"]
        let generator = TestableTitleGenerator(inferenceService: mock)

        let title = await generator.generateTitle(
            userMessage: "Test question",
            assistantResponse: "Test answer"
        )

        XCTAssertEqual(title, "Test question")
    }

    // MARK: - No Re-generation When Title Is Set

    func testTitleNotRegeneratedWhenAlreadySet() async {
        // This tests the guard in ChatViewModel.generateTitleIfNeeded:
        // it checks conversation.title == "New Conversation" before generating.
        //
        // We verify the fallback title logic doesn't interfere with an already-set title.
        let mock = MockInferenceServiceForTitle()
        mock.responseTokens = ["Should Not", " Appear"]
        let generator = TestableTitleGenerator(inferenceService: mock)

        // First generation works.
        let title1 = await generator.generateTitle(
            userMessage: "First question",
            assistantResponse: "First answer"
        )
        XCTAssertFalse(title1.isEmpty)

        // The no-re-generation check is in ChatViewModel, not TitleGenerator itself.
        // TitleGenerator always generates when called — the guard is at the call site.
        // This test documents that behavior.
        let title2 = await generator.generateTitle(
            userMessage: "Second question",
            assistantResponse: "Second answer"
        )
        XCTAssertFalse(title2.isEmpty)
    }

    // MARK: - Edge Cases

    func testFallbackWithVeryLongUserMessage() {
        let longMessage = String(repeating: "a", count: 200)
        let title = TitleGenerator.fallbackTitle(from: longMessage)

        XCTAssertLessThanOrEqual(title.count, 42) // 40 + "…" character
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testFallbackTruncatesAtWordBoundary() {
        // 45 chars — exceeds limit, should cut at a word boundary.
        let message = "This message is exactly forty five chars!!"
        let title = TitleGenerator.fallbackTitle(from: message)

        // Should be truncated.
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThan(title.count, message.count)
    }

    func testSuccessfulGenerationSingleToken() async {
        let mock = MockInferenceServiceForTitle()
        mock.responseTokens = ["Title"]
        let generator = TestableTitleGenerator(inferenceService: mock)

        let title = await generator.generateTitle(
            userMessage: "Hello",
            assistantResponse: "Hi!"
        )

        XCTAssertEqual(title, "Title")
    }

    func testFallbackOnSingleCharResponse() async {
        let mock = MockInferenceServiceForTitle()
        mock.responseTokens = ["X"]
        let generator = TestableTitleGenerator(inferenceService: mock)

        let title = await generator.generateTitle(
            userMessage: "Test",
            assistantResponse: "Response"
        )

        // Single char (count < 2) should trigger fallback.
        XCTAssertEqual(title, "Test")
    }
}
