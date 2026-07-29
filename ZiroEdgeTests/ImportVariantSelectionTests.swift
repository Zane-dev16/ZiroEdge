// ImportVariantSelectionTests.swift
// ZiroEdgeTests
//
// Tests for multi-variant GGUF selection, duplicate detection,
// and variant coexistence in the model library.

import XCTest
@testable import ZiroEdge

final class ImportVariantSelectionTests: XCTestCase {
    private func response(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://huggingface.co/api/models/acme/model")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func payload(
        revision: String = String(repeating: "a", count: 40),
        architecture: String = "llama",
        siblings: [[String: Any]]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "sha": revision,
            "cardData": ["license": "apache-2.0"],
            "gguf": ["architecture": architecture, "context_length": 8192, "chat_template": "fixture"],
            "siblings": siblings,
        ])
    }

    private func artifact(
        _ name: String,
        digest: String = String(repeating: "a", count: 64),
        size: Int64 = 16,
        lfs: Bool = true
    ) -> [String: Any] {
        var dict: [String: Any] = ["rfilename": name, "size": size]
        if lfs { dict["lfs"] = ["sha256": digest] }
        return dict
    }

    // MARK: - Variant listing

    func testInspectionListsEveryCompatibleBaseGGUFAtPinnedRevision() async throws {
        let revision = String(repeating: "b", count: 40)
        let data = try payload(revision: revision, siblings: [
            artifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64), size: 100),
            artifact("model-Q8_0.gguf", digest: String(repeating: "2", count: 64), size: 200),
            artifact("model-F16.gguf", digest: String(repeating: "3", count: 64), size: 400),
            artifact("README.md", size: 10, lfs: false),
            artifact("config.json", size: 1, lfs: false),
        ])
        let inspector = HFRepositoryInspector { _ in (data, self.response()) }
        let review = try await inspector.inspect("acme/model")

        XCTAssertEqual(review.baseArtifacts.count, 3)
        XCTAssertEqual(review.baseArtifacts.map(\.filename), [
            "model-F16.gguf", "model-Q4_K_M.gguf", "model-Q8_0.gguf"
        ])
        XCTAssertEqual(review.baseArtifacts.map(\.quantization), ["F16", "Q4_K_M", "Q8_0"])
    }

    func testInspectionRequiresExplicitVariantSelection() async throws {
        let data = try payload(siblings: [
            artifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64), size: 100),
            artifact("model-Q8_0.gguf", digest: String(repeating: "2", count: 64), size: 200),
        ])
        let inspector = HFRepositoryInspector { _ in (data, self.response()) }
        let review = try await inspector.inspect("acme/model")

        // With multiple variants, none should be auto-selected.
        XCTAssertGreaterThan(review.baseArtifacts.count, 1)
    }

    func testSingleVariantRepoAutoSelectsTheOnlyBase() async throws {
        let data = try payload(siblings: [
            artifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64), size: 100),
        ])
        let inspector = HFRepositoryInspector { _ in (data, self.response()) }
        let review = try await inspector.inspect("acme/model")

        XCTAssertEqual(review.baseArtifacts.count, 1)
    }

    // MARK: - Duplicate resolution

    func testDuplicateImportResolvesToExistingIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedModelStore(directory: directory)

        let q4 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let review = makeReview(artifacts: [q4])
        let first = ImportedModelFactory.makeRecord(review: review, base: q4)
        _ = try store.upsert(first)

        // Same repo/revision/artifact should resolve to existing record.
        let duplicate = store.record(
            repositoryID: review.repositoryID,
            revision: review.revision,
            baseFilename: q4.filename,
            projectorFilename: nil
        )
        XCTAssertNotNil(duplicate)
        XCTAssertEqual(duplicate?.id, first.id)
    }

    func testDifferentVariantsFromSameRepoAreDistinct() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedModelStore(directory: directory)

        let q4 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let q8 = makeArtifact("model-Q8_0.gguf", digest: String(repeating: "2", count: 64))
        let review = makeReview(artifacts: [q4, q8])

        let first = ImportedModelFactory.makeRecord(review: review, base: q4)
        let second = ImportedModelFactory.makeRecord(review: review, base: q8)
        _ = try store.upsert(first)
        _ = try store.upsert(second)

        XCTAssertEqual(store.allRecords.count, 2)
        XCTAssertNotEqual(first.id, second.id)

        // Both should be distinguishable in the model picker.
        let models = store.models
        XCTAssertEqual(models.count, 2)
        XCTAssertTrue(models.allSatisfy { $0.isImported })
        XCTAssertEqual(Set(models.map(\.id)), [first.id, second.id])
    }

    func testSameRepoDifferentRevisionsAreDistinct() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedModelStore(directory: directory)

        let artifact1 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let artifact2 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "2", count: 64))
        let review1 = HFRepositoryReview(
            repositoryID: "acme/model", revision: String(repeating: "a", count: 40),
            licenseName: "apache-2.0", licenseURL: URL(string: "https://example.com")!,
            artifacts: [artifact1]
        )
        let review2 = HFRepositoryReview(
            repositoryID: "acme/model", revision: String(repeating: "b", count: 40),
            licenseName: "apache-2.0", licenseURL: URL(string: "https://example.com")!,
            artifacts: [artifact2]
        )
        let r1 = ImportedModelFactory.makeRecord(review: review1, base: artifact1)
        let r2 = ImportedModelFactory.makeRecord(review: review2, base: artifact2)
        _ = try store.upsert(r1)
        _ = try store.upsert(r2)

        XCTAssertEqual(store.allRecords.count, 2)
    }

    // MARK: - Removing one variant does not alter remaining

    func testRemovingOneVariantPreservesOtherVariants() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedModelStore(directory: directory)

        let q4 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let q8 = makeArtifact("model-Q8_0.gguf", digest: String(repeating: "2", count: 64))
        let review = makeReview(artifacts: [q4, q8])
        let first = ImportedModelFactory.makeRecord(review: review, base: q4)
        let second = ImportedModelFactory.makeRecord(review: review, base: q8)
        _ = try store.upsert(first)
        _ = try store.upsert(second)

        try store.remove(id: first.id)

        let remaining = store.allRecords
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, second.id)
        XCTAssertNil(store.record(id: first.id))
        XCTAssertNotNil(store.record(id: second.id))
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
            filename: filename,
            size: size,
            sha256: digest,
            quantization: filename.uppercased().contains("Q8") ? "Q8_0"
                : filename.uppercased().contains("F16") ? "F16" : "Q4_K_M",
            architecture: architecture,
            role: role,
            metadata: HFGGUFMetadata(architecture: architecture, contextLength: 2048, chatTemplate: "fixture", modelName: "Fixture")
        )
    }

    private func makeReview(artifacts: [HFArtifact]) -> HFRepositoryReview {
        HFRepositoryReview(
            repositoryID: "acme/model",
            revision: String(repeating: "f", count: 40),
            licenseName: "apache-2.0",
            licenseURL: URL(string: "https://example.com/license")!,
            artifacts: artifacts
        )
    }
}
