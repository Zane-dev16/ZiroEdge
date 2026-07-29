import XCTest
import CryptoKit
@testable import ZiroEdge

@MainActor
final class DurableTransferStateTests: XCTestCase {

    // MARK: - Restore from disk

    func testRecreationRestoresPausedProgressWithoutStartingTransfer() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try Data("opaque-resume-state".utf8).write(to: task.resumeDataURL, options: .atomic)
        task.progress = 0.42

        let writer = DownloadManager()
        writer.persistDurableState(for: task)
        let restored = DownloadManager()
        restored.restoreDurableTransfers(models: [model])

        XCTAssertEqual(restored.status(for: model).baseState, .paused(progress: 0.42))
        XCTAssertTrue(restored.hasActiveDownload(model: model, artifact: .base))
    }

    func testCorruptMetadataDegradesToRestartableState() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try Data("resume".utf8).write(to: task.resumeDataURL, options: .atomic)
        try Data("not-json".utf8).write(to: task.metadataURL, options: .atomic)

        let restored = DownloadManager()
        restored.restoreDurableTransfers(models: [model])

        XCTAssertEqual(restored.status(for: model).baseState, .notDownloaded)
        XCTAssertFalse(restored.hasActiveDownload(model: model, artifact: .base))
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.resumeDataURL.path))
    }

    // MARK: - Repeated pause/resume cycles

    func testRepeatedPauseResumeCyclesPreserveProgress() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try Data("resume-data-v1".utf8).write(to: task.resumeDataURL, options: .atomic)

        let manager = DownloadManager()

        // Cycle 1: persist at 25%, restore, verify paused at 25%
        task.progress = 0.25
        manager.persistDurableState(for: task)
        manager.restoreDurableTransfers(models: [model])
        XCTAssertEqual(manager.status(for: model).baseState, .paused(progress: 0.25))

        // Simulate resume then pause again at 60%
        guard let restoredTask = manager.activeTasks[task.storageID] else {
            XCTFail("Expected restored task"); return
        }
        restoredTask.isPaused = false
        restoredTask.progress = 0.60
        manager.persistDurableState(for: restoredTask)

        // New manager instance restores at 60%
        let manager2 = DownloadManager()
        manager2.restoreDurableTransfers(models: [model])
        XCTAssertEqual(manager2.status(for: model).baseState, .paused(progress: 0.60))

        // Cycle 2: simulate resume then pause at 90%
        guard let task2 = manager2.activeTasks[task.storageID] else {
            XCTFail("Expected restored task"); return
        }
        task2.isPaused = false
        task2.progress = 0.90
        manager2.persistDurableState(for: task2)

        // Third restore at 90%
        let manager3 = DownloadManager()
        manager3.restoreDurableTransfers(models: [model])
        XCTAssertEqual(manager3.status(for: model).baseState, .paused(progress: 0.90))

        // Cleanup the active task in manager3 so teardown works
        manager3.cancelDownload(for: model)
    }

    // MARK: - Cancel vs Pause distinction

    func testCancelPreservesTransferStateWhileDiscardRemovesIt() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()

        // Set up resume data and metadata simulating a paused download
        try Data("resume-blob".utf8).write(to: task.resumeDataURL, options: .atomic)
        task.progress = 0.33

        let manager = DownloadManager()
        manager.persistDurableState(for: task)

        // Verify durable state exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.metadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.resumeDataURL.path))

        // Restore and verify paused state
        manager.restoreDurableTransfers(models: [model])
        XCTAssertEqual(manager.status(for: model).baseState, .paused(progress: 0.33))

        // Cancel stops activity but preserves resumable state.
        manager.cancelDownload(for: model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.metadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.resumeDataURL.path))
        XCTAssertEqual(manager.status(for: model).baseState, .notDownloaded)

        // Explicit discard removes resumable state.
        manager.discardPartialDownload(for: model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.metadataURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.resumeDataURL.path))
    }

    func testPausePreservesTransferStateOnDisk() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()

        // Simulate a paused download with metadata
        try Data("resume-blob".utf8).write(to: task.resumeDataURL, options: .atomic)
        task.progress = 0.50

        let manager = DownloadManager()
        manager.persistDurableState(for: task)

        // Restore — should be paused with metadata intact
        manager.restoreDurableTransfers(models: [model])
        XCTAssertEqual(manager.status(for: model).baseState, .paused(progress: 0.50))
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.metadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.resumeDataURL.path))

        // Another restore shouldn't lose the state
        let manager2 = DownloadManager()
        manager2.restoreDurableTransfers(models: [model])
        XCTAssertEqual(manager2.status(for: model).baseState, .paused(progress: 0.50))
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.metadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.resumeDataURL.path))

        manager2.cancelDownload(for: model)
    }

    // MARK: - Single-flight (duplicate prevention)

    func testDuplicateStartIsPrevented() {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        defer {
            let task = DownloadTask(model: model, artifact: .base)
            cleanup(task: task, model: model)
        }
        let manager = DownloadManager()

        // First registration succeeds
        let task1 = DownloadTask(model: model, artifact: .base)
        XCTAssertTrue(manager.registerActiveTaskIfAbsent(task1))

        // Second registration for the same storage ID fails
        let task2 = DownloadTask(model: model, artifact: .base)
        XCTAssertFalse(manager.registerActiveTaskIfAbsent(task2))

        // Cleanup
        manager.activeTasks.removeValue(forKey: task1.storageID)
    }

    func testDuplicatePauseIsNoop() {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        defer {
            let task = DownloadTask(model: model, artifact: .base)
            cleanup(task: task, model: model)
        }
        let manager = DownloadManager()

        // Register a task as paused
        let task = DownloadTask(model: model, artifact: .base)
        task.isPaused = true
        task.progress = 0.44
        task.state = .paused(progress: 0.44)
        manager.activeTasks[task.storageID] = task
        manager.updateStatus(model: model)

        // Calling pause again should be a no-op and not change state
        manager.pauseDownload(for: model)
        XCTAssertEqual(manager.status(for: model).baseState, .paused(progress: 0.44))

        manager.activeTasks.removeValue(forKey: task.storageID)
    }

    func testDuplicateResumeWhenAlreadyDownloadingIsNoop() {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        defer {
            let task = DownloadTask(model: model, artifact: .base)
            cleanup(task: task, model: model)
        }
        let manager = DownloadManager()

        // Register a task that is actively downloading
        let task = DownloadTask(model: model, artifact: .base)
        task.isPaused = false
        task.progress = 0.30
        task.state = .downloading(progress: 0.30)
        manager.activeTasks[task.storageID] = task
        manager.updateStatus(model: model)

        // Calling resume when not paused should be a no-op
        manager.resumeDownload(for: model)
        XCTAssertEqual(manager.status(for: model).baseState, .downloading(progress: 0.30))

        manager.activeTasks.removeValue(forKey: task.storageID)
    }

    // MARK: - State transitions

    func testFullStateTransitionCycle() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try Data("resume-data".utf8).write(to: task.resumeDataURL, options: .atomic)

        let manager = DownloadManager()

        // notDownloaded -> register task as downloading
        task.state = .downloading(progress: 0.0)
        manager.activeTasks[task.storageID] = task
        manager.updateStatus(model: model)
        XCTAssertTrue(manager.status(for: model).isDownloading)

        // downloading -> pausing
        task.state = .pausing(progress: 0.40)
        manager.updateStatus(model: model)
        XCTAssertEqual(manager.status(for: model).displayState, .pausing(progress: 0.40))

        // pausing -> paused (after durable persistence)
        manager.persistDurableState(for: task)
        task.state = .paused(progress: 0.40)
        manager.updateStatus(model: model)
        XCTAssertEqual(manager.status(for: model).displayState, .paused(progress: 0.40))
        XCTAssertFalse(manager.status(for: model).isDownloading)

        // paused -> resuming
        task.isPaused = false
        task.state = .resuming(progress: 0.40)
        manager.updateStatus(model: model)
        XCTAssertEqual(manager.status(for: model).displayState, .resuming(progress: 0.40))
        XCTAssertTrue(manager.status(for: model).isDownloading)

        // resuming -> downloading
        task.state = .downloading(progress: 0.40)
        manager.updateStatus(model: model)
        XCTAssertEqual(manager.status(for: model).displayState, .downloading(progress: 0.40))

        // Cleanup
        manager.activeTasks.removeValue(forKey: task.storageID)
    }

    func testPausingAndResumingAreActiveAndDownloading() {
        XCTAssertTrue(DownloadState.pausing(progress: 0.2).isActive)
        XCTAssertTrue(DownloadState.resuming(progress: 0.2).isActive)
        XCTAssertTrue(DownloadState.pausing(progress: 0.2).isDownloading)
        XCTAssertTrue(DownloadState.resuming(progress: 0.2).isDownloading)
        XCTAssertFalse(DownloadState.paused(progress: 0.2).isDownloading)
        XCTAssertFalse(DownloadState.paused(progress: 0.2).isActive)
    }

    // MARK: - Transfer continues after pause/resume

    func testProgressRetainedAcrossMultipleRestores() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()

        // Simulate a paused download at 40% with resume data
        try Data("resume-data-cycle".utf8).write(to: task.resumeDataURL, options: .atomic)
        task.progress = 0.40

        let manager1 = DownloadManager()
        manager1.persistDurableState(for: task)
        manager1.restoreDurableTransfers(models: [model])

        // Should restore at 40%
        XCTAssertEqual(manager1.status(for: model).baseState, .paused(progress: 0.40))

        // Simulate updating progress to 75% and re-persisting
        guard let active = manager1.activeTasks[task.storageID] else {
            XCTFail("Expected restored task"); return
        }
        active.progress = 0.75
        manager1.persistDurableState(for: active)

        // New instance restores at 75%
        let manager2 = DownloadManager()
        manager2.restoreDurableTransfers(models: [model])
        XCTAssertEqual(manager2.status(for: model).baseState, .paused(progress: 0.75))

        manager2.cancelDownload(for: model)
    }

}

