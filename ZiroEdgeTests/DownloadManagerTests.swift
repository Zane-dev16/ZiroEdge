// DownloadManagerTests.swift
// ZiroEdgeTests
//
// Tests for DownloadManager: state machine transitions, storage checks,
// network monitoring, and partial file cleanup.

import XCTest
import CryptoKit
@testable import ZiroEdge

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
        let model = ModelRegistry.llama32ThreeB
        let status = downloadManager.status(for: model)
        XCTAssertEqual(status.baseState, .notDownloaded)
        XCTAssertFalse(status.isReady)
        XCTAssertFalse(status.isDownloading)
    }

    func testStatusAfterDiskCheck() {
        let model = ModelRegistry.llama32ThreeB

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
        // Simulate pause: downloading → notDownloaded (with resume data held separately)
        var state: DownloadState = .downloading(progress: 0.5)
        XCTAssertTrue(state.isDownloading)

        state = .notDownloaded  // Paused state maps to notDownloaded in our model
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

}

extension DownloadManagerTests {

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
        let model = ModelRegistry.llama32ThreeB
        ModelManagerService.ensureModelsDirectory()

        // Create a fake staged partial file.
        let stagingPath = ModelManagerService.stagingPath(for: model, artifact: .base)
        FileManager.default.createFile(atPath: stagingPath.path, contents: Data("partial".utf8))

        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath.path))

        downloadManager.cleanupPartialFiles(for: model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath.path))
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

        let mmprojStagingPath = ModelManagerService.stagingPath(for: model, artifact: .mmproj)
        FileManager.default.createFile(atPath: mmprojStagingPath.path, contents: Data("partial-mmproj".utf8))

        XCTAssertTrue(FileManager.default.fileExists(atPath: mmprojStagingPath.path))

        downloadManager.cleanupPartialFiles(for: model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: mmprojStagingPath.path))
    }

    func testCleanupIsIdempotent() {
        let model = ModelRegistry.llama32ThreeB
        // Should not crash when no files exist
        downloadManager.cleanupPartialFiles(for: model)
    }

    // MARK: - Delete Model

    func testDeleteModelClearsStatus() {
        let model = ModelRegistry.llama32ThreeB
        ModelManagerService.ensureModelsDirectory()

        // Create a fake model file
        let basePath = ModelManagerService.baseModelPath(for: model)
        FileManager.default.createFile(atPath: basePath.path, contents: Data("fake-model".utf8))

        downloadManager.updateStatusesFromDisk()
        XCTAssertFalse(ModelManagerService.isBaseDownloaded(model), "A fake artifact must not be treated as installed")

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

extension DownloadManagerTests {

    // MARK: - Repair Downloads

    func testRepairDownloadDiscardsStaleResumeState() throws {
        let expected = validGGUFData(length: 16, fill: 0xA5)
        let model = makeTestModel(id: "repair-retry", expectedData: expected)
        let resumeURL = ModelManagerService.resumeDataPath(for: model, artifact: .base)
        let offsetURL = ModelManagerService.resumeOffsetPath(for: model, artifact: .base)
        defer {
            downloadManager.cancelDownload(for: model)
            ModelManagerService.deleteModel(model)
        }

        ModelManagerService.markRepairNeeded(for: model)
        try Data("stale resume metadata".utf8).write(to: resumeURL)
        try Data("32".utf8).write(to: offsetURL)
        XCTAssertTrue(downloadManager.status(for: model).isRepairNeeded)

        downloadManager.startDownload(for: model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: resumeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: offsetURL.path))
        XCTAssertFalse(downloadManager.status(for: model).isRepairNeeded)
        XCTAssertTrue(downloadManager.status(for: model).isDownloading)
    }

    // MARK: - Verified Staging and Promotion

    func testInvalidStagingContentNeverReachesInstalledPath() throws {
        let expected = validGGUFData(length: 16, fill: 0xA5)
        let cases: [(String, Data)] = [
            ("wrong-size", validGGUFData(length: 12, fill: 0xA5)),
            ("bad-header", Data(repeating: 0xA5, count: 16)),
            ("bad-hash", validGGUFData(length: 16, fill: 0x5A))
        ]

        for (id, content) in cases {
            let model = makeTestModel(id: id, expectedData: expected)
            let task = DownloadTask(model: model, artifact: .base)
            defer {
                downloadManager.cleanupPartialFiles(for: model)
                ModelManagerService.deleteModel(model)
            }

            try content.write(to: task.stagingURL)
            let result = downloadManager.verifyAndPromote(task: task)

            guard case .failure(let error) = result,
                  case .artifactCorrupted(let issues) = error else {
                return XCTFail("Invalid \(id) content must fail artifact validation")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: task.destinationURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: task.stagingURL.path))
            XCTAssertFalse(issues.isEmpty)
            XCTAssertEqual(task.state, .failed(error: error))
        }
    }

    func testVerifiedPromotionInstallsOnlyAfterSwapSucceeds() throws {
        let expected = validGGUFData(length: 16, fill: 0xA5)
        let model = makeTestModel(id: "promotion-success", expectedData: expected)
        let task = DownloadTask(model: model, artifact: .base)
        defer {
            downloadManager.cleanupPartialFiles(for: model)
            ModelManagerService.deleteModel(model)
        }

        try expected.write(to: task.stagingURL)
        let result = downloadManager.verifyAndPromote(task: task)

        guard case .success = result else {
            return XCTFail("A verified staging artifact should promote successfully")
        }
        XCTAssertEqual(task.state, .downloaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.destinationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.stagingURL.path))
        XCTAssertEqual(try Data(contentsOf: task.destinationURL), expected)
    }

    func testFailedReplacementPreservesPreviouslyInstalledModel() throws {
        let installedData = validGGUFData(length: 16, fill: 0xA5)
        let replacementData = validGGUFData(length: 16, fill: 0x5A)
        let model = makeTestModel(id: "preserve-install", expectedData: installedData)
        let task = DownloadTask(model: model, artifact: .base)
        defer {
            downloadManager.cleanupPartialFiles(for: model)
            ModelManagerService.deleteModel(model)
        }

        try installedData.write(to: task.destinationURL)
        try replacementData.write(to: task.stagingURL)
        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model))

        let result = downloadManager.verifyAndPromote(task: task)

        guard case .failure = result else {
            return XCTFail("A replacement with the wrong digest must fail")
        }
        XCTAssertEqual(try Data(contentsOf: task.destinationURL), installedData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.stagingURL.path))
        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model))
    }

    func testInterruptedPromotionRecoversVerifiedStagingOnNextLaunch() throws {
        let expected = validGGUFData(length: 16, fill: 0xA5)
        let model = makeTestModel(id: "recover-promotion", expectedData: expected)
        defer {
            ModelManagerService.deleteModel(model)
            downloadManager.cleanupPartialFiles(for: model)
        }

        let stagingURL = ModelManagerService.stagingPath(for: model, artifact: .base)
        try expected.write(to: stagingURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelManagerService.baseModelPath(for: model).path))

        // A fresh launch reconciles staged, already-verified bytes before the
        // download manager derives its on-disk status.
        ModelManagerService.recoverStagingArtifacts(models: [model])

        let installedURL = ModelManagerService.baseModelPath(for: model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertEqual(try Data(contentsOf: installedURL), expected)
        XCTAssertTrue(ModelManagerService.isFullyDownloaded(model))
    }

}

