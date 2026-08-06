// VisionRejectionRepairTests.swift
// ZiroEdgeTests
//
// Tests for vision-model rejection (no compatible projector, ambiguous pairs)
// and repair (download only missing/invalid artifacts while preserving the
// verified counterpart).

import XCTest
import CryptoKit
@testable import ZiroEdge

@MainActor
final class VisionRejectionRepairTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ModelMigrationService.ensureManagedDirectories()
    }

    // MARK: - Rejection: No Projector Available

    func testVisionImportRejectedWhenNoProjectorInRepository() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": String(repeating: "a", count: 40),
            "cardData": ["license": "mit"],
            "gguf": ["architecture": "gemma", "context_length": 4096],
            "siblings": [
                ["rfilename": "model-Q4_K_M.gguf", "size": 100, "lfs": ["sha256": String(repeating: "b", count: 64)]],
            ],
        ])
        let httpResponse = HTTPURLResponse(url: URL(string: "https://huggingface.co/api/models/test/model")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let inspector = HFRepositoryInspector { _ in (data, httpResponse) }
        let review = try await inspector.inspect("test/model")

        let resolver = VisionPairResolver()
        XCTAssertFalse(resolver.hasViableVisionPair(review))
        XCTAssertEqual(review.projectorArtifacts.count, 0)

        // The review's suggestedVisionPair should throw projectorMissing.
        XCTAssertThrowsError(try review.suggestedVisionPair(base: review.baseArtifacts.first!)) { error in
            XCTAssertEqual(error as? HFInspectionError, .projectorMissing)
        }
    }

    func testAmbiguousProjectorsAreRejected() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": String(repeating: "a", count: 40),
            "cardData": ["license": "mit"],
            "gguf": ["architecture": "gemma"],
            "siblings": [
                ["rfilename": "model-Q4_K_M.gguf", "size": 100, "lfs": ["sha256": String(repeating: "1", count: 64)]],
                ["rfilename": "mmproj-A-f16.gguf", "size": 50, "lfs": ["sha256": String(repeating: "2", count: 64)]],
                ["rfilename": "mmproj-B-f16.gguf", "size": 55, "lfs": ["sha256": String(repeating: "3", count: 64)]],
            ],
        ])
        let httpResponse = HTTPURLResponse(url: URL(string: "https://huggingface.co/api/models/test/amb")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let inspector = HFRepositoryInspector { _ in (data, httpResponse) }
        let review = try await inspector.inspect("test/amb")

        // Two projectors → ambiguous.
        XCTAssertThrowsError(try review.suggestedVisionPair(base: review.baseArtifacts.first!)) { error in
            XCTAssertEqual(error as? HFInspectionError, .projectorAmbiguous)
        }
    }

    // MARK: - Rejection: Incompatible Vision Pair Architecture

    func testIncompatibleProjectorArchitectureRejected() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": String(repeating: "a", count: 40),
            "cardData": ["license": "mit"],
            "gguf": ["architecture": "gemma"],
            "siblings": [
                ["rfilename": "model-Q4_K_M.gguf", "size": 100, "lfs": ["sha256": String(repeating: "1", count: 64)]],
                ["rfilename": "mmproj-f16.gguf", "size": 50, "lfs": ["sha256": String(repeating: "2", count: 64)]],
            ],
        ])
        let httpResponse = HTTPURLResponse(url: URL(string: "https://huggingface.co/api/models/test/inc")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let inspector = HFRepositoryInspector { _ in (data, httpResponse) }
        let review = try await inspector.inspect("test/inc")

        // The mmproj is found with architecture "clip" (since filename contains "mmproj"),
        // which is compatible with gemma. This should work.
        let pair = try review.suggestedVisionPair(base: review.baseArtifacts.first!)
        XCTAssertEqual(pair.1.filename, "mmproj-f16.gguf")
    }

    // MARK: - Repair: Download Only Missing Artifacts

    func testRepairDownloadsOnlyMissingBaseWhenProjectorIsValid() throws {
        let baseData = TestModelFixtures.gguf(count: 16)
        let projectorData = TestModelFixtures.gguf(count: 16)
        let model = makeVisionModel(
            id: "repair-base-only",
            baseData: baseData,
            projectorData: projectorData
        )
        defer { ModelManagerService.deleteModel(model) }

        // Install only the projector (valid).
        try projectorData.write(to: ModelManagerService.mmprojModelPath(for: model), options: .atomic)
        XCTAssertTrue(ModelManagerService.isMMProjDownloaded(model))
        XCTAssertFalse(ModelManagerService.isBaseDownloaded(model))
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model))

        // Repair should recognize only the base is missing.
        let availability = ModelManagerService.availability(for: model)
        guard case .repairNeeded(let issues) = availability else {
            XCTFail("Expected repair needed")
            return
        }
        XCTAssertTrue(issues.contains { if case .missing(artifact: .base) = $0 { true } else { false } })
    }

    func testRepairDownloadsOnlyMissingProjectorWhenBaseIsValid() throws {
        let baseData = TestModelFixtures.gguf(count: 16)
        let projectorData = TestModelFixtures.gguf(count: 16)
        let model = makeVisionModel(
            id: "repair-mmproj-only",
            baseData: baseData,
            projectorData: projectorData
        )
        defer { ModelManagerService.deleteModel(model) }

        // Install only the base (valid).
        try baseData.write(to: ModelManagerService.baseModelPath(for: model), options: .atomic)
        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model))
        XCTAssertFalse(ModelManagerService.isMMProjDownloaded(model))

        let availability = ModelManagerService.availability(for: model)
        guard case .repairNeeded(let issues) = availability else {
            XCTFail("Expected repair needed")
            return
        }
        XCTAssertTrue(issues.contains { if case .missing(artifact: .mmproj) = $0 { true } else { false } })
    }

    func testRepairPreservesVerifiedProjectorWhenBaseIsCorrupt() throws {
        let validBase = TestModelFixtures.gguf(count: 16)
        let corruptBase = Data(repeating: 0xFF, count: 16)
        let projectorData = TestModelFixtures.gguf(count: 16)
        let model = makeVisionModel(
            id: "repair-corrupt-base",
            baseData: validBase,
            projectorData: projectorData
        )
        defer { ModelManagerService.deleteModel(model) }

        // Write corrupt base and valid projector.
        try corruptBase.write(to: ModelManagerService.baseModelPath(for: model), options: .atomic)
        try projectorData.write(to: ModelManagerService.mmprojModelPath(for: model), options: .atomic)

        // Projector should still be verified despite corrupt base.
        XCTAssertTrue(ModelManagerService.isMMProjDownloaded(model))
        XCTAssertFalse(ModelManagerService.isBaseDownloaded(model))

        let availability = ModelManagerService.availability(for: model)
        guard case .repairNeeded(let issues) = availability else {
            XCTFail("Expected repair needed")
            return
        }
        // Should have GGUF header issue for corrupt base.
        let hasBaseIssue = issues.contains { issue in
            switch issue {
            case .missing(artifact: .base), .missingGGUFHeader, .sha256Mismatch, .sizeMismatch:
                return true
            default:
                return false
            }
        }
        XCTAssertTrue(hasBaseIssue, "Should have a base artifact issue; got \(issues)")
    }

    func testRepairPreservesVerifiedBaseWhenProjectorIsCorrupt() throws {
        let baseData = TestModelFixtures.gguf(count: 16)
        let validProjector = TestModelFixtures.gguf(count: 16)
        let corruptProjectorData = Data(repeating: 0xFF, count: 16)
        let model = makeVisionModel(
            id: "repair-corrupt-mmproj",
            baseData: baseData,
            projectorData: validProjector
        )
        defer { ModelManagerService.deleteModel(model) }

        try baseData.write(to: ModelManagerService.baseModelPath(for: model), options: .atomic)
        try corruptProjectorData.write(to: ModelManagerService.mmprojModelPath(for: model), options: .atomic)

        // Base should still be verified despite corrupt projector.
        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model))
        XCTAssertFalse(ModelManagerService.isMMProjDownloaded(model))
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model))
    }

    // MARK: - Digest/Size/GGUF Failure Identifies Affected Artifact

    func testAvailabilityIdentifiesSpecificArtifactIssues() throws {
        let validBase = TestModelFixtures.gguf(count: 16)
        let wrongSizeData = Data(repeating: 0xA5, count: 8)  // Wrong size (even with valid GGUF header initially)
        let model = makeVisionModel(
            id: "identify-issues",
            baseData: validBase,
            projectorData: TestModelFixtures.gguf(count: 16)
        )
        defer { ModelManagerService.deleteModel(model) }

        // Write base with wrong size and no projector.
        try wrongSizeData.write(to: ModelManagerService.baseModelPath(for: model), options: .atomic)

        let availability = ModelManagerService.availability(for: model)
        guard case .repairNeeded(let issues) = availability else {
            XCTFail("Expected repair needed")
            return
        }

        // Should identify both the base issue and missing projector independently.
        let hasBaseIssue = issues.contains { issue in
            switch issue {
            case .missingGGUFHeader, .sha256Mismatch, .sizeMismatch: return true
            default: return false
            }
        }
        let hasMMProjMissing = issues.contains { issue in
            if case .missing(artifact: .mmproj) = issue { true } else { false }
        }
        XCTAssertTrue(hasBaseIssue, "Should identify base artifact issue")
        XCTAssertTrue(hasMMProjMissing, "Should identify missing projector separately")
    }

    func testGGUFFailureInProjectorDoesNotInvalidateBase() throws {
        let baseData = TestModelFixtures.gguf(count: 16)
        let badProjector = Data(repeating: 0x00, count: 16) // Invalid GGUF
        let model = makeVisionModel(
            id: "projector-gguf-fail",
            baseData: baseData,
            projectorData: TestModelFixtures.gguf(count: 16)
        )
        defer { ModelManagerService.deleteModel(model) }

        try baseData.write(to: ModelManagerService.baseModelPath(for: model), options: .atomic)
        try badProjector.write(to: ModelManagerService.mmprojModelPath(for: model), options: .atomic)

        // Base should still pass independently.
        XCTAssertTrue(ModelManagerService.isBaseDownloaded(model))
        XCTAssertFalse(ModelManagerService.isMMProjDownloaded(model))
    }

    // MARK: - Storage Rejection Before Transfer

    @MainActor
    func testPairedVisionDownloadRejectedWhenInsufficientStorageForBoth() throws {
        let model = makeVisionModel(
            id: "paired-storage-reject",
            baseData: TestModelFixtures.gguf(count: 1_000_000),
            projectorData: TestModelFixtures.gguf(count: 500_000)
        )
        let tinyStorage: Int64 = 1_000_000  // Not enough for base + projector + margin
        let manager = DownloadManager(availableDiskSpaceProvider: { tinyStorage })

        // Storage check should account for both artifacts.
        XCTAssertFalse(manager.hasSufficientStorage(for: model), "Should reject when storage insufficient for both artifacts")
    }

    // MARK: - Unavailable Without Repair

    func testVisionModelIsUnavailableWhenCatalogHasNoIntegrityMetadata() {
        let model = AIModel(
            id: "no-metadata-vision",
            displayName: "No Metadata Vision",
            description: "Test",
            modelType: .vision,
            baseURL: URL(string: "https://example.com/base.gguf")!,
            mmprojURL: URL(string: "https://example.com/mmproj.gguf")!,
            baseFileSizeBytes: 16,
            mmprojFileSizeBytes: 16,
            baseSHA256: "",  // Missing metadata
            mmprojSHA256: nil,  // Missing metadata
            quantization: "Q4_K_M",
            config: .gemma4,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )
        guard case .unavailable = ModelManagerService.availability(for: model) else {
            return XCTFail("Missing catalog metadata must be unavailable")
        }
    }

    // MARK: - Helpers

    private func makeVisionModel(
        id: String,
        baseData: Data,
        projectorData: Data
    ) -> AIModel {
        AIModel(
            id: id,
            displayName: "Test Vision",
            description: "Test",
            modelType: .vision,
            baseURL: URL(string: "https://example.com/\(id)-base.gguf")!,
            mmprojURL: URL(string: "https://example.com/\(id)-mmproj.gguf")!,
            baseFileSizeBytes: Int64(baseData.count),
            mmprojFileSizeBytes: Int64(projectorData.count),
            baseSHA256: TestModelFixtures.sha256(baseData),
            mmprojSHA256: TestModelFixtures.sha256(projectorData),
            quantization: "Q4_K_M",
            config: .gemma4,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )
    }
}
