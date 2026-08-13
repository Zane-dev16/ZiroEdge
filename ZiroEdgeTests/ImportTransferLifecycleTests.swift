import XCTest
@testable import ZiroEdge

/// Validates the full download transfer lifecycle for imported models:
/// pause preserves resumable state, cancellation removes disposable partial
/// state, and progress is accurately reported.
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
        defer {
            try? FileManager.default.removeItem(at: task.stagingURL)
            try? FileManager.default.removeItem(at: task.metadataURL)
        }

        task.progress = 0.5
        DownloadManager(availableDiskSpaceProvider: { .max }).persistDurableState(for: task)
        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        manager.restoreDurableTransfers(models: [model])
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
        _ = DownloadManager(availableDiskSpaceProvider: { .max })
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
                       "User-visible cancel must remove disposable staging")
    }

    @MainActor
    func testCancelRemovesResumeData() throws {
        let model = makeImportedModel(size: 1_000_000)
        let task = DownloadTask(model: model, artifact: .base)
        try Data(repeating: 0xDD, count: 100).write(to: task.resumeDataURL)

        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        manager.cancelDownload(for: model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.resumeDataURL.path),
                       "User-visible cancel must remove disposable resume data")
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
            guard case .sizeMismatch(expected: 1_000, actual: 100) = error else {
                XCTFail("Expected size mismatch before structural parsing, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testVerifierRejectsMagicAndVersionOnlyFixture() throws {
        var malformed = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0])
        malformed.append(Data(repeating: 0xA5, count: 92))
        let model = makeImportedModel(
            size: Int64(malformed.count),
            digest: TestModelFixtures.sha256(malformed)
        )
        let task = DownloadTask(model: model, artifact: .base)
        try malformed.write(to: task.stagingURL)
        defer { try? FileManager.default.removeItem(at: task.stagingURL) }

        let result = DownloadManager(availableDiskSpaceProvider: { .max })
            .verifyAndPromote(task: task)
        guard case .failure(.structureInvalid) = result else {
            return XCTFail("A matching size and digest cannot substitute for GGUF table validation")
        }
    }

    @MainActor
    func testSharedArtifactDiscardPreservesAnotherActiveTransfer() throws {
        let digest = String(repeating: "a", count: 64)
        let first = makeImportedModel(id: "hf-shared-first", size: 1_000_000, digest: digest)
        let second = makeImportedModel(id: "hf-shared-second", size: 1_000_000, digest: digest)
        let firstTask = DownloadTask(model: first, artifact: .base)
        let secondTask = DownloadTask(model: second, artifact: .base)
        XCTAssertEqual(firstTask.storageID, secondTask.storageID)
        try Data(repeating: 0xAA, count: 128).write(to: firstTask.stagingURL)
        defer { try? FileManager.default.removeItem(at: firstTask.stagingURL) }

        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        manager.activeTasks[firstTask.storageID] = firstTask
        manager.discardPartialDownload(for: second)

        XCTAssertTrue(FileManager.default.fileExists(atPath: firstTask.stagingURL.path))
        XCTAssertTrue(manager.activeTasks[firstTask.storageID] === firstTask)
    }

    @MainActor
    func testArtifactScopedSnapshotRestoresThroughAnyMatchingModel() throws {
        let digest = String(repeating: "b", count: 64)
        let first = makeImportedModel(id: "hf-shared-owner", size: 1_000_000, digest: digest)
        let second = makeImportedModel(id: "hf-shared-relaunch", size: 1_000_000, digest: digest)
        let persistedTask = DownloadTask(model: first, artifact: .base)
        try Data(repeating: 0xBB, count: 100).write(to: persistedTask.stagingURL)
        persistedTask.progress = 0.25
        let writer = DownloadManager(availableDiskSpaceProvider: { .max })
        writer.persistDurableState(for: persistedTask)
        defer {
            try? FileManager.default.removeItem(at: persistedTask.stagingURL)
            try? FileManager.default.removeItem(at: persistedTask.metadataURL)
        }

        let restored = DownloadManager(availableDiskSpaceProvider: { .max })
        restored.restoreDurableTransfers(models: [second])

        XCTAssertEqual(restored.activeTasks[persistedTask.storageID]?.model.id, second.id)
    }

    @MainActor
    func testCancelledTaskCannotStartTransferAfterResolutionCallback() {
        let model = makeImportedModel(size: 1_000_000)
        let task = DownloadTask(model: model, artifact: .base)
        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        manager.activeTasks[task.storageID] = task
        manager.cancelDownload(for: model)

        manager.transfer(task: task, key: task.storageID, downloadURL: task.sourceURL)

        XCTAssertNil(task.task)
        XCTAssertNil(task.chunkTask)
        XCTAssertNil(manager.activeTasks[task.storageID])
    }

    @MainActor
    func testLargeImportedArtifactUsesBoundedChunkedTransfer() {
        let model = makeImportedModel(size: DownloadManager.chunkedDownloadThreshold + 1)
        let task = DownloadTask(model: model, artifact: .base)
        XCTAssertTrue(managerForTransferDecision().shouldUseChunkedTransfer(for: task))
    }

    @MainActor
    func testLargeImportedDurableStagingRestoresAsChunked() throws {
        let size = DownloadManager.chunkedDownloadThreshold + 1
        let model = makeImportedModel(size: size)
        let task = DownloadTask(model: model, artifact: .base)
        try Data(repeating: 0xAA, count: 1).write(to: task.stagingURL)
        task.progress = 0.1
        managerForTransferDecision().persistDurableState(for: task)
        defer {
            try? FileManager.default.removeItem(at: task.stagingURL)
            try? FileManager.default.removeItem(at: task.metadataURL)
        }

        let restored = managerForTransferDecision()
        restored.restoreDurableTransfers(models: [model])
        let active = try XCTUnwrap(restored.activeTasks[task.storageID])
        XCTAssertTrue(active.isChunked)
        XCTAssertEqual(active.totalChunks, DownloadManager.chunkCount(for: size))
    }

    @MainActor
    func testChunkCountHandlesExtremeByteCountWithoutOverflow() {
        XCTAssertEqual(DownloadManager.chunkCount(for: Int64.max), 87_960_930_223)
    }

    @MainActor
    func testChunkResumeTruncatesToPreviousBoundary() throws {
        let model = makeImportedModel(size: DownloadManager.chunkSize * 3)
        let task = DownloadTask(model: model, artifact: .base)
        let partialSize = DownloadManager.chunkSize + 17
        guard FileManager.default.createFile(atPath: task.stagingURL.path, contents: nil) else {
            return XCTFail("Failed to create test-owned partial staging file")
        }
        defer { try? FileManager.default.removeItem(at: task.stagingURL) }
        let handle = try FileHandle(forWritingTo: task.stagingURL)
        try handle.truncate(atOffset: UInt64(partialSize))
        try handle.close()

        let offset = try managerForTransferDecision().resumableChunkOffset(for: task)
        XCTAssertEqual(offset, DownloadManager.chunkSize)
        let size = try FileManager.default.attributesOfItem(atPath: task.stagingURL.path)[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, DownloadManager.chunkSize)
    }

    @MainActor
    func testContentRangeMustMatchExactly() {
        let manager = managerForTransferDecision()
        let url = URL(string: "https://huggingface.co/acme/model/resolve/revision/model.gguf")!
        let accepted = HTTPURLResponse(
            url: url, statusCode: 206, httpVersion: nil,
            headerFields: ["Content-Range": "bytes 0-99/200"]
        )!
        let rejected = HTTPURLResponse(
            url: url, statusCode: 206, httpVersion: nil,
            headerFields: ["Content-Range": "bytes 0-100/200"]
        )!
        let wrongStatus = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Range": "bytes 0-99/200"]
        )!
        XCTAssertTrue(manager.isValidChunkResponse(accepted, start: 0, end: 99, total: 200))
        XCTAssertFalse(manager.isValidChunkResponse(rejected, start: 0, end: 99, total: 200))
        XCTAssertFalse(manager.isValidChunkResponse(wrongStatus, start: 0, end: 99, total: 200))
    }

    @MainActor
    private func managerForTransferDecision() -> DownloadManager {
        DownloadManager(availableDiskSpaceProvider: { .max })
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

    private func makeImportedModel(
        id: String? = nil,
        size: Int64 = 16,
        digest: String = String(repeating: "a", count: 64)
    ) -> AIModel {
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
        return ImportedModelFactory.makeRecord(review: review, base: artifact, stableID: id).model
    }
}
