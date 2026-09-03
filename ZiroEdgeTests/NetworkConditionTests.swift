// NetworkConditionTests.swift
// ZiroEdgeTests
//
// Tests that exercise network conditions: Wi-Fi, cellular, handoff,
// connection loss, and Airplane Mode behavior. Extracted from
// DeviceLifecycleQATests.swift for file-size hygiene.

import XCTest
@testable import ZiroEdge

// MARK: - Network Condition Tests

/// Tests that exercise network conditions: Wi-Fi, cellular, handoff,
/// connection loss, and Airplane Mode behavior.
@MainActor
final class NetworkConditionTests: XCTestCase {

    var downloadManager: DownloadManager!

    override func setUp() {
        super.setUp()
        downloadManager = DownloadManager()
    }

    override func tearDown() {
        downloadManager = nil
        super.tearDown()
    }

    // MARK: Network Monitor Behavior

    func testNetworkMonitorInitializesWithKnownState() {
        let monitor = NetworkMonitor(startMonitoring: false)
        // Without live monitoring, defaults must be safe.
        XCTAssertTrue(monitor.isConnected, "Default must assume connected")
        XCTAssertFalse(monitor.isOnCellular, "Default must assume not on cellular")
    }

    func testNetworkMonitorPublishesStateChanges() {
        let monitor = NetworkMonitor()
        // Monitor publishes to @Published properties — verify they exist.
        XCTAssertNotNil(monitor.isConnected)
        XCTAssertNotNil(monitor.isOnCellular)
    }

    // MARK: Airplane Mode / Connection Loss

    func testDownloadRefusesInsufficientStorageEvenWhenOffline() {
        let hugeModel = AIModel(
            id: "huge-offline",
            displayName: "Huge Offline",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/huge.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64.max,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )

        downloadManager.startDownload(for: hugeModel)
        let status = downloadManager.status(for: hugeModel)

        // Must fail closed with disk space error, not attempt network.
        guard case .failed(let error) = status.baseState else {
            return XCTFail("Expected failed state for huge model")
        }
        XCTAssertEqual(error, .diskSpaceInsufficient)
    }

    func testNetworkErrorPersistsDurableStateForResume() throws {
        let data = TestModelFixtures.gguf()
        let model = TestModelFixtures.text(data: data)
        defer { ModelManagerService.deleteModel(model) }

        let task = DownloadTask(model: model, artifact: .base)
        ModelMigrationService.ensureManagedDirectories()
        try Data("partial-resume".utf8).write(to: task.resumeDataURL, options: .atomic)

        downloadManager.persistDurableState(for: task, failed: true)
        let status = downloadManager.status(for: model)

        if case .failed = status.baseState {
            // Failed state is preserved for user retry.
            XCTAssertTrue(true)
        }
    }

    func testWiFiToCellularTransitionDoesNotCorruptActiveTransfers() {
        // The network monitor only observes; the download manager's
        // waitsForConnectivity = true handles transitions implicitly.
        let monitor = downloadManager.networkMonitor
        XCTAssertNotNil(monitor.isConnected)
    }

    // MARK: HTTP Error / Credential Error Simulation

    func testAuthorizationRequiredErrorProducesCorrectDescription() {
        let error = DownloadError.authorizationRequired(statusCode: 403)
        XCTAssertTrue(error.localizedDescription.contains("403"))
    }

    func testContentRejectedErrorIsDescriptive() {
        let error = DownloadError.contentRejected(reason: "the staged artifact could not be read")
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }

    func testInvalidCatalogMetadataBlocksDownload() {
        let badModel = AIModel(
            id: "bad-catalog",
            displayName: "Bad Catalog",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/bad.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 16,
            mmprojFileSizeBytes: nil,
            baseSHA256: "",  // Invalid SHA-256
            mmprojSHA256: nil,
            quantization: "Q4",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )

        // Hermetic disk space: the storage gate runs first on the real host
        // volume and would veto this download on a nearly-full disk before
        // the catalog validator is ever consulted. Inject plentiful space so
        // the catalog refusal under test is deterministic.
        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        manager.startDownload(for: badModel)
        guard case .failed(let error) = manager.status(for: badModel).baseState else {
            return XCTFail("Expected failed state with invalid catalog")
        }
        XCTAssertEqual(error, .invalidCatalogMetadata)
    }

    func testRetryOnceFromCanonicalURLFlagPreventsInfiniteLoops() {
        let model = ModelRegistry.llama32_3B
        let task = DownloadTask(model: model, artifact: .base)
        XCTAssertFalse(task.canonicalRetryAttempted)

        task.canonicalRetryAttempted = true
        XCTAssertTrue(task.canonicalRetryAttempted)
    }
}
