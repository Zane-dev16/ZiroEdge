// ForegroundDoubleKickIdempotencyTests.swift
// ZiroEdgeTests
//
// Double-kick hardening: both ZiroEdgeApp.onChange(scenePhase.active) and
// ChatView.onChange call ChatViewModel.handleForegroundTransition(). When the
// app returns to the foreground the two kicks fire back-to-back on the same
// MainActor turn, so the deferred loader must coalesce them into a single
// load. These tests prove the guards hold — deferredLoadTask == nil,
// activeModel == nil, !isLoadAttemptInFlight, !isUserUnloaded — and that a
// Settings → Unload intent stays parked across kicks while a system eviction
// recovers exactly once.

import XCTest
@testable import ZiroEdge

@MainActor
final class ForegroundDoubleKickIdempotencyTests: XCTestCase {

    // MARK: - Doubles

    /// Reports the validated E2B profile as fully downloaded (base + mmproj)
    /// so preferredAutoLoadCandidate() nominates it; everything else reads
    /// as not downloaded.
    private final class ReadyDownloadProvider: ModelDownloadStatusProvider {
        func status(for model: AIModel) -> ModelDownloadStatus {
            if model.id == ModelRegistry.gemma4_e2b.id {
                return ModelDownloadStatus(
                    modelID: model.id,
                    baseState: .downloaded,
                    mmprojState: .downloaded
                )
            }
            return ModelDownloadStatus(
                modelID: model.id,
                baseState: .notDownloaded,
                mmprojState: nil
            )
        }
    }

    /// Counting inference stub with an optional load delay so tests can hold
    /// the lifecycle's isLoadAttemptInFlight window open deterministically.
    private actor CountingInferenceStub: InferenceServiceProtocol {
        private(set) var loadCount = 0
        private(set) var unloadCount = 0
        private var loaded = false
        private let loadDelay: Duration

        init(loadDelay: Duration = .zero) {
            self.loadDelay = loadDelay
        }

        var isModelLoaded: Bool { loaded }
        var loadedModelID: String? { loaded ? ModelRegistry.gemma4_e2b.id : nil }

        func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
            loadCount += 1
            if loadDelay > .zero {
                try? await Task.sleep(for: loadDelay)
            }
            loaded = true
        }

        func unloadModel() async {
            unloadCount += 1
            loaded = false
        }

        func streamChat(
            messages: [ChatMessagePayload],
            systemPrompt: String?,
            sampling: SamplingConfig
        ) async throws -> AsyncThrowingStream<String, Error> {
            throw InferenceError.modelNotLoaded
        }

        func streamVisionChat(
            messages: [ChatMessagePayload],
            images: [Data],
            systemPrompt: String?,
            sampling: SamplingConfig
        ) async throws -> AsyncThrowingStream<String, Error> {
            throw InferenceError.modelNotLoaded
        }

