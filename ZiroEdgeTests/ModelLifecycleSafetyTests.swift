import XCTest
@testable import ZiroEdge

@MainActor
final class ModelLifecycleSafetyTests: XCTestCase {
    private func makeStore() throws -> LoadSafetyStore {
        try LoadSafetyStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
    }

    private func makeBudgeter() -> MemoryBudgeter {
        MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: 4_000_000_000,
            total: 8_054_095_872
        ))
    }

    func testCategorizedNativeFailureReturnsTypedResultAndShowsSanitizedAlert() async throws {
        let inference = LifecycleInferenceStub(
            loadError: InferenceError.nativeFailure(
                kind: .contextCreation,
                diagnostic: "/private/sensitive/model.gguf"
            )
        )
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: try makeStore(),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        ExperimentalModelConsent.setGranted(true, for: ModelRegistry.gemma4_e2b)
        defer { ExperimentalModelConsent.setGranted(false, for: ModelRegistry.gemma4_e2b) }

        let result = await manager.loadModel(ModelRegistry.gemma4_e2b)

        XCTAssertEqual(result, .failed(ModelLoadFailure(
            kind: .nativeLoadFailure,
            message: "The model context could not be created safely.",
            nativeKind: .contextCreation
        )))
        XCTAssertEqual(manager.currentState, .loadFailed)
        XCTAssertTrue(manager.showLoadFailure)
        XCTAssertEqual(manager.loadFailureMessage, "The model context could not be created safely.")
        XCTAssertFalse(manager.loadFailureMessage?.contains("/private/") == true)
    }

    func testBackgroundDuringSwitchRecoveryInvalidatesBeforeConstruction() async throws {
        let inference = LifecycleInferenceStub(initiallyLoaded: true)
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: try makeStore(),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .milliseconds(250)
        )
        ExperimentalModelConsent.setGranted(true, for: ModelRegistry.gemma4_e2b)
        defer { ExperimentalModelConsent.setGranted(false, for: ModelRegistry.gemma4_e2b) }

        let loadTask = Task { await manager.loadModel(ModelRegistry.gemma4_e2b) }
        for _ in 0..<100 {
            if await inference.unloadCount > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        await manager.handleBackgroundTransition()
        let result = await loadTask.value

        guard case .failed(let failure) = result else { return XCTFail("Expected invalidated load") }
        XCTAssertEqual(failure.kind, .invalidatedBySafetyEvent)
        let loadCount = await inference.loadCount
        let isLoaded = await inference.isModelLoaded
        XCTAssertEqual(loadCount, 0)
        XCTAssertFalse(isLoaded)
        XCTAssertEqual(manager.currentState, .evicted)
    }

    /// An epoch-invalidated load must not burn a safety slot: the pending
    /// marker is withdrawn, so a relaunch records no unclean attempt and the
    /// profile stays enabled. Regression cover for background/foreground
    /// watchdog exits being misattributed to the model.
    func testInvalidatedLoadWithdrawsPendingSafetyMarker() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = try LoadSafetyStore(directory: directory)
        let profileID = MemoryProfileRegistry.e2bVision.id
        let inference = LifecycleInferenceStub()
        await inference.setSuspendLoads(true)
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: store,
            availabilityProvider: { _ in .ready }
        )
        ExperimentalModelConsent.setGranted(true, for: ModelRegistry.gemma4_e2b)
        defer { ExperimentalModelConsent.setGranted(false, for: ModelRegistry.gemma4_e2b) }

        let loadTask = Task { await manager.loadModel(ModelRegistry.gemma4_e2b) }
        for _ in 0..<200 {
            if await inference.loadCount > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        // Native construction is now in flight: prime its safety marker, then
        // tear the attempt down the way a background transition would.
        try store.beginLoad(profileID: profileID)
        await manager.handleBackgroundTransition()
        await inference.releaseLoad()
        let result = await loadTask.value

        guard case .failed(let failure) = result else {
            return XCTFail("Expected invalidated load")
        }
        XCTAssertEqual(failure.kind, .invalidatedBySafetyEvent)
        let relaunched = try LoadSafetyStore(directory: directory)
        XCTAssertEqual(relaunched.recentUncleanAttemptCount(profileID: profileID), 0)
        XCTAssertFalse(relaunched.isDisabled(profileID: profileID))
        XCTAssertNil(relaunched.lastLaunchClassification)
    }

    func testExplicitResetOnlyResetsDisabledExactProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var store = try LoadSafetyStore(directory: directory)
        for _ in 0..<2 {
            try store.beginLoad(profileID: MemoryProfileRegistry.e2bVision.id)
            store = try LoadSafetyStore(directory: directory)
        }
        let manager = ModelLifecycleManager(
            inferenceService: LifecycleInferenceStub(),
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: store,
            availabilityProvider: { _ in .ready }
        )

        XCTAssertEqual(manager.resetLoadSafety(for: ModelRegistry.llama32_3B), .notDisabled)
        XCTAssertEqual(manager.resetLoadSafety(for: ModelRegistry.gemma4_e2b), .reset)
        XCTAssertFalse(manager.isLoadSafetyDisabled(for: ModelRegistry.gemma4_e2b))
    }

    // MARK: - P0-1 async preflight off-main with loading + cancellation

    /// Preflight must run off-main via detached utility with loading visible.
    /// Old sync provider hashed multi-GB on the MainActor on memo miss.
    func testP01PreflightRunsOffMainAndShowsLoading() async throws {
        let probe = P0Probe()
        let inference = LifecycleInferenceStub()
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: try makeStore(),
            availabilityProvider: { _ in
                probe.recordOffMain(!Thread.isMainThread)
                Thread.sleep(forTimeInterval: 0.2)
                return .ready
            },
            recoveryDelay: .zero
        )
        ExperimentalModelConsent.setGranted(true, for: ModelRegistry.gemma4_e2b)
        defer { ExperimentalModelConsent.setGranted(false, for: ModelRegistry.gemma4_e2b) }
        let loadTask = Task { await manager.loadModel(ModelRegistry.gemma4_e2b) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(manager.isLoadAttemptInFlight, "loading must be visible during async preflight")
        XCTAssertEqual(manager.currentState, .loading)
        let result = await loadTask.value
        guard case .loaded = result else { return XCTFail("expected loaded, got \(result)") }
        XCTAssertEqual(probe.ranOffMain, true, "preflight must run off-main via detached utility")
    }

    /// Cancelling during async preflight must invalidate, not hang or commit.
    func testP01PreflightCancellationInvalidates() async throws {
        let inference = LifecycleInferenceStub()
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: try makeStore(),
            availabilityProvider: { _ in
                Thread.sleep(forTimeInterval: 0.3)
                return .ready
            },
            recoveryDelay: .zero
        )
        ExperimentalModelConsent.setGranted(true, for: ModelRegistry.gemma4_e2b)
        defer { ExperimentalModelConsent.setGranted(false, for: ModelRegistry.gemma4_e2b) }
        let loadTask = Task { await manager.loadModel(ModelRegistry.gemma4_e2b) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(manager.isLoadAttemptInFlight)
        loadTask.cancel()
        let result = await loadTask.value
        guard case .failed(let failure) = result else { return XCTFail("expected invalidated") }
        XCTAssertEqual(failure.kind, .invalidatedBySafetyEvent)
        XCTAssertEqual(manager.currentState, .evicted)
    }

    // MARK: - P0-2 epoch-gated safety eviction

    /// A stale eviction (old epoch) must never wipe a fresh load.
    func testP02StaleSafetyEvictionIsIgnored() async throws {
        let inference = LifecycleInferenceStub()
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: try makeStore(),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        ExperimentalModelConsent.setGranted(true, for: ModelRegistry.gemma4_e2b)
        defer { ExperimentalModelConsent.setGranted(false, for: ModelRegistry.gemma4_e2b) }
        let result = await manager.loadModel(ModelRegistry.gemma4_e2b)
        guard case .loaded = result else { return XCTFail("setup load must succeed") }
        XCTAssertTrue(manager.isModelLoaded)
        await manager.cancelAndUnloadForSafety(showWarning: true, expectedEpoch: .max)
        XCTAssertTrue(manager.isModelLoaded, "stale epoch must not evict fresh load")
        XCTAssertEqual(manager.activeModel?.id, ModelRegistry.gemma4_e2b.id)
    }

    /// The current epoch eviction must still unload.
    func testP02CurrentEpochEvictionUnloads() async throws {
        let inference = LifecycleInferenceStub()
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: try makeStore(),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        ExperimentalModelConsent.setGranted(true, for: ModelRegistry.gemma4_e2b)
        defer { ExperimentalModelConsent.setGranted(false, for: ModelRegistry.gemma4_e2b) }
        let result = await manager.loadModel(ModelRegistry.gemma4_e2b)
        guard case .loaded = result else { return XCTFail("setup load must succeed") }
        let epoch = manager.currentSafetyEpochForTests
        await manager.cancelAndUnloadForSafety(showWarning: true, expectedEpoch: epoch)
        XCTAssertFalse(manager.isModelLoaded)
        XCTAssertNil(manager.activeModel)
        XCTAssertEqual(manager.currentState, .evicted)
    }

    // MARK: - P0-3 admit-before-teardown keeps resident

    /// A profile-missing refusal must keep the prior working model resident with no new unload.
    func testP03ProfileMissingKeepsPriorResident() async throws {
        let inference = LifecycleInferenceStub()
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: try makeStore(),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        ExperimentalModelConsent.setGranted(true, for: ModelRegistry.gemma4_e2b)
        defer { ExperimentalModelConsent.setGranted(false, for: ModelRegistry.gemma4_e2b) }
        let first = await manager.loadModel(ModelRegistry.gemma4_e2b)
        guard case .loaded = first else { return XCTFail("first load must succeed") }
        let unloadsAfterFirst = await inference.unloadCount
        let fixture = TestModelFixtures.text()
        let second = await manager.loadModel(fixture)
        guard case .failed(let failure) = second else { return XCTFail("expected profile refusal") }
        XCTAssertEqual(failure.kind, .runtimeProfileUnavailable)
        XCTAssertEqual(manager.activeModel?.id, ModelRegistry.gemma4_e2b.id, "prior must stay resident")
        XCTAssertTrue(manager.isModelLoaded)
        let unloadsAfterSecond = await inference.unloadCount
        XCTAssertEqual(unloadsAfterSecond, unloadsAfterFirst, "no teardown on refusal")
    }

    /// A budget refusal must keep the prior working model resident with no new unload.
    /// E2B is validated (passes 4GB budget); E4B is unvalidated without consent (fails).
    func testP03BudgetRefusalKeepsPriorResident() async throws {
        let inference = LifecycleInferenceStub()
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: try makeStore(),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        ExperimentalModelConsent.setGranted(true, for: ModelRegistry.gemma4_e2b)
        defer { ExperimentalModelConsent.setGranted(false, for: ModelRegistry.gemma4_e2b) }
        let first = await manager.loadModel(ModelRegistry.gemma4_e2b)
        guard case .loaded = first else { return XCTFail("first load must succeed") }
        let unloadsAfterFirst = await inference.unloadCount
        let second = await manager.loadModel(ModelRegistry.gemma4_e4b)
        guard case .failed(let failure) = second else { return XCTFail("expected budget refusal") }
        XCTAssertEqual(failure.kind, .insufficientMemory)
        XCTAssertEqual(manager.activeModel?.id, ModelRegistry.gemma4_e2b.id, "prior must stay resident")
        XCTAssertTrue(manager.isModelLoaded)
        let unloadsAfterBudget = await inference.unloadCount
        XCTAssertEqual(unloadsAfterBudget, unloadsAfterFirst, "no teardown on budget refusal")
    }

    /// Recovery sleep must check epochs per 100ms: background during a 1s sleep
    /// invalidates fast (<800ms) before native construction.
    func testP03RecoverySleepChecksEpochPer100ms() async throws {
        let inference = LifecycleInferenceStub(initiallyLoaded: true)
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: try makeStore(),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .seconds(1)
        )
        ExperimentalModelConsent.setGranted(true, for: ModelRegistry.gemma4_e2b)
        defer { ExperimentalModelConsent.setGranted(false, for: ModelRegistry.gemma4_e2b) }
        let loadTask = Task { await manager.loadModel(ModelRegistry.gemma4_e2b) }
        for _ in 0..<200 {
            if await inference.unloadCount > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let start = Date()
        await manager.handleBackgroundTransition()
        let result = await loadTask.value
        let elapsed = Date().timeIntervalSince(start)
        guard case .failed(let failure) = result else { return XCTFail("expected invalidated") }
        XCTAssertEqual(failure.kind, .invalidatedBySafetyEvent)
        let nativeLoads = await inference.loadCount
        XCTAssertEqual(nativeLoads, 0, "native construction must never run")
        XCTAssertLessThan(elapsed, 0.8, "epoch checks per 100ms must fail fast, took \(elapsed)s")
        XCTAssertEqual(manager.currentState, .evicted)
    }

    // MARK: - P1-3 double-unload coalescing + single warning

    /// Concurrent evictions for one epoch share a single teardown: second
    /// joiner returns without a duplicate unload, warning presents once.
    func testP1DoubleEvictionCoalescesSingleUnloadAndWarning() async throws {
        let inference = LifecycleInferenceStub()
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeBudgeter(),
            loadSafetyStore: try makeStore(),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        ExperimentalModelConsent.setGranted(true, for: ModelRegistry.gemma4_e2b)
        defer { ExperimentalModelConsent.setGranted(false, for: ModelRegistry.gemma4_e2b) }
        let loaded = await manager.loadModel(ModelRegistry.gemma4_e2b)
        guard case .loaded = loaded else { return XCTFail("setup load must succeed") }
        let unloadsBefore = await inference.unloadCount
        let epoch = manager.currentSafetyEpochForTests
        async let first: Void = manager.cancelAndUnloadForSafety(showWarning: true, expectedEpoch: epoch)
        async let second: Void = manager.cancelAndUnloadForSafety(showWarning: true, expectedEpoch: epoch)
        await first
        await second
        let unloadsAfter = await inference.unloadCount
        XCTAssertEqual(unloadsAfter - unloadsBefore, 1, "concurrent evictions must share one teardown")
        XCTAssertTrue(manager.showMemoryWarning, "warning presents once")
        XCTAssertNil(manager.activeModel)
        XCTAssertEqual(manager.currentState, .evicted)
        // Background (false) never clears a pressure modal: single warning.
        await manager.cancelAndUnloadForSafety(showWarning: false, expectedEpoch: manager.currentSafetyEpochForTests)
        XCTAssertTrue(manager.showMemoryWarning, "background must not clear pressure warning")
    }

    // MARK: - P1-1 pre-mmap fresh resample

    /// Headroom that falls after preflight (teardown sleep) must refuse before
    /// native construction: fresh resample fails, native never runs.
    func testP1PreMmapResampleRefusesWhenHeadroomFalls() async throws {
        let metrics = P1FlakyHeadroom(values: [4_000_000_000, 0, 0], total: 8_054_095_872)
        let inference = LifecycleInferenceStub()
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: MemoryBudgeter(metrics: metrics),
            loadSafetyStore: try makeStore(),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        let result = await manager.loadModel(ModelRegistry.gemma4_e2b)
        guard case .failed(let failure) = result else { return XCTFail("expected fresh-resample refusal") }
        XCTAssertEqual(failure.kind, .insufficientMemory)
        let nativeLoads = await inference.loadCount
        XCTAssertEqual(nativeLoads, 0, "native construction must never run on stale approval")
        XCTAssertTrue(manager.showInsufficientMemoryWarning)
    }
}

