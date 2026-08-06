// ImportedModelUpdateTests.swift
// ZiroEdgeTests
//
// Tests for manual update checking, staging alongside installed revision,
// atomic promotion, and failure rollback.

import XCTest
@testable import ZiroEdge

@MainActor
final class ImportedModelUpdateTests: XCTestCase {

    private nonisolated func response(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://huggingface.co/api/models/acme/model")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    // MARK: - Update checking

    func testUpdateCheckReportsUpToDateWhenRevisionMatches() async throws {
        let revision = String(repeating: "a", count: 40)
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": revision,
            "cardData": ["license": "apache-2.0"],
            "gguf": ["architecture": "llama", "context_length": 2048],
            "siblings": [
                ["rfilename": "model-Q4_K_M.gguf", "size": 16, "lfs": ["sha256": String(repeating: "1", count: 64)]],
            ],
        ])

        let inspector = HFRepositoryInspector { _ in (data, self.response()) }
        let store = ImportedModelStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let manager = DownloadManager(availableDiskSpaceProvider: { 100_000_000_000 })
        let coordinator = ImportedModelUpdateCoordinator(inspector: inspector, store: store, downloadManager: manager)

        let model = makeImportedModel(revision: revision)
        let result = try await coordinator.checkForUpdate(model: model)
        XCTAssertEqual(result, .upToDate)
    }

    func testUpdateCheckReportsReviewWhenRevisionDiffers() async throws {
        let installedRevision = String(repeating: "a", count: 40)
        let newRevision = String(repeating: "b", count: 40)
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": newRevision,
            "cardData": ["license": "apache-2.0"],
            "gguf": ["architecture": "llama", "context_length": 2048],
            "siblings": [
                ["rfilename": "model-Q4_K_M.gguf", "size": 16, "lfs": ["sha256": String(repeating: "1", count: 64)]],
            ],
        ])

        let inspector = HFRepositoryInspector { _ in (data, self.response()) }
        let store = ImportedModelStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let manager = DownloadManager(availableDiskSpaceProvider: { 100_000_000_000 })
        let coordinator = ImportedModelUpdateCoordinator(inspector: inspector, store: store, downloadManager: manager)

        let model = makeImportedModel(revision: installedRevision)
        let result = try await coordinator.checkForUpdate(model: model)
        guard case .review(let review) = result else {
            return XCTFail("Expected review result")
        }
        XCTAssertEqual(review.revision, newRevision)
    }

    func testCheckForUpdateDoesNotMutateInstalledModel() async throws {
        let installedRevision = String(repeating: "a", count: 40)
        let newRevision = String(repeating: "b", count: 40)
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": newRevision,
            "cardData": ["license": "apache-2.0"],
            "gguf": ["architecture": "llama"],
            "siblings": [
                ["rfilename": "model-Q4_K_M.gguf", "size": 16, "lfs": ["sha256": String(repeating: "1", count: 64)]],
            ],
        ])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedModelStore(directory: directory)
        let inspector = HFRepositoryInspector { _ in (data, self.response()) }
        let manager = DownloadManager(availableDiskSpaceProvider: { 100_000_000_000 })
        let coordinator = ImportedModelUpdateCoordinator(inspector: inspector, store: store, downloadManager: manager)

        let model = makeImportedModel(revision: installedRevision)
        let record = makeRecord(model: model, revision: installedRevision)
        try store.upsert(record)

        _ = try await coordinator.checkForUpdate(model: model)

        // The installed record must be completely unchanged.
        let persisted = store.record(id: model.id)
        XCTAssertEqual(persisted?.provenance.revision, installedRevision)
    }

    // MARK: - Staging

    func testStageUpdateRequiresSufficientStorage() {
        let manager = DownloadManager(availableDiskSpaceProvider: { 0 })
        let coordinator = ImportedModelUpdateCoordinator(downloadManager: manager)

        let existing = makeImportedModel()
        let review = makeReview(revision: String(repeating: "b", count: 40))
        let base = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "2", count: 64), size: 16_000_000_000)

        XCTAssertThrowsError(try coordinator.stageUpdate(existing: existing, review: review, base: base, projector: nil)) {
            XCTAssertEqual($0 as? DownloadError, .diskSpaceInsufficient)
        }
        // The installed record must NOT be deleted when staging fails.
        XCTAssertNil(coordinator.stagedModel(modelID: existing.id))
    }

    func testStageUpdateDoesNotPromoteUntilVerified() async throws {
        let manager = DownloadManager(availableDiskSpaceProvider: { 100_000_000_000 })
        let coordinator = ImportedModelUpdateCoordinator(downloadManager: manager)

        let existing = makeImportedModel()
        let review = makeReview(revision: String(repeating: "b", count: 40))
        let base = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "2", count: 64))

        let stagedModel = try coordinator.stageUpdate(existing: existing, review: review, base: base, projector: nil)
        XCTAssertNotEqual(stagedModel.id, existing.id)
        XCTAssertEqual(stagedModel.huggingFaceProvenance?.revision, review.revision)
        XCTAssertTrue(coordinator.hasStagedUpdate(modelID: existing.id))

        // Before download completes, promotion should return nil.
        let incompletePromotion = try await coordinator.promoteIfVerified(modelID: existing.id)
        XCTAssertNil(incompletePromotion)
        XCTAssertTrue(coordinator.hasStagedUpdate(modelID: existing.id))
    }

    func testStagedUpdateSurvivesCoordinatorRecreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportedModelStore(directory: root.appendingPathComponent("installed"))
        let updateStore = ImportedModelUpdateStore(directory: root.appendingPathComponent("updates"))
        let manager = DownloadManager(availableDiskSpaceProvider: { 100_000_000_000 })
        let existing = makeImportedModel()
        try store.upsert(makeRecord(model: existing, revision: String(repeating: "a", count: 40)))
        let review = makeReview(revision: String(repeating: "b", count: 40))
        let base = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "2", count: 64))

        let first = ImportedModelUpdateCoordinator(
            store: store,
            downloadManager: manager,
            updateStore: updateStore
        )
        _ = try first.stageUpdate(existing: existing, review: review, base: base, projector: nil)

        let restored = ImportedModelUpdateCoordinator(
            store: store,
            downloadManager: manager,
            updateStore: updateStore
        )
        XCTAssertTrue(restored.hasStagedUpdate(modelID: existing.id))
        XCTAssertEqual(restored.stagedModel(modelID: existing.id)?.baseSHA256, base.sha256)
        restored.discardStagedUpdate(modelID: existing.id)
    }

    func testStagedTransferIdentityDoesNotMaskInstalledReadiness() throws {
        let manager = DownloadManager(availableDiskSpaceProvider: { 100_000_000_000 })
        let coordinator = ImportedModelUpdateCoordinator(downloadManager: manager)
        let installedData = TestModelFixtures.gguf(count: 16)
        let existing = makeImportedModel()
        let installed = AIModel(
            id: existing.id, displayName: existing.displayName, description: existing.description,
            modelType: existing.modelType, baseURL: existing.baseURL, mmprojURL: existing.mmprojURL,
            baseFileSizeBytes: Int64(installedData.count), mmprojFileSizeBytes: nil,
            baseSHA256: TestModelFixtures.sha256(installedData), mmprojSHA256: nil,
            quantization: existing.quantization, config: existing.config, license: existing.license,
            source: existing.source
        )
        try installedData.write(to: ModelManagerService.baseModelPath(for: installed), options: .atomic)
        defer { ModelManagerService.deleteModel(installed) }

        let review = makeReview(revision: String(repeating: "b", count: 40))
        let base = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "2", count: 64))
        let staged = try coordinator.stageUpdate(existing: installed, review: review, base: base, projector: nil)
        defer { coordinator.discardStagedUpdate(modelID: installed.id) }

        XCTAssertNotEqual(staged.id, installed.id)
        XCTAssertTrue(manager.status(for: installed).isReady)
        XCTAssertFalse(manager.status(for: staged).isReady)
    }

    func testUpdatePreflightExposesTemporaryStorageMarginAndRAMRisk() {
        let manager = DownloadManager(availableDiskSpaceProvider: { 1_000_000_000 })
        let coordinator = ImportedModelUpdateCoordinator(
            downloadManager: manager,
            physicalRAM: { 128_000_000 }
        )
        let base = makeArtifact("model-Q4_K_M.gguf", size: 600_000_000)
        let storage = coordinator.storagePreflight(base: base, projector: nil)
        let ram = coordinator.ramAssessment(base: base, projector: nil)

        XCTAssertEqual(storage.requiredBytes, 600_000_000)
        XCTAssertGreaterThanOrEqual(storage.safetyMarginBytes, DownloadManager.storageSafetyMarginBytes)
        XCTAssertEqual(storage.availableBytes, 1_000_000_000)
        XCTAssertFalse(storage.canProceed)
        XCTAssertEqual(ram.classification, .risky)
        XCTAssertNotNil(ram.warning)
    }

    func testPromotionUnloadsActiveOldProvenanceBeforeSwap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportedModelStore(directory: root.appendingPathComponent("installed"))
        let updateStore = ImportedModelUpdateStore(directory: root.appendingPathComponent("updates"))
        let oldData = TestModelFixtures.gguf(fill: 0x31, count: 16)
        let oldArtifact = makeArtifact("model-Q4_K_M.gguf", digest: TestModelFixtures.sha256(oldData))
        let oldReview = makeReview(revision: String(repeating: "a", count: 40), artifacts: [oldArtifact])
        let oldRecord = ImportedModelFactory.makeRecord(
            review: oldReview,
            base: oldArtifact,
            stableID: "active-update-model"
        )
        try store.upsert(oldRecord)
        try oldData.write(to: ModelManagerService.baseModelPath(for: oldRecord.model), options: .atomic)
        defer { ModelManagerService.deleteModel(oldRecord.model) }

        let inference = UpdateInferenceStub()
        let safetyStore = try LoadSafetyStore(directory: root.appendingPathComponent("safety"))
        let lifecycle = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
                processAvailable: 8_000_000_000,
                total: 16_000_000_000
            )),
            loadSafetyStore: safetyStore,
            importedModelStore: store,
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )
        ExperimentalModelConsent.setGranted(true, for: oldRecord.model)
        defer { ExperimentalModelConsent.setGranted(false, for: oldRecord.model) }
        let loadResult = await lifecycle.loadModel(oldRecord.model)
        XCTAssertEqual(loadResult, .loaded)

        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        let coordinator = ImportedModelUpdateCoordinator(
            store: store,
            downloadManager: manager,
            updateStore: updateStore,
            lifecycleManager: lifecycle
        )
        let newData = TestModelFixtures.gguf(fill: 0x42, count: 16)
        let newArtifact = makeArtifact("model-Q4_K_M.gguf", digest: TestModelFixtures.sha256(newData))
        let newReview = makeReview(revision: String(repeating: "b", count: 40), artifacts: [newArtifact])
        let staged = try coordinator.stageUpdate(
            existing: oldRecord.model,
            review: newReview,
            base: newArtifact,
            projector: nil
        )
        manager.cancelDownload(for: staged)
        try newData.write(to: ModelManagerService.baseModelPath(for: staged), options: .atomic)

        let promoted = try await coordinator.promoteIfVerified(modelID: oldRecord.id)
        XCTAssertEqual(promoted?.id, oldRecord.id)
        XCTAssertEqual(promoted?.huggingFaceProvenance?.revision, newReview.revision)
        XCTAssertNil(lifecycle.activeModel)
        let unloadCount = await inference.unloadCount
        XCTAssertEqual(unloadCount, 1)
    }

    // MARK: - Failure rollback

    func testDiscardStagedUpdateCancelsAndCleansUp() throws {
        let manager = DownloadManager(availableDiskSpaceProvider: { 100_000_000_000 })
        let coordinator = ImportedModelUpdateCoordinator(downloadManager: manager)

        let existing = makeImportedModel()
        let review = makeReview(revision: String(repeating: "b", count: 40))
        let base = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "2", count: 64))

        _ = try coordinator.stageUpdate(existing: existing, review: review, base: base, projector: nil)
        XCTAssertTrue(coordinator.hasStagedUpdate(modelID: existing.id))

        coordinator.discardStagedUpdate(modelID: existing.id)
        XCTAssertFalse(coordinator.hasStagedUpdate(modelID: existing.id))
    }

    func testDiscardDoesNotAffectInstalledModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedModelStore(directory: directory)
        let manager = DownloadManager(availableDiskSpaceProvider: { 100_000_000_000 })
        let coordinator = ImportedModelUpdateCoordinator(store: store, downloadManager: manager)

        let model = makeImportedModel(revision: String(repeating: "a", count: 40))
        let record = makeRecord(model: model, revision: String(repeating: "a", count: 40))
        try store.upsert(record)

        let review = makeReview(revision: String(repeating: "b", count: 40))
        let base = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "2", count: 64))
        _ = try coordinator.stageUpdate(existing: model, review: review, base: base, projector: nil)
        coordinator.discardStagedUpdate(modelID: model.id)

        let persisted = store.record(id: model.id)
        XCTAssertEqual(persisted?.provenance.revision, String(repeating: "a", count: 40))
    }

    // MARK: - Helpers

    private func makeImportedModel(revision: String = String(repeating: "a", count: 40)) -> AIModel {
        let provenance = HuggingFaceProvenance(
            repositoryID: "acme/model", revision: revision,
            baseFilename: "model-Q4_K_M.gguf",
            baseSHA256: String(repeating: "1", count: 64),
            architecture: "llama",
            projectorFilename: nil, projectorSHA256: nil
        )
        return AIModel(
            id: "hf-\(UUID().uuidString.prefix(24))",
            displayName: "Test Import",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://huggingface.co/acme/model/resolve/\(revision)/model-Q4_K_M.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 16, mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "1", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .imported(promptPath: .raw, contextLength: 512),
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test"),
            source: .huggingFace(provenance)
        )
    }

    private func makeRecord(model: AIModel, revision: String) -> ImportedModelRecord {
        let provenance = HuggingFaceProvenance(
            repositoryID: "acme/model", revision: revision,
            baseFilename: "model-Q4_K_M.gguf",
            baseSHA256: String(repeating: "1", count: 64),
            architecture: "llama",
            projectorFilename: nil, projectorSHA256: nil
        )
        return ImportedModelRecord(
            id: model.id, displayName: model.displayName, description: model.description,
            modelType: model.modelType,
            baseURL: model.baseURL, mmprojURL: model.mmprojURL,
            baseFileSizeBytes: model.baseFileSizeBytes, mmprojFileSizeBytes: model.mmprojFileSizeBytes,
            baseSHA256: model.baseSHA256, mmprojSHA256: model.mmprojSHA256,
            quantization: model.quantization,
            config: model.config, license: model.license,
            provenance: provenance,
            importedAt: Date(), loadStatus: .neverLoaded
        )
    }

    private func makeArtifact(_ filename: String, digest: String = String(repeating: "a", count: 64), size: Int64 = 16) -> HFArtifact {
        HFArtifact(
            filename: filename, size: size, sha256: digest,
            quantization: "Q4_K_M", architecture: "llama",
            role: .base,
            metadata: HFGGUFMetadata(architecture: "llama", contextLength: 2048, chatTemplate: "fixture", modelName: "Fixture")
        )
    }

    private func makeReview(revision: String, artifacts: [HFArtifact]? = nil) -> HFRepositoryReview {
        HFRepositoryReview(
            repositoryID: "acme/model",
            revision: revision,
            licenseName: "apache-2.0",
            licenseURL: URL(string: "https://example.com/license")!,
            artifacts: artifacts ?? [makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))]
        )
    }
}

private actor UpdateInferenceStub: InferenceServiceProtocol {
    private var loaded = false
    private(set) var unloadCount = 0

    var isModelLoaded: Bool { loaded }
    var loadedModelID: String? { loaded ? "active-update-model" : nil }

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
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