        func cancelCurrentStream() async {}
    }

    // MARK: - Harness

    private var storeDirectories: [URL] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.lastUsedModelID)
    }

    override func tearDown() {
        for directory in storeDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        storeDirectories = []
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.lastUsedModelID)
        super.tearDown()
    }

    private func makeHarness(
        loadDelay: Duration = .zero
    ) throws -> (viewModel: ChatViewModel, lifecycle: ModelLifecycleManager, inference: CountingInferenceStub) {
        let persistence = PersistenceController(inMemory: true)
        let inference = CountingInferenceStub(loadDelay: loadDelay)
        let budgeter = MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: 4_000_000_000,
            total: 8_054_095_872
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForegroundDoubleKick-\(UUID().uuidString)")
        storeDirectories.append(directory)
        let safety = try LoadSafetyStore(directory: directory)
        let lifecycle = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: budgeter,
            loadSafetyStore: safety,
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        let session = ChatSessionActor(inferenceService: inference, persistence: persistence)
        let viewModel = ChatViewModel(
            persistence: persistence,
            inferenceService: inference,
            sessionActor: session,
            lifecycleManager: lifecycle,
            downloadStatusProvider: ReadyDownloadProvider(),
            modelProvider: { [ModelRegistry.gemma4_e2b] }
        )
        return (viewModel, lifecycle, inference)
    }

    /// Wait until any spawned deferred load settles (the task nils itself on
    /// completion). Returns immediately when no kick spawned a task — which
    /// is itself the assertion for parked/blocked kicks.
    private func settle(_ viewModel: ChatViewModel) async {
        for _ in 0..<200 {
            if viewModel.deferredLoadTask == nil { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - Double-kick idempotency

    /// The core regression: the App-level and ChatView-level foreground kicks
    /// fire back-to-back on the same MainActor turn and must coalesce into a
    /// single load via the deferredLoadTask guard.
    func testConcurrentForegroundKicksIssueSingleLoad() async throws {
        let (viewModel, lifecycle, inference) = try makeHarness()

        // Fresh surface is kick-eligible on every guard.
        XCTAssertNil(viewModel.deferredLoadTask, "Precondition: no deferred load in flight")
        XCTAssertNil(lifecycle.activeModel, "Precondition: nothing resident")
        XCTAssertFalse(lifecycle.isLoadAttemptInFlight, "Precondition: no load attempt in flight")
        XCTAssertFalse(lifecycle.isUserUnloaded, "Precondition: no parked user-unload intent")

        // Simulate the double-kick: ZiroEdgeApp.onChange(active) immediately
        // followed by ChatView.onChange(active), no await between them.
        viewModel.handleForegroundTransition()
        viewModel.handleForegroundTransition()

        await settle(viewModel)

        let loads = await inference.loadCount
        XCTAssertEqual(loads, 1, "Concurrent foreground kicks must coalesce into a single load")
        XCTAssertNotNil(lifecycle.activeModel, "The single coalesced load must go resident")
        XCTAssertNil(viewModel.deferredLoadTask, "Deferred task must clear itself after the load")
    }

    /// A second foreground kick after the first load has settled must no-op
    /// on the activeModel guard — residency, not another load cycle.
    func testSequentialForegroundKicksIssueSingleLoad() async throws {
        let (viewModel, lifecycle, inference) = try makeHarness()

        viewModel.handleForegroundTransition()
        await settle(viewModel)
        let firstLoads = await inference.loadCount
        XCTAssertEqual(firstLoads, 1, "First kick loads once")
        XCTAssertNotNil(lifecycle.activeModel)

        viewModel.handleForegroundTransition()
        await settle(viewModel)

        let sequentialLoads = await inference.loadCount
        XCTAssertEqual(
            sequentialLoads, 1,
            "Sequential kick after residency must no-op (activeModel guard)"
        )
        XCTAssertNil(viewModel.deferredLoadTask)
    }

    /// While a load attempt is genuinely in flight, a foreground kick must
    /// park instead of stacking a second loadModel call onto the engine.
    func testLoadAttemptInFlightBlocksForegroundKick() async throws {
        let (viewModel, lifecycle, inference) = try makeHarness(loadDelay: .milliseconds(500))

        // Hold the lifecycle's in-flight window open with a direct load.
        let direct = Task { await lifecycle.loadModel(ModelRegistry.gemma4_e2b) }
        for _ in 0..<200 where !lifecycle.isLoadAttemptInFlight {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(
            lifecycle.isLoadAttemptInFlight,
            "Precondition: direct load must be holding the in-flight window"
        )

        viewModel.handleForegroundTransition()

        XCTAssertNil(
            viewModel.deferredLoadTask,
            "Kick during an in-flight load must not spawn a second task"
        )

        await direct.value
        await settle(viewModel)
        let inFlightLoads = await inference.loadCount
        XCTAssertEqual(inFlightLoads, 1, "In-flight kick must not stack a second load")
    }

    // MARK: - Intent parking vs eviction recovery

    /// Settings → Unload records isUserUnloaded; foreground kicks must leave
    /// that explicit intent parked — no reload, no intent consumption.
    func testUserUnloadIntentStaysParkedAcrossForegroundKicks() async throws {
        let (viewModel, lifecycle, inference) = try makeHarness()

        viewModel.handleForegroundTransition()
        await settle(viewModel)
        let preUnloadLoads = await inference.loadCount
        XCTAssertEqual(preUnloadLoads, 1, "Precondition: model resident before unload")

        _ = await lifecycle.unloadCurrentModel(userInitiated: true)
        XCTAssertTrue(lifecycle.isUserUnloaded, "Precondition: user-unload intent recorded")
        XCTAssertNil(lifecycle.activeModel, "Precondition: model unloaded")

        // Double-kick against the parked intent.
        viewModel.handleForegroundTransition()
        viewModel.handleForegroundTransition()
        // Yield so an erroneously spawned task would have time to appear.
        try? await Task.sleep(for: .milliseconds(200))

        let parkedLoads = await inference.loadCount
        XCTAssertEqual(
            parkedLoads, 1,
            "Foreground kicks must not reverse an explicit Settings → Unload"
        )
        XCTAssertNil(viewModel.deferredLoadTask, "Parked kick must not spawn a task")
        XCTAssertTrue(
            lifecycle.isUserUnloaded,
            "Blocked kick must not consume the parked user-unload intent"
        )
        XCTAssertNotEqual(viewModel.modelLoadPhase, .loading, "Parked surface must never read loading")
    }

    /// Background/memory eviction is not user intent: the same double-kick
    /// must auto-reload exactly once.
    func testSystemEvictionReloadsOnceOnForegroundDoubleKick() async throws {
        let (viewModel, lifecycle, inference) = try makeHarness()

        viewModel.handleForegroundTransition()
        await settle(viewModel)
        let preEvictionLoads = await inference.loadCount
        XCTAssertEqual(preEvictionLoads, 1, "Precondition: model resident before eviction")

        await lifecycle.handleBackgroundTransition()
        XCTAssertEqual(lifecycle.currentState, .evicted, "Precondition: background eviction recorded")
        XCTAssertFalse(lifecycle.isUserUnloaded, "Precondition: eviction is not user intent")
        XCTAssertNil(lifecycle.activeModel, "Precondition: evicted model is not resident")

        viewModel.handleForegroundTransition()
        viewModel.handleForegroundTransition()
        await settle(viewModel)

        let recoveryLoads = await inference.loadCount
        XCTAssertEqual(
            recoveryLoads, 2,
            "Evicted model must auto-reload exactly once on foreground double-kick"
        )
        XCTAssertNotNil(lifecycle.activeModel, "Reloaded model must go resident")
        XCTAssertNil(viewModel.deferredLoadTask)
    }
}