private actor LifecycleInferenceStub: InferenceServiceProtocol {
    private var loaded: Bool
    private let loadError: Error?
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private var suspendLoads = false
    private var loadGate: CheckedContinuation<Void, Never>?

    init(initiallyLoaded: Bool = false, loadError: Error? = nil) {
        loaded = initiallyLoaded
        self.loadError = loadError
    }

    func setSuspendLoads(_ value: Bool) { suspendLoads = value }
    func releaseLoad() { loadGate?.resume(); loadGate = nil }

    var isModelLoaded: Bool { loaded }
    var loadedModelID: String? { loaded ? "fixture" : nil }

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        loadCount += 1
        if suspendLoads {
            await withCheckedContinuation { self.loadGate = $0 }
        }
        if let loadError { throw loadError }
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

private final class P0Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var _ranOffMain: Bool?
    func recordOffMain(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        _ranOffMain = value
    }
    var ranOffMain: Bool? {
        lock.lock(); defer { lock.unlock() }
        return _ranOffMain
    }
}

/// Hermetic falling headroom: replays `values` in order, repeating the last.
/// Preflight sees ample headroom; the pre-mmap resample sees the dip.
private final class P1FlakyHeadroom: MemoryMetricsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let values: [UInt64]
    let total: UInt64

    init(values: [UInt64], total: UInt64) {
        self.values = values
        self.total = total
    }

    private var callCount = 0
    func processAvailableMemory() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let index = min(callCount, values.count - 1)
        callCount += 1
        return values[index]
    }

    func totalRAM() -> UInt64 { total }
}

