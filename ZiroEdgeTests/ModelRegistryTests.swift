// ModelRegistryTests.swift
// ZiroEdgeTests
//
// Tests for model registry, configuration, and download state.

import XCTest
@testable import ZiroEdge

final class ModelRegistryTests: XCTestCase {

    // MARK: - Model Registry

    func testRegistryHasModels() throws {
        XCTAssertFalse(ModelRegistry.allModels.isEmpty)
    }

    func testLlama32InRegistry() throws {
        let model = ModelRegistry.model(for: "llama3.2-3b-q4")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.displayName, "Llama 3.2 3B")
        XCTAssertEqual(model?.modelType, .text)
        XCTAssertEqual(model?.quantization, "Q4_K_M")
        XCTAssertNil(model?.mmprojURL)
        XCTAssertFalse(model?.requiresMMProj ?? true)
    }

    func testModelLookupByID() throws {
        let model = ModelRegistry.model(for: "llama3.2-3b-q4")
        XCTAssertNotNil(model)
        XCTAssertNil(ModelRegistry.model(for: "nonexistent"))
    }

    func testDeviceRAMGating() throws {
        // With enough RAM, all models should be available.
        let allModels = ModelRegistry.availableModels(deviceRAM: 16_000_000_000)
        XCTAssertFalse(allModels.isEmpty)

        // With very low RAM, no models should be available.
        let noModels = ModelRegistry.availableModels(deviceRAM: 500_000_000)
        XCTAssertTrue(noModels.isEmpty)
    }

    func testModelFileSizeFormatting() throws {
        let model = ModelRegistry.llama32_3B
        XCTAssertFalse(model.formattedSize.isEmpty)
        XCTAssertGreaterThan(model.totalFileSizeBytes, 0)
    }

    // MARK: - Model Configuration

    func testLlama32Config() throws {
        let config = ModelConfiguration.llama32
        XCTAssertEqual(config.contextLength, 4096)
        XCTAssertEqual(config.threadCount, 2)
        XCTAssertTrue(config.useMmap)
        XCTAssertTrue(config.f16KV)
        XCTAssertEqual(config.gpuLayers, 0)
        XCTAssertNil(config.addBos)
        XCTAssertTrue(config.stopStrings.contains("<|eot_id|>"))
    }

    func testSamplingConfigDefaults() throws {
        let sampling = SamplingConfig.default
        XCTAssertEqual(sampling.temperature, 0.7)
        XCTAssertEqual(sampling.topP, 0.9)
        XCTAssertEqual(sampling.topK, 40)
        XCTAssertEqual(sampling.maxTokens, 2048)
    }

    func testGreedySamplingConfig() throws {
        let greedy = SamplingConfig.greedy
        XCTAssertEqual(greedy.temperature, 0.0)
        XCTAssertEqual(greedy.topP, 1.0)
        XCTAssertEqual(greedy.topK, 1)
    }

    // MARK: - Download State

    func testDownloadStateNotDownloaded() throws {
        let state = DownloadState.notDownloaded
        XCTAssertFalse(state.isDownloaded)
        XCTAssertFalse(state.isDownloading)
        XCTAssertFalse(state.isActive)
    }

    func testDownloadStateDownloading() throws {
        let state = DownloadState.downloading(progress: 0.5)
        XCTAssertFalse(state.isDownloaded)
        XCTAssertTrue(state.isDownloading)
        XCTAssertTrue(state.isActive)
    }

    func testDownloadStateDownloaded() throws {
        let state = DownloadState.downloaded
        XCTAssertTrue(state.isDownloaded)
        XCTAssertFalse(state.isDownloading)
        XCTAssertFalse(state.isActive)
    }

    func testModelDownloadStatusReady() throws {
        let status = ModelDownloadStatus(baseState: .downloaded, mmprojState: nil)
        XCTAssertTrue(status.isReady)
        XCTAssertFalse(status.isDownloading)
        XCTAssertEqual(status.overallProgress, 1.0)
    }

    func testModelDownloadStatusPartial() throws {
        let status = ModelDownloadStatus(
            baseState: .downloading(progress: 0.5),
            mmprojState: .notDownloaded
        )
        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.isDownloading)
    }

    func testModelDownloadStatusVisionModel() throws {
        let status = ModelDownloadStatus(
            baseState: .downloaded,
            mmprojState: .downloaded
        )
        XCTAssertTrue(status.isReady)
    }

    func testModelDownloadStatusVisionIncomplete() throws {
        let status = ModelDownloadStatus(
            baseState: .downloaded,
            mmprojState: .downloading(progress: 0.3)
        )
        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.isDownloading)
    }
}
