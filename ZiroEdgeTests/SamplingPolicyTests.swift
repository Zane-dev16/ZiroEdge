import XCTest
@testable import ZiroEdge

@MainActor
final class SamplingPolicyTests: XCTestCase {
    func testE4BTextChatDispatchesGreedySampling() async throws {
        XCTAssertEqual(ModelRegistry.gemma4_e4b_text.config.defaultSampling, .greedy)
#if DEBUG
        XCTAssertEqual(
            ModelRegistry.gemma4E4BTextCalibration.config.defaultSampling,
            ModelRegistry.gemma4_e4b_text.config.defaultSampling
        )
#endif

        let persistence = PersistenceController(inMemory: true)
        let conversationID = try await persistence.createConversation(
            title: "Sampling",
            modelID: ModelRegistry.gemma4_e4b_text.id
        )
        _ = await persistence.insertMessage(
            conversationID: conversationID,
            role: .assistant,
            content: "Existing response"
        )

        let inference = SamplingRecordingInferenceService()
        let lifecycleManager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
                processAvailable: 4_000_000_000,
                total: 8_054_095_872
            )),
            loadSafetyStore: try LoadSafetyStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            ),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        let loadResult = await lifecycleManager.loadModel(ModelRegistry.gemma4_e4b_text)
        XCTAssertEqual(loadResult, .loaded)

        let viewModel = ChatViewModel(
            persistence: persistence,
            inferenceService: InferenceService(),
            sessionActor: ChatSessionActor(
                inferenceService: inference,
                persistence: persistence
            ),
            lifecycleManager: lifecycleManager,
            downloadStatusProvider: SamplingReadyModelProvider()
        )
        await viewModel.loadConversation(conversationID)
        viewModel.inputText = "Hello"

        await viewModel.sendMessage()

        let sampling = try await waitForSampling(from: inference)
        XCTAssertEqual(sampling, .greedy)
    }

    private func waitForSampling(
        from inference: SamplingRecordingInferenceService
    ) async throws -> SamplingConfig {
        for _ in 0..<100 {
            if let sampling = await inference.lastTextSampling {
                return sampling
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Chat did not dispatch text inference")
        return .default
    }
}

private final class SamplingReadyModelProvider: ModelDownloadStatusProvider {
    func status(for model: AIModel) -> ModelDownloadStatus {
        ModelDownloadStatus(baseState: .downloaded, mmprojState: nil)
    }
}

private actor SamplingRecordingInferenceService: InferenceServiceProtocol {
    private var loadedModelIDValue: String?
    private(set) var lastTextSampling: SamplingConfig?

    var isModelLoaded: Bool { loadedModelIDValue != nil }
    var loadedModelID: String? { loadedModelIDValue }

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        loadedModelIDValue = model.id
    }

    func unloadModel() async {
        loadedModelIDValue = nil
    }

    func streamChat(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        lastTextSampling = sampling
        return AsyncThrowingStream { continuation in
            continuation.yield("Hello")
            continuation.finish()
        }
    }

    func streamVisionChat(
        messages: [ChatMessagePayload],
        images: [Data],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        throw InferenceError.visionNotSupported
    }

    func cancelCurrentStream() async {}
}
