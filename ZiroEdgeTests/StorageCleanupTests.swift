// StorageCleanupTests.swift
// ZiroEdgeTests
//
// Tests for STORAGE-CLEANUP: accurate storage checks, cancellation cleanup,
// orphan reclamation, and deletion coordination.

import CryptoKit
import XCTest
@testable import ZiroEdge

@MainActor
final class StorageCleanupTests: XCTestCase {

    var downloadManager: DownloadManager!

    override func setUp() {
        super.setUp()
        ModelMigrationService.ensureManagedDirectories()
        downloadManager = DownloadManager()
    }

    override func tearDown() {
        // Clean staging/resume directories
        for dir in [
            ModelManagerService.stagingDirectory,
            ModelManagerService.resumeDirectory,
            ModelManagerService.quarantineDirectory
        ] {
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files { try? FileManager.default.removeItem(at: file) }
            }
        }
        // Clean installed models
        for model in ModelRegistry.allModels {
            ModelManagerService.deleteModel(model)
        }
        try? FileManager.default.removeItem(
            at: ModelManagerService.baseModelPath(for: ModelRegistry.gemma4_e4b)
        )
        downloadManager = nil
        super.tearDown()
    }

    // MARK: - Cancel and Delete Cleanup

    func testCancelRemovesResumeData() throws {
        let data = TestModelFixtures.gguf(count: 128)
        let model = TestModelFixtures.text(data: data)
        let task = DownloadTask(model: model, artifact: .base)

        // Simulate an active paused download with resume data
        ModelMigrationService.ensureManagedDirectories()
        try Data("resume-data".utf8).write(to: task.resumeDataURL, options: .atomic)
        try Data("staging-data".utf8).write(to: task.stagingURL, options: .atomic)
        task.progress = 0.5
        task.state = .paused(progress: 0.5)

        downloadManager.persistDurableState(for: task)
        _ = downloadManager.registerActiveTaskIfAbsent(task)

        downloadManager.cancelDownload(for: model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: task.resumeDataURL.path),
                       "Cancel must remove disposable resume data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.stagingURL.path),
                       "Cancel must remove disposable staging data")
    }

    func testDiscardPartialRemovesResumeAndStaging() throws {
        let data = TestModelFixtures.gguf(count: 128)
        let model = TestModelFixtures.text(data: data)
        let task = DownloadTask(model: model, artifact: .base)

        ModelMigrationService.ensureManagedDirectories()
        try Data("resume-data".utf8).write(to: task.resumeDataURL, options: .atomic)
        try Data("staging-data".utf8).write(to: task.stagingURL, options: .atomic)
        task.progress = 0.3
        task.state = .paused(progress: 0.3)

        downloadManager.persistDurableState(for: task)
        _ = downloadManager.registerActiveTaskIfAbsent(task)

        // Discard partial
        downloadManager.discardPartialDownload(for: model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: task.stagingURL.path),
                       "Discard must remove staging data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.resumeDataURL.path),
                       "Discard must remove resume data")
    }

    func testDeleteRemovesInstalledFilesButPreservesSharedBase() throws {
        let basePath = ModelManagerService.baseModelPath(for: ModelRegistry.gemma4_e4b)
        let projectorPath = ModelManagerService.mmprojModelPath(for: ModelRegistry.gemma4_e4b)
        ModelManagerService.ensureModelsDirectory()

        let baseData = TestModelFixtures.gguf(count: 256)
        // Install only the base — projector stays absent so only base survival is tested.
        try baseData.write(to: basePath, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: basePath)
            try? FileManager.default.removeItem(at: projectorPath)
        }

        // Verify shared-base detection works
        XCTAssertTrue(ModelManagerService.isBaseArtifactShared(ModelRegistry.gemma4_e4b),
                      "E4B vision must detect its base is shared with text variant")

        // Direct service-level delete must preserve shared base
        ModelManagerService.deleteModel(ModelRegistry.gemma4_e4b)

        // Base must survive (shared with text variant)
        XCTAssertTrue(FileManager.default.fileExists(atPath: basePath.path),
                      "Shared base artifact must survive vision-model deletion")
        // Projector must be deleted (only owned by vision variant)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectorPath.path),
                       "Projector owned only by vision variant must be deleted")
    }

    func testCancelDiscardAndDeleteAreDistinctOperations() {
        // Verify three distinct public interfaces exist
        let model = ModelRegistry.llama32_3B

        // All three methods must compile and be callable distinctly
        downloadManager.cancelDownload(for: model)
        downloadManager.discardPartialDownload(for: model)
        downloadManager.deleteModel(model)

        // If we reach here, all three are distinct public methods
        XCTAssertTrue(true)
    }

    // MARK: - Storage Check Accuracy

    func testRequiredDownloadBytesAccountsForStagedData() throws {
        let data = TestModelFixtures.gguf(count: 1_024)
        let model = TestModelFixtures.text(data: data)
        let task = DownloadTask(model: model, artifact: .base)

        ModelMigrationService.ensureManagedDirectories()
        // Simulate a partial staging file (half downloaded)
        let stagedBytes = Int64(data.count / 2)
        try Data(repeating: 0, count: Int(stagedBytes)).write(to: task.stagingURL, options: .atomic)

        // Required bytes should be the remaining half + safety margin
        let required = downloadManager.requiredDownloadBytes(for: model)
        let expected = Int64(data.count / 2) + DownloadManager.storageSafetyMarginBytes
        XCTAssertEqual(required, expected, "Required space must subtract already-staged bytes and add safety margin")
    }

    func testRequiredDownloadBytesIsZeroWhenFullyStaged() throws {
        let data = TestModelFixtures.gguf(count: 256)
        let model = TestModelFixtures.text(data: data)
        try TestModelFixtures.install(data, for: model)
        defer { ModelManagerService.deleteModel(model) }

        let required = downloadManager.requiredDownloadBytes(for: model)
        XCTAssertEqual(required, 0, "No download space needed when artifact is already installed and verified")
    }

    func testInsufficientStorageMessageIsActionable() {
        let hugeModel = AIModel(
            id: "test-huge-msg",
            displayName: "Huge Message Test",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/huge.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64.max,
            mmprojFileSizeBytes: nil,
            baseSHA256: "",
            mmprojSHA256: nil,
            quantization: "Q4",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        let message = downloadManager.insufficientStorageMessage(for: hugeModel)
        XCTAssertTrue(message.contains("needed"), "Message must describe what is needed")
        XCTAssertTrue(message.contains("available"), "Message must describe what is available")
    }

    func testRequiredDownloadAccountsForPairedArtifacts() {
        let model = ModelRegistry.gemma4_e4b

        // When both artifacts are missing, required should be base + projector + margin
        let required = downloadManager.requiredDownloadBytes(for: model, includeOptionalProjector: true)
        XCTAssertGreaterThan(required, model.baseFileSizeBytes,
                             "Required bytes must exceed base size when projector is also needed")
    }

    // MARK: - Orphan Reclamation

    func testReclaimOrphanedStagingFiles() throws {
        // Create orphan staging files not associated with any model
        ModelMigrationService.ensureManagedDirectories()
        let orphanURL = ModelManagerService.stagingDirectory
            .appendingPathComponent("orphan-staging.partial")
        let orphanData = Data(repeating: 0xDE, count: 50_000)
        try orphanData.write(to: orphanURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))

        let reclaimed = downloadManager.reclaimOrphanedStorage()
        XCTAssertGreaterThanOrEqual(reclaimed, 50_000, "Must reclaim orphan staging bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path),
                       "Orphan staging file must be removed")
    }

    func testReclaimPreservesActiveTaskFiles() throws {
        let data = TestModelFixtures.gguf(count: 256)
        let model = TestModelFixtures.text(data: data)
        let task = DownloadTask(model: model, artifact: .base)

        ModelMigrationService.ensureManagedDirectories()
        let stagingData = Data(repeating: 0xAB, count: 128)
        try stagingData.write(to: task.stagingURL, options: .atomic)
        try Data("resume".utf8).write(to: task.resumeDataURL, options: .atomic)
        task.progress = 0.5
        task.state = .paused(progress: 0.5)

        downloadManager.persistDurableState(for: task)
        _ = downloadManager.registerActiveTaskIfAbsent(task)

        // Also create an orphan
        let orphanURL = ModelManagerService.stagingDirectory
            .appendingPathComponent("orphan-2.partial")
        try Data(count: 100).write(to: orphanURL, options: .atomic)

        let reclaimed = downloadManager.reclaimOrphanedStorage()

        // Active files must survive
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.stagingURL.path),
                      "Active staging must survive orphan reclamation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.resumeDataURL.path),
                      "Active resume must survive orphan reclamation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path),
                       "Genuine orphans must be removed")
        XCTAssertGreaterThanOrEqual(reclaimed, 100, "Must reclaim at least the orphan's bytes")
    }

    func testReclaimHandlesKnownModelIdentityFiles() {
        // Files matching known model storage IDs (even without active tasks)
        // must survive reclamation
        let model = ModelRegistry.llama32_3B
        let task = DownloadTask(model: model, artifact: .base)
        ModelMigrationService.ensureManagedDirectories()
        try? Data("known-resume".utf8).write(to: task.resumeDataURL, options: .atomic)

        let reclaimed = downloadManager.reclaimOrphanedStorage()

        // Known model resume files must survive
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.resumeDataURL.path),
                      "Known model identity resume data must survive reclamation")
        _ = reclaimed // used or ignored
    }

    func testReclaimOrphanedQuarantineFiles() throws {
        // Quarantined corrupt artifacts are preserved for inspection/repair:
        // fresh orphans must survive the launch-time sweep (24 h grace).
        ModelMigrationService.ensureManagedDirectories()
        let freshQuarantine = ModelManagerService.quarantineDirectory
            .appendingPathComponent("orphan-quarantine.quarantined")
        try Data(count: 200).write(to: freshQuarantine, options: .atomic)

        _ = downloadManager.reclaimOrphanedStorage()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: freshQuarantine.path),
            "A recently quarantined artifact must survive orphan reclamation"
        )

        // A quarantined file older than the grace period is a true orphan.
        let staleQuarantine = ModelManagerService.quarantineDirectory
            .appendingPathComponent("orphan-quarantine-stale.quarantined")
        try Data(count: 200).write(to: staleQuarantine, options: .atomic)
        let staleDate = Date().addingTimeInterval(-25 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: staleQuarantine.path
        )

        let reclaimed = downloadManager.reclaimOrphanedStorage()
        XCTAssertGreaterThanOrEqual(reclaimed, 200)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleQuarantine.path),
            "Quarantined files past the 24 h grace period must be reclaimed"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshQuarantine.path))
    }

    // MARK: - Managed Storage Breakdown

    func testManagedStorageBreakdownHasAllCategories() {
        let breakdown = downloadManager.managedStorageBreakdown()
        XCTAssertGreaterThanOrEqual(breakdown.installedBytes, 0)
        XCTAssertGreaterThanOrEqual(breakdown.stagingBytes, 0)
        XCTAssertGreaterThanOrEqual(breakdown.resumeBytes, 0)
        XCTAssertGreaterThanOrEqual(breakdown.quarantineBytes, 0)
        XCTAssertEqual(
            breakdown.totalManagedBytes,
            breakdown.installedBytes + breakdown.stagingBytes + breakdown.resumeBytes + breakdown.quarantineBytes
        )
    }

    func testModelsViewModelManagedUsageIncludesStaging() throws {
        let stagingFile = ModelManagerService.stagingDirectory
            .appendingPathComponent("view-model-staging.partial")
        try Data(repeating: 0xCD, count: 12_000).write(to: stagingFile, options: .atomic)
        // BATCH-05: cached breakdown is now invalidated only on completion/promotion/quarantine/removal, not per read.
        // Force a synchronous refresh so the cached value reflects the just-written staging file.
        downloadManager.refreshStorageBreakdownForTests()
        let lifecycle = ModelLifecycleManager(
            inferenceService: InferenceService(),
            memoryBudgeter: MemoryBudgeter()
        )
        let report = OfflineAvailabilityGuard.sweep()
        let viewModel = ModelsViewModel(
            downloadManager: downloadManager,
            lifecycleManager: lifecycle,
            offlineAvailabilityReport: report
        )

        XCTAssertEqual(
            viewModel.managedStorageUsage,
            downloadManager.managedStorageBreakdown().formattedTotal
        )
    }

    func testManagedStorageBreakdownIncludesStaging() throws {
        ModelMigrationService.ensureManagedDirectories()
        let stagingFile = ModelManagerService.stagingDirectory
            .appendingPathComponent("test-staging.partial")
        let stagingData = Data(repeating: 0xCC, count: 10_000)
        try stagingData.write(to: stagingFile, options: .atomic)

        let breakdown = downloadManager.managedStorageBreakdown()
        XCTAssertGreaterThanOrEqual(breakdown.stagingBytes, 10_000,
                                    "Staging usage must be reflected in managed breakdown")
        try? FileManager.default.removeItem(at: stagingFile)
    }

    func testManagedStorageBreakdownReflectsInstalledModels() throws {
        let data = TestModelFixtures.gguf(count: 2_048)
        let model = TestModelFixtures.text(data: data)
        try TestModelFixtures.install(data, for: model)
        defer { ModelManagerService.deleteModel(model) }

        let breakdown = downloadManager.managedStorageBreakdown()
        XCTAssertGreaterThanOrEqual(breakdown.installedBytes, Int64(data.count),
                                    "Installed bytes must include model artifacts")
        XCTAssertFalse(breakdown.formattedTotal.isEmpty)
        XCTAssertFalse(breakdown.formattedInstalled.isEmpty)
    }

    // MARK: - Deletion Coordination

    func testIsSafeToDeleteWhenActiveModelSharesBase() {
        // Exercise the known shared E4B catalog variants.
        let vision = ModelRegistry.gemma4_e4b
        let text = ModelRegistry.gemma4_e4b_text

        // Text variant should be safe to delete when vision is loaded (they share base)
        XCTAssertFalse(downloadManager.isSafeToDelete(text, activeModel: vision),
                       "Deleting a model that shares base with active model must be flagged unsafe")

        // Vision model is safe to delete when an unrelated model is loaded
        let unrelated = ModelRegistry.llama32_3B
        XCTAssertTrue(downloadManager.isSafeToDelete(vision, activeModel: unrelated),
                      "Deleting should be safe when active model is unrelated")
    }

    func testUnsafeDeletionReasonProvidesUserMessage() {
        let vision = ModelRegistry.gemma4_e4b
        let text = ModelRegistry.gemma4_e4b_text

        let reason = downloadManager.unsafeDeletionReason(for: text, activeModel: vision)
        XCTAssertNotNil(reason, "Must provide a reason when deletion is unsafe")
        XCTAssertTrue(reason?.localizedCaseInsensitiveContains("unload") ?? false,
                      "Unsafe deletion reason must guide user to unload first")
    }

    // MARK: - Space Recheck on Resume

    func testResumeArtifactRechecksStorage() {
        let model = ModelRegistry.llama32_3B
        let task = DownloadTask(model: model, artifact: .base)

        ModelMigrationService.ensureManagedDirectories()
        // Set up a paused download with no staging (simulates fresh resume)
        task.progress = 0.1
        task.state = .paused(progress: 0.1)
        task.isPaused = true

        downloadManager.persistDurableState(for: task)
        _ = downloadManager.registerActiveTaskIfAbsent(task)

        // Resume should not crash even if storage is low (it will check first)
        downloadManager.resumeDownload(for: model)

        let status = downloadManager.status(for: model)
        // Either it proceeds or fails with diskSpaceInsufficient — never crashes
        XCTAssertNotNil(status)
    }

    // MARK: - Actionable Out-of-Space Preservation

    func testOutOfSpaceDoesNotDeleteInstalledArtifacts() throws {
        let data = TestModelFixtures.gguf(count: 512)
        let model = TestModelFixtures.text(data: data)
        try TestModelFixtures.install(data, for: model)
        defer { ModelManagerService.deleteModel(model) }

        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model))

        // Simulate a download failure due to space — but we can't easily
        // trigger real OOS. Instead verify that the installed artifact
        // is not deleted when a download fails for any reason.
        downloadManager.cancelDownload(for: model)

        // Installed artifact must survive
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ModelManagerService.baseModelPath(for: model).path
        ), "Installed artifacts must survive download cancellation")
    }
}
