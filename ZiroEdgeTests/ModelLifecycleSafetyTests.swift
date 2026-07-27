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
}

private actor LifecycleInferenceStub: InferenceServiceProtocol {
    private var loaded: Bool
    private let loadError: Error?
    private(set) var loadCount = 0
    private(set) var unloadCount = 0

    init(initiallyLoaded: Bool = false, loadError: Error? = nil) {
        loaded = initiallyLoaded
        self.loadError = loadError
    }

    var isModelLoaded: Bool { loaded }
    var loadedModelID: String? { loaded ? "fixture" : nil }

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        loadCount += 1
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
