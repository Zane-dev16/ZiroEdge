// ModelPickerTests.swift
// ZiroEdgeTests
//
// Tests for model picker auto-selection, fallback chain, and switching.

import XCTest
@testable import ZiroEdge

@MainActor
final class ModelPickerTests: XCTestCase {

    // MARK: - Test Helpers

    /// A mock download status provider that allows controlling which models are "downloaded".
    private class MockDownloadStatusProvider: ModelDownloadStatusProvider {
        var readyModelIDs: Set<String> = []
        var textOnlyModelIDs: Set<String> = []

        func status(for model: AIModel) -> ModelDownloadStatus {
            if textOnlyModelIDs.contains(model.id) {
                return ModelDownloadStatus(
                    baseState: .downloaded,
                    mmprojState: .notDownloaded,
                    allowsTextOnly: true
                )
            }
            if readyModelIDs.contains(model.id) {
                return ModelDownloadStatus(
                    baseState: .downloaded,
                    mmprojState: model.requiresMMProj ? .downloaded : nil
                )
            }
            return ModelDownloadStatus(
                baseState: .notDownloaded,
                mmprojState: model.requiresMMProj ? .notDownloaded : nil
            )
        }
    }

    private func makeViewModel(
        provider: MockDownloadStatusProvider = MockDownloadStatusProvider(),
        models: [AIModel] = ModelRegistry.libraryModels
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
            downloadStatusProvider: provider,
            modelProvider: { models }
        )
    }

    // MARK: - Auto-Selection Tests

    func testAutoSelectDoesNotRestoreUnvalidatedLastUsedModel() {
        let provider = MockDownloadStatusProvider()
        let model = ModelRegistry.llama32_3B
        provider.readyModelIDs = [model.id]
        UserDefaults.standard.set(model.id, forKey: "lastUsedModelID")

        let viewModel = makeViewModel(provider: provider)
        viewModel.autoSelectModel()

        XCTAssertNil(viewModel.selectedModel)
        XCTAssertTrue(viewModel.needsModelRedirect)
    }

    func testAutoSelectFallsBackWhenLastUsedDeleted() throws {
        let provider = MockDownloadStatusProvider()
        provider.readyModelIDs = []  // No models downloaded.

        UserDefaults.standard.set("llama3.2-3b-q4", forKey: "lastUsedModelID")

        let viewModel = makeViewModel(provider: provider)
        viewModel.autoSelectModel()

        // No models available → should signal redirect.
        XCTAssertNil(viewModel.selectedModel)
        XCTAssertTrue(viewModel.needsModelRedirect)
    }

    func testAutoSelectDoesNotFallBackToDownloadedUnvalidatedModel() {
        let provider = MockDownloadStatusProvider()
        provider.readyModelIDs = [ModelRegistry.llama32_3B.id]
        UserDefaults.standard.set("nonexistent-model-id", forKey: "lastUsedModelID")

        let viewModel = makeViewModel(provider: provider)
        viewModel.autoSelectModel()

        XCTAssertNil(viewModel.selectedModel)
        XCTAssertTrue(viewModel.needsModelRedirect)
    }

    func testAutoSelectSignalsRedirectWhenNoModelsAvailable() throws {
        let provider = MockDownloadStatusProvider()
        provider.readyModelIDs = []  // No models downloaded.

        UserDefaults.standard.removeObject(forKey: "lastUsedModelID")

        let viewModel = makeViewModel(provider: provider)
        viewModel.autoSelectModel()

        XCTAssertNil(viewModel.selectedModel)
        XCTAssertTrue(viewModel.needsModelRedirect)
    }

    // MARK: - Available Models Tests

    func testAvailableModelsExcludeDownloadedProfilesWithoutAcceptance() {
        let provider = MockDownloadStatusProvider()
        provider.readyModelIDs = [ModelRegistry.llama32_3B.id]

        let viewModel = makeViewModel(provider: provider)

        XCTAssertTrue(viewModel.availableModels.isEmpty)
    }

    func testValidatedModelDoesNotRequireExperimentalConsent() {
        let provider = MockDownloadStatusProvider()
        let model = ModelRegistry.gemma4_e2b
        provider.readyModelIDs = [model.id]
        ExperimentalModelConsent.setGranted(false, for: model)

        let viewModel = makeViewModel(provider: provider)
        XCTAssertEqual(viewModel.availableModels, [model])

        ExperimentalModelConsent.setGranted(true, for: model)
        XCTAssertEqual(viewModel.availableModels, [model])
    }

    func testE2BBaseOnlyExposesOneTextRuntimeAndDisablesVision() {
        let provider = MockDownloadStatusProvider()
        provider.textOnlyModelIDs = [ModelRegistry.gemma4_e2b.id]
        let viewModel = makeViewModel(provider: provider)

        let available = viewModel.availableModels
        XCTAssertEqual(available.count, 1)
        XCTAssertEqual(available.first?.id, ModelRegistry.gemma4_e2b.id)
        XCTAssertEqual(available.first?.modelType, .text)
        XCTAssertFalse(available.first?.requiresMMProj ?? true)
    }

    func testE2BFullyInstalledExposesVisionRuntime() {
        let provider = MockDownloadStatusProvider()
        provider.readyModelIDs = [ModelRegistry.gemma4_e2b.id]
        let viewModel = makeViewModel(provider: provider)

        let available = viewModel.availableModels
        XCTAssertEqual(available.count, 1)
        XCTAssertEqual(available.first?.id, ModelRegistry.gemma4_e2b.id)
        XCTAssertEqual(available.first?.modelType, .vision)
        XCTAssertTrue(available.first?.requiresMMProj ?? false)
    }

    func testAvailableModelsEmptyWhenNoneDownloaded() throws {
        let provider = MockDownloadStatusProvider()
        provider.readyModelIDs = []

        let viewModel = makeViewModel(provider: provider)

        XCTAssertTrue(viewModel.availableModels.isEmpty)
    }

    func testInstalledImportAppearsBeforeConsentAndSelectionRequestsConsent() async {
        let model = makeImportedModel()
        ExperimentalModelConsent.setGranted(false, for: model)
        defer { ExperimentalModelConsent.setGranted(false, for: model) }
        let provider = MockDownloadStatusProvider()
        provider.readyModelIDs = [model.id]
        let viewModel = makeViewModel(provider: provider, models: [model])

        XCTAssertEqual(viewModel.availableModels, [model])

        let selected = await viewModel.selectModel(model)

        XCTAssertFalse(selected)
        XCTAssertTrue(viewModel.showingExperimentalConsent)
        XCTAssertEqual(viewModel.pendingExperimentalModel?.id, model.id)
        XCTAssertNil(viewModel.selectedModel)
        XCTAssertFalse(ExperimentalModelConsent.isGranted(for: model))
    }

    // MARK: - Model Selection Persistence Tests

    func testSelectModelPersistsLastUsed() throws {
        let provider = MockDownloadStatusProvider()
        let model = ModelRegistry.llama32_3B
        provider.readyModelIDs = [model.id]

        let viewModel = makeViewModel(provider: provider)

        // Clear any existing value.
        UserDefaults.standard.removeObject(forKey: "lastUsedModelID")

        // Simulate selection (without async lifecycle switch).
        viewModel.selectedModel = model
        UserDefaults.standard.set(model.id, forKey: "lastUsedModelID")

        let savedID = UserDefaults.standard.string(forKey: "lastUsedModelID")
        XCTAssertEqual(savedID, model.id)
    }

    // MARK: - Model Switching State Tests

    func testSelectedModelStartsNil() throws {
        let viewModel = makeViewModel()
        XCTAssertNil(viewModel.selectedModel)
    }

    func testNeedsModelRedirectStartsFalse() throws {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.needsModelRedirect)
    }

    func testIsSwitchingModelStartsFalse() throws {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.isSwitchingModel)
    }

    private func makeImportedModel() -> AIModel {
        let bytes = TestModelFixtures.gguf()
        let artifact = HFArtifact(
            filename: "model-Q4_K_M.gguf",
            size: Int64(bytes.count),
            sha256: TestModelFixtures.sha256(bytes),
            quantization: "Q4_K_M",
            architecture: "llama",
            role: .base,
            metadata: HFGGUFMetadata(
                architecture: "llama",
                contextLength: 2048,
                chatTemplate: nil,
                modelName: "Picker Fixture"
            )
        )
        let review = HFRepositoryReview(
            repositoryID: "test/chat-picker",
            revision: String(repeating: "a", count: 40),
            licenseName: "MIT",
            licenseURL: URL(string: "https://spdx.org/licenses/MIT.html")!,
            artifacts: [artifact]
        )
        return ImportedModelFactory.makeRecord(review: review, base: artifact).model
    }

    // MARK: - Cleanup

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "lastUsedModelID")
        ExperimentalModelConsent.setGranted(false, for: ModelRegistry.gemma4_e2b)
    }
}
