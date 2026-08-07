// ImportedModelRemovalTests.swift
// ZiroEdgeTests
//
// Tests for safe removal of imported models with shared-artifact awareness,
// variant isolation, and conversation reconciliation.

import XCTest
@testable import ZiroEdge

final class ImportedModelRemovalTests: XCTestCase {

    // MARK: - Basic removal

    func testRemovingImportedModelDeletesRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ImportedModelStore(directory: directory)
        let record = makeRecord(id: "hf-test-1")
        try store.upsert(record)

        XCTAssertEqual(store.allRecords.count, 1)
        try store.remove(id: "hf-test-1")
        XCTAssertEqual(store.allRecords.count, 0)
    }

    func testRemovingNonexistentModelIsNoOp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ImportedModelStore(directory: directory)
        let removed = try store.remove(id: "hf-nonexistent")
        XCTAssertNil(removed)
    }

    // MARK: - Shared artifact awareness

    func testSharedBaseArtifactIsDetected() {
        // Gemma 4 E4B text and vision share the same base artifact.
        let text = ModelRegistry.gemma4_e4b_text
        let vision = ModelRegistry.gemma4_e4b

        XCTAssertEqual(text.baseArtifactStorageID, vision.baseArtifactStorageID)
        XCTAssertTrue(ModelManagerService.isBaseArtifactShared(text))
        XCTAssertTrue(ModelManagerService.isBaseArtifactShared(vision))
    }

    func testUnsharedArtifactIsNotShared() {
        // Llama 3.2 shares its base with no other model.
        XCTAssertFalse(ModelManagerService.isBaseArtifactShared(ModelRegistry.llama32_3B))
    }

    func testDeleteModelOnlyRemovesUnsharedArtifacts() throws {
        // Install a valid base GGUF for a unique model.
        let data = TestModelFixtures.gguf()
        let sha = TestModelFixtures.sha256(data)
        let model = AIModel(
            id: "unique-model", displayName: "Unique", description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(data.count), mmprojFileSizeBytes: nil,
            baseSHA256: sha, mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        try data.write(to: ModelManagerService.baseModelPath(for: model))
        defer { ModelManagerService.deleteModel(model) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: ModelManagerService.baseModelPath(for: model).path))

        // Not shared, so delete should remove the file.
        ModelManagerService.deleteModel(model)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ModelManagerService.baseModelPath(for: model).path),
            "Unshared artifact should be deleted"
        )
    }

    func testDeleteSharedModelPreservesArtifactForOtherVariant() throws {
        // Use the Gemma E4B shared-base pair — deleting text variant shouldn't
        // delete the shared base artifact since the vision variant still references it.
        let data = TestModelFixtures.gguf()
        let textModel = ModelRegistry.gemma4_e4b_text
        let sharedPath = ModelManagerService.baseModelPath(for: textModel)

        // Install the shared base.
        try data.write(to: sharedPath)
        defer { try? FileManager.default.removeItem(at: sharedPath) }

        // "Delete" the text model. Since the base is shared with the vision model,
        // the file should remain.
        ModelManagerService.deleteModel(textModel)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sharedPath.path),
            "Shared base artifact must be preserved when another model references it"
        )
    }

    // MARK: - Variant isolation

    func testRemovingOneVariantDoesNotAlterOtherVariantsInStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ImportedModelStore(directory: directory)
        let q4 = makeRecord(id: "hf-q4", filename: "model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let q8 = makeRecord(id: "hf-q8", filename: "model-Q8_0.gguf", digest: String(repeating: "2", count: 64))
        try store.upsert(q4)
        try store.upsert(q8)

        try store.remove(id: "hf-q4")

        let remaining = store.allRecords
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, "hf-q8")
    }

    // MARK: - Conversation model reconciliation

    func testUnavailableModelReasonIdentifiesRemovedImport() {
        // An "hf-*" ID that's not in the registry is a removed import.
        let reason = ModelRegistry.unavailableModelReason(for: "hf-abcdef1234567890abcdef1234")
        XCTAssertEqual(reason, .removed)
    }

    func testUnavailableModelReasonForUnknownIDIsNeverExisted() {
        let reason = ModelRegistry.unavailableModelReason(for: "completely-unknown-id")
        XCTAssertEqual(reason, .neverExisted)
    }

    func testAvailableModelHasNoUnavailableReason() {
        let reason = ModelRegistry.unavailableModelReason(for: ModelRegistry.llama32_3B.id)
        XCTAssertNil(reason)
    }

    func testKnownCuratedModelIDIsRecognized() {
        XCTAssertTrue(ModelRegistry.isKnownModelID(ModelRegistry.llama32_3B.id))
        XCTAssertTrue(ModelRegistry.isKnownModelID(ModelRegistry.gemma4_e2b.id))
        XCTAssertFalse(ModelRegistry.isKnownModelID("hf-removed-import"))
        XCTAssertFalse(ModelRegistry.isKnownModelID("completely-unknown"))
    }

    // MARK: - Store mutation safety

    func testRegistryWriteFailureRollsBackToLastPersistedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        var writeCount = 0
        let store = ImportedModelStore(directory: directory, writer: { data, url in
            writeCount += 1
            if writeCount == 2 { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        try store.upsert(makeRecord(id: "hf-good"))

        XCTAssertThrowsError(try store.upsert(makeRecord(id: "hf-must-rollback")))
        XCTAssertEqual(store.allRecords.count, 1)
        XCTAssertEqual(store.record(id: "hf-good")?.id, "hf-good")
        XCTAssertNil(store.record(id: "hf-must-rollback"))
    }

    func testMissingRecordUpdateThrows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedModelStore(directory: directory)

        XCTAssertThrowsError(try store.update(id: "hf-missing") { _ in }) { error in
            XCTAssertEqual(error as? ImportedModelStoreError, .recordNotFound("hf-missing"))
        }
    }

    func testCompareAndSwapRejectsChangedProvenance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedModelStore(directory: directory)
        let original = makeRecord(id: "hf-cas", repo: "acme/original")
        let changed = makeRecord(id: "hf-cas", repo: "acme/changed")
        let replacement = makeRecord(id: "hf-cas", repo: "acme/replacement")
        try store.upsert(original)
        try store.update(id: original.id) { $0 = changed }

        XCTAssertThrowsError(try store.replace(
            id: original.id,
            expectedProvenance: original.provenance,
            with: replacement
        )) { error in
            XCTAssertEqual(error as? ImportedModelStoreError, .provenanceChanged(original.id))
        }
        XCTAssertEqual(store.record(id: original.id)?.provenance, changed.provenance)
    }

    func testCorruptRegistryBlocksMutationInsteadOfOverwritingWithEmptyState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registryURL = directory.appendingPathComponent("registry.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: registryURL)

        let store = ImportedModelStore(directory: directory)

        XCTAssertFalse(store.isAvailable)
        XCTAssertThrowsError(try store.upsert(makeRecord(id: "hf-must-not-overwrite"))) { error in
            XCTAssertEqual(error as? ImportedModelStoreError, .registryUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), corrupt)
    }

    func testRegistryRecoversLastVersionedBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedModelStore(directory: directory)
        try store.upsert(makeRecord(id: "hf-backed-up"))
        try store.upsert(makeRecord(id: "hf-newer", repo: "acme/newer"))
        try Data("corrupt-primary".utf8).write(to: directory.appendingPathComponent("registry.json"))

        let recovered = ImportedModelStore(directory: directory)

        XCTAssertTrue(recovered.isAvailable)
        XCTAssertNotNil(recovered.record(id: "hf-backed-up"))
        XCTAssertNil(recovered.record(id: "hf-newer"))

        // Recovery must also repair the primary on the next mutation rather
        // than trying to rotate corrupt bytes over the known-good backup.
        try recovered.upsert(makeRecord(id: "hf-after-recovery", repo: "acme/after-recovery"))
        let relaunched = ImportedModelStore(directory: directory)
        XCTAssertNotNil(relaunched.record(id: "hf-backed-up"))
        XCTAssertNotNil(relaunched.record(id: "hf-after-recovery"))
    }

    func testProtectedDataReadFailureBlocksThenRecoversRegistry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seeded = ImportedModelStore(directory: directory)
        try seeded.upsert(makeRecord(id: "hf-protected"))

        var protectedDataAvailable = false
        let locked = ImportedModelStore(directory: directory, reader: { url in
            guard protectedDataAvailable else { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })

        XCTAssertFalse(locked.isAvailable)
        XCTAssertThrowsError(try locked.upsert(makeRecord(id: "hf-must-wait"))) { error in
            XCTAssertEqual(error as? ImportedModelStoreError, .registryUnavailable)
        }

        protectedDataAvailable = true
        XCTAssertTrue(locked.isAvailable)
        XCTAssertNotNil(locked.record(id: "hf-protected"))
        try locked.upsert(makeRecord(id: "hf-after-unlock", repo: "acme/after-unlock"))
        XCTAssertNotNil(ImportedModelStore(directory: directory).record(id: "hf-after-unlock"))
    }

    func testMissingPrimaryRecoversFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedModelStore(directory: directory)
        try store.upsert(makeRecord(id: "hf-backup-base"))
        try store.upsert(makeRecord(id: "hf-primary-only", repo: "acme/primary-only"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("registry.json"))

        let recovered = ImportedModelStore(directory: directory)

        XCTAssertTrue(recovered.isAvailable)
        XCTAssertNotNil(recovered.record(id: "hf-backup-base"))
        XCTAssertNil(recovered.record(id: "hf-primary-only"))
    }

    @MainActor
    func testDeletionWriteFailureLeavesRecordAndArtifactIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var writeCount = 0
        let store = ImportedModelStore(directory: directory, writer: { data, url in
            writeCount += 1
            if writeCount == 2 { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let record = makeRecord(id: "hf-delete-transaction")
        try store.upsert(record)
        let artifactURL = ModelManagerService.baseModelPath(for: record.model)
        try TestModelFixtures.gguf().write(to: artifactURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: artifactURL) }

        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        let lifecycle = ModelLifecycleManager(
            inferenceService: InferenceService(),
            memoryBudgeter: MemoryBudgeter()
        )
        let viewModel = ModelsViewModel(
            downloadManager: manager,
            lifecycleManager: lifecycle,
            importedModelStore: store,
            importedModelUpdateStore: ImportedModelUpdateStore(
                directory: directory.appendingPathComponent("updates")
            )
        )

        do {
            try await viewModel.deleteModel(record.model)
            XCTFail("Expected registry write failure")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: artifactURL.path))
            XCTAssertNotNil(store.record(id: record.id))
        }
    }

    @MainActor
    func testDeletionAlsoForgetsPendingUpdateAndConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportedModelStore(directory: root.appendingPathComponent("installed"))
        let updateStore = ImportedModelUpdateStore(directory: root.appendingPathComponent("updates"))
        let installed = makeRecord(id: "hf-delete-with-update")
        var staged = makeRecord(
            id: "hf-delete-with-update-staged",
            digest: String(repeating: "b", count: 64),
            repo: "acme/model-update"
        )
        staged.updateTargetModelID = installed.id
        try store.upsert(installed)
        try updateStore.upsert(staged)
        ExperimentalModelConsent.setGranted(true, for: installed.model)
        defer { ExperimentalModelConsent.setGranted(false, for: installed.model) }

        let stagedTask = DownloadTask(model: staged.model, artifact: .base)
        try Data("partial".utf8).write(to: stagedTask.stagingURL, options: .atomic)
        stagedTask.progress = 0.2
        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        manager.persistDurableState(for: stagedTask)
        let lifecycle = ModelLifecycleManager(
            inferenceService: InferenceService(),
            memoryBudgeter: MemoryBudgeter()
        )
        let viewModel = ModelsViewModel(
            downloadManager: manager,
            lifecycleManager: lifecycle,
            importedModelStore: store,
            importedModelUpdateStore: updateStore
        )

        try await viewModel.deleteModel(installed.model)

        XCTAssertNil(store.record(id: installed.id))
        XCTAssertNil(updateStore.record(targetModelID: installed.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedTask.stagingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedTask.metadataURL.path))
        XCTAssertFalse(ExperimentalModelConsent.isGranted(for: installed.model))
    }

    // MARK: - Helpers

    private func makeRecord(
        id: String,
        filename: String = "model-Q4_K_M.gguf",
        digest: String = String(repeating: "a", count: 64),
        repo: String = "acme/model"
    ) -> ImportedModelRecord {
        let artifact = HFArtifact(
            filename: filename, size: 16, sha256: digest,
            quantization: "Q4_K_M", architecture: "llama",
            role: .base,
            metadata: HFGGUFMetadata(architecture: "llama", contextLength: 2048, chatTemplate: nil, modelName: "Fixture")
        )
        let review = HFRepositoryReview(
            repositoryID: repo,
            revision: String(repeating: "f", count: 40),
            licenseName: "apache-2.0",
            licenseURL: URL(string: "https://example.com/license")!,
            artifacts: [artifact]
        )
        return ImportedModelFactory.makeRecord(review: review, base: artifact, stableID: id)
    }
}