// MARK: - P0 chat-switch teardown-then-fail (synthesis items 1-3, item 1)

/// Hermetic cover for the chat-switch teardown-then-fail path: switching from
/// a resident model A to a target B that fails AFTER teardown must either
/// bring A back (single restore attempt, no recursion) or park .loadFailed
/// with the failed target pinned so Retry retries B.
@MainActor
final class ChatSwitchTests: XCTestCase {
    private func makeStore() throws -> LoadSafetyStore {
        try LoadSafetyStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
    }

    private func makeAmpleBudgeter() -> MemoryBudgeter {
        MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: 4_000_000_000,
            total: 8_054_095_872
        ))
    }

    private func makePriorImport() -> ImportedModelRecord {
        let data = TestModelFixtures.gguf()
        let sha = TestModelFixtures.sha256(data)
        return ImportedModelRecord(
            id: "hf-switch-prior-\(UUID().uuidString.prefix(8))",
            displayName: "Switch Prior", description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/prior.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(data.count), mmprojFileSizeBytes: nil,
            baseSHA256: sha, mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .imported(promptPath: .raw, contextLength: 512),
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test"),
            provenance: HuggingFaceProvenance(
                repositoryID: "acme/prior", revision: String(repeating: "b", count: 40),
                baseFilename: "prior.gguf", baseSHA256: sha,
                architecture: "llama", projectorFilename: nil, projectorSHA256: nil
            ),
            importedAt: Date(), loadStatus: .neverLoaded
        )
    }

    private func makeManager(
        inference: SwitchFailoverInferenceStub,
        budgeter: MemoryBudgeter? = nil,
        availability: @escaping @Sendable (AIModel) -> ModelAvailability = { _ in .ready }
    ) throws -> ModelLifecycleManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: budgeter ?? makeAmpleBudgeter(),
            loadSafetyStore: try makeStore(),
            importedModelStore: ImportedModelStore(directory: directory),
            availabilityProvider: availability,
            recoveryDelay: .zero
        )
    }

    /// Post-teardown native failure with a displaced resident must bring the
    /// prior model back with a single direct engine load (no recursion).
    func testPostTeardownNativeFailureRestoresPriorResident() async throws {
        let inference = SwitchFailoverInferenceStub()
        let manager = try makeManager(inference: inference)
        let prior = makePriorImport().model
        ExperimentalModelConsent.setGranted(true, for: prior)
        defer { ExperimentalModelConsent.setGranted(false, for: prior) }

        let first = await manager.loadModel(prior)
        guard case .loaded = first else { return XCTFail("prior must load, got \(first)") }
        await inference.setFailIDs([ModelRegistry.gemma4_e2b.id])

        let result = await manager.loadModel(ModelRegistry.gemma4_e2b)
        guard case .failed(let failure) = result else { return XCTFail("target must fail, got \(result)") }
        XCTAssertEqual(failure.kind, .nativeLoadFailure)
        XCTAssertEqual(manager.activeModel?.id, prior.id, "displaced resident must be restored")
        XCTAssertEqual(manager.currentState, .loaded)
    }

    /// Post-teardown failure with no prior resident (cold start) must park
    /// .loadFailed with no active model.
    func testPostTeardownFailureWithoutPriorLeavesLoadFailed() async throws {
        let inference = SwitchFailoverInferenceStub()
        let manager = try makeManager(inference: inference)
        await inference.setFailIDs([ModelRegistry.gemma4_e2b.id])

        let result = await manager.loadModel(ModelRegistry.gemma4_e2b)
        guard case .failed(let failure) = result else { return XCTFail("expected failure, got \(result)") }
        XCTAssertEqual(failure.kind, .nativeLoadFailure)
        XCTAssertNil(manager.activeModel)
        XCTAssertEqual(manager.currentState, .loadFailed)
    }

    /// Headroom that falls between preflight and teardown must refuse BEFORE
    /// teardown: the resident stays loaded and native construction never runs.
    func testPreTeardownFreshResampleRefusalPreservesResident() async throws {
        let ample: UInt64 = 4_000_000_000
        // Load A consumes 4 ample samples (preflight + pre-teardown + pre-mmap
        // + post-load reserve); B's preflight sees the last ample sample, then
        // the pre-teardown resample hits the dip and refuses.
        let metrics = P1FlakyHeadroom(values: [ample, ample, ample, ample, ample, 0, 0], total: 8_054_095_872)
        let inference = SwitchFailoverInferenceStub()
        let manager = try makeManager(inference: inference, budgeter: MemoryBudgeter(metrics: metrics))

        let first = await manager.loadModel(ModelRegistry.gemma4_e2b)
        guard case .loaded = first else { return XCTFail("setup load must succeed, got \(first)") }
        let loadsAfterFirst = await inference.loadCount

        let prior = makePriorImport().model
        ExperimentalModelConsent.setGranted(true, for: prior)
        defer { ExperimentalModelConsent.setGranted(false, for: prior) }
        let result = await manager.loadModel(prior)
        guard case .failed(let failure) = result else { return XCTFail("expected budget refusal, got \(result)") }
        XCTAssertEqual(failure.kind, .insufficientMemory)
        XCTAssertEqual(manager.activeModel?.id, ModelRegistry.gemma4_e2b.id, "resident must survive pre-teardown refusal")
        XCTAssertEqual(manager.currentState, .loaded)
        let loadsAfterRefusal = await inference.loadCount
        XCTAssertEqual(loadsAfterRefusal, loadsAfterFirst, "native construction must never run")
        XCTAssertTrue(manager.showInsufficientMemoryWarning)
    }

    // MARK: - ViewModel selection pinning

    private final class SwitchVMStatusProvider: ModelDownloadStatusProvider {
        var readyIDs: Set<String> = []
        func status(for model: AIModel) -> ModelDownloadStatus {
            guard readyIDs.contains(model.id) else {
                return ModelDownloadStatus(baseState: .notDownloaded, mmprojState: nil)
            }
            return ModelDownloadStatus(modelID: model.id, baseState: .downloaded, mmprojState: .downloaded)
        }
    }

    private struct SwitchHarness {
        let viewModel: ChatViewModel
        let lifecycle: ModelLifecycleManager
        let inference: SwitchFailoverInferenceStub
    }

    private func makeSwitchHarness(models: [AIModel]) throws -> SwitchHarness {
        let persistence = PersistenceController(inMemory: true)
        let inference = SwitchFailoverInferenceStub()
        let lifecycle = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: makeAmpleBudgeter(),
            loadSafetyStore: try makeStore(),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        let session = ChatSessionActor(inferenceService: inference, persistence: persistence)
        let status = SwitchVMStatusProvider()
        status.readyIDs = Set(models.map(\.id))
        let viewModel = ChatViewModel(
            persistence: persistence,
            inferenceService: inference,
            sessionActor: session,
            lifecycleManager: lifecycle,
            downloadStatusProvider: status,
            modelProvider: { models }
        )
        return SwitchHarness(viewModel: viewModel, lifecycle: lifecycle, inference: inference)
    }

    /// A failed switch with no resident must pin the failed target so Retry
    /// retries B (not nil/stale) and the phase projects .failed.
    func testSelectModelFailurePinsFailedTarget() async throws {
        let target = ModelRegistry.gemma4_e2b
        let harness = try makeSwitchHarness(models: [target])
        await harness.inference.setFailIDs([target.id])

        let ok = await harness.viewModel.selectModel(target)
        XCTAssertFalse(ok)
        XCTAssertEqual(harness.viewModel.selectedModel?.id, target.id, "failed target must stay pinned for Retry")
        XCTAssertNil(harness.lifecycle.activeModel)
        XCTAssertEqual(harness.lifecycle.currentState, .loadFailed)
        guard case .failed = harness.viewModel.modelLoadPhase else {
            return XCTFail("phase must project .failed, got \(harness.viewModel.modelLoadPhase)")
        }
    }

    /// A failed switch with a restored prior resident must fall back to the
    /// resident selection so the composer reads .ready again.
    func testSelectModelFailureWithRestoredPriorReadsReady() async throws {
        let prior = makePriorImport().model
        let target = ModelRegistry.gemma4_e2b
        ExperimentalModelConsent.setGranted(true, for: prior)
        defer { ExperimentalModelConsent.setGranted(false, for: prior) }
        let harness = try makeSwitchHarness(models: [prior, target])

        let setup = await harness.lifecycle.loadModel(prior)
        guard case .loaded = setup else { return XCTFail("prior must load, got \(setup)") }
        harness.viewModel.selectedModel = prior
        await harness.inference.setFailIDs([target.id])

        let ok = await harness.viewModel.selectModel(target)
        XCTAssertFalse(ok)
        XCTAssertEqual(harness.lifecycle.activeModel?.id, prior.id, "prior must be restored")
        XCTAssertEqual(harness.viewModel.selectedModel?.id, prior.id, "selection must fall back to resident")
        XCTAssertEqual(harness.viewModel.modelLoadPhase, .ready)
    }

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.lastUsedModelID)
        UserDefaults.standard.removeObject(forKey: ChatViewModel.DefaultsKeys.defaultSystemPrompt)
    }
}

/// Mutable failover stub for switch tests: loads succeed except for armed IDs.
private actor SwitchFailoverInferenceStub: InferenceServiceProtocol {
    private var loadedID: String?
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private var failIDs: Set<String> = []

    func setFailIDs(_ ids: Set<String>) { failIDs = ids }

    var isModelLoaded: Bool { loadedID != nil }
    var loadedModelID: String? { loadedID }

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        loadCount += 1
        if failIDs.contains(model.id) {
            throw InferenceError.nativeFailure(kind: .memoryPressure, diagnostic: "switch-failover-test")
        }
        loadedID = model.id
    }

    func unloadModel() async {
        unloadCount += 1
        loadedID = nil
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
