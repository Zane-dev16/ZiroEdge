import XCTest
@testable import ZiroEdge

@MainActor
final class ImportedChatCompositionTests: XCTestCase {
    func testImportedTextCompositionUsesPersistedSamplingAndPersistsResponse() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sampling = SamplingConfig(
            temperature: 1.3, topP: 0.55, topK: 17, maxTokens: 321, repeatPenalty: 1.25
        )
        let record = importedRecord(id: "hf-chat-text-\(UUID().uuidString)", sampling: sampling)
        let harness = try await makeHarness(
            model: record.model,
            persistedRecord: record,
            root: root
        )
        ExperimentalModelConsent.setGranted(true, for: record.model)
        defer { ExperimentalModelConsent.setGranted(false, for: record.model) }

        let conversationID = try await harness.persistence.createConversation(
            title: "Imported text", modelID: record.id
        )
        _ = await harness.persistence.insertMessage(
            conversationID: conversationID, role: .assistant, content: "Existing context"
        )
        await harness.viewModel.loadConversation(conversationID)
        harness.viewModel.inputText = "Explain the local model"
        await harness.viewModel.sendMessage()
        try await waitForCompletion(harness.viewModel)

        let calls = await harness.inference.calls()
        let textCall = try XCTUnwrap(calls.first(where: { $0.kind == .text }))
        XCTAssertEqual(textCall.sampling, sampling)
        XCTAssertEqual(textCall.messages.last?.content, "Explain the local model")
        let persisted = await harness.persistence.fetchMessages(conversationID: conversationID)
        XCTAssertTrue(persisted.contains { $0.role == .user && $0.content == "Explain the local model" })
        XCTAssertTrue(persisted.contains { $0.role == .assistant && !$0.content.isEmpty && $0.content == "Canned response" })
    }

    func testCuratedGemmaTextCompositionKeepsDefaultSampling() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ModelRegistry.gemma4_e2b.textOnlyRuntimeVariant
        let harness = try await makeHarness(model: model, root: root)
        let conversationID = try await harness.persistence.createConversation(
            title: "Curated text", modelID: model.id
        )
        _ = await harness.persistence.insertMessage(
            conversationID: conversationID, role: .assistant, content: "Existing context"
        )
        await harness.viewModel.loadConversation(conversationID)
        harness.viewModel.inputText = "Hello"
        await harness.viewModel.sendMessage()
        try await waitForCompletion(harness.viewModel)

        let calls = await harness.inference.calls()
        let call = try XCTUnwrap(calls.first(where: { $0.kind == .text }))
        XCTAssertEqual(call.sampling, .default)
    }

    func testImportedVisionCompositionUsesImageAndSamplingAndPersistsAttachment() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sampling = SamplingConfig(
            temperature: 0.8, topP: 0.7, topK: 23, maxTokens: 456, repeatPenalty: 1.1
        )
        let record = importedRecord(
            id: "hf-chat-vision-\(UUID().uuidString)",
            sampling: sampling,
            vision: true
        )
        let harness = try await makeHarness(
            model: record.model,
            persistedRecord: record,
            root: root,
            visionReady: true
        )
        ExperimentalModelConsent.setGranted(true, for: record.model)
        defer { ExperimentalModelConsent.setGranted(false, for: record.model) }
        let conversationID = try await harness.persistence.createConversation(
            title: "Imported vision", modelID: record.id
        )
        _ = await harness.persistence.insertMessage(
            conversationID: conversationID, role: .assistant, content: "Existing context"
        )
        await harness.viewModel.loadConversation(conversationID)
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        harness.viewModel.inputText = "What is shown?"
        harness.viewModel.pendingImages = [png]
        await harness.viewModel.sendMessage()
        try await waitForCompletion(harness.viewModel)

        let calls = await harness.inference.calls()
        let call = try XCTUnwrap(calls.first(where: { $0.kind == .vision }))
        XCTAssertEqual(call.sampling, sampling)
        XCTAssertEqual(call.images, [png])
        let persisted = await harness.persistence.fetchMessages(conversationID: conversationID)
        XCTAssertTrue(persisted.contains {
            $0.role == .user && $0.content == "What is shown?" && $0.attachments == [png]
        })
        XCTAssertTrue(persisted.contains { $0.role == .assistant && $0.content == "Canned response" })
    }

    private func makeHarness(
        model: AIModel,
        persistedRecord: ImportedModelRecord? = nil,
        root: URL,
        visionReady: Bool = false
    ) async throws -> ChatHarness {
        let persistence = try await PersistenceController.open(
            configuration: .store(root.appendingPathComponent("chat.sqlite"))
        ).get()
        let inference = RecordingInferenceService()
        let loadSafety = try LoadSafetyStore(directory: root.appendingPathComponent("load-safety"))
        let importedStore = ImportedModelStore(directory: root.appendingPathComponent("imports"))
        if let persistedRecord { try importedStore.upsert(persistedRecord) }
        let lifecycle = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
                processAvailable: UInt64.max,
                total: UInt64.max
            )),
            loadSafetyStore: loadSafety,
            importedModelStore: importedStore,
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        let status = RecordingStatusProvider(modelID: model.id, visionReady: visionReady)
        let session = ChatSessionActor(inferenceService: inference, persistence: persistence)
        let viewModel = ChatViewModel(
            persistence: persistence,
            inferenceService: inference,
            sessionActor: session,
            lifecycleManager: lifecycle,
            downloadStatusProvider: status,
            modelProvider: {
                let imported = importedStore.models
                return imported.isEmpty ? [model] : imported
            }
        )
        return ChatHarness(
            persistence: persistence,
            inference: inference,
            viewModel: viewModel,
            status: status
        )
    }

    private func importedRecord(
        id: String,
        sampling: SamplingConfig,
        vision: Bool = false
    ) -> ImportedModelRecord {
        let base = artifact("model-Q4_K_M.gguf", digest: "a", role: .base)
        let projector = vision ? artifact("mmproj-model-F16.gguf", digest: "b", role: .projector) : nil
        let review = HFRepositoryReview(
            repositoryID: "acme/\(id)",
            revision: String(repeating: "c", count: 40),
            licenseName: "MIT",
            licenseURL: URL(string: "https://example.com/license")!,
            artifacts: [base] + (projector.map { [$0] } ?? [])
        )
        var record = ImportedModelFactory.makeRecord(
            review: review, base: base, projector: projector, stableID: id
        )
        record.config = .imported(
            promptPath: record.config.promptPath,
            contextLength: 3072,
            sampling: sampling,
            addBos: record.config.addBos,
            stopStrings: record.config.stopStrings
        )
        return record
    }

    private func artifact(_ filename: String, digest: Character, role: HFArtifact.Role) -> HFArtifact {
        HFArtifact(
            filename: filename,
            size: 100,
            sha256: String(repeating: digest, count: 64),
            quantization: role == .base ? "Q4_K_M" : "F16",
            architecture: role == .base ? "llama" : "clip",
            role: role,
            metadata: HFGGUFMetadata(
                architecture: role == .base ? "llama" : "clip",
                contextLength: 3072,
                chatTemplate: "fixture",
                modelName: "Fixture"
            )
        )
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportedChatComposition-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForCompletion(_ viewModel: ChatViewModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while viewModel.isStreaming || viewModel.messages.last?.content != "Canned response" {
            guard clock.now < deadline else {
                throw NSError(
                    domain: "ImportedChatCompositionTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for finite canned stream"]
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private struct ChatHarness {
    let persistence: PersistenceController
    let inference: RecordingInferenceService
    let viewModel: ChatViewModel
    // Retain the weakly-referenced provider for the duration of each test.
    let status: RecordingStatusProvider
}

private final class RecordingStatusProvider: ModelDownloadStatusProvider {
    let modelID: String
    let visionReady: Bool

    init(modelID: String, visionReady: Bool) {
        self.modelID = modelID
        self.visionReady = visionReady
    }

    func status(for model: AIModel) -> ModelDownloadStatus {
        guard model.id == modelID else {
            return ModelDownloadStatus(baseState: .notDownloaded, mmprojState: nil)
        }
        return ModelDownloadStatus(
            modelID: model.id,
            baseState: .downloaded,
            mmprojState: visionReady ? .downloaded : nil
        )
    }
}

private actor RecordingInferenceService: InferenceServiceProtocol {
    enum Kind: Equatable, Sendable { case text, vision }

    struct Call: Sendable {
        let kind: Kind
        let messages: [ChatMessagePayload]
        let images: [Data]
        let sampling: SamplingConfig
    }

    private var recorded: [Call] = []
    private var loadedID: String?

    var isModelLoaded: Bool { loadedID != nil }
    var loadedModelID: String? { loadedID }

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        loadedID = model.id
    }

    func unloadModel() async { loadedID = nil }

    func streamChat(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        recorded.append(Call(kind: .text, messages: messages, images: [], sampling: sampling))
        return cannedStream()
    }

    func streamVisionChat(
        messages: [ChatMessagePayload],
        images: [Data],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        recorded.append(Call(kind: .vision, messages: messages, images: images, sampling: sampling))
        return cannedStream()
    }

    func cancelCurrentStream() async {}
    func calls() -> [Call] { recorded }

    private func cannedStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("Canned ")
            continuation.yield("response")
            continuation.finish()
        }
    }
}