extension DurableTransferStateTests {
    func testRestorationIsIdempotentAndCannotDuplicateTransfers() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try Data("opaque-resume-state".utf8).write(to: task.resumeDataURL, options: .atomic)
        task.progress = 0.42

        let writer = DownloadManager()
        writer.persistDurableState(for: task)

        let manager = DownloadManager()
        // Restore twice on the same instance.
        manager.restoreDurableTransfers(models: [model])
        manager.restoreDurableTransfers(models: [model])

        // Verify the task was restored exactly once.
        XCTAssertEqual(manager.status(for: model).baseState, .paused(progress: 0.42))
        XCTAssertTrue(manager.hasActiveDownload(model: model, artifact: .base))

        // Count active tasks for this storage ID: must be exactly one.
        let count = manager.activeTasks.values.filter { $0.storageID == task.storageID }.count
        XCTAssertEqual(count, 1, "Restoration must not duplicate active tasks")
    }

    func testFailedStateIsPersistedAndRestoredCorrectly() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try Data("stale-staging".utf8).write(to: task.stagingURL, options: .atomic)
        task.progress = 0.65

        let writer = DownloadManager()
        writer.persistDurableState(for: task, failed: true)

        let restored = DownloadManager()
        restored.restoreDurableTransfers(models: [model])

        XCTAssertEqual(restored.status(for: model).baseState, .failed(error: .networkError))
        XCTAssertTrue(restored.hasActiveDownload(model: model, artifact: .base))

        let restoredTask = restored.activeTasks[task.storageID]
        XCTAssertNotNil(restoredTask)
        XCTAssertEqual(restoredTask?.progress, 0.65)
    }

    func testMissingResumeDataWithValidMetadataDegradesGracefully() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()

        // Create metadata that claims resume is available, but provide neither
        // resume data nor staging.
        let snapshot: [String: Any] = [
            "version": 1,
            "modelID": model.id,
            "artifact": "base",
            "expectedBytes": task.expectedBytes,
            "progress": 0.33,
            "resumeAvailable": true,
            "failed": false
        ]
        let metadata = try JSONSerialization.data(withJSONObject: snapshot)
        try metadata.write(to: task.metadataURL, options: .atomic)

        let restored = DownloadManager()
        restored.restoreDurableTransfers(models: [model])

        // Metadata should have been cleaned up; no stale task remains.
        XCTAssertEqual(restored.status(for: model).baseState, .notDownloaded)
        XCTAssertFalse(restored.hasActiveDownload(model: model, artifact: .base))
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.metadataURL.path))
    }

    // MARK: - Background lifecycle restoration

    func testRestorePutsTaskInPausedStateNotDownloading() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try Data("resume".utf8).write(to: task.resumeDataURL, options: .atomic)

        let writer = DownloadManager()
        writer.persistDurableState(for: task)
        let restored = DownloadManager()
        restored.restoreDurableTransfers(models: [model])

        let status = restored.status(for: model)
        guard case .paused = status.baseState else {
            XCTFail("Expected paused but got \(status.baseState)")
            return
        }
        XCTAssertFalse(status.isDownloading, "Restored transfers must not auto-resume")
    }

    func testPersistAllWritesMetadataForEveryActiveTask() throws {
        let bytes = gguf()
        let modelA = fixtureModel(bytes: bytes, suffix: "a")
        let modelB = fixtureModel(bytes: bytes, suffix: "b")
        let taskA = DownloadTask(model: modelA, artifact: .base)
        let taskB = DownloadTask(model: modelB, artifact: .base)
        defer {
            cleanup(task: taskA, model: modelA)
            cleanup(task: taskB, model: modelB)
        }
        ModelMigrationService.ensureManagedDirectories()

        let mgr = DownloadManager()
        _ = mgr.registerActiveTaskIfAbsent(taskA)
        _ = mgr.registerActiveTaskIfAbsent(taskB)
        taskA.progress = 0.12
        taskB.progress = 0.78

        mgr.persistAllActiveTransferState()

        XCTAssertTrue(FileManager.default.fileExists(atPath: taskA.metadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskB.metadataURL.path))
    }

    func testHandleBackgroundTransitionPersistsAllWithoutCancelling() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()

        let mgr = DownloadManager()
        _ = mgr.registerActiveTaskIfAbsent(task)
        task.progress = 0.35

        mgr.handleBackgroundTransition()

        XCTAssertTrue(FileManager.default.fileExists(atPath: task.metadataURL.path))
        // The task must still be tracked; background transition must not cancel.
        XCTAssertTrue(mgr.hasActiveDownload(model: model, artifact: .base))
    }

    func testResolveStorageIDMapsBasePrefixToCorrectArtifact() {
        let model = ModelRegistry.llama32_3B
        let expectedStorageID = DownloadTask(model: model, artifact: .base).storageID

        let resolved = DownloadManager.resolveStorageID(expectedStorageID)

        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.model.id, model.id)
        XCTAssertEqual(resolved?.artifact, .base)
        XCTAssertEqual(resolved?.storageID, expectedStorageID)
    }

    func testResolveStorageIDMapsMMProjPrefixToCorrectArtifact() {
        let model = ModelRegistry.gemma4_e4b
        let task = DownloadTask(model: model, artifact: .mmproj)

        let resolved = DownloadManager.resolveStorageID(task.storageID)

        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.model.id, model.id)
        XCTAssertEqual(resolved?.artifact, .mmproj)
    }

    func testResolveStorageIDReturnsNilForUnknownKey() {
        XCTAssertNil(DownloadManager.resolveStorageID("base-nonexistent"))
        XCTAssertNil(DownloadManager.resolveStorageID("mmproj-nonexistent"))
        XCTAssertNil(DownloadManager.resolveStorageID("garbage"))
    }

    func testCompletionStoreRetainsAndDrainsHandler() {
        let identifier = "com.test.session"
        var drained = false
        BackgroundDownloadCompletionStore.retain(identifier: identifier) {
            drained = true
        }
        XCTAssertTrue(BackgroundDownloadCompletionStore.hasPendingHandler(for: identifier))

        BackgroundDownloadCompletionStore.drain(identifier: identifier)

        XCTAssertTrue(drained)
        XCTAssertFalse(BackgroundDownloadCompletionStore.hasPendingHandler(for: identifier))
    }

    func testCompletionStoreDoubleDrainIsSafe() {
        let identifier = "com.test.session2"
        var drainCount = 0
        BackgroundDownloadCompletionStore.retain(identifier: identifier) {
            drainCount += 1
        }
        BackgroundDownloadCompletionStore.drain(identifier: identifier)
        BackgroundDownloadCompletionStore.drain(identifier: identifier)
        XCTAssertEqual(drainCount, 1)
    }

    func testCompletionHandlerDeliveredThroughDidFinishEvents() {
        let identifier = DownloadManager.backgroundSessionIdentifier
        // Simulate the store/retain flow — the system calls
        // handleEventsForBackgroundURLSession, which retains the handler.
        // Later, urlSessionDidFinishEvents drains it.
        BackgroundDownloadCompletionStore.retain(identifier: identifier) {}
        XCTAssertTrue(BackgroundDownloadCompletionStore.hasPendingHandler(for: identifier))

        // Simulate what urlSessionDidFinishEvents does.
        BackgroundDownloadCompletionStore.drain(identifier: identifier)
        XCTAssertFalse(BackgroundDownloadCompletionStore.hasPendingHandler(for: identifier))
    }

    func testDurableMetadataSurvivesRoundTripWithResumeDataOnly() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try Data("resume-data".utf8).write(to: task.resumeDataURL, options: .atomic)
        task.progress = 0.27

        let writer = DownloadManager()
        writer.persistDurableState(for: task)

        let restored = DownloadManager()
        restored.restoreDurableTransfers(models: [model])

        XCTAssertEqual(restored.status(for: model).baseState, .paused(progress: 0.27))
    }

    func testFailedDurableStateRestoresAsFailed() throws {
        let bytes = gguf()
        let model = fixtureModel(bytes: bytes)
        let task = DownloadTask(model: model, artifact: .base)
        defer { cleanup(task: task, model: model) }
        ModelMigrationService.ensureManagedDirectories()
        try Data("staged".utf8).write(to: task.stagingURL, options: .atomic)
        task.progress = 0.55

        let writer = DownloadManager()
        writer.persistDurableState(for: task, failed: true)

        let restored = DownloadManager()
        restored.restoreDurableTransfers(models: [model])

        guard case .failed = restored.status(for: model).baseState else {
            XCTFail("Expected failed state after restoring failed metadata")
            return
        }
        XCTAssertTrue(restored.hasActiveDownload(model: model, artifact: .base))
    }

    private func fixtureModel(bytes: Data, suffix: String = "") -> AIModel {
        let id = "durable-\(UUID().uuidString.lowercased())\(suffix)"
        return AIModel(
            id: id,
            displayName: "Durable Fixture",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/\(id).gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(bytes.count),
            mmprojFileSizeBytes: nil,
            baseSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )
    }

    private func gguf() -> Data {
        Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0, 1, 2, 3, 4])
    }

    private func cleanup(task: DownloadTask, model: AIModel) {
        try? FileManager.default.removeItem(at: task.resumeDataURL)
        try? FileManager.default.removeItem(at: task.metadataURL)
        try? FileManager.default.removeItem(at: task.stagingURL)
        ModelManagerService.deleteModel(model)
    }
}
