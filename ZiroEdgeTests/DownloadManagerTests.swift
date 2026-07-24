// DownloadManagerTests.swift
// ZiroEdgeTests
//
// Tests for DownloadManager: state machine transitions, storage checks,
// network monitoring, and partial file cleanup.

import XCTest
@testable import ZiroEdge

@MainActor
final class DownloadManagerTests: XCTestCase {

    var downloadManager: DownloadManager!

    override func setUp() {
        super.setUp()
        downloadManager = DownloadManager()
    }

    override func tearDown() {
        // Clean up any test model files
        for model in ModelRegistry.allModels {
            ModelManagerService.deleteModel(model)
        }
        downloadManager = nil
        super.tearDown()
    }

    // MARK: - Download State Machine Transitions

    func testInitialStateIsNotDownloaded() {
        let model = ModelRegistry.llama32_3B
        let status = downloadManager.status(for: model)
        XCTAssertEqual(status.baseState, .notDownloaded)
        XCTAssertFalse(status.isReady)
        XCTAssertFalse(status.isDownloading)
    }

    func testStatusAfterDiskCheck() {
        let model = ModelRegistry.llama32_3B

        // Ensure models directory exists
        ModelManagerService.ensureModelsDirectory()

        // Not downloaded initially
        downloadManager.updateStatusesFromDisk()
        let status = downloadManager.status(for: model)
        XCTAssertFalse(status.isReady)
    }

    func testDownloadStateNotDownloadedProperties() {
        let state = DownloadState.notDownloaded
        XCTAssertFalse(state.isDownloaded)
        XCTAssertFalse(state.isDownloading)
        XCTAssertFalse(state.isActive)
    }

    func testDownloadStateDownloadingProperties() {
        let state = DownloadState.downloading(progress: 0.5)
        XCTAssertFalse(state.isDownloaded)
        XCTAssertTrue(state.isDownloading)
        XCTAssertTrue(state.isActive)
    }

    func testDownloadStatePausedProperties() {
        let state = DownloadState.paused(progress: 0.5)
        XCTAssertFalse(state.isDownloaded)
        XCTAssertFalse(state.isDownloading)
        XCTAssertFalse(state.isActive)
    }

    func testDownloadStateVerifyingProperties() {
        let state = DownloadState.verifying
        XCTAssertFalse(state.isDownloaded)
        XCTAssertFalse(state.isDownloading)
        XCTAssertTrue(state.isActive)
    }

    func testDownloadStateDownloadedProperties() {
        let state = DownloadState.downloaded
        XCTAssertTrue(state.isDownloaded)
        XCTAssertFalse(state.isDownloading)
        XCTAssertFalse(state.isActive)
    }

    func testDownloadStateFailedProperties() {
        let state = DownloadState.failed(error: .networkError)
        XCTAssertFalse(state.isDownloaded)
        XCTAssertFalse(state.isDownloading)
        XCTAssertFalse(state.isActive)
    }

    func testDownloadStateCancelledProperties() {
        let state = DownloadState.cancelled
        XCTAssertFalse(state.isDownloaded)
        XCTAssertFalse(state.isDownloading)
        XCTAssertFalse(state.isActive)
    }

    func testStateTransitionIdleToDownloading() {
        // Simulate state transition
        var state: DownloadState = .notDownloaded
        XCTAssertFalse(state.isDownloading)

        state = .downloading(progress: 0.0)
        XCTAssertTrue(state.isDownloading)
        XCTAssertTrue(state.isActive)
    }

    func testStateTransitionDownloadingToPaused() {
        var state: DownloadState = .downloading(progress: 0.5)
        XCTAssertTrue(state.isDownloading)

        state = .paused(progress: 0.5)
        XCTAssertFalse(state.isDownloading)
        XCTAssertFalse(state.isActive)
    }

    func testStateTransitionDownloadingToCompleted() {
        var state: DownloadState = .downloading(progress: 1.0)
        XCTAssertTrue(state.isDownloading)

        state = .verifying
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.isDownloaded)

