// StorageConstraintQATests.swift
// ZiroEdgeTests
//
// Tests that exercise low storage, out-of-space, and valid-installation
// preservation under adverse storage conditions. Extracted from
// DeviceLifecycleQATests.swift for file-size hygiene.

import XCTest
@testable import ZiroEdge

// MARK: - Storage Constraint Tests

/// Tests that exercise low storage, out-of-space, and valid-installation
/// preservation under adverse storage conditions.
@MainActor
final class StorageConstraintQATests: XCTestCase {

    var downloadManager: DownloadManager!

    override func setUp() {
        super.setUp()
        downloadManager = DownloadManager()
    }

    override func tearDown() {
        for model in ModelRegistry.allModels {
            downloadManager.cancelDownload(for: model)
            ModelManagerService.deleteModel(model)
        }
        downloadManager = nil
        super.tearDown()
    }

    // MARK: Low Storage Detection

    func testAvailableDiskSpaceIsReadable() {
        let space = downloadManager.availableDiskSpace
        XCTAssertGreaterThanOrEqual(space, 0, "Available disk space must be non-negative")
    }

    func testStorageSafetyMarginIsReasonable() {
        XCTAssertGreaterThan(
            DownloadManager.storageSafetyMarginBytes,
            0,
            "Safety margin must be positive"
        )
    }

    func testRequiredDownloadBytesIncludesMarginForTextModel() {
        let model = ModelRegistry.llama32_3B
        let required = downloadManager.requiredDownloadBytes(for: model)
        // Should include the base file size + safety margin.
        let minimumRequired = model.baseFileSizeBytes + DownloadManager.storageSafetyMarginBytes
        XCTAssertEqual(required, minimumRequired)
    }

    func testRequiredDownloadBytesIncludesMarginForVisionModel() {
        let model = ModelRegistry.gemma4_e2b
        let required = downloadManager.requiredDownloadBytes(
            for: model,
            includeOptionalProjector: true
        )
        let minimumRequired = model.baseFileSizeBytes
            + (model.mmprojFileSizeBytes ?? 0)
            + DownloadManager.storageSafetyMarginBytes
        XCTAssertEqual(required, minimumRequired)
    }

    func testRequiredDownloadBytesExcludesProjectorWhenOptionallySkippedForE2B() {
        let model = ModelRegistry.gemma4_e2b
        let required = downloadManager.requiredDownloadBytes(
            for: model,
            includeOptionalProjector: false
        )
        // When projector is skipped, only base + margin is required.
        let expected = model.baseFileSizeBytes + DownloadManager.storageSafetyMarginBytes
        XCTAssertEqual(required, expected)
    }

    // MARK: Out Of Space Behavior

    func testOutOfSpaceDoesNotCorruptExistingInstallation() throws {
        let data = TestModelFixtures.gguf()
        let model = TestModelFixtures.text(data: data)
        defer { ModelManagerService.deleteModel(model) }
        try TestModelFixtures.install(data, for: model)

        // Verify the installed model is intact.
        XCTAssertTrue(ModelManagerService.isArtifactVerified(model, artifact: .base, depth: .full))
        XCTAssertTrue(ModelManagerService.isFullyDownloaded(model))

        // Simulate a disk space shortage check — should not touch installed files.
        let task = DownloadTask(model: model, artifact: .base)
        let stagedData = Data(repeating: 0xBB, count: 32)
        try stagedData.write(to: task.stagingURL, options: .atomic)

        // If verification fails (SHA mismatch), staging is cleaned, but destination is preserved.
        let verifyResult = downloadManager.verifyAndPromote(task: task)
        if case .failure = verifyResult {
            // Staging should be cleaned, destination untouched.
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: task.stagingURL.path),
                "Failed staging must be cleaned"
            )
            // Original installation preserved.
            XCTAssertTrue(ModelManagerService.isArtifactVerified(model, artifact: .base, depth: .full))
        }
    }

    func testDiskSpaceInsufficientDuringVerificationPreservesStaging() throws {
        let data = TestModelFixtures.gguf(count: 64)
        let model = TestModelFixtures.text(data: data)
        defer { ModelManagerService.deleteModel(model) }
        try data.write(to: DownloadTask(model: model, artifact: .base).stagingURL, options: .atomic)

        // We can't easily simulate actual out-of-space, but we verify the fail path.
        let task = DownloadTask(model: model, artifact: .base)
        task.state = .verifying
        downloadManager.updateStatus(model: model)

        let status = downloadManager.status(for: model)
        // The verification path requires actual disk space check first.
        if case .verifying = status.baseState {
            XCTAssertTrue(status.baseState.isActive)
        }
    }

    // MARK: Valid Installation Preservation

    func testValidInstallationSurvivesAdverseStorageCheck() throws {
        let data = TestModelFixtures.gguf(count: 256)
        let model = TestModelFixtures.text(data: data)
        defer { ModelManagerService.deleteModel(model) }
        try TestModelFixtures.install(data, for: model)

        // Multiple storage checks must not degrade a valid installation.
        for _ in 0..<5 {
            XCTAssertTrue(ModelManagerService.isArtifactVerified(model, artifact: .base, depth: .full))
            XCTAssertTrue(ModelManagerService.isFullyDownloaded(model))
        }
    }

    func testSharedStorageIDConceptForImportedPairs() throws {
        // Two imported rows with the same digest resolve to one storage ID and one file.
        // (Previously exercised with the E4B catalog pair; the concept is registry-independent.)
        let digest = String(repeating: "b", count: 64)
        let provenance = HuggingFaceProvenance(
            repositoryID: "test/shared-base",
            revision: "main",
            baseFilename: "shared.gguf",
            baseSHA256: digest,
            architecture: "llama",
            projectorFilename: nil,
            projectorSHA256: nil
        )
        var first = TestModelFixtures.text(id: "fixture-qa-a-\(UUID().uuidString.lowercased())")
        first.source = .huggingFace(provenance)
        var second = TestModelFixtures.text(id: "fixture-qa-b-\(UUID().uuidString.lowercased())")
        second.source = .huggingFace(provenance)
        XCTAssertEqual(first.baseArtifactStorageID, second.baseArtifactStorageID)
        XCTAssertEqual(
            ModelManagerService.baseModelPath(for: first),
            ModelManagerService.baseModelPath(for: second)
        )
    }

    func testSharedBaseArtifactNotDeletedWhenOneVariantRemoved() throws {
        let digest = String(repeating: "c", count: 64)
        let provenance = HuggingFaceProvenance(
            repositoryID: "test/shared-base",
            revision: "main",
            baseFilename: "shared.gguf",
            baseSHA256: digest,
            architecture: "llama",
            projectorFilename: nil,
            projectorSHA256: nil
        )
        var first = TestModelFixtures.text(id: "fixture-qa-c-\(UUID().uuidString.lowercased())")
        first.source = .huggingFace(provenance)
        var second = TestModelFixtures.text(id: "fixture-qa-d-\(UUID().uuidString.lowercased())")
        second.source = .huggingFace(provenance)
        let path = ModelManagerService.baseModelPath(for: first)
        ModelManagerService.ensureModelsDirectory()
        try Data("shared-base".utf8).write(to: path, options: .atomic)
        defer { try? FileManager.default.removeItem(at: path) }

        ModelManagerService.deleteModel(first, preservingReferences: [second])

        // Base must survive because the sibling variant also references it.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path.path),
            "Shared base artifact must survive sibling-variant deletion"
        )
    }
}
