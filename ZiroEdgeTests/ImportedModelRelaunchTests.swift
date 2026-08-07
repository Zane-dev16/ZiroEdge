// ImportedModelRelaunchTests.swift
// ZiroEdgeTests
//
// Tests for relaunch behavior: registry persistence across app restarts,
// load status recovery, and duplicate prevention on re-import.

import XCTest
@testable import ZiroEdge

final class ImportedModelRelaunchTests: XCTestCase {

    // MARK: - Registry persistence across relaunch

    func testRegistryPersistsRecordsAcrossRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let q4 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let review = makeReview(artifacts: [q4])

        // First launch: create a record.
        let store1 = ImportedModelStore(directory: directory)
        let record = ImportedModelFactory.makeRecord(review: review, base: q4)
        try store1.upsert(record)
        XCTAssertEqual(store1.allRecords.count, 1)

        // "Relaunch": create a new store with the same directory.
        let store2 = ImportedModelStore(directory: directory)
        XCTAssertEqual(store2.allRecords.count, 1)
        XCTAssertEqual(store2.allRecords.first?.id, record.id)
        XCTAssertEqual(store2.allRecords.first?.provenance.revision, review.revision)
    }

    func testRegistryPreservesLoadStatusAcrossRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let q4 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let review = makeReview(artifacts: [q4])
        var record = ImportedModelFactory.makeRecord(review: review, base: q4)
        record.loadStatus = .loadFailed(kind: "contextCreation", diagnostic: "Test diagnostic", at: Date())

        let store1 = ImportedModelStore(directory: directory)
        try store1.upsert(record)

        let store2 = ImportedModelStore(directory: directory)
        let recovered = store2.record(id: record.id)
        guard case .loadFailed(let kind, let diagnostic, _) = recovered?.loadStatus else {
            return XCTFail("Expected loadFailed status across relaunch")
        }
        XCTAssertEqual(kind, "contextCreation")
        XCTAssertEqual(diagnostic, "Test diagnostic")
    }

    func testRegistryPreservesConfigurationChangeStatusAcrossRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let q4 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let review = makeReview(artifacts: [q4])
        var record = ImportedModelFactory.makeRecord(review: review, base: q4)
        record.loadStatus = .configurationChanged

        let store1 = ImportedModelStore(directory: directory)
        try store1.upsert(record)

        let store2 = ImportedModelStore(directory: directory)
        let recovered = store2.record(id: record.id)
        XCTAssertEqual(recovered?.loadStatus, .configurationChanged)
    }

    // MARK: - Duplicate prevention on re-import

    func testReImportResolvesToExistingIdentityInsteadOfDuplicating() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ImportedModelStore(directory: directory)
        let q4 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let review = makeReview(artifacts: [q4])
        let first = ImportedModelFactory.makeRecord(review: review, base: q4)
        try store.upsert(first)

        // Re-import the same repo/revision/artifact.
        let duplicate = store.record(
            repositoryID: review.repositoryID,
            revision: review.revision,
            baseFilename: q4.filename,
            projectorFilename: nil
        )
        XCTAssertNotNil(duplicate)
        XCTAssertEqual(duplicate?.id, first.id)

        // upsert with same identity key returns existing, doesn't create second.
        let result = try store.upsert(ImportedModelFactory.makeRecord(review: review, base: q4))
        XCTAssertEqual(result.id, first.id)
        XCTAssertEqual(store.allRecords.count, 1)
    }

    func testReImportWithDifferentRevisionCreatesNewRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ImportedModelStore(directory: directory)

        let q4v1 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let review1 = makeReview(revision: String(repeating: "a", count: 40), artifacts: [q4v1])
        let first = ImportedModelFactory.makeRecord(review: review1, base: q4v1)
        try store.upsert(first)

        // Different revision — should create a distinct record.
        let q4v2 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "2", count: 64))
        let review2 = makeReview(revision: String(repeating: "b", count: 40), artifacts: [q4v2])
        let second = ImportedModelFactory.makeRecord(review: review2, base: q4v2)
        try store.upsert(second)

        XCTAssertEqual(store.allRecords.count, 2)
        XCTAssertNotEqual(first.id, second.id)
    }

    // MARK: - Store integrity

    func testCorruptRegistryFileBlocksMutationWithoutBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registryURL = directory.appendingPathComponent("registry.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: registryURL)

        let store = ImportedModelStore(directory: directory)
        XCTAssertFalse(store.isAvailable)

        let q4 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let review = makeReview(artifacts: [q4])
        let record = ImportedModelFactory.makeRecord(review: review, base: q4)
        XCTAssertThrowsError(try store.upsert(record)) { error in
            XCTAssertEqual(error as? ImportedModelStoreError, .registryUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), corrupt)
    }

    func testStoreUpdatePreservesOtherRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ImportedModelStore(directory: directory)
        let q4 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let q8 = makeArtifact("model-Q8_0.gguf", digest: String(repeating: "2", count: 64))
        let review = makeReview(artifacts: [q4, q8])
        let first = ImportedModelFactory.makeRecord(review: review, base: q4)
        let second = ImportedModelFactory.makeRecord(review: review, base: q8)
        try store.upsert(first)
        try store.upsert(second)

        // Update one record's display name.
        try store.update(id: first.id) { $0.displayName = "Renamed Q4" }

        // Verify the second record is unchanged.
        let store2 = ImportedModelStore(directory: directory)
        let r1 = store2.record(id: first.id)
        let r2 = store2.record(id: second.id)
        XCTAssertEqual(r1?.displayName, "Renamed Q4")
        XCTAssertEqual(r2?.displayName, second.displayName)
    }

    // MARK: - Helpers

    private func makeArtifact(
        _ filename: String,
        digest: String = String(repeating: "a", count: 64),
        role: HFArtifact.Role = .base,
        architecture: String = "llama",
        size: Int64 = 16
    ) -> HFArtifact {
        HFArtifact(
            filename: filename, size: size, sha256: digest,
            quantization: filename.uppercased().contains("Q8") ? "Q8_0" : "Q4_K_M",
            architecture: architecture, role: role,
            metadata: HFGGUFMetadata(architecture: architecture, contextLength: 2048, chatTemplate: "fixture", modelName: "Fixture")
        )
    }

    private func makeReview(revision: String = String(repeating: "f", count: 40), artifacts: [HFArtifact]) -> HFRepositoryReview {
        HFRepositoryReview(
            repositoryID: "acme/model",
            revision: revision,
            licenseName: "apache-2.0",
            licenseURL: URL(string: "https://example.com/license")!,
            artifacts: artifacts
        )
    }
}
