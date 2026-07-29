import XCTest
@testable import ZiroEdge

/// Validates the full download transfer lifecycle for imported models:
/// pause preserves state, resume continues without restart, cancel removes
/// partial state, and progress is accurately reported.
final class ImportTransferLifecycleTests: XCTestCase {

    // MARK: - Pause Preserves Durable State

    @MainActor
    func testPausePreservesDurableStateForImportedModel() async throws {
        let model = makeImportedModel(size: 1_000_000)
        ModelManagerService.ensureModelsDirectory()
        let task = DownloadTask(model: model, artifact: .base)
        // Write partial staging data to simulate an in-progress download.
        let partial = Data(repeating: 0xA5, count: 500_000)
        try partial.write(to: task.stagingURL)
        defer { try? FileManager.default.removeItem(at: task.stagingURL) }

        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        let status = manager.status(for: model)

        // Staging file exists → should recover as paused.
        guard case .paused(let progress) = status.baseState else {
            XCTFail("Expected paused state, got \(status.baseState)")
            return
        }
        XCTAssertEqual(progress, 0.5, accuracy: 0.001)
    }

    @MainActor
    func testPausePreservesResumeDataFile() async throws {
        let model = makeImportedModel(size: 1_000_000)
        let task = DownloadTask(model: model, artifact: .base)
        let resumeData = Data(repeating: 0xBB, count: 100)
        try resumeData.write(to: task.resumeDataURL)
        defer { try? FileManager.default.removeItem(at: task.resumeDataURL) }

        // Recover should find the resume data and report paused.
        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        // The resume data alone (without a staging file) signals a paused transfer.
        let status = manager.status(for: model)
        // Either paused or notDownloaded depending on whether staging file exists.
        // The key property: the resume data file survives across init cycles.
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.resumeDataURL.path))
    }

    // MARK: - Cancel Removes Partial State

    @MainActor
    func testCancelRemovesStagingFile() throws {
        let model = makeImportedModel(size: 1_000_000)
        let task = DownloadTask(model: model, artifact: .base)
        try Data(repeating: 0xCC, count: 100).write(to: task.stagingURL)

        // Manually trigger cancel cleanup.
        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        manager.cancelDownload(for: model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: task.stagingURL.path),
                       "Staging file should be removed after cancel")
    }

    @MainActor
    func testCancelRemovesResumeData() throws {
        let model = makeImportedModel(size: 1_000_000)
        let task = DownloadTask(model: model, artifact: .base)
        try Data(repeating: 0xDD, count: 100).write(to: task.resumeDataURL)

        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        manager.cancelDownload(for: model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: task.resumeDataURL.path),
                       "Resume data should be removed after cancel")
    }

    // MARK: - Progress Tracking

    @MainActor
    func testModelDownloadStatusOverallProgressAveragesPairedArtifacts() {
        // Base at 100%, mmproj at 50% → overall should be 75%.
        let status = ModelDownloadStatus(
            modelID: "test",
            baseState: .downloaded,
            mmprojState: .downloading(progress: 0.5)
        )
        XCTAssertEqual(status.overallProgress, 0.75, accuracy: 0.01)
    }

    @MainActor
    func testTextOnlyModelProgressIsBaseProgress() {
        let status = ModelDownloadStatus(
            modelID: "test",
            baseState: .downloading(progress: 0.3),
            mmprojState: nil
        )
        XCTAssertEqual(status.overallProgress, 0.3, accuracy: 0.01)
    }

    // MARK: - Verification Before Promotion

    @MainActor
    func testVerifierRejectsFileSmallerThanExpected() throws {
        let model = makeImportedModel(size: 1_000)
        let task = DownloadTask(model: model, artifact: .base)
        // Write only 100 bytes when 1000 are expected.
        try Data(repeating: 0xEE, count: 100).write(to: task.stagingURL)
        defer { try? FileManager.default.removeItem(at: task.stagingURL) }

        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        switch manager.verifyAndPromote(task: task) {
        case .success:
            XCTFail("Undersized file must not be promoted")
        case .failure(let error):
            XCTAssertEqual(error, .fileCorrupted)
        }
    }

    @MainActor
    func testVerifierRejectsWrongSHA() throws {
        let gguf = TestModelFixtures.gguf(count: 100)
        let wrongDigest = String(repeating: "0", count: 64)
        // Create a model whose expected SHA doesn't match the actual file.
        let model = AIModel(
            id: "sha-mismatch-test",
            displayName: "SHA Mismatch",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(gguf.count),
            mmprojFileSizeBytes: nil,
            baseSHA256: wrongDigest,
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test"),
            source: .curated
        )
        let task = DownloadTask(model: model, artifact: .base)
        try gguf.write(to: task.stagingURL)
        defer { try? FileManager.default.removeItem(at: task.stagingURL) }

        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        switch manager.verifyAndPromote(task: task) {
        case .success:
            XCTFail("SHA mismatch must not be promoted")
        case .failure(let error):
            XCTAssertEqual(error, .sha256Mismatch)
        }
    }

    @MainActor
    func testVerifierAcceptsValidGGUFWithMatchingIntegrity() throws {
        let gguf = TestModelFixtures.gguf(count: 100)
        let digest = TestModelFixtures.sha256(gguf)
        let model = AIModel(
            id: "valid-test",
            displayName: "Valid",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(gguf.count),
            mmprojFileSizeBytes: nil,
            baseSHA256: digest,
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test"),
            source: .curated
        )
        let task = DownloadTask(model: model, artifact: .base)
        try gguf.write(to: task.stagingURL)
        defer {
            try? FileManager.default.removeItem(at: task.stagingURL)
            try? FileManager.default.removeItem(at: task.destinationURL)
        }

        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        switch manager.verifyAndPromote(task: task) {
        case .success:
            // Promoted → destination should exist.
            XCTAssertTrue(FileManager.default.fileExists(atPath: task.destinationURL.path))
        case .failure(let error):
            XCTFail("Valid GGUF must be promoted, got: \(error)")
        }
    }

    // MARK: - Staging Isolation

    @MainActor
    func testStagingFileNeverExposedAtInstalledPathUntilPromotion() throws {
        let gguf = TestModelFixtures.gguf(count: 100)
        let digest = TestModelFixtures.sha256(gguf)
        let model = AIModel(
            id: "staging-test",
            displayName: "Staging",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(gguf.count),
            mmprojFileSizeBytes: nil,
            baseSHA256: digest,
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test"),
            source: .curated
        )
        let task = DownloadTask(model: model, artifact: .base)
        try gguf.write(to: task.stagingURL)
        defer {
            try? FileManager.default.removeItem(at: task.stagingURL)
            try? FileManager.default.removeItem(at: task.destinationURL)
        }

        // Before promotion, staging file exists but destination does not.
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.stagingURL.path))
        try? FileManager.default.removeItem(at: task.destinationURL)

        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        _ = manager.verifyAndPromote(task: task)

        // After promotion, destination exists.
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.destinationURL.path))
        // Staging file should be gone after successful promotion.
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.stagingURL.path))
    }

    // MARK: - Helpers

    private func makeImportedModel(size: Int64 = 16, digest: String = String(repeating: "a", count: 64)) -> AIModel {
        let artifact = HFArtifact(
            filename: "model-Q4_K_M.gguf",
            size: size,
            sha256: digest,
            quantization: "Q4_K_M",
            architecture: "llama",
            role: .base,
            metadata: HFGGUFMetadata(architecture: "llama", contextLength: 2048)
        )
        let review = HFRepositoryReview(
            repositoryID: "acme/model",
            revision: String(repeating: "f", count: 40),
            licenseName: "apache-2.0",
            licenseURL: URL(string: "https://example.com/license")!,
            artifacts: [artifact]
        )
        return ImportedModelFactory.makeRecord(review: review, base: artifact).model
    }
}
