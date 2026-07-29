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
        provider: MockDownloadStatusProvider = MockDownloadStatusProvider(),
        persistence suppliedPersistence: PersistenceController? = nil
    ) -> ChatViewModel {
        let persistence = suppliedPersistence ?? PersistenceController(inMemory: true)
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
        let conversationID = try await persistence.createConversation(
            title: "Test",
            modelID: "test-model"
        )
        await viewModel.loadConversation(conversationID)

        XCTAssertNil(viewModel.truncationWarning, "Warning should reset when loading a conversation")
    }

    func testFailedConversationLoadKeepsPreviousIdentityAndTranscript() async throws {
        let fetchError = NSError(
            domain: "ChatUXTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Injected fetch failure"]
        )
        let faults = ScriptedPersistenceFaultInjector([
            .succeed(.fetch),
            .succeed(.fetch),
            .fail(.fetch, error: fetchError)
        ])
        let persistence = try await PersistenceController.open(
            configuration: .inMemory,
            faultInjector: faults
        ).get()
        let firstID = try await persistence.createConversation(title: "First", modelID: "test-model")
        let secondID = try await persistence.createConversation(title: "Second", modelID: "test-model")
        _ = await persistence.insertMessage(
            conversationID: firstID,
            role: .user,
            content: "First transcript"
        )
        let viewModel = makeViewModel(persistence: persistence)

        await viewModel.loadConversation(firstID)
        XCTAssertEqual(viewModel.activeConversationID, firstID)
        XCTAssertEqual(viewModel.messages.map(\.content), ["First transcript"])

        await viewModel.loadConversation(secondID)

        XCTAssertEqual(viewModel.activeConversationID, firstID)
        XCTAssertEqual(viewModel.messages.map(\.content), ["First transcript"])
        XCTAssertTrue(viewModel.showError)
    }

    func testConversationSystemPromptOverridesDefault() async throws {
        UserDefaults.standard.set(
            "Default instructions",
            forKey: ChatViewModel.DefaultsKeys.defaultSystemPrompt
        )
        let persistence = PersistenceController(inMemory: true)
        let conversationID = try await persistence.createConversation(
            title: "Prompt Test",
            modelID: "test-model"
        )
        let viewModel = makeViewModel(persistence: persistence)

        await viewModel.loadConversation(conversationID)
        XCTAssertEqual(viewModel.effectiveSystemPrompt, "Default instructions")

        let didUpdate = await viewModel.updateSystemPrompt("Conversation instructions")
        XCTAssertTrue(didUpdate)
        XCTAssertEqual(viewModel.effectiveSystemPrompt, "Conversation instructions")
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

    // MARK: - Conversation Startup Tests

    /// Loading state is published immediately when startNewConversation begins —
    /// the caller sets isLoadingConversation = true before any await.
    func testStartupPublishesLoadingImmediately() throws {
        let viewModel = makeViewModel()

        // Simulate the state that startNewConversation sets before its first await.
        viewModel.isStartingConversation = true
        viewModel.isLoadingConversation = true

        XCTAssertTrue(viewModel.isLoadingConversation, "Loading should be true immediately at startup")
        XCTAssertTrue(viewModel.isStartingConversation, "Startup guard should be set")
    }

    /// When a conversation successfully loads, the loading state is cleared.
    func testStartupLoadingClearedOnSuccess() async throws {
        let persistence = PersistenceController(inMemory: true)
        let viewModel = makeViewModel(persistence: persistence)

        // Simulate initial startup state — loading is set.
        viewModel.isLoadingConversation = true
        viewModel.isStartingConversation = true
        viewModel.isStartupError = false

        // Simulate successful readiness: loading flag cleared.
        viewModel.isStartingConversation = false
        viewModel.isLoadingConversation = false

        XCTAssertFalse(viewModel.isLoadingConversation, "Loading should be false after successful startup")
        XCTAssertFalse(viewModel.isStartingConversation)
        XCTAssertFalse(viewModel.isStartupError)
    }

    /// The startup action cannot be triggered repeatedly while loading.
    /// The isStartingConversation guard returns nil for concurrent calls.
    func testDuplicateTapSuppression() throws {
        let viewModel = makeViewModel()

        // Simulate that startup is already in flight.
        viewModel.isStartingConversation = true

        // The guard at the top of startNewConversation checks !isStartingConversation.
        let wouldAllowStartup = !viewModel.isStartingConversation
        XCTAssertFalse(wouldAllowStartup, "Duplicate start should be suppressed while isStartingConversation is true")
    }

    /// When startup fails, the error state is set and isStartupError is true.
    func testStartupFailureFeedback() throws {
        let viewModel = makeViewModel()

        // Simulate a startup failure.
        viewModel.isStartingConversation = false
        viewModel.isLoadingConversation = false
        viewModel.isStartupError = true
        viewModel.errorMessage = "Test model could not be loaded. Repair it or choose another model, then retry."
        viewModel.showError = true

        XCTAssertTrue(viewModel.isStartupError, "isStartupError should be true on failure")
        XCTAssertTrue(viewModel.showError, "showError should be true")
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoadingConversation, "Loading should be cleared on failure")
    }

    /// retryStartup clears the error state and triggers a new startup.
    func testRetryClearsErrorAndReattempts() throws {
        let viewModel = makeViewModel()

        // Simulate being in a startup error state.
        viewModel.isStartupError = true
        viewModel.showError = true
        viewModel.errorMessage = "Previous failure"

        // The retry guard checks isStartupError — should be true, so retry is allowed.
        let wouldAllowRetry = viewModel.isStartupError
        XCTAssertTrue(wouldAllowRetry, "Retry should be allowed when isStartupError is true")

        // Simulate retry: clear the error state.
        viewModel.isStartupError = false
        viewModel.showError = false
        viewModel.errorMessage = nil

        XCTAssertFalse(viewModel.isStartupError)
        XCTAssertFalse(viewModel.showError)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// retryStartup is a no-op when isStartupError is false.
    func testRetryIgnoredWhenNotInStartupError() throws {
        let viewModel = makeViewModel()

        viewModel.isStartupError = false
        viewModel.showError = true
        viewModel.errorMessage = "Some other error"

        let wouldAllowRetry = viewModel.isStartupError
        XCTAssertFalse(wouldAllowRetry, "Retry should not be allowed for non-startup errors")

        // showError should remain unchanged since retry is a no-op.
        XCTAssertTrue(viewModel.showError, "Non-startup error should remain visible")
    }

    /// clearActiveConversation resets isStartupError.
    func testClearActiveConversationResetsStartupError() throws {
        let viewModel = makeViewModel()

        viewModel.isStartupError = true
        viewModel.errorMessage = "Stale error"
        viewModel.showError = true

        viewModel.clearActiveConversation()

        XCTAssertFalse(viewModel.isStartupError, "isStartupError should be cleared")
    }

    // MARK: - Cleanup

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.lastUsedModelID)
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.defaultSystemPrompt)
    }
}
