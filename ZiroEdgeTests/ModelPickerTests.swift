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

    // MARK: - Auto-Selection Tests

    func testAutoSelectLastUsedModel() throws {
        let provider = MockDownloadStatusProvider()
        let model = ModelRegistry.llama32_3B
        provider.readyModelIDs = [model.id]

        UserDefaults.standard.set(model.id, forKey: "lastUsedModelID")

        let viewModel = makeViewModel(provider: provider)
        viewModel.autoSelectModel()

        XCTAssertNotNil(viewModel.selectedModel)
        XCTAssertEqual(viewModel.selectedModel?.id, model.id)
        XCTAssertFalse(viewModel.needsModelRedirect)
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

    func testAutoSelectPicksNextAvailableWhenLastUsedMismatch() throws {
        let provider = MockDownloadStatusProvider()
        let model = ModelRegistry.llama32_3B
        provider.readyModelIDs = [model.id]

        // Set a non-existent model ID as last used.
        UserDefaults.standard.set("nonexistent-model-id", forKey: "lastUsedModelID")

        let viewModel = makeViewModel(provider: provider)
        viewModel.autoSelectModel()

        // Should fall back to the first available model.
        XCTAssertNotNil(viewModel.selectedModel)
        XCTAssertEqual(viewModel.selectedModel?.id, model.id)
        XCTAssertFalse(viewModel.needsModelRedirect)
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

    func testAvailableModelsOnlyIncludesDownloaded() throws {
        let provider = MockDownloadStatusProvider()
        let model = ModelRegistry.llama32_3B
        provider.readyModelIDs = [model.id]

        let viewModel = makeViewModel(provider: provider)

        XCTAssertEqual(viewModel.availableModels.count, 1)
        XCTAssertEqual(viewModel.availableModels.first?.id, model.id)
    }

    func testAvailableModelsEmptyWhenNoneDownloaded() throws {
        let provider = MockDownloadStatusProvider()
        provider.readyModelIDs = []

        let viewModel = makeViewModel(provider: provider)

        XCTAssertTrue(viewModel.availableModels.isEmpty)
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

    // MARK: - Cleanup

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "lastUsedModelID")
    }
}
