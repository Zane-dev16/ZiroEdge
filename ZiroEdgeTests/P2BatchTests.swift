// P2BatchTests.swift
// ZiroEdgeTests — P2 batch (eviction triple-surface, resume R1-R7,
// stuck-watchdog S1-S5, integrity C/E). Hermetic: byte-scale fixtures,
// no network I/O beyond suspended/parked tasks cancelled in-test.

import CryptoKit
import XCTest
@testable import ZiroEdge

@MainActor
final class P2BatchTests: XCTestCase {

    // MARK: - Eviction triple-surface (single source of truth)

    func testEvictionAlertAndInlineShareOneMessage() {
        let name = "Llama 3.2 3B"
        let shared = ModelEvictionPresentation.message(modelName: name)
        XCTAssertTrue(ModelEvictionPresentation.alertMessage(modelName: name).contains(shared))
        XCTAssertTrue(ModelEvictionPresentation.announcement(modelName: name).contains(shared))
        XCTAssertEqual(ModelEvictionPresentation.inlineTitle(modelName: name), "Model unloaded")
    }

    func testEvictionAccessibilityIDsArePinned() {
        XCTAssertEqual(ModelEvictionPresentation.retryButtonID, "modelRetryButton")
        XCTAssertEqual(ModelEvictionPresentation.retryBannerID, "modelRetryBanner")
        // Picker tail keeps the model-named "unloaded" wording aligned.
        XCTAssertTrue(ChatModelPicker.title(phase: .evicted, modelName: "Llama").contains("unloaded"))
    }

    // MARK: - R1 stale resumeData freshness

