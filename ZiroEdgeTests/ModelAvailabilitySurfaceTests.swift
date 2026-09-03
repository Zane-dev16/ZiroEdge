// ModelAvailabilitySurfaceTests.swift
// ZiroEdgeTests
//
// Unified availability surface regression coverage (Acceptance Criterion 3),
// extracted from ModelArtifactVerificationTests.swift for file-size hygiene.

import XCTest
import CryptoKit
@testable import ZiroEdge

@MainActor
final class ModelAvailabilitySurfaceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ModelMigrationService.ensureManagedDirectories()
    }

    // MARK: - Unified Availability Surface (Acceptance Criterion 3)

    /// Every model-facing surface must agree that a valid text model is ready.
    func testAllSurfacesAgreeTextModelIsReady() throws {
        let data = validGGUFData(length: 32)
        let id = "unified-ready-\(UUID().uuidString.lowercased())"
        let model = AIModel(
            id: id,
            displayName: "Unified Ready",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/\(id).gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(data.count),
            mmprojFileSizeBytes: nil,
            baseSHA256: sha256(data),
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )
        defer { ModelManagerService.deleteModel(model) }
        try data.write(to: ModelManagerService.baseModelPath(for: model), options: .atomic)

        // 1. ModelManagerService authoritative check
        let availResult = ModelManagerService.availability(for: model)
        guard case .ready = availResult else {
            return XCTFail("ModelManagerService must report ready, got: \(availResult)")
        }

        // 2. DownloadManager status
        let dmStatus = DownloadManager().status(for: model)
        XCTAssertTrue(dmStatus.isReady, "DownloadManager status must report ready")
        XCTAssertFalse(dmStatus.isRepairNeeded, "DownloadManager must not report repair needed")

        // 3. ModelManagerService.isFullyDownloaded
        XCTAssertTrue(ModelManagerService.isFullyDownloaded(model))
        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model))
    }

    /// A vision model with only a valid base and no projector must NOT be vision-ready
    /// and must be flagged as needing repair.
    func testE2BTextReadyWithoutProjector() throws {
        let baseData = validGGUFData(length: 64)
        let projectorData = validGGUFData(length: 32)
        let id = "e2b-unified-\(UUID().uuidString.lowercased())"
        let model = AIModel(
            id: id,
            displayName: "E2B Unified",
            description: "Test model without text-only capability",
            modelType: .vision,
            baseURL: URL(string: "https://example.com/\(id).gguf")!,
            mmprojURL: URL(string: "https://example.com/\(id)-mmproj.gguf")!,
            baseFileSizeBytes: Int64(baseData.count),
            mmprojFileSizeBytes: Int64(projectorData.count),
            baseSHA256: sha256(baseData),
            mmprojSHA256: sha256(projectorData),
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )
        defer { ModelManagerService.deleteModel(model) }
        try baseData.write(to: ModelManagerService.baseModelPath(for: model), options: .atomic)

        // With only base installed and no text-only capability (allowsTextOnly not set): repair needed
        let status = DownloadManager().status(for: model)
        XCTAssertTrue(status.isRepairNeeded, "Vision model with only base should need repair")
        XCTAssertFalse(status.isReady, "Vision model with only base should not be ready")
        XCTAssertFalse(status.isVisionReady, "Vision model without projector should not be vision-ready")
    }

    /// Reconciliation must be deterministic and crash-safe — re-running it must
    /// produce the same result without exceptions.
    func testReconciliationIsDeterministic() throws {
        let data = validGGUFData(length: 32)
        let id = "deterministic-recon-\(UUID().uuidString.lowercased())"
        let model = AIModel(
            id: id,
            displayName: "Deterministic Recon",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/\(id).gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(data.count),
            mmprojFileSizeBytes: nil,
            baseSHA256: sha256(data),
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )
        defer { ModelManagerService.deleteModel(model) }
        try data.write(to: ModelManagerService.baseModelPath(for: model), options: .atomic)

        let first = ModelManagerService.availability(for: model)
        let second = ModelManagerService.availability(for: model)
        // Running it twice on a valid artifact must produce the same result
        XCTAssertEqual(first, second, "Availability check must be deterministic")

        // Running after removing the file must also be deterministic
        try FileManager.default.removeItem(at: ModelManagerService.baseModelPath(for: model))
        let third = ModelManagerService.availability(for: model)
        let fourth = ModelManagerService.availability(for: model)
        // Both post-removal checks must agree
        guard case .repairNeeded = third, case .repairNeeded = fourth else {
            return XCTFail("Missing artifact must be repairable, got: \(third), \(fourth)")
        }
    }

    /// Quarantined artifacts must be moved away from their original location.
    func testQuarantineRemovesInvalidArtifactFromInstalledPath() throws {
        let data = validGGUFData(length: 32)
        let id = "quarantine-test-\(UUID().uuidString.lowercased())"
        let model = AIModel(
            id: id,
            displayName: "Quarantine Test",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/\(id).gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(data.count),
            mmprojFileSizeBytes: nil,
            baseSHA256: sha256(data),
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )
        defer { ModelManagerService.deleteModel(model) }
        let destURL = ModelManagerService.baseModelPath(for: model)
        // Write a valid GGUF structure but with wrong content → wrong hash
        var wrongData = validGGUFData(length: Int(data.count))
        wrongData[wrongData.count - 1] = 0xFF  // flip last byte → wrong SHA
        try wrongData.write(to: destURL, options: .atomic)

        // The authoritative check must detect the hash mismatch
        guard case .repairNeeded(let issues) = ModelManagerService.availability(for: model) else {
            return XCTFail("Wrong hash must be repairable")
        }
        XCTAssertTrue(issues.contains { if case ArtifactIssue.sha256Mismatch = $0 { return true }; return false })

        // isBaseDownloaded must return false AND quarantine the artifact
        XCTAssertFalse(ModelManagerService.isBaseDownloaded(model))

        // The original must be gone after failed validation
        XCTAssertFalse(FileManager.default.fileExists(atPath: destURL.path),
                       "Quarantine must move invalid artifact away from installed path")
    }

    private func validGGUFData(length: Int) -> Data {
        TestModelFixtures.gguf(count: length)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