extension DownloadManagerTests {

    // MARK: - Deterministic Transport Fixtures

    func testTransportFixturesRejectHTTPContentAndMalformedRangesBeforeHashing() throws {
        let expected = validGGUFData(length: 16, fill: 0xA5)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziroedge-transport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func writeFixture(_ name: String, _ body: Data) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try body.write(to: url)
            return url
        }

        func response(_ statusCode: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(
                url: URL(string: "https://fixture.example/model.gguf")!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
        }

        let fullURL = try writeFixture("full", expected)
        XCTAssertNil(DownloadTransportValidator.failure(
            response: response(200, ["Content-Type": "application/octet-stream", "Content-Length": "16"]),
            bodyURL: fullURL,
            expectedBytes: 16,
            expectedOffset: 0
        ))

        let resumedURL = try writeFixture("resumed", expected)
        XCTAssertNil(DownloadTransportValidator.failure(
            response: response(206, [
                "Content-Type": "application/octet-stream",
                "Content-Length": "8",
                "Content-Range": "bytes 8-15/16"
            ]),
            bodyURL: resumedURL,
            expectedBytes: 16,
            expectedOffset: 8
        ))

        let ignoredRange = DownloadTransportValidator.failure(
            response: response(200, ["Content-Type": "application/octet-stream", "Content-Length": "16"]),
            bodyURL: resumedURL,
            expectedBytes: 16,
            expectedOffset: 8
        )
        XCTAssertEqual(ignoredRange?.category, .range)

        let invalidRange = DownloadTransportValidator.failure(
            response: response(206, [
                "Content-Type": "application/octet-stream",
                "Content-Length": "13",
                "Content-Range": "bytes 3-15/16"
            ]),
            bodyURL: resumedURL,
            expectedBytes: 16,
            expectedOffset: 8
        )
        XCTAssertEqual(invalidRange?.category, .range)

        let rangeBeyondTotal = DownloadTransportValidator.failure(
            response: response(206, [
                "Content-Type": "application/octet-stream",
                "Content-Length": "13",
                "Content-Range": "bytes 8-20/16"
            ]),
            bodyURL: resumedURL,
            expectedBytes: 16,
            expectedOffset: 8
        )
        XCTAssertEqual(rangeBeyondTotal?.category, .range)

        let truncatedURL = try writeFixture("truncated", expected.prefix(12))
        let truncated = DownloadTransportValidator.failure(
            response: response(200, ["Content-Type": "application/octet-stream", "Content-Length": "12"]),
            bodyURL: truncatedURL,
            expectedBytes: 16,
            expectedOffset: 0
        )
        XCTAssertEqual(truncated?.category, .size)

        let oversizedURL = try writeFixture("oversized", expected + Data([0x01]))
        let oversized = DownloadTransportValidator.failure(
            response: response(200, ["Content-Type": "application/octet-stream", "Content-Length": "17"]),
            bodyURL: oversizedURL,
            expectedBytes: 16,
            expectedOffset: 0
        )
        XCTAssertEqual(oversized?.category, .size)

    }