    func testStaleResumeBlobIsDiscarded() {
        let bytes = TestModelFixtures.gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try? Data("stale-resume".utf8).write(to: task.resumeDataURL, options: .atomic)
        let eightDaysAgo = Date(timeIntervalSinceNow: -8 * 24 * 3_600)
        try? FileManager.default.setAttributes(
            [.modificationDate: eightDaysAgo], ofItemAtPath: task.resumeDataURL.path
        )

        let manager = DownloadManager()
        XCTAssertNil(manager.loadFreshResumeData(for: task))
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.resumeDataURL.path))
    }

    func testFreshResumeBlobIsKept() {
        let bytes = TestModelFixtures.gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        let blob = plausibleResumeBlob()
        try? blob.write(to: task.resumeDataURL, options: .atomic)

        let manager = DownloadManager()
        XCTAssertEqual(manager.loadFreshResumeData(for: task), blob)
    }

    // MARK: - R2 corrupt blob trap

    func testEmptyResumeBlobIsDiscarded() {
        let bytes = TestModelFixtures.gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try? Data().write(to: task.resumeDataURL, options: .atomic)

        let manager = DownloadManager()
        XCTAssertNil(manager.loadFreshResumeData(for: task))
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.resumeDataURL.path))
    }

    func testNonPlistResumeBlobIsDiscarded() {
        let bytes = TestModelFixtures.gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        // Non-empty but not a resume plist: URLSession would trap on this,
        // so the loader must discard it before any transfer sees it.
        try? Data("fresh-resume".utf8).write(to: task.resumeDataURL, options: .atomic)

        let manager = DownloadManager()
        XCTAssertNil(manager.loadFreshResumeData(for: task))
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.resumeDataURL.path))
    }

    // MARK: - R3 no progress-0 flash on resume

    func testTransferPreservesResumeProgress() {
        let bytes = TestModelFixtures.gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer {
            task.task?.cancel()
            task.resolutionTask?.cancel()
            self.cleanup(task: task, model: model)
        }
        ModelMigrationService.ensureManagedDirectories()
        try? plausibleResumeBlob().write(to: task.resumeDataURL, options: .atomic)
        task.progress = 0.42

        let manager = DownloadManager()
        let key = task.storageID
        manager.activeTasks[key] = task
        manager.transfer(task: task, key: key, downloadURL: model.baseURL)

        guard case .downloading(let progress) = task.state else {
            return XCTFail("Resume must stay .downloading, got \(task.state)")
        }
        XCTAssertEqual(progress, 0.42, accuracy: 0.001)
    }

    // MARK: - R4 storage gate credits resume bytes

    func testResumeGateCreditsStagingBytes() {
        let bytes = TestModelFixtures.gguf(count: 256)
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        let staged = Data(repeating: 0xA5, count: 100)
        try? staged.write(to: task.stagingURL, options: .atomic)

        let manager = DownloadManager()
        XCTAssertEqual(manager.creditedResumeBytes(for: task), 100)
        let expected = Int64(bytes.count) - 100 + DownloadManager.storageSafetyMarginBytes
        XCTAssertEqual(manager.resumeRemainingBytes(for: task), expected)
    }

    func testResumeGateFallsBackToProgressEstimate() {
        let bytes = TestModelFixtures.gguf(count: 200)
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        task.progress = 0.5

        let manager = DownloadManager()
        let estimated = Int64((0.5 * Double(bytes.count)).rounded())
        XCTAssertEqual(manager.creditedResumeBytes(for: task), estimated)
    }

    // MARK: - R5 download allowlist

    func testAllowlistRejectsNonHTTPSAndUnknownHosts() {
        XCTAssertFalse(DownloadManager.isAllowedDownloadURL(URL(string: "http://catalog.ziroedge.app/m.gguf")!))
        XCTAssertFalse(DownloadManager.isAllowedDownloadURL(URL(string: "https://evil.example.com/m.gguf")!))
        XCTAssertFalse(DownloadManager.isAllowedDownloadURL(URL(string: "https://huggingface.co.evil.example.com/m.gguf")!))
    }

    func testAllowlistAcceptsCatalogAndCDNHosts() {
        XCTAssertTrue(DownloadManager.isAllowedDownloadURL(URL(string: "https://catalog.ziroedge.app/m.gguf")!))
        XCTAssertTrue(DownloadManager.isAllowedDownloadURL(URL(string: "https://huggingface.co/org/model.gguf")!))
        XCTAssertTrue(DownloadManager.isAllowedDownloadURL(URL(string: "https://cdn-lfs.huggingface.co/m.gguf")!))
    }

    func testTransferFailsClosedToCanonicalURL() {
        let bytes = TestModelFixtures.gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer {
            task.task?.cancel()
            self.cleanup(task: task, model: model)
        }
        ModelMigrationService.ensureManagedDirectories()

        let manager = DownloadManager()
        let key = task.storageID
        manager.activeTasks[key] = task
        manager.transfer(task: task, key: key, downloadURL: URL(string: "https://evil.example.com/m.gguf")!)

        XCTAssertEqual(task.downloadURL, task.sourceURL)
    }

    // MARK: - R6 pause-before-start

    func testPauseBeforeStartParksTransferWithoutBytes() {
        let bytes = TestModelFixtures.gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        task.progress = 0.25

        let manager = DownloadManager()
        let key = task.storageID
        manager.activeTasks[key] = task
        manager.notePendingPause(key: key)
        manager.transfer(task: task, key: key, downloadURL: model.baseURL)

        XCTAssertTrue(task.isPaused)
        XCTAssertNil(task.task, "Parked transfer must not create a URLSession task")
        guard case .paused(let progress) = task.state else {
            return XCTFail("Expected .paused, got \(task.state)")
        }
        XCTAssertEqual(progress, 0.25, accuracy: 0.001)
    }

    func testPauseWithNoActiveTaskRecordsIntent() {
        let bytes = TestModelFixtures.gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }

        let manager = DownloadManager()
        manager.pauseArtifactDownload(model: model, artifact: .base)
        XCTAssertTrue(manager.consumePendingPause(key: task.storageID))
    }

    // MARK: - S1-S5 stuck watchdog

    func testWatchdogIncludesChunkedAndResuming() {
        let manager = DownloadManager()
        let chunked = makeTask(state: .downloading(progress: 0.1), manager: manager)
        chunked.isChunked = true
        let resuming = makeTask(state: .resuming(progress: 0.2), manager: manager)
        let old = Date(timeIntervalSinceNow: -1_000)
        manager.lastProgressTime[chunked.storageID] = old
        manager.lastProgressTime[resuming.storageID] = old
        defer { removeTasks(manager, [chunked, resuming]) }

        let stuck = manager.stuckTransferKeys(now: Date())
        XCTAssertTrue(stuck.contains(chunked.storageID), "S1: chunked stalls must trip the watchdog")
        XCTAssertTrue(stuck.contains(resuming.storageID), "S2: resuming stalls must trip the watchdog")
    }

    func testWatchdogExcludesVerifyingAndPaused() {
        let manager = DownloadManager()
        let verifying = makeTask(state: .verifying, manager: manager)
        let paused = makeTask(state: .paused(progress: 0.3), manager: manager)
        paused.isPaused = true
        let old = Date(timeIntervalSinceNow: -10_000)
        manager.lastProgressTime[verifying.storageID] = old
        manager.lastProgressTime[paused.storageID] = old
        defer { removeTasks(manager, [verifying, paused]) }

        let stuck = manager.stuckTransferKeys(now: Date())
        XCTAssertFalse(stuck.contains(verifying.storageID))
        XCTAssertFalse(stuck.contains(paused.storageID))
    }

    func testWatchdogMissingHeartbeatTrips() {
        let manager = DownloadManager()
        let task = makeTask(state: .downloading(progress: 0.1), manager: manager)
        defer { removeTasks(manager, [task]) }

        XCTAssertEqual(manager.watchdogHeartbeat(forKey: task.storageID), .distantPast)
        XCTAssertTrue(manager.stuckTransferKeys(now: Date()).contains(task.storageID))
    }

    func testStopIfIdleIgnoresPausedEntries() {
        let manager = DownloadManager()
        let paused = makeTask(state: .paused(progress: 0.3), manager: manager)
        paused.isPaused = true
        defer { removeTasks(manager, [paused]) }

        XCTAssertFalse(manager.hasWatchdogCandidates)
        manager.stuckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in }
        manager.stopStuckWatchdogIfIdle()
        XCTAssertNil(manager.stuckTimer, "S4: paused-only entries must not pin the timer")
    }

    func testWatchdogCoversCDNResolution() {
        let manager = DownloadManager()
        let task = makeTask(state: .notDownloaded, manager: manager)
        task.resolutionTask = URLSession.shared.dataTask(
            with: URL(string: "https://catalog.ziroedge.app/head")!
        )
        manager.lastProgressTime[task.storageID] = Date(timeIntervalSinceNow: -1_000)
        defer {
            task.resolutionTask?.cancel()
            self.removeTasks(manager, [task])
        }

        XCTAssertTrue(manager.isWatchdogCandidate(task), "S5: in-flight CDN HEAD must be a candidate")
        XCTAssertTrue(manager.stuckTransferKeys(now: Date()).contains(task.storageID))
    }

    // MARK: - Integrity C/E single source

    func testIntegrityCopyIsSingleSourced() {
        XCTAssertEqual(ArtifactIntegrityPresentation.needsRepairSubtitle, "Needs repair")
        XCTAssertEqual(ArtifactIntegrityPresentation.needsRepairSpoken, "needs repair")
        XCTAssertTrue(ArtifactIntegrityPresentation.repairBannerMessage.contains("needs repair"))
        XCTAssertFalse(ArtifactIntegrityPresentation.message(for: .sha256Mismatch).isEmpty)
        XCTAssertTrue(ArtifactIntegrityPresentation.message(for: .missing(artifact: .base)).lowercased().contains("missing"))
    }

    // MARK: - Helpers

    private func fixtureModel(bytes: Data) -> AIModel {
        let id = "p2batch-\(UUID().uuidString.lowercased())"
        return AIModel(
            id: id,
            displayName: "P2 Fixture",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://catalog.ziroedge.app/\(id).gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(bytes.count),
            mmprojFileSizeBytes: nil,
            baseSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(
                name: "Test",
                url: URL(string: "https://example.com/license")!,
                copyright: "Test"
            )
        )
    }

    /// Plist-shaped stand-in for an opaque URLSession resume blob: passes the
    /// R2 shape gate (so no trap) without carrying real resume state.
    private func plausibleResumeBlob() -> Data {
        (try? PropertyListSerialization.data(
            fromPropertyList: ["NSURLSessionResumeInfoLocalPath": "stub"],
            format: .binary,
            options: 0
        )) ?? Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74])
    }

    /// Registers a bare task (no bytes started) so watchdog candidacy stays hermetic.
    private func makeTask(state: DownloadState, manager: DownloadManager) -> DownloadTask {
        let task = DownloadTask(model: fixtureModel(bytes: TestModelFixtures.gguf()), artifact: .base)
        task.state = state
        manager.activeTasks[task.storageID] = task
        return task
    }

    private func removeTasks(_ manager: DownloadManager, _ tasks: [DownloadTask]) {
        for task in tasks {
            manager.activeTasks.removeValue(forKey: task.storageID)
            manager.clearTransferProgress(task.storageID)
            cleanup(task: task, model: task.model)
        }
    }

    private func cleanup(task: DownloadTask, model: AIModel) {
        task.task?.cancel()
        task.chunkTask?.cancel()
        task.resolutionTask?.cancel()
        try? FileManager.default.removeItem(at: task.resumeDataURL)
        try? FileManager.default.removeItem(at: task.metadataURL)
        try? FileManager.default.removeItem(at: task.stagingURL)
        ModelManagerService.deleteModel(model)
    }
}

