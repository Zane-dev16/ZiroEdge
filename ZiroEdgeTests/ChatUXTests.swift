// ChatUXTests.swift
// ZiroEdgeTests
//
// Tests for chat UX features: thinking indicator state, truncation warnings,
// and token count tracking.

import XCTest
@testable import ZiroEdge

@MainActor
final class ChatUXTests: XCTestCase {

    // MARK: - Test Helpers

    private class MockDownloadStatusProvider: ModelDownloadStatusProvider {
        var readyModelIDs: Set<String> = []

        func status(for model: AIModel) -> ModelDownloadStatus {
            if readyModelIDs.contains(model.id) {
                return ModelDownloadStatus(baseState: .downloaded, mmprojState: nil)
            }
            return ModelDownloadStatus(baseState: .notDownloaded, mmprojState: nil)
        }
    }

    private func makeViewModel(
        provider: MockDownloadStatusProvider = MockDownloadStatusProvider()
    ) -> ChatViewModel {
        let persistence = PersistenceController(inMemory: true)
        let inferenceService = InferenceService()
        let memoryBudgeter = MemoryBudgeter()
        let lifecycleManager = ModelLifecycleManager(
            inferenceService: inferenceService,
            memoryBudgeter: memoryBudgeter
        )
        let sessionActor = ChatSessionActor(
            inferenceService: inferenceService,
            persistence: persistence
        )
        return ChatViewModel(
            persistence: persistence,
            inferenceService: inferenceService,
            sessionActor: sessionActor,
            lifecycleManager: lifecycleManager,
            downloadStatusProvider: provider
        )
    }

    // MARK: - Thinking Indicator State Tests

    /// When isStreaming is true and streamingText is empty, the thinking indicator should be visible.
    /// This corresponds to the state right after sendMessage() is called but before the first token arrives.
    func testThinkingIndicatorVisibleWhenStreamingWithEmptyText() throws {
        let viewModel = makeViewModel()

        // Simulate the state after sendMessage() but before first token.
        viewModel.isStreaming = true
        viewModel.streamingText = ""

        XCTAssertTrue(viewModel.isStreaming)
        XCTAssertTrue(viewModel.streamingText.isEmpty)

        // In ChatView, the condition is: isStreaming && streamingText.isEmpty
        let thinkingIndicatorVisible = viewModel.isStreaming && viewModel.streamingText.isEmpty
        XCTAssertTrue(thinkingIndicatorVisible, "Thinking indicator should be visible when streaming with empty text")
    }

    /// When the first token arrives, streamingText becomes non-empty and the thinking indicator should hide.
    func testThinkingIndicatorHiddenWhenFirstTokenArrives() throws {
        let viewModel = makeViewModel()

        // Start streaming.
        viewModel.isStreaming = true
        viewModel.streamingText = ""

        // Simulate first token arriving.
        viewModel.streamingText = "H"

        // The streaming bubble should now be visible instead of thinking indicator.
        let thinkingIndicatorVisible = viewModel.isStreaming && viewModel.streamingText.isEmpty
        let streamingBubbleVisible = viewModel.isStreaming && !viewModel.streamingText.isEmpty
        XCTAssertFalse(thinkingIndicatorVisible, "Thinking indicator should hide when first token arrives")
        XCTAssertTrue(streamingBubbleVisible, "Streaming bubble should be visible when text is non-empty")
    }

    /// When streaming ends, neither thinking indicator nor streaming bubble should be visible.
    func testThinkingIndicatorHiddenWhenStreamingEnds() throws {
        let viewModel = makeViewModel()

        viewModel.isStreaming = true
        viewModel.streamingText = "Hello, world!"

        // Simulate stream completion.
        viewModel.isStreaming = false
        viewModel.streamingText = ""

        let thinkingIndicatorVisible = viewModel.isStreaming && viewModel.streamingText.isEmpty
        XCTAssertFalse(thinkingIndicatorVisible, "Thinking indicator should not be visible when not streaming")
    }

    // MARK: - Truncation Warning Tests

    /// Truncation warning starts as nil.
    func testTruncationWarningStartsNil() throws {
        let viewModel = makeViewModel()
        XCTAssertNil(viewModel.truncationWarning, "Truncation warning should start as nil")
    }

    /// notifyTruncation sets the warning message.
    func testNotifyTruncationSetsWarning() throws {
        let viewModel = makeViewModel()

        viewModel.notifyTruncation(messageCount: 3)

        XCTAssertNotNil(viewModel.truncationWarning)
        XCTAssertTrue(viewModel.truncationWarning!.contains("3"))
        XCTAssertTrue(viewModel.truncationWarning!.contains("removed"))
    }

    /// notifyTruncation uses singular form for one message.
    func testNotifyTruncationSingularMessage() throws {
        let viewModel = makeViewModel()

        viewModel.notifyTruncation(messageCount: 1)

        XCTAssertNotNil(viewModel.truncationWarning)
        XCTAssertTrue(viewModel.truncationWarning!.contains("was removed"))
    }

    /// notifyTruncation uses plural form for multiple messages.
    func testNotifyTruncationPluralMessages() throws {
        let viewModel = makeViewModel()

        viewModel.notifyTruncation(messageCount: 5)

        XCTAssertNotNil(viewModel.truncationWarning)
        XCTAssertTrue(viewModel.truncationWarning!.contains("were removed"))
    }

    /// dismissTruncationWarning clears the warning.
    func testDismissTruncationWarningClearsWarning() throws {
        let viewModel = makeViewModel()

        viewModel.notifyTruncation(messageCount: 2)
        XCTAssertNotNil(viewModel.truncationWarning)

        viewModel.dismissTruncationWarning()
        XCTAssertNil(viewModel.truncationWarning, "Warning should be nil after dismissal")
    }

    /// Truncation warning resets on loadConversation.
    func testTruncationWarningResetsOnLoadConversation() async throws {
        let viewModel = makeViewModel()

        viewModel.notifyTruncation(messageCount: 3)
        XCTAssertNotNil(viewModel.truncationWarning)

        let persistence = PersistenceController(inMemory: true)
        let conversationID = await persistence.createConversation(
            title: "Test",
            modelID: "test-model"
        )
        await viewModel.loadConversation(conversationID)

        XCTAssertNil(viewModel.truncationWarning, "Warning should reset when loading a conversation")
    }

    // MARK: - Token Count Tests

    /// Token count starts at 0.
    func testTokenCountStartsAtZero() throws {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.tokenCount, 0, "Token count should start at 0")
    }

    /// Token count increments when tokens are received.
    func testTokenCountIncrementsOnToken() throws {
        let viewModel = makeViewModel()

        // Simulate the token callback behavior from sendMessage.
        viewModel.tokenCount += 1
        viewModel.tokenCount += 1
        viewModel.tokenCount += 1

        XCTAssertEqual(viewModel.tokenCount, 3, "Token count should be 3 after 3 increments")
    }

    /// resetTokenCount resets the count to 0.
    func testResetTokenCount() throws {
        let viewModel = makeViewModel()

        viewModel.tokenCount = 42
        XCTAssertEqual(viewModel.tokenCount, 42)

        viewModel.resetTokenCount()
        XCTAssertEqual(viewModel.tokenCount, 0, "Token count should be 0 after reset")
    }

    /// Context window size is set to the expected default.
    func testContextWindowSizeDefault() throws {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.contextWindowSize, 4096, "Context window size should default to 4096")
    }

    // MARK: - Cleanup

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "lastUsedModelID")
    }
}
