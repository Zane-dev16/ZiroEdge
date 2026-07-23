// ModelArtifactVerificationTests.swift
// ZiroEdgeTests
//
// Deterministic regression coverage for false-installed model artifacts.

import XCTest
import CryptoKit
@testable import ZiroEdge

final class ModelArtifactVerificationTests: XCTestCase {

    func testAuthenticationBodyAtBothGemmaDestinationsIsNotInstalled() throws {
        let model = ModelRegistry.gemma4_e2b
        ModelManagerService.deleteModel(model)
        defer { ModelManagerService.deleteModel(model) }

        let authenticationBody = Data(repeating: 0x41, count: 32)
        try authenticationBody.write(to: ModelManagerService.baseModelPath(for: model))
        try authenticationBody.write(to: ModelManagerService.mmprojModelPath(for: model))

        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model))
        XCTAssertFalse(ModelManagerService.isBaseDownloaded(model))
        XCTAssertFalse(ModelManagerService.isMMProjDownloaded(model))

        let status = DownloadManager().status(for: model)
        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.isRepairNeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelManagerService.baseModelPath(for: model).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelManagerService.mmprojModelPath(for: model).path))
    }

    func testValidLengthWithWrongSHA256NeedsRepair() throws {
        let model = makeRuntimeModel(id: "wrong-hash", baseSHA256: String(repeating: "f", count: 64))
        defer { ModelManagerService.deleteModel(model) }
        try validGGUFData(length: 16).write(to: ModelManagerService.baseModelPath(for: model))

        guard case .repairNeeded(let issues) = ModelManagerService.availability(for: model) else {
            return XCTFail("Wrong SHA-256 must be repairable")
        }
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model))
        XCTAssertTrue(issues.contains { if case ArtifactIssue.sha256Mismatch = $0 { return true }; return false })
    }

    func testCorrectSHA256WithWrongByteCountNeedsRepair() throws {
        let model = makeRuntimeModel(id: "wrong-size")
        defer { ModelManagerService.deleteModel(model) }
        try validGGUFData(length: 12).write(to: ModelManagerService.baseModelPath(for: model))

        guard case .repairNeeded(let issues) = ModelManagerService.availability(for: model) else {
            return XCTFail("Wrong byte count must be repairable")
        }
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model))
        XCTAssertTrue(issues.contains { if case ArtifactIssue.sizeMismatch = $0 { return true }; return false })
    }

    func testVisionModelWithOnlyValidBaseIsNotInstalled() throws {
        let model = makeRuntimeModel(id: "vision-base-only", vision: true)
        defer { ModelManagerService.deleteModel(model) }
        try validGGUFData(length: 16).write(to: ModelManagerService.baseModelPath(for: model))

        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model))
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model))
        XCTAssertTrue(DownloadManager().status(for: model).isRepairNeeded)
    }

    func testVisionModelWithOnlyValidMMProjIsNotInstalled() throws {
        let model = makeRuntimeModel(id: "vision-mmproj-only", vision: true)
        defer { ModelManagerService.deleteModel(model) }
        try validGGUFData(length: 16).write(to: ModelManagerService.mmprojModelPath(for: model))

        XCTAssertTrue(ModelManagerService.isMMProjDownloaded(model))
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model))
        XCTAssertTrue(DownloadManager().status(for: model).isRepairNeeded)
    }

    func testTextModelWithValidArtifactIsInstalled() throws {
        let model = makeRuntimeModel(id: "valid-text")
        defer { ModelManagerService.deleteModel(model) }
        try validGGUFData(length: 16).write(to: ModelManagerService.baseModelPath(for: model))

        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model))
        XCTAssertTrue(ModelManagerService.isFullyDownloaded(model))
        XCTAssertTrue(DownloadManager().status(for: model).isReady)
    }

    func testUnrecognizedModelFileIsIgnoredDuringReconciliation() throws {
        ModelManagerService.ensureModelsDirectory()
        let orphan = ModelManagerService.modelsDirectory.appendingPathComponent("orphan-artifact.gguf")
        defer { try? FileManager.default.removeItem(at: orphan) }
        try Data(repeating: 0xFF, count: 32).write(to: orphan)

        let manager = DownloadManager()
        manager.updateStatusesFromDisk()

        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(ModelRegistry.allModels.allSatisfy { !manager.status(for: $0).isReady })
    }

    func testMissingCatalogMetadataIsUnavailableWithoutCrashing() throws {
        let invalid = makeCatalogModel(baseSHA256: "")

        XCTAssertFalse(ModelManagerService.isFullyDownloaded(invalid))
        guard case .unavailable = ModelManagerService.availability(for: invalid) else {
            return XCTFail("Missing catalog metadata must be unavailable")
        }
    }

    private func makeRuntimeModel(
        id: String,
        vision: Bool = false,
        baseSHA256: String? = nil,
        mmprojSHA256: String? = nil
    ) -> AIModel {
        let baseData = validGGUFData(length: 16)
        let projectorData = validGGUFData(length: 16)
        return AIModel(
            id: id,
            displayName: "Runtime Test",
            description: "Test model",
            modelType: vision ? .vision : .text,
            baseURL: URL(string: "https://example.com/\(id).gguf")!,
            mmprojURL: vision ? URL(string: "https://example.com/\(id)-mmproj.gguf") : nil,
            baseFileSizeBytes: Int64(baseData.count),
            mmprojFileSizeBytes: vision ? Int64(projectorData.count) : nil,
            baseSHA256: baseSHA256 ?? sha256(baseData),
            mmprojSHA256: vision ? (mmprojSHA256 ?? sha256(projectorData)) : nil,
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

    private func makeCatalogModel(baseSHA256: String) -> AIModel {
        AIModel(
            id: "missing-metadata",
            displayName: "Missing Metadata",
            description: "Test model",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 16,
            mmprojFileSizeBytes: nil,
            baseSHA256: baseSHA256,
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

    private func validGGUFData(length: Int) -> Data {
        var data = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0x00, 0x00, 0x00])
        data.append(contentsOf: repeatElement(0xA5, count: max(0, length - data.count)))
        return data
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
