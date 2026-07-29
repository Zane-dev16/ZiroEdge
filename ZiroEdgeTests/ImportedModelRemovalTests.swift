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
        let visionModel = ModelRegistry.gemma4_e4b
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
        let store = ImportedModelStore(directory: directory) { data, url in
            writeCount += 1
            if writeCount == 2 { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
        try store.upsert(makeRecord(id: "hf-good"))

        XCTAssertThrowsError(try store.upsert(makeRecord(id: "hf-must-rollback")))
        XCTAssertEqual(store.allRecords.count, 1)
        XCTAssertEqual(store.record(id: "hf-good")?.id, "hf-good")
        XCTAssertNil(store.record(id: "hf-must-rollback"))
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