// MARK: - P2 focus + draft flows (synthesis items 6-8)

/// Hermetic pins for the P2 keyboard/draft flows: shell-driven composer
/// resign (item 6), gated suggestion focus (item 6), release-focus condition
/// (item 7), and per-conversation draft park/persist/restore (item 8).
/// In-memory store plus removed-model IDs (no engine loads); the shared
/// UserDefaults draft keys are scrubbed in setUp/tearDown. No new files —
/// appended at EOF per the no-pbxproj constraint.
@MainActor
final class P2FocusDraftTests: XCTestCase {
    private final class StubStatusProvider: ModelDownloadStatusProvider {
        func status(for model: AIModel) -> ModelDownloadStatus {
            ModelDownloadStatus(baseState: .notDownloaded, mmprojState: nil)
        }
    }

    private func makeViewModel(persistence store: PersistenceController? = nil) -> (ChatViewModel, PersistenceController) {
        let persistence = store ?? PersistenceController(inMemory: true)
        let inferenceService = InferenceService()
        let viewModel = ChatViewModel(
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
            downloadStatusProvider: StubStatusProvider(),
            modelProvider: { [] }
        )
        return (viewModel, persistence)
    }

    private func scrubDraftDefaults() {
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.draftsByConversation)
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.newChatDraft)
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.lastUsedModelID)
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.defaultSystemPrompt)
    }

    override func setUp() {
        super.setUp()
        scrubDraftDefaults()
    }

    override func tearDown() {
        super.tearDown()
        scrubDraftDefaults()
    }

    // MARK: P2-6 resign generation

    func testComposerResignGenerationBumpsPerNavigation() {
        let (viewModel, _) = makeViewModel()
        XCTAssertEqual(viewModel.composerResignGeneration, 0)
        viewModel.requestComposerResign(reason: "openSidebar")
        XCTAssertEqual(viewModel.composerResignGeneration, 1)
        viewModel.requestComposerResign(reason: "selectConversation")
        viewModel.requestComposerResign(reason: "newConversation")
        viewModel.requestComposerResign(reason: "openRoute")
        XCTAssertEqual(viewModel.composerResignGeneration, 4)
    }

    // MARK: P2-6 suggestion focus gate

    func testSuggestionFocusTakenOnlyWhenReady() {
        let (viewModel, _) = makeViewModel()
        // Typing stays enabled while the model loads: only a
        // conversation-load or the no-model state refuses suggestion focus.
        viewModel.isLoadingConversation = false
        for phase in [
            ModelLoadPhase.ready, .idle, .loading, .evicted, .failed("boom")
        ] {
            viewModel.modelLoadPhase = phase
            XCTAssertTrue(
                viewModel.shouldTakeSuggestionFocus(),
                "suggestion must take focus while \(phase) when no conversation is loading"
            )
        }
        viewModel.modelLoadPhase = .needsDownload
        XCTAssertFalse(viewModel.shouldTakeSuggestionFocus())
        viewModel.modelLoadPhase = .ready
        viewModel.isLoadingConversation = true
        XCTAssertFalse(viewModel.shouldTakeSuggestionFocus())
    }

    // MARK: P2-7 release-focus condition

    func testComposerReleaseFocusMatchesDisabledCondition() {
        let (viewModel, _) = makeViewModel()
        // The field gates on conversation-load plus the no-model state
        // (`.needsDownload` — typing stays enabled across every other
        // phase, `.loading` included), so release must mirror exactly that.
        let phases: [ModelLoadPhase] = [.idle, .needsDownload, .loading, .ready, .evicted, .failed("boom")]
        for phase in phases {
            for loading in [false, true] {
                viewModel.modelLoadPhase = phase
                viewModel.isLoadingConversation = loading
                XCTAssertEqual(
                    viewModel.composerShouldReleaseFocus,
                    loading || phase == .needsDownload,
                    "release must mirror the disabled condition (phase=\(phase), loading=\(loading))"
                )
            }
        }
        viewModel.modelLoadPhase = .ready
        viewModel.isLoadingConversation = false
        XCTAssertFalse(viewModel.composerShouldReleaseFocus)
    }

    // MARK: P2-8 drafts

    func testParkCurrentDraftScopesToActiveConversation() async throws {
        let (viewModel, store) = makeViewModel()
        let convA = try await store.createConversation(title: "A", modelID: "removed-model")
        let convB = try await store.createConversation(title: "B", modelID: "removed-model")
        await viewModel.loadConversation(convA)
        viewModel.inputText = "draft for A"
        viewModel.parkCurrentDraft()
        XCTAssertEqual(viewModel.parkedDraft(for: convA), "draft for A")

        await viewModel.loadConversation(convB)
        XCTAssertEqual(viewModel.inputText, "", "switching must not carry A's draft into B")
        XCTAssertEqual(viewModel.parkedDraft(for: convA), "draft for A")
        XCTAssertNil(viewModel.parkedDraft(for: convB))
    }

    func testBackgroundPersistsDraftAcrossInstances() async throws {
        let store = PersistenceController(inMemory: true)
        let (first, _) = makeViewModel(persistence: store)
        let conv = try await store.createConversation(title: "A", modelID: "removed-model")
        await first.loadConversation(conv)
        first.inputText = "survive relaunch"
        first.noteBackgroundTransition()

        // Fresh instance: empty memory, same defaults + same store (kill-relaunch).
        let (second, _) = makeViewModel(persistence: store)
        XCTAssertEqual(
            second.parkedDraft(for: conv), "survive relaunch",
            "init must hydrate drafts flushed to UserDefaults"
        )
        await second.loadConversation(conv)
        XCTAssertEqual(second.inputText, "survive relaunch")
    }

    func testBlankDraftsAreNotPersisted() async throws {
        let (viewModel, store) = makeViewModel()
        let conv = try await store.createConversation(title: "A", modelID: "removed-model")
        await viewModel.loadConversation(conv)
        viewModel.inputText = "   "
        viewModel.noteBackgroundTransition()
        XCTAssertNil(viewModel.parkedDraft(for: conv))
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: ChatViewModel.DefaultsKeys.draftsByConversation))
        XCTAssertNil(UserDefaults.standard.string(forKey: ChatViewModel.DefaultsKeys.newChatDraft))
    }

    func testNewChatDraftSurvivesBackgroundAndClearsOnNewDraft() {
        let (viewModel, _) = makeViewModel()
        XCTAssertTrue(viewModel.parkedNewChatDraft.isEmpty)
        viewModel.inputText = "unsent idea"
        viewModel.noteBackgroundTransition()
        XCTAssertEqual(viewModel.parkedNewChatDraft, "unsent idea")
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: ChatViewModel.DefaultsKeys.newChatDraft),
            "unsent idea"
        )

        viewModel.beginNewDraft()
        XCTAssertTrue(viewModel.parkedNewChatDraft.isEmpty)
        XCTAssertEqual(viewModel.inputText, "")
        XCTAssertNil(UserDefaults.standard.string(forKey: ChatViewModel.DefaultsKeys.newChatDraft))
    }

    func testForegroundNeverClobbersLiveTyping() async throws {
        let (viewModel, store) = makeViewModel()
        let conv = try await store.createConversation(title: "A", modelID: "removed-model")
        await viewModel.loadConversation(conv)
        viewModel.inputText = "parked"
        viewModel.noteBackgroundTransition()

        viewModel.inputText = "typed after return"
        viewModel.noteForegroundTransition()
        XCTAssertEqual(viewModel.inputText, "typed after return")

        viewModel.inputText = ""
        viewModel.noteForegroundTransition()
        XCTAssertEqual(viewModel.inputText, "parked")
    }

    func testHandleForegroundTransitionRestoresDrafts() async throws {
        let store = PersistenceController(inMemory: true)
        let (first, _) = makeViewModel(persistence: store)
        let conv = try await store.createConversation(title: "A", modelID: "removed-model")
        await first.loadConversation(conv)
        first.inputText = "via handle"
        first.noteBackgroundTransition()

        let (second, _) = makeViewModel(persistence: store)
        await second.loadConversation(conv)
        second.inputText = ""
        second.handleForegroundTransition()
        XCTAssertEqual(second.inputText, "via handle")
        // Repeated kicks converge (double-kick idempotency).
        second.handleForegroundTransition()
        XCTAssertEqual(second.inputText, "via handle")
    }
}

