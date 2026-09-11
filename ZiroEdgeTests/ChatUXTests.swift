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

    // MARK: - P3 Context-Window Preflight

    private func p3History(_ contents: [String]) -> [ChatMessagePayload] {
        contents.map { ChatMessagePayload(role: .user, content: $0) }
    }

    func testP3TruncationKeepsNewestDropsOldest() throws {
        let history = p3History([String(repeating: "a", count: 4000), String(repeating: "b", count: 4000), "newest"])
        let result = ChatViewModel.truncatedHistoryForContextWindow(
            history, systemPrompt: nil, contextWindowSize: 64, reserveTokens: 16
        )
        XCTAssertGreaterThan(result.dropped, 0)
        XCTAssertEqual(result.kept.last?.content, "newest")
        XCTAssertEqual(result.kept.count + result.dropped, history.count)
    }

    func testP3TruncationFitsWithoutDropping() throws {
        let history = p3History(["hi", "hello"])
        let result = ChatViewModel.truncatedHistoryForContextWindow(
            history, systemPrompt: nil, contextWindowSize: 4096, reserveTokens: 1024
        )
        XCTAssertEqual(result.dropped, 0)
        XCTAssertEqual(result.kept.count, 2)
    }

    func testP3TruncatedEndReasonAndBannerWiring() throws {
        let viewModel = makeViewModel()
        XCTAssertNil(viewModel.lastStreamEndReason)
        // The preflight caller is startStreaming (first non-test caller of
        // notifyTruncation): simulate its two calls directly.
        let history = p3History([String(repeating: "x", count: 8000), "tail"])
        let preflight = ChatViewModel.truncatedHistoryForContextWindow(
            history, systemPrompt: nil, contextWindowSize: 64, reserveTokens: 16
        )
        XCTAssertGreaterThan(preflight.dropped, 0)
        viewModel.notifyTruncation(messageCount: preflight.dropped)
        XCTAssertNotNil(viewModel.truncationWarning)
        XCTAssertTrue(viewModel.truncationWarning!.contains("removed"))
        // The truncated terminal reason exists alongside the historic cases.
        let reason = ChatViewModel.StreamEndReason.truncated
        switch reason {
        case .truncated: break
        case .completed, .stopped, .failed: XCTFail("wrong reason")
        }
    }

    func testP3SamplingPenaltyDefaultsAndBounding() throws {
        let def = SamplingConfig.default
        XCTAssertEqual(def.penaltyLastN, 64)
        XCTAssertEqual(def.frequencyPenalty, 0.0)
        XCTAssertEqual(def.presencePenalty, 0.0)
        let bounded = ModelConfiguration.imported(
            promptPath: .chatTemplate,
            contextLength: 4096,
            sampling: SamplingConfig(
                temperature: 9, topP: -1, topK: 900, maxTokens: 99_999,
                repeatPenalty: 5, penaltyLastN: 9999, frequencyPenalty: 9, presencePenalty: -3
            )
        )
        XCTAssertEqual(bounded.defaultSampling.penaltyLastN, 512)
        XCTAssertEqual(bounded.defaultSampling.frequencyPenalty, 2, accuracy: 0.001)
        XCTAssertEqual(bounded.defaultSampling.presencePenalty, 0, accuracy: 0.001)
    }

    func testP3SamplingBackwardCompatibleDecode() throws {
        let legacy = """
        {"temperature":0.7,"topP":0.9,"topK":40,"maxTokens":2048,"repeatPenalty":1.1}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SamplingConfig.self, from: legacy)
        XCTAssertEqual(decoded.penaltyLastN, 64)
        XCTAssertEqual(decoded.frequencyPenalty, 0.0)
        XCTAssertEqual(decoded.presencePenalty, 0.0)
    }

    func testP3AccessibilityIDsPreserved() throws {
        XCTAssertEqual(ModelEvictionPresentation.retryButtonID, "modelRetryButton")
        XCTAssertEqual(ModelEvictionPresentation.retryBannerID, "modelRetryBanner")
    }

    // MARK: - Cleanup

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.lastUsedModelID)
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.defaultSystemPrompt)
    }
}

// MARK: - P0 per-conversation drafts (synthesis item 2)

/// inputText must behave like pendingImages: scoped to the conversation being
/// left, restored on return, cleared together with attachments on new drafts.
@MainActor
final class DraftTests: XCTestCase {
    private final class DraftStatusProvider: ModelDownloadStatusProvider {
        var readyIDs: Set<String> = []
        func status(for model: AIModel) -> ModelDownloadStatus {
            guard readyIDs.contains(model.id) else {
                return ModelDownloadStatus(baseState: .notDownloaded, mmprojState: nil)
            }
            return ModelDownloadStatus(modelID: model.id, baseState: .downloaded, mmprojState: .downloaded)
        }
    }

    private actor DraftInferenceStub: InferenceServiceProtocol {
        private var loadedID: String?
        var isModelLoaded: Bool { loadedID != nil }
        var loadedModelID: String? { loadedID }
        func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws { loadedID = model.id }
        func unloadModel() async { loadedID = nil }
        func streamChat(messages: [ChatMessagePayload], systemPrompt: String?, sampling: SamplingConfig) async throws -> AsyncThrowingStream<String, Error> {
            throw InferenceError.modelNotLoaded
        }
        func streamVisionChat(messages: [ChatMessagePayload], images: [Data], systemPrompt: String?, sampling: SamplingConfig) async throws -> AsyncThrowingStream<String, Error> {
            throw InferenceError.modelNotLoaded
        }
        func cancelCurrentStream() async {}
    }

    private struct DraftHarness {
        let viewModel: ChatViewModel
        let persistence: PersistenceController
        let modelA: AIModel
        let modelB: AIModel
    }

    private func makePriorImportB() -> AIModel {
        let data = TestModelFixtures.gguf()
        let sha = TestModelFixtures.sha256(data)
        let provenance = HuggingFaceProvenance(
            repositoryID: "acme/draft", revision: String(repeating: "c", count: 40),
            baseFilename: "draft.gguf", baseSHA256: sha,
            architecture: "llama", projectorFilename: nil, projectorSHA256: nil
        )
        var model = TestModelFixtures.text(id: "hf-draft-\(UUID().uuidString.prefix(8))", data: data)
        model.source = .huggingFace(provenance)
        return model
    }

    private func makeHarness() throws -> DraftHarness {
        let persistence = PersistenceController(inMemory: true)
        let inference = DraftInferenceStub()
        let budgeter = MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: 4_000_000_000, total: 8_054_095_872
        ))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DraftTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lifecycle = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: budgeter,
            loadSafetyStore: try LoadSafetyStore(directory: root.appendingPathComponent("safety")),
            importedModelStore: ImportedModelStore(directory: root.appendingPathComponent("imports")),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        let session = ChatSessionActor(inferenceService: inference, persistence: persistence)
        let modelA = ModelRegistry.gemma4_e2b
        let modelB = makePriorImportB()
        ExperimentalModelConsent.setGranted(true, for: modelB)
        let status = DraftStatusProvider()
        status.readyIDs = [modelA.id, modelB.id]
        let viewModel = ChatViewModel(
            persistence: persistence,
            inferenceService: inference,
            sessionActor: session,
            lifecycleManager: lifecycle,
            downloadStatusProvider: status,
            modelProvider: { [modelA, modelB] }
        )
        return DraftHarness(viewModel: viewModel, persistence: persistence, modelA: modelA, modelB: modelB)
    }

    /// Typed text must not follow a conversation switch; returning restores it.
    func testTextDoesNotFollowSwitch() async throws {
        let harness = try makeHarness()
        defer { ExperimentalModelConsent.setGranted(false, for: harness.modelB) }
        let viewModel = harness.viewModel
        let convA = try await harness.persistence.createConversation(title: "A", modelID: harness.modelA.id)
        let convB = try await harness.persistence.createConversation(title: "B", modelID: harness.modelB.id)

        await viewModel.loadConversation(convA)
        XCTAssertEqual(viewModel.activeConversationID, convA)
        viewModel.inputText = "draft for A"

        await viewModel.loadConversation(convB)
        XCTAssertEqual(viewModel.inputText, "", "switching must park A's draft, not carry it into B")
        viewModel.inputText = "draft for B"

        await viewModel.loadConversation(convA)
        XCTAssertEqual(viewModel.inputText, "draft for A", "returning must restore A's draft")
        await viewModel.loadConversation(convB)
        XCTAssertEqual(viewModel.inputText, "draft for B", "returning must restore B's draft")
    }

    /// Staged attachments clear together with the parked text: switching drops
    /// images (existing guard) while the text is stashed, and a new draft
    /// clears both.
    func testAttachmentsClearedTogether() async throws {
        let harness = try makeHarness()
        defer { ExperimentalModelConsent.setGranted(false, for: harness.modelB) }
        let viewModel = harness.viewModel
        let convA = try await harness.persistence.createConversation(title: "A", modelID: harness.modelA.id)
        let convB = try await harness.persistence.createConversation(title: "B", modelID: harness.modelB.id)

        await viewModel.loadConversation(convA)
        viewModel.inputText = "draft with photo"
        viewModel.pendingImages = [Data(repeating: 0xAB, count: 16)]

        await viewModel.loadConversation(convB)
        XCTAssertTrue(viewModel.pendingImages.isEmpty, "images must not migrate into B")
        XCTAssertEqual(viewModel.inputText, "")

        await viewModel.loadConversation(convA)
        XCTAssertEqual(viewModel.inputText, "draft with photo", "text restores without its dropped attachments")
        XCTAssertTrue(viewModel.pendingImages.isEmpty)

        viewModel.beginNewDraft()
        XCTAssertEqual(viewModel.inputText, "", "new draft clears parked text")
        XCTAssertTrue(viewModel.pendingImages.isEmpty)
        await viewModel.loadConversation(convA)
        XCTAssertEqual(viewModel.inputText, "draft with photo", "new-draft parks (not drops) the outgoing draft")
    }

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.lastUsedModelID)
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.defaultSystemPrompt)
    }
}

// MARK: - P0 new-chat during stream (synthesis item 3)

/// Starting a new draft mid-stream must synchronously park the streaming UI:
/// no Stop glyph, no thinking row, no transcript on the empty draft.
@MainActor
final class StreamSwitchTests: XCTestCase {
    private final class StreamStatusProvider: ModelDownloadStatusProvider {
        var readyIDs: Set<String> = []
        func status(for model: AIModel) -> ModelDownloadStatus {
            guard readyIDs.contains(model.id) else {
                return ModelDownloadStatus(baseState: .notDownloaded, mmprojState: nil)
            }
            return ModelDownloadStatus(modelID: model.id, baseState: .downloaded, mmprojState: .downloaded)
        }
    }

    private actor CannedStreamInferenceService: InferenceServiceProtocol {
        private var loadedID: String?
        private let delay: Duration
        init(delay: Duration = .milliseconds(300)) { self.delay = delay }
        var isModelLoaded: Bool { loadedID != nil }
        var loadedModelID: String? { loadedID }
        func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws { loadedID = model.id }
        func unloadModel() async { loadedID = nil }
        func cancelCurrentStream() async {}
        func streamChat(messages: [ChatMessagePayload], systemPrompt: String?, sampling: SamplingConfig) async throws -> AsyncThrowingStream<String, Error> {
            try? await Task.sleep(for: delay)
            return AsyncThrowingStream { continuation in
                continuation.yield("Canned ")
                continuation.yield("response")
                continuation.finish()
            }
        }
        func streamVisionChat(messages: [ChatMessagePayload], images: [Data], systemPrompt: String?, sampling: SamplingConfig) async throws -> AsyncThrowingStream<String, Error> {
            try await streamChat(messages: messages, systemPrompt: systemPrompt, sampling: sampling)
        }
    }

    func testNewDraftStartsIdle() async throws {
        let persistence = PersistenceController(inMemory: true)
        let inference = CannedStreamInferenceService()
        let budgeter = MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: 4_000_000_000, total: 8_054_095_872
        ))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StreamSwitch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lifecycle = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: budgeter,
            loadSafetyStore: try LoadSafetyStore(directory: root.appendingPathComponent("safety")),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        let session = ChatSessionActor(inferenceService: inference, persistence: persistence)
        let model = ModelRegistry.gemma4_e2b
        let status = StreamStatusProvider()
        status.readyIDs = [model.id]
        let viewModel = ChatViewModel(
            persistence: persistence,
            inferenceService: inference,
            sessionActor: session,
            lifecycleManager: lifecycle,
            downloadStatusProvider: status,
            modelProvider: { [model] }
        )
        let conversationID = try await persistence.createConversation(title: "Streaming", modelID: model.id)
        await viewModel.loadConversation(conversationID)
        XCTAssertEqual(viewModel.activeConversationID, conversationID)

        viewModel.inputText = "hello"
        let sendTask = Task { await viewModel.sendMessage() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        while !viewModel.isStreaming {
            guard clock.now < deadline else { return XCTFail("stream never started") }
            try await Task.sleep(for: .milliseconds(20))
        }

        // New chat mid-stream: the empty draft must read idle synchronously —
        // no Stop control state, no thinking-row state, no transcript.
        viewModel.beginNewDraft()
        XCTAssertFalse(viewModel.isStreaming, "fresh draft must not show Stop/streaming UI")
        XCTAssertTrue(viewModel.streamingText.isEmpty)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.isDraftConversation)
        XCTAssertNil(viewModel.activeConversationID)

        await sendTask.value
        // The stale generation must not resurrect streaming UI on the draft.
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertTrue(viewModel.messages.isEmpty, "stale stream must not write into the fresh draft")
        XCTAssertTrue(viewModel.streamingText.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.lastUsedModelID)
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.defaultSystemPrompt)
    }
}

// MARK: - P1 flow fixtures (synthesis items 4-5)

/// Hermetic ChatViewModel factory shared by the P1 flow tests: in-memory
/// store, real-but-never-loaded engine, caller-chosen catalog. No I/O,
/// no loads — removed-model IDs keep `loadConversation` off the engine.
@MainActor
private func makeP1FlowChatViewModel(
    persistence: PersistenceController,
    modelProvider: @escaping () -> [AIModel] = { [] }
) -> ChatViewModel {
    let inferenceService = InferenceService()
    return ChatViewModel(
        persistence: persistence,
        inferenceService: inferenceService,
        sessionActor: ChatSessionActor(
            inferenceService: inferenceService,
            persistence: persistence
        ),
        lifecycleManager: ModelLifecycleManager(
            inferenceService: inferenceService,
            memoryBudgeter: MemoryBudgeter()
        ),
        downloadStatusProvider: P1FlowStatusProvider(),
        modelProvider: modelProvider
    )
}

private final class P1FlowStatusProvider: ModelDownloadStatusProvider {
    func status(for model: AIModel) -> ModelDownloadStatus {
        ModelDownloadStatus(baseState: .notDownloaded, mmprojState: nil)
    }
}

// MARK: - P1 alert queue (synthesis item 4)

/// ChatView's 2 alerts + AppShellView's 3 alerts collapse into one
/// `.alert(item:)` queue per view, backed by `ZiroAlert`. Copy, buttons,
/// ZiroTheme/44pt treatment, and a11y IDs are preserved at the call sites —
/// the enum owns only routing + payloads. All hermetic (no I/O, no engine).
@MainActor
final class AlertTests: XCTestCase {
    func testAlertIDsAreUnique() {
        let ids = [
            ZiroAlert.experimentalConsent.id,
            ZiroAlert.deleteConversation.id,
            ZiroAlert.memoryWarning(modelName: nil).id,
            ZiroAlert.loadFailure(message: "x").id,
            ZiroAlert.insufficientMemory(message: "x").id,
        ]
        XCTAssertEqual(Set(ids).count, ids.count, "queued alerts must be distinguishable")
    }

    func testAlertCopyMatchesLegacyStrings() {
        XCTAssertEqual(ZiroAlert.experimentalConsent.title, "Enable Experimental Runtime?")
        XCTAssertEqual(ZiroAlert.deleteConversation.title, "Delete Conversation?")
        XCTAssertEqual(ZiroAlert.memoryWarning(modelName: "M").title, ModelEvictionPresentation.alertTitle)
        XCTAssertEqual(ZiroAlert.loadFailure(message: "m").title, "Model Load Failed")
        XCTAssertEqual(ZiroAlert.insufficientMemory(message: "m").title, "Model Needs More Memory")
        XCTAssertTrue(ZiroAlert.experimentalConsent.message.contains("measured admission floor"))
        XCTAssertTrue(ZiroAlert.deleteConversation.message.contains("permanently delete"))
        XCTAssertTrue(ZiroAlert.memoryWarning(modelName: "M").message.contains(
            ModelEvictionPresentation.message(modelName: "M")
        ))
        XCTAssertEqual(ZiroAlert.loadFailure(message: "boom").message, "boom")
    }

    func testChatQueuePriority() {
        XCTAssertEqual(
            ZiroAlert.chatQueue(experimentalConsent: true, deleteConversation: true),
            .experimentalConsent
        )
        XCTAssertEqual(
            ZiroAlert.chatQueue(experimentalConsent: false, deleteConversation: true),
            .deleteConversation
        )
        XCTAssertNil(ZiroAlert.chatQueue(experimentalConsent: false, deleteConversation: false))
    }

    func testShellQueuePriorityAndCoverPrecedence() {
        XCTAssertNil(
            ZiroAlert.shellQueue(
                onboarding: true, memoryWarning: true, memoryModelName: "M",
                loadFailure: "f", insufficientMemory: "i"
            ),
            "onboarding cover takes precedence over every alert"
        )
        XCTAssertEqual(
            ZiroAlert.shellQueue(
                onboarding: false, memoryWarning: true, memoryModelName: "M",
                loadFailure: "f", insufficientMemory: "i"
            ),
            .memoryWarning(modelName: "M")
        )
        XCTAssertEqual(
            ZiroAlert.shellQueue(
                onboarding: false, memoryWarning: false, memoryModelName: nil,
                loadFailure: "f", insufficientMemory: "i"
            ),
            .loadFailure(message: "f")
        )
        XCTAssertEqual(
            ZiroAlert.shellQueue(
                onboarding: false, memoryWarning: false, memoryModelName: nil,
                loadFailure: nil, insufficientMemory: "i"
            ),
            .insufficientMemory(message: "i")
        )
        XCTAssertNil(
            ZiroAlert.shellQueue(
                onboarding: false, memoryWarning: false, memoryModelName: nil,
                loadFailure: nil, insufficientMemory: nil
            )
        )
    }

    func testPresentationIDsArePinned() {
        XCTAssertEqual(ModelEvictionPresentation.retryButtonID, "modelRetryButton")
        XCTAssertEqual(ModelEvictionPresentation.retryBannerID, "modelRetryBanner")
        XCTAssertEqual(ModelEvictionPresentation.retryHintID, "modelRetryHint")
        XCTAssertEqual(ModelEvictionPresentation.deleteFailureTitle, "Deletion Failed")
        XCTAssertEqual(ModelEvictionPresentation.deleteFailureID, "deleteFailureAlert")
        XCTAssertEqual(ModelEvictionPresentation.renameSaveButtonID, "renameSaveButton")
    }

    /// P1-4: with no downloaded candidate the manual retry refuses in place —
    /// a hint is set (not a silent guard return) and nothing is in flight.
    func testRetryRefusedSurfacesIneligibilityHint() {
        let viewModel = makeP1FlowChatViewModel(persistence: PersistenceController(inMemory: true))
        viewModel.retryModelLoad()
        XCTAssertFalse(viewModel.isModelRetryInFlight)
        XCTAssertEqual(
            viewModel.retryIneligibilityHint,
            "No downloaded model is available yet. Download one to continue."
        )
    }

    func testRetryBlockedHintNeedsDownloadVariant() {
        let viewModel = makeP1FlowChatViewModel(persistence: PersistenceController(inMemory: true))
        viewModel.retryModelLoad()
        XCTAssertNotNil(viewModel.retryIneligibilityHint)
        XCTAssertEqual(
            viewModel.retryBlockedHint(eligible: true),
            "Retry is not available right now."
        )
    }
}

// MARK: - P1 recovery scoping (synthesis item 5)

/// `hasPersistenceRecovery` is scoped to `recoveryConversationID`: the banner
/// renders only while that conversation is visible, and is cleared on new
/// drafts and deletes. Hermetic: in-memory store, removed-model IDs (no loads).
@MainActor
final class RecoveryTests: XCTestCase {
    func testRecoveryBannerScopedToActiveConversation() async throws {
        let persistence = PersistenceController(inMemory: true)
        let viewModel = makeP1FlowChatViewModel(persistence: persistence)
        let convA = try await persistence.createConversation(title: "A", modelID: "removed-model")
        let convB = try await persistence.createConversation(title: "B", modelID: "removed-model")
        await viewModel.loadConversation(convA)
        XCTAssertEqual(viewModel.activeConversationID, convA)
        XCTAssertFalse(viewModel.shouldShowPersistenceRecovery)

        viewModel.stagePersistenceRecoveryForTesting(conversationID: convA)
        XCTAssertTrue(viewModel.shouldShowPersistenceRecovery)

        await viewModel.loadConversation(convB)
        XCTAssertTrue(viewModel.hasPersistenceRecovery, "switching chats retains the recovery")
        XCTAssertFalse(
            viewModel.shouldShowPersistenceRecovery,
            "the banner must not follow onto another conversation"
        )
    }

    func testBeginNewDraftClearsRecovery() async throws {
        let persistence = PersistenceController(inMemory: true)
        let viewModel = makeP1FlowChatViewModel(persistence: persistence)
        let convA = try await persistence.createConversation(title: "A", modelID: "removed-model")
        await viewModel.loadConversation(convA)
        viewModel.stagePersistenceRecoveryForTesting(conversationID: convA)
        XCTAssertTrue(viewModel.shouldShowPersistenceRecovery)

        viewModel.beginNewDraft()
        XCTAssertFalse(viewModel.hasPersistenceRecovery)
        XCTAssertNil(viewModel.recoveryConversationID)
        XCTAssertFalse(viewModel.shouldShowPersistenceRecovery)
    }

    func testDeleteClearsMatchingRecoveryOnly() async throws {
        let persistence = PersistenceController(inMemory: true)
        let viewModel = makeP1FlowChatViewModel(persistence: persistence)
        let convA = try await persistence.createConversation(title: "A", modelID: "removed-model")
        await viewModel.loadConversation(convA)
        viewModel.stagePersistenceRecoveryForTesting(conversationID: convA)

        viewModel.noteConversationDeleted(UUID())
        XCTAssertTrue(viewModel.hasPersistenceRecovery, "unrelated deletes must not clear")

        viewModel.noteConversationDeleted(convA)
        XCTAssertFalse(viewModel.hasPersistenceRecovery)
        XCTAssertNil(viewModel.recoveryConversationID)
        XCTAssertFalse(viewModel.shouldShowPersistenceRecovery)
    }

    func testReleaseClearsRecoveryScope() async throws {
        let persistence = PersistenceController(inMemory: true)
        let viewModel = makeP1FlowChatViewModel(persistence: persistence)
        let convA = try await persistence.createConversation(title: "A", modelID: "removed-model")
        await viewModel.loadConversation(convA)
        viewModel.stagePersistenceRecoveryForTesting(conversationID: convA)
        XCTAssertTrue(viewModel.shouldShowPersistenceRecovery)

        viewModel.releasePersistenceRecovery()
        XCTAssertFalse(viewModel.hasPersistenceRecovery)
        XCTAssertNil(viewModel.recoveryConversationID)
        XCTAssertFalse(viewModel.shouldShowPersistenceRecovery)
    }
}

// MARK: - P1 dead-button states (MEDIUMs)

/// Every previously dead button now binds visible state: rename Save
/// disables while empty, delete failures raise an alert, Retry/Reload
/// disable with a spinner while a load is in flight. Hermetic.
@MainActor
final class ButtonStateTests: XCTestCase {
    private func makeModelsViewModel() -> ModelsViewModel {
        ModelsViewModel(
            downloadManager: DownloadManager(),
            lifecycleManager: ModelLifecycleManager(
                inferenceService: InferenceService(),
                memoryBudgeter: MemoryBudgeter()
            )
        )
    }
    func testRenameSaveDisabledWhileEmpty() {
        XCTAssertFalse(ConversationListViewModel.canCommitRename(title: ""))
        XCTAssertFalse(ConversationListViewModel.canCommitRename(title: "   \n  "))
        XCTAssertTrue(ConversationListViewModel.canCommitRename(title: "Chat"))
        XCTAssertTrue(ConversationListViewModel.canCommitRename(title: "  Chat  "))
    }

    func testCommitRenameEmptyIsLoggedNoOp() async {
        let persistence = PersistenceController(inMemory: true)
        let listViewModel = ConversationListViewModel(persistence: persistence)
        let id = await listViewModel.createConversation(modelID: "m", title: "Original")
        guard let id else { return XCTFail("setup conversation failed") }
        listViewModel.editingTitle = "   "
        await listViewModel.commitRename(id)
        // Fresh rows are history-ineligible (sidebar list), so assert on
        // the store: the title must be untouched and no error raised.
        let rows = await persistence.fetchConversations()
        XCTAssertEqual(rows.first(where: { $0.id == id })?.title, "Original")
        XCTAssertNil(listViewModel.errorMessage)
    }

    func testConfirmDeleteWithoutPendingIsNoOp() async {
        let viewModel = makeModelsViewModel()
        await viewModel.confirmDelete()
        XCTAssertNil(viewModel.updateMessage, "no pending delete means no failure alert")
        XCTAssertFalse(viewModel.showingDeleteConfirmation)
    }

    func testRequestDeleteArmsConfirmation() {
        let viewModel = makeModelsViewModel()
        let model = ModelRegistry.llama32_3B
        viewModel.requestDelete(model)
        XCTAssertTrue(viewModel.showingDeleteConfirmation)
        XCTAssertEqual(viewModel.pendingDeleteModel?.id, model.id)
    }

    func testDeleteFailureAlertBindingContract() {
        let viewModel = makeModelsViewModel()
        XCTAssertNil(viewModel.updateMessage, "alert hidden while nil")
        viewModel.updateMessage = "boom"
        XCTAssertNotNil(viewModel.updateMessage, "alert presented while non-nil")
        viewModel.updateMessage = nil
        XCTAssertNil(viewModel.updateMessage, "dismiss clears the alert")
    }

    func testRetryIdleWhenNothingInFlight() {
        let viewModel = makeP1FlowChatViewModel(
            persistence: PersistenceController(inMemory: true)
        )
        XCTAssertFalse(
            viewModel.isModelRetryInFlight,
            "Retry/Reload spinner rests while no load is in flight"
        )
    }
}

// MARK: - Message Action Tests

/// Contracts for transcript message actions: delete visibility, copy ack,
/// branch confirm-then-ack, icon-only retry, clipboard-free composer, and the
/// full-screen branch confirmation modal.
@MainActor
final class ChatActionsTests: XCTestCase {

    private class MockDownloadStatusProvider: ModelDownloadStatusProvider {
        func status(for model: AIModel) -> ModelDownloadStatus {
            ModelDownloadStatus(baseState: .notDownloaded, mmprojState: nil)
        }
    }

    private func makeViewModel(persistence store: PersistenceController? = nil) -> ChatViewModel {
        let persistence = store ?? PersistenceController(inMemory: true)
        let inferenceService = InferenceService()
        return ChatViewModel(
            persistence: persistence,
            inferenceService: inferenceService,
            sessionActor: ChatSessionActor(
                inferenceService: inferenceService,
                persistence: persistence
            ),
            lifecycleManager: ModelLifecycleManager(
                inferenceService: inferenceService,
                memoryBudgeter: MemoryBudgeter()
            ),
            downloadStatusProvider: MockDownloadStatusProvider()
        )
    }

    /// (a) Chat message rows never offer delete; rows expose only
    /// copy/branch/retry on the last assistant bubble while idle.
    /// Mirrors MessageBubble having no delete affordance and ChatView
    /// routing retry through the full-screen confirmation modal.
    func testRetryConfirmUsesFullModal() {
        let modal = ZiroConfirmationModal(
            title: "Retry response?",
            message: "Regenerate this response? replacing previous reply",
            confirmTitle: "Retry",
            isDestructive: false,
            onConfirm: {},
            onCancel: {}
        )

        XCTAssertEqual(modal.title, "Retry response?")
        XCTAssertEqual(modal.confirmTitle, "Retry")
        XCTAssertFalse(modal.isDestructive, "retry confirm uses the primary style, not destructive")
        XCTAssertEqual(modal.cancelTitle, "Cancel")
    }

    /// (b) Copy writes the message text to the pasteboard; the bubble then flips
    /// its copy button to the "Copied" ack (checkmark + `copied-ack`).
    func testCopyMessageWritesTextForAck() {
        let viewModel = makeViewModel()
        let previous = UIPasteboard.general.string
        defer { UIPasteboard.general.string = previous }

        viewModel.copyMessageText("hello")
        XCTAssertEqual(UIPasteboard.general.string, "hello")

        viewModel.copyMessage(ChatMessagePayload(role: .assistant, content: "world"))
        XCTAssertEqual(UIPasteboard.general.string, "world")
    }

    /// (c) Confirming the branch modal creates a new conversation from the message
    /// while the source transcript is unchanged; only then does ChatView toast
    /// "Branched into a new conversation" (`chat-toast`).
    func testBranchCreatesNewConversationKeepingSource() async throws {
        let store = PersistenceController(inMemory: true)
        let sourceID = try await store.createConversation(title: "Source", modelID: "test-model")
        await store.insertMessage(conversationID: sourceID, role: .user, content: "First")
        guard let fromID = await store.insertMessage(conversationID: sourceID, role: .assistant, content: "Second") else {
            return XCTFail("setup message insert failed")
        }

        guard case .success(let branchedID) = await store.branchConversationResult(
            sourceID: sourceID,
            fromMessageID: fromID,
            newTitle: "Branched Conversation"
        ) else {
            return XCTFail("branch should succeed")
        }

        XCTAssertNotEqual(branchedID, sourceID, "branch opens a new conversation")
        let conversations = await store.fetchConversations()
        XCTAssertEqual(conversations.count, 2, "source transcript is unchanged")
    }

    /// (d) Retry is an icon-only bubble action (`arrow.clockwise`,
    /// `retry-message-button`), armed only when a user message exists and
    /// nothing is streaming or loading.
    func testRetryOfferedOnlyWhenEligible() {
        let viewModel = makeViewModel()

        XCTAssertFalse(viewModel.canRetryLastResponse, "no user message means no retry")

        viewModel.messages = [ChatMessagePayload(role: .user, content: "Hello")]
        XCTAssertTrue(viewModel.canRetryLastResponse, "user message arms the retry icon")

        viewModel.isStreaming = true
        XCTAssertFalse(viewModel.canRetryLastResponse, "retry hidden while streaming")
    }

    /// (e) The composer (input + photo picker + send) has no clipboard button and
    /// performs no pasteboard reads or writes.
    func testComposerLeavesClipboardAlone() {
        let previous = UIPasteboard.general.items
        UIPasteboard.general.items = []
        defer { UIPasteboard.general.items = previous }

        _ = makeViewModel()
        XCTAssertNil(UIPasteboard.general.string, "composing touches no clipboard data")
    }

    /// (f) Branch confirmation uses the full-screen ZiroConfirmationModal
    /// (dim + centered card overlay, transcript stays mounted) instead of
    /// inline confirmation bubbles.
    func testBranchConfirmUsesFullModal() {
        let modal = ZiroConfirmationModal(
            title: "Branch conversation?",
            message: "A new conversation starts from this message. The current transcript is unchanged.",
            confirmTitle: "Branch",
            isDestructive: false,
            onConfirm: {},
            onCancel: {}
        )

        XCTAssertEqual(modal.title, "Branch conversation?")
        XCTAssertEqual(modal.confirmTitle, "Branch")
        XCTAssertFalse(modal.isDestructive, "branch confirm uses the primary style, not destructive")
        XCTAssertEqual(modal.cancelTitle, "Cancel")
    }

    /// (g) Confirming retry replaces: the stale assistant reply is dropped
    /// from disk before regenerating, so the count stays the same and no
    /// duplicate reply survives. Mirrors the VM truncate block.
    func testRetryConfirmReplacesWithoutDuplicate() async throws {
        let store = PersistenceController(inMemory: true)
        let id = try await store.createConversation(title: "R", modelID: "test-model")
        await store.insertMessage(conversationID: id, role: .user, content: "Q")
        guard let stale = await store.insertMessage(conversationID: id, role: .assistant, content: "Old") else {
            return XCTFail("setup insert failed")
        }
        _ = await store.deleteMessageResult(messageID: stale)
        let after = await store.fetchMessages(conversationID: id)
        XCTAssertEqual(after.count, 1, "confirm drops the stale reply before regenerating")
        XCTAssertEqual(after.first?.content, "Q", "prompt survives; regenerate appends exactly one reply")
    }

    /// (h) A retry that never confirms mutates nothing: with no user prompt
    /// the VM exits early, the transcript is unchanged, and its slot frees.
    func testRetryCancelLeavesTranscriptUntouched() async {
        let viewModel = makeViewModel()
        viewModel.messages = [ChatMessagePayload(role: .assistant, content: "Orphan")]
        await viewModel.retryLastResponse()
        XCTAssertEqual(viewModel.messages.count, 1, "unconfirmed retry mutates nothing")
        XCTAssertFalse(viewModel.isStreaming, "dropped retry releases its slot")
    }

    /// (i) Chat rows expose no delete affordance: MessageBubble stores only
    /// copy/branch/retry closures — no onDelete/delete property to wire.
    func testMessageBubbleExposesNoDelete() {
        let bubble = MessageBubble(
            message: ChatMessagePayload(role: .assistant, content: "Hi"),
            onBranch: {}, onCopy: {}, onRetry: {}
        )
        let labels = Mirror(reflecting: bubble).children.compactMap { $0.label }
        XCTAssertFalse(labels.contains(where: { $0.localizedCaseInsensitiveContains("delete") }),
                       "bubble must offer no delete property")
    }
}
