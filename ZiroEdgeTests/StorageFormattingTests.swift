// StorageFormattingTests.swift
// ZiroEdgeTests
//
// BATCH-06: all screens must render identical byte counts identically.
// Single source of truth: StorageByteFormatter (POSIX-pinned ByteCountFormatter).

import XCTest
@testable import ZiroEdge

@MainActor
final class StorageFormattingTests: XCTestCase {

    /// 2_000_000_000 bytes must render as "2 GB" (decimal .file style, no
    /// trailing ".0", locale-independent).
    private let twoGB: Int64 = 2_000_000_000

    // MARK: - Shared formatter contract

    func testTwoGigabytesRendersAsTwoGB() {
        XCTAssertEqual(StorageByteFormatter.string(fromByteCount: twoGB), "2 GB")
    }

    func testNegativeBytesClampToZero() {
        XCTAssertEqual(
            StorageByteFormatter.string(fromByteCount: -1),
            StorageByteFormatter.string(fromByteCount: 0)
        )
    }

    func testMemoryCountStyleRenders() {
        let formatted = StorageByteFormatter.string(fromByteCount: 268_435_456, countStyle: .memory)
        XCTAssertFalse(formatted.isEmpty)
    }

    // MARK: - Cross-site consistency (same bytes → identical string everywhere)

    func testCatalogAndAvailableSpaceCallSitesAgreeForSameBytes() {
        let expected = StorageByteFormatter.string(fromByteCount: twoGB)

        // Catalog size row (AIModel.formattedSize, ModelDetailView "Size").
        let model = TestModelFixtures.text()
        let catalogSized = AIModel(
            id: model.id,
            displayName: model.displayName,
            description: model.description,
            modelType: .text,
            baseURL: model.baseURL,
            mmprojURL: nil,
            baseFileSizeBytes: twoGB,
            mmprojFileSizeBytes: nil,
            baseSHA256: model.baseSHA256,
            mmprojSHA256: nil,
            quantization: model.quantization,
            config: model.config,
            license: model.license
        )
        XCTAssertEqual(catalogSized.formattedSize, expected)

        // Available-space row (ModelDetailView storage warning).
        let downloadManager = DownloadManager(availableDiskSpaceProvider: { self.twoGB })
        XCTAssertEqual(downloadManager.formattedAvailableSpace(), expected)
    }

    func testInstalledModelUsageIsIdenticalAcrossViewModelAndManagerService() throws {
        let data = TestModelFixtures.gguf(count: 4096)
        let bytes = Int64(data.count)
        let model = TestModelFixtures.text(data: data)
        try TestModelFixtures.install(data, for: model)
        defer { ModelManagerService.deleteModel(model) }

        let expected = StorageByteFormatter.string(fromByteCount: bytes)

        XCTAssertEqual(ModelManagerService.diskUsage(for: model), bytes)
        XCTAssertEqual(ModelManagerService.formattedDiskUsage(for: model), expected)

        let viewModel = ModelsViewModel(
            downloadManager: DownloadManager(availableDiskSpaceProvider: { .max }),
            lifecycleManager: ModelLifecycleManager(
                inferenceService: InferenceService(),
                memoryBudgeter: MemoryBudgeter()
            )
        )
        XCTAssertTrue(viewModel.isDownloaded(model))
        XCTAssertEqual(viewModel.diskUsage(for: model), expected)
    }

    // MARK: - Empty state consistency

    func testNotDownloadedModelRendersConsistentEmptyState() throws {
        let model = TestModelFixtures.text()
        ModelManagerService.deleteModel(model)
        defer { ModelManagerService.deleteModel(model) }

        let viewModel = ModelsViewModel(
            downloadManager: DownloadManager(availableDiskSpaceProvider: { .max }),
            lifecycleManager: ModelLifecycleManager(
                inferenceService: InferenceService(),
                memoryBudgeter: MemoryBudgeter()
            )
        )

        XCTAssertFalse(viewModel.isDownloaded(model))
        XCTAssertEqual(ModelManagerService.diskUsage(for: model), 0)
        // Empty state is the single agreed representation for not-downloaded.
        XCTAssertEqual(viewModel.diskUsage(for: model), "")
    }
}