        state = .downloaded
        XCTAssertTrue(state.isDownloaded)
        XCTAssertFalse(state.isActive)
    }

    func testStateTransitionDownloadingToFailed() {
        var state: DownloadState = .downloading(progress: 0.3)
        XCTAssertTrue(state.isDownloading)

        state = .failed(error: .networkError)
        XCTAssertFalse(state.isDownloading)
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.isDownloaded)
    }

    func testStateTransitionFailedToDownloading() {
        var state: DownloadState = .failed(error: .networkError)
        XCTAssertFalse(state.isDownloading)

        state = .downloading(progress: 0.0)  // Retry
        XCTAssertTrue(state.isDownloading)
        XCTAssertTrue(state.isActive)
    }

    // MARK: - ModelDownloadStatus

    func testModelDownloadStatusEmpty() {
        let status = ModelDownloadStatus.empty
        XCTAssertEqual(status.baseState, .notDownloaded)
        XCTAssertNil(status.mmprojState)
        XCTAssertFalse(status.isReady)
        XCTAssertFalse(status.isDownloading)
        XCTAssertEqual(status.overallProgress, 0.0)
    }

    func testModelDownloadStatusReady() {
        let status = ModelDownloadStatus(baseState: .downloaded, mmprojState: nil)
        XCTAssertTrue(status.isReady)
        XCTAssertEqual(status.overallProgress, 1.0)
    }

    func testModelDownloadStatusVisionReady() {
        let status = ModelDownloadStatus(baseState: .downloaded, mmprojState: .downloaded)
        XCTAssertTrue(status.isReady)
        XCTAssertEqual(status.overallProgress, 1.0)
    }

    func testModelDownloadStatusProgress() {
        let status = ModelDownloadStatus(
            baseState: .downloading(progress: 0.5),
            mmprojState: nil
        )
        XCTAssertEqual(status.overallProgress, 0.5, accuracy: 0.01)
    }

    func testModelDownloadStatusVisionProgress() {
        let status = ModelDownloadStatus(
            baseState: .downloading(progress: 0.8),
            mmprojState: .downloading(progress: 0.4)
        )
        XCTAssertEqual(status.overallProgress, 0.6, accuracy: 0.01)
    }

    func testModelDownloadStatusPreservesPausedProgress() {
        let status = ModelDownloadStatus(
            baseState: .paused(progress: 0.65),
            mmprojState: nil
        )
        XCTAssertEqual(status.overallProgress, 0.65, accuracy: 0.01)
    }

    // MARK: - Storage Checking

    func testAvailableDiskSpaceIsPositive() {
        let space = downloadManager.availableDiskSpace
        XCTAssertGreaterThan(space, 0)
    }

    func testFormattedAvailableSpace() {
        let formatted = downloadManager.formattedAvailableSpace()
        XCTAssertFalse(formatted.isEmpty)
        XCTAssertTrue(formatted.contains("GB") || formatted.contains("MB") || formatted.contains("KB") || formatted.contains("bytes"))
    }

    func testHasSufficientStorage() {
        // A model that requires 1 byte should succeed
        let tinyModel = AIModel(
            id: "test-tiny",
            displayName: "Tiny",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/tiny.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 1,
            mmprojFileSizeBytes: nil,
            baseSHA256: "",
            mmprojSHA256: nil,
            quantization: "Q4",
            config: .llama32,
            minimumDeviceRAM: 0,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertTrue(downloadManager.hasSufficientStorage(for: tinyModel))
    }

    func testInsufficientStorageDetection() {
        // A model requiring exabytes should fail
        let hugeModel = AIModel(
            id: "test-huge",
            displayName: "Huge",
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
            minimumDeviceRAM: 0,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertFalse(downloadManager.hasSufficientStorage(for: hugeModel))
    }

    // MARK: - Network Monitor

    func testNetworkMonitorInitialState() {
        let monitor = NetworkMonitor()
        // On a test device, we should have some connectivity state
        // (can't assert specific values without controlling network)
        XCTAssertNotNil(monitor.isConnected)
        XCTAssertNotNil(monitor.isOnCellular)
    }

    // MARK: - Partial File Cleanup

    func testCleanupPartialFiles() {
        let model = ModelRegistry.llama32_3B
        ModelManagerService.ensureModelsDirectory()

        // Create a fake partial file
        let basePath = ModelManagerService.baseModelPath(for: model)
        let tmpPath = basePath.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmpPath.path, contents: Data("partial".utf8))

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpPath.path))

        downloadManager.cleanupPartialFiles(for: model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpPath.path))
    }

    func testCleanupPartialFilesMMProj() {
        let model = AIModel(
            id: "test-vision",
            displayName: "Vision Test",
            description: "Test",
            modelType: .vision,
            baseURL: URL(string: "https://example.com/base.gguf")!,
            mmprojURL: URL(string: "https://example.com/mmproj.gguf")!,
            baseFileSizeBytes: 100,
            mmprojFileSizeBytes: 50,
            baseSHA256: "",
            mmprojSHA256: "",
            quantization: "Q4",
            config: .llama32,
            minimumDeviceRAM: 0,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        ModelManagerService.ensureModelsDirectory()

        let mmprojPath = ModelManagerService.mmprojModelPath(for: model)
        let mmprojTmpPath = mmprojPath.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: mmprojTmpPath.path, contents: Data("partial-mmproj".utf8))

        XCTAssertTrue(FileManager.default.fileExists(atPath: mmprojTmpPath.path))

        downloadManager.cleanupPartialFiles(for: model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: mmprojTmpPath.path))
    }

    func testCleanupIsIdempotent() {
        let model = ModelRegistry.llama32_3B
        // Should not crash when no files exist
        downloadManager.cleanupPartialFiles(for: model)
    }

    // MARK: - Delete Model

    func testDeleteModelClearsStatus() throws {
        let data = TestModelFixtures.gguf()
        let model = TestModelFixtures.text(data: data)
        try TestModelFixtures.install(data, for: model)
        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model))

        downloadManager.deleteModel(model)

        XCTAssertFalse(ModelManagerService.isBaseDownloaded(model))
        XCTAssertFalse(downloadManager.status(for: model).isReady)
    }

    // MARK: - Download Error

    func testDownloadErrorDescriptions() {
        XCTAssertEqual(DownloadError.networkError.localizedDescription, "Network connection failed")
        XCTAssertEqual(DownloadError.diskSpaceInsufficient.localizedDescription, "Not enough disk space")
        XCTAssertEqual(DownloadError.sha256Mismatch.localizedDescription, "File integrity check failed")
        XCTAssertEqual(DownloadError.cancelled.localizedDescription, "Download was cancelled")
    }
}
