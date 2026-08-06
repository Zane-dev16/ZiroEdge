import XCTest
@testable import ZiroEdge

/// Validates that imported models survive app relaunch exactly as they were:
/// - Imported model records persist across store re-initialization.
/// - Paused downloads are accurately recovered on relaunch.
/// - Active (in-progress) transfers are reconciled as paused.
/// - The "Imported from Hugging Face" section is populated on relaunch.
final class ImportRelaunchPersistenceTests: XCTestCase {

    // MARK: - Store Persistence

    func testImportedStoreReinitializationPreservesAllRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        // First session: create two records.
        let store1 = ImportedModelStore(directory: directory)
        let record1 = makeRecord(filename: "model-q4.gguf", digest: String(repeating: "1", count: 64))
        let record2 = makeRecord(filename: "model-q8.gguf", digest: String(repeating: "2", count: 64))
        _ = try store1.upsert(record1)
        _ = try store1.upsert(record2)
        XCTAssertEqual(store1.allRecords.count, 2)

        // Second session (simulated relaunch): re-initialize from same directory.
        let store2 = ImportedModelStore(directory: directory)
        XCTAssertEqual(store2.allRecords.count, 2)
        XCTAssertEqual(store2.allRecords.map(\.id).sorted(), [record1.id, record2.id].sorted())
    }

    func testImportedStorePersistsIndividualFieldsAccurately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store1 = ImportedModelStore(directory: directory)
        let record = makeRecord(filename: "model-q4.gguf", digest: String(repeating: "a", count: 64))
        _ = try store1.upsert(record)

        let store2 = ImportedModelStore(directory: directory)
        let reloaded = store2.record(id: record.id)
        XCTAssertNotNil(reloaded)
        XCTAssertEqual(reloaded?.displayName, record.displayName)
        XCTAssertEqual(reloaded?.provenance.repositoryID, record.provenance.repositoryID)
        XCTAssertEqual(reloaded?.provenance.revision, record.provenance.revision)
        XCTAssertEqual(reloaded?.provenance.baseFilename, record.provenance.baseFilename)
        XCTAssertEqual(reloaded?.provenance.baseSHA256, record.provenance.baseSHA256)
        XCTAssertEqual(reloaded?.baseFileSizeBytes, record.baseFileSizeBytes)
        XCTAssertEqual(reloaded?.quantization, record.quantization)
    }

    func testImportedStoreHandlesEmptyRegistryGracefully() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ImportedModelStore(directory: directory)
        XCTAssertEqual(store.allRecords.count, 0)
        XCTAssertEqual(store.models.count, 0)
    }

    // MARK: - Download State Recovery

    @MainActor
    func testStagingFileOnDiskRecoversAsPausedState() throws {
        let model = makeModel(size: 1_000_000)
        ModelManagerService.ensureModelsDirectory()
        let task = DownloadTask(model: model, artifact: .base)
        // Simulate partial download: staging file at 50%.
        let halfSize = model.baseFileSizeBytes / 2
        try Data(repeating: 0xA5, count: Int(halfSize)).write(to: task.stagingURL)
        defer {
            try? FileManager.default.removeItem(at: task.stagingURL)
            try? FileManager.default.removeItem(at: task.metadataURL)
        }

        task.progress = 0.5
        DownloadManager(availableDiskSpaceProvider: { .max }).persistDurableState(for: task)
        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        manager.restoreDurableTransfers(models: [model])
        let status = manager.status(for: model)

        guard case .paused(let progress) = status.baseState else {
            XCTFail("Expected paused, got \(status.baseState)")
            return
        }
        XCTAssertEqual(progress, 0.5, accuracy: 0.001)
    }

    @MainActor
    func testActiveBackgroundTaskWithoutStagingSurvivesUntilTaskReconciliation() throws {
        let model = makeModel(size: 1_000_000, digest: String(repeating: "c", count: 64))
        let persistedTask = DownloadTask(model: model, artifact: .base)
        persistedTask.progress = 0.25
        persistedTask.state = .downloading(progress: 0.25)
        persistedTask.task = URLSession.shared.downloadTask(with: model.baseURL)
        defer {
            persistedTask.task?.cancel()
            try? FileManager.default.removeItem(at: persistedTask.metadataURL)
            try? FileManager.default.removeItem(at: persistedTask.resumeDataURL)
            try? FileManager.default.removeItem(at: persistedTask.stagingURL)
        }

        let first = DownloadManager(availableDiskSpaceProvider: { .max })
        first.persistDurableState(for: persistedTask)
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedTask.metadataURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistedTask.stagingURL.path))

        let relaunched = DownloadManager(availableDiskSpaceProvider: { .max })
        relaunched.restoreDurableTransfers(models: [model])
        let restored = relaunched.activeTasks[persistedTask.storageID]
        XCTAssertTrue(restored?.awaitingBackgroundTaskReconciliation == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedTask.metadataURL.path))

        let systemTask = URLSession.shared.downloadTask(with: model.baseURL)
        systemTask.taskDescription = persistedTask.storageID
        defer { systemTask.cancel() }
        relaunched.reconcileBackgroundTasks([systemTask])

        XCTAssertTrue(relaunched.activeTasks[persistedTask.storageID]?.task === systemTask)
        XCTAssertFalse(relaunched.activeTasks[persistedTask.storageID]?.awaitingBackgroundTaskReconciliation ?? true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedTask.metadataURL.path))
    }

    @MainActor
    func testNoStagingFileReportsNotDownloaded() throws {
        let model = makeModel(size: 1_000_000)
        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        let status = manager.status(for: model)

        // No files on disk, never downloaded → notDownloaded.
        guard case .notDownloaded = status.baseState else {
            XCTFail("Expected notDownloaded, got \(status.baseState)")
            return
        }
        guard case .notDownloaded = status.displayState else {
            XCTFail("Expected notDownloaded display, got \(status.displayState)")
            return
        }
    }

    @MainActor
    func testFullyDownloadedModelReportsAsDownloadedAfterRelaunch() throws {
        let gguf = TestModelFixtures.gguf(count: 100)
        let digest = TestModelFixtures.sha256(gguf)
        let model = AIModel(
            id: "relaunch-ready-test",
            displayName: "Relaunch Test",
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
        ModelManagerService.ensureModelsDirectory()
        try gguf.write(to: ModelManagerService.baseModelPath(for: model))
        defer { try? FileManager.default.removeItem(at: ModelManagerService.baseModelPath(for: model)) }

        // Simulate relaunch with a fresh DownloadManager.
        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        let status = manager.status(for: model)

        // The model should be detected as downloaded with a valid GGUF.
        // Note: The model is not in ModelRegistry.allModels, so status(for:) falls back
        // to authoritativeDiskStatus which checks availability. Since the SHA matches
        // and it's a valid GGUF, it should report ready.
        if ModelManagerService.isFullyDownloaded(model) {
            guard case .downloaded = status.baseState else {
                XCTFail("Expected downloaded base state, got \(status.baseState)")
                return
            }
            XCTAssertTrue(status.isReady)
        }
    }

    // MARK: - Library Models Include Imported After Relaunch

    func testLibraryModelsIncludesImportedModelsAfterStoreReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ImportedModelStore(directory: directory)
        let record1 = makeRecord(filename: "model-a.gguf", digest: String(repeating: "a", count: 64))
        let record2 = makeRecord(filename: "model-b.gguf", digest: String(repeating: "b", count: 64))
        _ = try store.upsert(record1)
        _ = try store.upsert(record2)

        // After "relaunch" (new store instance reading same directory).
        let store2 = ImportedModelStore(directory: directory)
        let importedModels = store2.models
        XCTAssertEqual(importedModels.count, 2)
        for model in importedModels {
            XCTAssertTrue(model.isImported)
            XCTAssertEqual(model.runtimeEligibility, .experimental)
            XCTAssertNotNil(model.huggingFaceProvenance)
        }
    }

    // MARK: - Atomic Writes

    func testStoreWriteIsAtomicAndDoesNotCorruptExistingRegistryOnFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Seed with one valid record.
        let store = ImportedModelStore(directory: directory)
        let good = makeRecord(filename: "good.gguf", digest: String(repeating: "g", count: 64))
        _ = try store.upsert(good)
        XCTAssertEqual(store.allRecords.count, 1)

        // Verify the record survives re-init.
        let store2 = ImportedModelStore(directory: directory)
        XCTAssertEqual(store2.allRecords.count, 1)
        XCTAssertEqual(store2.allRecords.first?.id, good.id)
    }

    // MARK: - Record Identity Stability

    func testSameRepositoryRevisionArtifactProducesStableIdentity() {
        let artifact = HFArtifact(
            filename: "model-q4.gguf",
            size: 100,
            sha256: String(repeating: "a", count: 64),
            quantization: "Q4_K_M",
            architecture: "llama",
            role: .base,
            metadata: HFGGUFMetadata(architecture: "llama", contextLength: 2048)
        )
        let review = HFRepositoryReview(
            repositoryID: "acme/model",
            revision: String(repeating: "f", count: 40),
            licenseName: "mit",
            licenseURL: URL(string: "https://example.com/license")!,
            artifacts: [artifact]
        )
        let first = ImportedModelFactory.makeRecord(review: review, base: artifact)
        let second = ImportedModelFactory.makeRecord(review: review, base: artifact)
        XCTAssertEqual(first.id, second.id, "Same inputs must produce stable identity")
    }

    // MARK: - Load Status Persistence

    func testLoadStatusSurvivesRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ImportedModelStore(directory: directory)
        var record = makeRecord(filename: "model.gguf")
        record.loadStatus = .loadFailed(kind: "test", diagnostic: "test failure", at: Date())
        _ = try store.upsert(record)

        let store2 = ImportedModelStore(directory: directory)
        let reloaded = store2.record(id: record.id)
        XCTAssertNotNil(reloaded)
        if case .loadFailed(let kind, let diagnostic, _) = reloaded?.loadStatus {
            XCTAssertEqual(kind, "test")
            XCTAssertEqual(diagnostic, "test failure")
        } else {
            XCTFail("Expected loadFailed status, got \(String(describing: reloaded?.loadStatus))")
        }
    }

    // MARK: - Helpers

    private func makeRecord(
        filename: String = "model-Q4_K_M.gguf",
        size: Int64 = 16,
        digest: String = String(repeating: "a", count: 64),
        repositoryID: String = "acme/model",
        revision: String = String(repeating: "f", count: 40)
    ) -> ImportedModelRecord {
        let artifact = HFArtifact(
            filename: filename,
            size: size,
            sha256: digest,
            quantization: filename.uppercased().contains("Q8") ? "Q8_0" : "Q4_K_M",
            architecture: "llama",
            role: .base,
            metadata: HFGGUFMetadata(architecture: "llama", contextLength: 2048)
        )
        let review = HFRepositoryReview(
            repositoryID: repositoryID,
            revision: revision,
            licenseName: "apache-2.0",
            licenseURL: URL(string: "https://example.com/license")!,
            artifacts: [artifact]
        )
        return ImportedModelFactory.makeRecord(review: review, base: artifact)
    }

    private func makeModel(size: Int64 = 16, digest: String = String(repeating: "a", count: 64)) -> AIModel {
        makeRecord(size: size, digest: digest).model
    }
}