    func testTransportFixturesRejectErrorBodiesWithGranularReasons() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziroedge-transport-errors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func writeFixture(_ name: String, _ body: Data) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try body.write(to: url)
            return url
        }

        func response(_ statusCode: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(
                url: URL(string: "https://fixture.example/model.gguf")!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
        }

        let credentialBody = Data("credential expired".utf8)
        let credentialURL = try writeFixture("credential", credentialBody)
        let credential = DownloadTransportValidator.failure(
            response: response(401, ["Content-Type": "text/plain", "Content-Length": "\(credentialBody.count)"]),
            bodyURL: credentialURL,
            expectedBytes: 16,
            expectedOffset: 0
        )
        XCTAssertEqual(credential?.category, .authorization)

        let htmlURL = try writeFixture("html", Data("<html><body>error</body></html>".utf8))
        XCTAssertEqual(DownloadTransportValidator.failure(
            response: response(200, ["Content-Type": "text/html"]),
            bodyURL: htmlURL,
            expectedBytes: 16,
            expectedOffset: 0
        )?.category, .content)

        let jsonURL = try writeFixture("json", Data("{\"error\":\"unauthorized\"}".utf8))
        XCTAssertEqual(DownloadTransportValidator.failure(
            response: response(200, ["Content-Type": "application/json"]),
            bodyURL: jsonURL,
            expectedBytes: 16,
            expectedOffset: 0
        )?.category, .content)

        let emptyURL = try writeFixture("empty", Data())
        XCTAssertEqual(DownloadTransportValidator.failure(
            response: response(200, ["Content-Type": "application/octet-stream"]),
            bodyURL: emptyURL,
            expectedBytes: 16,
            expectedOffset: 0
        )?.category, .content)

        let wrongContentURL = try writeFixture("wrong-content", Data(repeating: 0xA5, count: 16))
        XCTAssertEqual(DownloadTransportValidator.failure(
            response: response(200, ["Content-Type": "application/octet-stream"]),
            bodyURL: wrongContentURL,
            expectedBytes: 16,
            expectedOffset: 0
        )?.category, .structure)

        XCTAssertEqual(DownloadTransportValidator.failure(
            response: response(503),
            bodyURL: wrongContentURL,
            expectedBytes: 16,
            expectedOffset: 0
        )?.category, .http)
    }

    private func makeTestModel(id: String, expectedData: Data) -> AIModel {
        AIModel(
            id: id,
            displayName: "Download Test",
            description: "Deterministic test model",
            modelType: .text,
            baseURL: URL(string: "https://example.com/\(id).gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(expectedData.count),
            mmprojFileSizeBytes: nil,
            baseSHA256: sha256(expectedData),
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            minimumDeviceRAM: 0,
            license: LicenseInfo(
                name: "Test",
                url: URL(string: "https://example.com/license")!,
                copyright: "Test"
            )
        )
    }

    private func validGGUFData(length: Int, fill: UInt8) -> Data {
        var data = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0x00, 0x00, 0x00])
        data.append(contentsOf: repeatElement(fill, count: max(0, length - data.count)))
        return data
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
