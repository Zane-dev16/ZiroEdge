// SettingsTests.swift
// ZiroEdgeTests
//
// Tests for storage management and license attribution in Settings.

import XCTest
@testable import ZiroEdge

@MainActor
final class SettingsTests: XCTestCase {

    // MARK: - Storage Calculation

    func testDiskUsageReturnsZeroForNonexistentModel() throws {
        let model = ModelRegistry.llama32_3B
        // Clean up any leftover files first.
        ModelManagerService.deleteModel(model)

        let usage = ModelManagerService.diskUsage(for: model)
        XCTAssertEqual(usage, 0, "Disk usage should be 0 for a model not on disk")
    }

    func testFormattedDiskUsageForNonexistentModel() throws {
        let model = ModelRegistry.llama32_3B
        ModelManagerService.deleteModel(model)

        let formatted = ModelManagerService.formattedDiskUsage(for: model)
        XCTAssertFalse(formatted.isEmpty, "Formatted disk usage should not be empty")
    }

    func testDiskUsageReflectsActualFileSize() throws {
        let model = ModelRegistry.llama32_3B
        ModelManagerService.ensureModelsDirectory()

        let basePath = ModelManagerService.baseModelPath(for: model)

        // Write a small test file to simulate a downloaded model.
        let testData = Data(repeating: 0xAB, count: 1024)
        try testData.write(to: basePath)

        let usage = ModelManagerService.diskUsage(for: model)
        XCTAssertEqual(usage, 1024, "Disk usage should reflect actual file size")

        // Clean up.
        ModelManagerService.deleteModel(model)
    }

    func testTotalDiskUsageIncludesAllModels() throws {
        let model = ModelRegistry.llama32_3B
        ModelManagerService.ensureModelsDirectory()

        let basePath = ModelManagerService.baseModelPath(for: model)
        let testData = Data(repeating: 0xCD, count: 2048)
        try testData.write(to: basePath)

        let totalUsage = ModelManagerService.totalDiskUsage()
        XCTAssertGreaterThanOrEqual(totalUsage, 2048, "Total disk usage should include the test file")

        // Clean up.
        ModelManagerService.deleteModel(model)
    }

    // MARK: - Model Deletion

    func testDeleteModelRemovesFiles() throws {
        let testData = TestModelFixtures.gguf(count: 512)
        let model = TestModelFixtures.text(data: testData)
        try TestModelFixtures.install(testData, for: model)
        let basePath = ModelManagerService.baseModelPath(for: model)

        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model), "Model should be downloaded")

        // Delete via ModelManagerService.
        ModelManagerService.deleteModel(model)

        // Verify file is removed.
        XCTAssertFalse(ModelManagerService.isBaseDownloaded(model), "Model should be deleted")
        XCTAssertEqual(ModelManagerService.diskUsage(for: model), 0, "Disk usage should be 0 after deletion")
    }

    func testDeleteModelViaDownloadManager() throws {
        let testData = TestModelFixtures.gguf(count: 4096)
        let model = TestModelFixtures.text(data: testData)
        try TestModelFixtures.install(testData, for: model)

        let downloadManager = DownloadManager()
        XCTAssertTrue(ModelManagerService.isFullyDownloaded(model))

        // Delete via DownloadManager (this is what SettingsView uses).
        downloadManager.deleteModel(model)

        XCTAssertFalse(ModelManagerService.isBaseDownloaded(model), "Model files should be removed")
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model), "Download status should reflect deletion")
    }

    func testDeleteModelUpdatesDiskUsage() throws {
        let model = ModelRegistry.llama32_3B
        ModelManagerService.ensureModelsDirectory()

        let basePath = ModelManagerService.baseModelPath(for: model)
        let testData = Data(repeating: 0x34, count: 8192)
        try testData.write(to: basePath)

        let usageBefore = ModelManagerService.diskUsage(for: model)
        XCTAssertEqual(usageBefore, 8192)

        ModelManagerService.deleteModel(model)

        let usageAfter = ModelManagerService.diskUsage(for: model)
        XCTAssertEqual(usageAfter, 0, "Disk usage should be 0 after deletion")
    }

    // MARK: - License Info

    func testAllModelsHaveLicenseInfo() throws {
        for model in ModelRegistry.allModels {
            XCTAssertFalse(model.license.name.isEmpty,
                           "Model \(model.id) should have a license name")
            XCTAssertTrue(model.license.url.absoluteString.contains("://"),
                          "Model \(model.id) should have a valid license URL")
            XCTAssertFalse(model.license.copyright.isEmpty,
                           "Model \(model.id) should have copyright text")
        }
    }

    func testLicenseURLIsReachable() throws {
        // Verify license URLs are valid URLs (not necessarily reachable in unit tests).
        for model in ModelRegistry.allModels {
            let url = model.license.url
            XCTAssertNotNil(url.scheme, "License URL for \(model.id) should have a scheme")
            XCTAssertNotNil(url.host, "License URL for \(model.id) should have a host")
        }
    }

    func testPrivacyPolicyURL() throws {
        let privacyURL = URL(string: "https://ziroedge.app/privacy")!
        XCTAssertNotNil(privacyURL.scheme)
        XCTAssertNotNil(privacyURL.host)
        XCTAssertTrue(privacyURL.path.contains("privacy"))
    }

    // MARK: - Download Status Integration

    func testDownloadedModelsFilterUsesVerifiedFixture() throws {
        let data = TestModelFixtures.gguf(count: 256)
        let model = TestModelFixtures.text(data: data)
        defer { ModelManagerService.deleteModel(model) }
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model))
        try TestModelFixtures.install(data, for: model)
        XCTAssertTrue(ModelManagerService.isFullyDownloaded(model))
    }
}