// MARK: - P3 Send/Stream Races R1-R8 + Item 9 Synthesis (hermetic, EOF)

/// P3 races: single-flight send (R1), residency re-gate (R2), conversation
/// snapshot abort (R3), switch suppress + sidebar single-funnel (R4), delete
/// notFound exemption (R5), eviction gate release + no reload (R6), retry
/// single-flight + recovery pre-check (R7), vision re-gate (R8), and the
/// post-stream reload synthesis gate (Item 9). Hermetic: in-memory
/// persistence, canned inference with controlled delays, no network.
@MainActor
final class P3RacesTests: XCTestCase {

    private final class MockP3Status: ModelDownloadStatusProvider {
        var readyIDs: Set<String> = []
        func status(for model: AIModel) -> ModelDownloadStatus {
            guard readyIDs.contains(model.id) else {
                return ModelDownloadStatus(baseState: .notDownloaded, mmprojState: nil)
            }
            if model.modelType == .vision {
                return ModelDownloadStatus(
                    modelID: model.id, baseState: .downloaded, mmprojState: .downloaded)
            }
            return ModelDownloadStatus(baseState: .downloaded, mmprojState: nil)
        }
    }

    private actor DelayedP3Inference: InferenceServiceProtocol {
        struct Call: Sendable { let images: [Data] }
        private var recorded: [Call] = []
        private var loadedID: String?
        private var chunks: [String] = ["Canned ", "response"]
        let delay: Duration
        init(delay: Duration = .milliseconds(120)) { self.delay = delay }
        var isModelLoaded: Bool { loadedID != nil }
        var loadedModelID: String? { loadedID }
        func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
            loadedID = model.id
        }
        func unloadModel() async { loadedID = nil }
        func cancelCurrentStream() async {}
        func streamChat(messages: [ChatMessagePayload], systemPrompt: String?, sampling: SamplingConfig) async throws -> AsyncThrowingStream<String, Error> {
            try? await Task.sleep(for: delay)
            recorded.append(Call(images: []))
            return canned()
        }
        func streamVisionChat(messages: [ChatMessagePayload], images: [Data], systemPrompt: String?, sampling: SamplingConfig) async throws -> AsyncThrowingStream<String, Error> {
            try? await Task.sleep(for: delay)
            recorded.append(Call(images: images))
            return canned()
        }
        func calls() -> [Call] { recorded }
        private func canned() -> AsyncThrowingStream<String, Error> {
            let cannedChunks = chunks
            return AsyncThrowingStream { cont in
                for chunk in cannedChunks { cont.yield(chunk) }
                cont.finish()
            }
        }
    }

    private struct Harness {
        let vm: ChatViewModel
        let store: PersistenceController
        let inference: DelayedP3Inference
        let session: ChatSessionActor
        let lifecycle: ModelLifecycleManager
        let status: MockP3Status
        let root: URL
        let vision: AIModel
        let text: AIModel
    }

    private func makeHarness(delay: Duration = .milliseconds(120)) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("P3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = PersistenceController(inMemory: true)
        let inference = DelayedP3Inference(delay: delay)
        let budgeter = MemoryBudgeter(metrics: FixedMemoryMetricsProvider(processAvailable: UInt64.max, total: UInt64.max))
        let safety = try LoadSafetyStore(directory: root.appendingPathComponent("safety"))
        let imports = ImportedModelStore(directory: root.appendingPathComponent("imports"))
        let lifecycle = ModelLifecycleManager(
            inferenceService: inference, memoryBudgeter: budgeter,
            loadSafetyStore: safety, importedModelStore: imports,
            availabilityProvider: { _ in .ready }, recoveryDelay: .zero)
        let vision = ModelRegistry.gemma4_e2b
        let text = ModelRegistry.llama32_3B
        let status = MockP3Status()
        status.readyIDs = [vision.id, text.id]
        let session = ChatSessionActor(inferenceService: inference, persistence: store)
        let vm = ChatViewModel(
            persistence: store, inferenceService: inference, sessionActor: session,
            lifecycleManager: lifecycle, downloadStatusProvider: status,
            modelProvider: { [vision, text] })
        return Harness(vm: vm, store: store, inference: inference, session: session,
                       lifecycle: lifecycle, status: status, root: root, vision: vision, text: text)
    }

    private func waitStreamEnd(_ vm: ChatViewModel, timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock(); let end = clock.now.advanced(by: timeout)
        while vm.isStreaming {
            guard clock.now < end else { throw NSError(domain: "P3", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "stream timeout"]) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitDone(_ vm: ChatViewModel, timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock(); let end = clock.now.advanced(by: timeout)
        while vm.isStreaming || vm.messages.last?.content != "Canned response" {
            guard clock.now < end else { throw NSError(domain: "P3", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "done timeout streaming=\(vm.isStreaming) msgs=\(vm.messages.map(\.content))"]) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.lastUsedModelID)
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.defaultSystemPrompt)
    }

    // R1: concurrent double-send collapses to one generation.
    func testR1_ConcurrentDoubleSendSingleFlight() async throws {
        let harness = try await makeHarness(delay: .milliseconds(200))
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let id = try await harness.store.createConversation(title: "R1", modelID: harness.vision.id)
        await harness.vm.loadConversation(id)
        harness.vm.inputText = "hello r1"
        async let firstSend: Void = harness.vm.sendMessage()
        async let secondSend: Void = harness.vm.sendMessage()
        await firstSend; await secondSend
        try await waitDone(harness.vm)
        let streamCalls = await harness.inference.calls().count
        XCTAssertEqual(streamCalls, 1, "R1: second send must drop on isStreaming slot")
        XCTAssertEqual(harness.vm.messages.filter { $0.role == .user }.count, 1)
        XCTAssertFalse(harness.vm.isStreaming)
    }

    // R2: residency gate blocks a send with no resident model and no reload path.
    func testR2_ResidencyGateBlocksSendWhenNotResident() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let id = try await harness.store.createConversation(title: "R2", modelID: harness.vision.id)
        await harness.vm.loadConversation(id)
        await harness.lifecycle.unloadCurrentModel()
        harness.status.readyIDs = [] // reload impossible: preflight must refuse
        harness.vm.inputText = "hello r2"
        await harness.vm.sendMessage()
        let streamCalls = await harness.inference.calls().count
        XCTAssertEqual(streamCalls, 0, "R2: no stream without residency")
        XCTAssertFalse(harness.vm.isStreaming, "R2: slot must release on gate refusal")
    }

    // R3: switch during the pre-stream hook aborts the stale send.
    func testR3_SwitchDuringSendAbortsStaleStream() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let convA = try await harness.store.createConversation(title: "R3A", modelID: harness.vision.id)
        let convB = try await harness.store.createConversation(title: "R3B", modelID: harness.vision.id)
        await harness.vm.loadConversation(convA)
        harness.vm.inputText = "hello r3"
        harness.vm.testHookBetweenAwaits = { [weak vm = harness.vm] in await vm?.loadConversation(convB) }
        await harness.vm.sendMessage()
        harness.vm.testHookBetweenAwaits = nil
        try await Task.sleep(for: .milliseconds(200))
        let streamCalls = await harness.inference.calls().count
        XCTAssertEqual(streamCalls, 0, "R3: stale send must abort before spawn")
        XCTAssertEqual(harness.vm.activeConversationID, convB)
        XCTAssertFalse(harness.vm.isStreaming)
    }

    // R4: switch while streaming stays on the target (suppress + single funnel).
    func testR4_SwitchWhileStreamingStaysOnTarget() async throws {
        let harness = try await makeHarness(delay: .milliseconds(300))
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let convA = try await harness.store.createConversation(title: "R4A", modelID: harness.vision.id)
        let convB = try await harness.store.createConversation(title: "R4B", modelID: harness.vision.id)
        await harness.vm.loadConversation(convA)
        harness.vm.inputText = "hello r4"
        let sendTask = Task { await harness.vm.sendMessage() }
        // Wait until the send claims the slot, then switch via the single funnel.
        let clock = ContinuousClock(); let end = clock.now.advanced(by: .seconds(3))
        while !harness.vm.isStreaming {
            guard clock.now < end else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(harness.vm.isStreaming)
        await harness.vm.loadConversation(convB) // R4: internally suppressReloads the cancel
        await sendTask.value
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.vm.activeConversationID, convB, "R4: completion must not yank back to doomed ID")
    }

    // R5: delete clears staged recovery; actor with no handle reports notFound.
    func testR5_DeletedConversationClearsStagedRecovery() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let id = try await harness.store.createConversation(title: "R5", modelID: harness.vision.id)
        await harness.vm.loadConversation(id)
        harness.vm.stagePersistenceRecoveryForTesting(conversationID: id)
        XCTAssertTrue(harness.vm.hasPersistenceRecovery)
        await harness.vm.noteConversationDeleted(id)
        XCTAssertFalse(harness.vm.hasPersistenceRecovery, "R5: doomed-ID recovery must not surface elsewhere")
        XCTAssertNil(harness.vm.recoveryConversationID)
        let retry = await harness.session.retryRecoverySave()
        if case .failure(let failure) = retry {
            XCTAssertEqual(failure.category, .notFound, "R5: empty handle must read notFound, never wedge")
        } else { XCTFail("R5: expected notFound with no handle") }
    }

    // R6: evicted/unloaded state skips the post-stream reload.
    func testR6_EvictedStateSkipsPostStreamReload() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let id = try await harness.store.createConversation(title: "R6", modelID: harness.vision.id)
        await harness.vm.loadConversation(id)
        XCTAssertTrue(harness.vm.shouldReloadAfterGeneration(conversationID: id), "resident same-ID must reload")
        await harness.lifecycle.unloadCurrentModel()
        XCTAssertFalse(harness.vm.shouldReloadAfterGeneration(conversationID: id), "R6: no reload without residency (evict path)")
    }

    // R7: retry drops while streaming and blocks on pending recovery.
    func testR7_RetrySingleFlightAndRecoveryBlock() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let id = try await harness.store.createConversation(title: "R7", modelID: harness.vision.id)
        await harness.vm.loadConversation(id)
        harness.vm.messages = [ChatMessagePayload(role: .user, content: "hi r7")]
        harness.vm.isStreaming = true
        await harness.vm.retryLastResponse()
        XCTAssertTrue(harness.vm.isStreaming, "R7: dropped retry must not release another owner's slot")
        let preRecoveryCalls = await harness.inference.calls().count
        XCTAssertEqual(preRecoveryCalls, 0)
        harness.vm.isStreaming = false
        harness.vm.stagePersistenceRecoveryForTesting(conversationID: id)
        await harness.vm.retryLastResponse()
        XCTAssertFalse(harness.vm.isStreaming, "R7: recovery block must release its own slot")
        XCTAssertTrue(harness.vm.showError)
        let postRecoveryCalls = await harness.inference.calls().count
        XCTAssertEqual(postRecoveryCalls, 0, "R7: recovery must block spawn (actor bufferFull)")
    }

    // R8: text-only model + images is refused (pre + post-suspension re-gate).
    func testR8_VisionGateBlocksTextOnlyImageSend() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let id = try await harness.store.createConversation(title: "R8", modelID: harness.text.id)
        await harness.vm.loadConversation(id)
        harness.vm.pendingImages = [Data([0x01, 0x02])]
        harness.vm.inputText = "hello r8"
        await harness.vm.sendMessage()
        let streamCalls = await harness.inference.calls().count
        XCTAssertEqual(streamCalls, 0, "R8: vision must not reach a text-only model")
        XCTAssertNotNil(harness.vm.visionWarning)
        XCTAssertFalse(harness.vm.isStreaming)
    }

    // Item 9 synthesis: post-stream reload needs ownership + residency + intent.
    func testP3_Item9_PostStreamReloadGateSynthesis() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let id = try await harness.store.createConversation(title: "P3-9", modelID: harness.vision.id)
        let other = try await harness.store.createConversation(title: "P3-9-other", modelID: harness.vision.id)
        await harness.vm.loadConversation(id)
        XCTAssertTrue(harness.vm.shouldReloadAfterGeneration(conversationID: id))
        XCTAssertFalse(harness.vm.shouldReloadAfterGeneration(conversationID: other), "switched surface must not reload stale ID")
        _ = await harness.lifecycle.unloadCurrentModel(userInitiated: true)
        XCTAssertFalse(harness.vm.shouldReloadAfterGeneration(conversationID: id), "user-unload intent must not reload")
    }
}
