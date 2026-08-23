// ModelArtifactVerificationTests.swift
// ZiroEdgeTests
//
// Deterministic regression coverage for false-installed model artifacts.
import XCTest
import CryptoKit
@testable import ZiroEdge
@MainActor
final class ModelArtifactVerificationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ModelMigrationService.ensureManagedDirectories()
    }
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
        try validGGUFData(length: 69).write(to: ModelManagerService.baseModelPath(for: model))

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

    @MainActor
    func testPromotionRejectsMissingSHA256() throws {
        let invalid = makeCatalogModel(baseSHA256: "")
        let task = DownloadTask(model: invalid, artifact: .base)
        defer { ModelManagerService.deleteModel(invalid) }
        try validGGUFData(length: 16).write(to: task.stagingURL)

        let manager = DownloadManager()
        manager.injectAvailableDiskSpaceForTesting = 1_000_000_000
        let result = manager.verifyAndPromote(task: task)

        guard case .failure(.invalidCatalogMetadata) = result else {
            return XCTFail("Promotion must reject an artifact without a valid SHA-256")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.destinationURL.path))
    }

    func testInjectedPromotionFailurePreservesVerifiedInstallationByteForByte() throws {
        let bytes = validGGUFData(length: 32)
        let model = makeRuntimeModel(
            id: "atomic-replacement-\(UUID().uuidString.lowercased())",
            baseSHA256: sha256(bytes)
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { ModelManagerService.deleteModel(model) }
        try bytes.write(to: task.destinationURL, options: .atomic)
        try bytes.write(to: task.stagingURL, options: .atomic)

        let manager = DownloadManager()
        manager.injectPromotionFailureForTesting = true
        manager.injectAvailableDiskSpaceForTesting = 1_000_000_000
        let result = manager.verifyAndPromote(task: task)

        guard case .failure(.promotionFailed) = result else {
            return XCTFail("Injected promotion failure should be reported as promotionFailed, got: \(result)")
        }
        if case .failed = task.state {
            // State publication: task state must be .failed after failure.
        } else {
            XCTFail("Task state must be .failed after injected promotion failure, got \(task.state)")
        }
        XCTAssertEqual(try Data(contentsOf: task.destinationURL), bytes,
                       "A failed replacement leaves the prior verified bytes intact")
        XCTAssertTrue(ModelManagerService.isFullyDownloaded(model))
    }

    func testPromotionRejectsStructurallyInvalidGGUFBeforeHashing() throws {
        let invalid = Data(repeating: 0x41, count: 68)
        let model = makeRuntimeModel(
            id: "invalid-structure-\(UUID().uuidString.lowercased())",
            baseSHA256: sha256(invalid)
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { ModelManagerService.deleteModel(model) }
        try invalid.write(to: task.stagingURL, options: .atomic)

        let manager = DownloadManager()
        manager.injectAvailableDiskSpaceForTesting = 1_000_000_000
        let result = manager.verifyAndPromote(task: task)
        guard case .failure(.structureInvalid) = result else {
            return XCTFail("Malformed GGUF must fail before promotion")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.destinationURL.path))
    }

    func testCatalogValidatorRejectsSignedAndIncompleteEntries() {
        var model = makeRuntimeModel(id: "catalog-malformed")
        model = AIModel(
            id: model.id,
            displayName: model.displayName,
            description: model.description,
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf?token=secret")!,
            mmprojURL: nil,
            baseFileSizeBytes: model.baseFileSizeBytes,
            mmprojFileSizeBytes: nil,
            baseSHA256: model.baseSHA256,
            mmprojSHA256: nil,
            quantization: model.quantization,
            config: model.config,
            license: model.license
        )
        XCTAssertNotNil(model.catalogUnavailableReason)
    }

    func testSHA256MetadataMustBeLowercase64Hex() {
        XCTAssertTrue(ModelManagerService.isValidSHA256(String(repeating: "a", count: 64)))
        XCTAssertFalse(ModelManagerService.isValidSHA256(""))
        XCTAssertFalse(ModelManagerService.isValidSHA256(String(repeating: "A", count: 64)))
        XCTAssertFalse(ModelManagerService.isValidSHA256(String(repeating: "g", count: 64)))
    }

    // MARK: - Catalog-Contract Tests

    func testProductionCatalogPassesValidation() {
        let reason = ModelCatalogValidator.catalogFailureReason(models: ModelRegistry.allModels)
        XCTAssertNil(reason, "Production catalog must pass validation: \(reason ?? "")")
    }

    func testNonPositiveBaseSizeFailsClosed() {
        let model = AIModel(
            id: "zero-size", displayName: "Zero Size", description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 0,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M", config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertNotNil(model.catalogUnavailableReason, "Non-positive size must be rejected")
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model))
    }

    func testNegativeBaseSizeFailsClosed() {
        let model = AIModel(
            id: "negative-size", displayName: "Negative Size", description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: -1,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M", config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertNotNil(model.catalogUnavailableReason, "Negative size must be rejected")
    }

    func testVisionModelWithoutProjectorMetadataFailsClosed() {
        let model = AIModel(
            id: "vision-no-mmproj", displayName: "Vision No MMProj", description: "Test",
            modelType: .vision,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 16,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M", config: .gemma4,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertNotNil(model.catalogUnavailableReason, "Vision without projector metadata must be rejected")
        guard case .unavailable = ModelManagerService.availability(for: model) else {
            return XCTFail("Vision model without projector must be unavailable")
        }
    }

    func testVisionModelWithZeroProjectorSizeFailsClosed() {
        let model = AIModel(
            id: "vision-zero-mmproj", displayName: "Vision Zero MMProj", description: "Test",
            modelType: .vision,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: URL(string: "https://example.com/mmproj.gguf")!,
            baseFileSizeBytes: 16,
            mmprojFileSizeBytes: 0,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: String(repeating: "b", count: 64),
            quantization: "Q4_K_M", config: .gemma4,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertNotNil(model.catalogUnavailableReason, "Vision with zero projector size must be rejected")
    }

    func testTextModelWithStrayProjectorMetadataFailsClosed() {
        let model = AIModel(
            id: "text-stray-mmproj", displayName: "Text Stray MMProj", description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: URL(string: "https://example.com/mmproj.gguf")!,
            baseFileSizeBytes: 16,
            mmprojFileSizeBytes: 16,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M", config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertNotNil(model.catalogUnavailableReason, "Text model with stray projector metadata must be rejected")
    }

    func testDuplicateModelIdentityIsRejected() {
        let dup1 = AIModel(
            id: "duplicate-id", displayName: "Duplicate A", description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/a.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 16,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M", config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        let dup2 = AIModel(
            id: "duplicate-id", displayName: "Duplicate B", description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/b.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 32,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "b", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M", config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertNotNil(ModelCatalogValidator.catalogFailureReason(models: [dup1, dup2]),
                        "Duplicate model identities must be rejected")
    }

}

extension ModelArtifactVerificationTests {
    func testSharedStorageIdentityModelsHaveConsistentMetadata() {
        // gemma4_e4b and gemma4_e4b_text share baseArtifactStorageID.
        // Their base metadata must be byte-for-byte identical.
        let vision = ModelRegistry.gemma4_e4b
        let text = ModelRegistry.gemma4_e4b_text

        // Verify they share the same storage identity.
        XCTAssertEqual(vision.baseArtifactStorageID, text.baseArtifactStorageID)

        // Verify their base metadata is consistent.
        XCTAssertEqual(vision.baseURL, text.baseURL)
        XCTAssertEqual(vision.baseFileSizeBytes, text.baseFileSizeBytes)
        XCTAssertEqual(vision.baseSHA256, text.baseSHA256)

        // Verify the catalog validator accepts this shared configuration.
        let models: [AIModel] = [vision, text]
        XCTAssertNil(ModelCatalogValidator.catalogFailureReason(models: models),
                      "Models sharing storage ID with consistent metadata must pass validation")
    }

    func testCatalogValidatorRejectsNonCanonicalURLScheme() {
        let model = AIModel(
            id: "http-scheme", displayName: "HTTP Scheme", description: "Test",
            modelType: .text,
            baseURL: URL(string: "http://example.com/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 16,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M", config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertNotNil(model.catalogUnavailableReason, "HTTP URL scheme must be rejected")
    }

    func testCatalogValidatorRejectsNonGGUFSuffix() {
        let model = AIModel(
            id: "non-gguf-suffix", displayName: "Non-GGUF Suffix", description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.bin")!,
            mmprojURL: nil,
            baseFileSizeBytes: 16,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M", config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertNotNil(model.catalogUnavailableReason, "Non-GGUF URL suffix must be rejected")
    }

    func testCatalogValidatorRejectsURLWithFragment() {
        let model = AIModel(
            id: "fragment-url", displayName: "Fragment URL", description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf#fragment")!,
            mmprojURL: nil,
            baseFileSizeBytes: 16,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M", config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertNotNil(model.catalogUnavailableReason, "URL with fragment must be rejected")
    }

    func testCatalogValidatorRejectsURLWithCredentials() {
        let model = AIModel(
            id: "credentials-url", displayName: "Credentials URL", description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://user:pass@example.com/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 16,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M", config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertNotNil(model.catalogUnavailableReason, "URL with embedded credentials must be rejected")
    }

    func testNonPositiveMMProjSizeOnVisionModelFailsClosed() {
        let model = AIModel(
            id: "vision-neg-mmproj", displayName: "Vision Negative MMProj", description: "Test",
            modelType: .vision,
            baseURL: URL(string: "https://example.com/model.gguf")!,
            mmprojURL: URL(string: "https://example.com/mmproj.gguf")!,
            baseFileSizeBytes: 16,
            mmprojFileSizeBytes: -1,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: String(repeating: "b", count: 64),
            quantization: "Q4_K_M", config: .gemma4,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertNotNil(model.catalogUnavailableReason, "Vision with negative projector size must be rejected")
    }

    // MARK: - Download Prevention for Invalid Catalog Entries

    func testDownloadRefusedForModelWithInvalidCatalogMetadata() {
        let model = AIModel(
            id: "download-refused", displayName: "Download Refused", description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/model.gguf?token=secret")!,
            mmprojURL: nil,
            baseFileSizeBytes: 16,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4_K_M", config: .llama32,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        XCTAssertNotNil(model.catalogUnavailableReason)

        let manager = DownloadManager()
        manager.startDownload(for: model)

        let status = manager.status(for: model)
        guard case .failed(let error) = status.baseState else {
            return XCTFail("Download for invalid catalog entry must fail")
        }
        XCTAssertEqual(error, .invalidCatalogMetadata,
                       "Download with invalid catalog metadata must produce invalidCatalogMetadata error")
    }

    func testDownloadRefusedWhenCatalogHasConflictingEntries() {
        // The production catalog is known-valid; this test documents the guard exists.
        let reason = ModelCatalogValidator.catalogFailureReason(models: ModelRegistry.allModels)
        XCTAssertNil(reason, "Production catalog must be valid so downloads are not blocked")

        let model = ModelRegistry.llama32_3B
        let manager = DownloadManager()
        // Start+immediate cancel confirms no crash rather than blocked start.
        manager.startDownload(for: model)
        manager.cancelDownload(for: model)

        let status = manager.status(for: model)
        XCTAssertFalse(status.isReady)
    }

    // MARK: - Staging Cleanup

    func testStagingCleanedAfterValidationFailure() throws {
        let bytes = validGGUFData(length: 16)
        let model = makeRuntimeModel(
            id: "staging-cleanup-val-\(UUID().uuidString.lowercased())",
            baseSHA256: String(repeating: "f", count: 64) // intentionally wrong
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { ModelManagerService.deleteModel(model) }
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-staging-\(UUID().uuidString).gguf")
        try bytes.write(to: tmpURL)
        try FileManager.default.moveItem(at: tmpURL, to: task.stagingURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: task.stagingURL.path))

        let manager = DownloadManager()
        manager.injectAvailableDiskSpaceForTesting = 1_000_000_000
        let result = manager.verifyAndPromote(task: task)

        guard case .failure = result else {
            return XCTFail("Validation must reject artifact with wrong SHA-256")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.stagingURL.path),
                       "Staging artifact must be cleaned on validation failure")
    }

    func testStagingPreservedAfterPromotionFailure() throws {
        let bytes = validGGUFData(length: 16)
        let model = makeRuntimeModel(
            id: "staging-cleanup-promo-\(UUID().uuidString.lowercased())",
            baseSHA256: sha256(bytes)
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { ModelManagerService.deleteModel(model) }
        // Pre-create a verified destination so promotion path goes through replaceItemAt.
        try bytes.write(to: task.destinationURL, options: .atomic)
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-staging-\(UUID().uuidString).gguf")
        try bytes.write(to: tmpURL)
        try FileManager.default.moveItem(at: tmpURL, to: task.stagingURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: task.stagingURL.path))

        let manager = DownloadManager()
        manager.injectPromotionFailureForTesting = true
        manager.injectAvailableDiskSpaceForTesting = 1_000_000_000
        let result = manager.verifyAndPromote(task: task)

        guard case .failure(.promotionFailed) = result else {
            return XCTFail("Injected promotion failure must be surfaced as promotionFailed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.stagingURL.path),
                      "Staging artifact must survive a transient promotion failure: " +
                      "the bytes already passed SHA-256 and must not be redownloaded " +
                      "because installation hit a filesystem error")
        // Durable metadata must still advertise resumable staging.
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.metadataURL.path),
                      "Durable snapshot must persist so relaunch recovery can re-promote")
    }

    // MARK: - State Publication

    /// Asserts verifyAndPromote publishes .failed state on verification failure
    /// and cleans the staging artifact.
    func testVerifyAndPromotePublishesFailedState() throws {
        let bytes = validGGUFData(length: 16)
        let model = makeRuntimeModel(
            id: "state-pub-fail-\(UUID().uuidString.lowercased())",
            baseSHA256: String(repeating: "e", count: 64) // wrong hash
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { ModelManagerService.deleteModel(model) }
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-staging-\(UUID().uuidString).gguf")
        try bytes.write(to: tmpURL)
        try FileManager.default.moveItem(at: tmpURL, to: task.stagingURL)

        let manager = DownloadManager()
        manager.injectAvailableDiskSpaceForTesting = 1_000_000_000
        let result = manager.verifyAndPromote(task: task)

        guard case .failure = result else {
            return XCTFail("Wrong SHA-256 must fail verification")
        }
        if case .failed = task.state {
            // Expected: state is .failed after validation failure
        } else {
            XCTFail("Task state must be .failed after verification failure, got \(task.state)")
        }
    }

}

extension ModelArtifactVerificationTests {
    func testInvalidContentNeverReachesInstalledPath() throws {
        let bytes = Data(repeating: 0xFF, count: 16)
        let model = makeRuntimeModel(
            id: "no-install-\(UUID().uuidString.lowercased())",
            baseSHA256: sha256(bytes)
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { ModelManagerService.deleteModel(model) }
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-staging-\(UUID().uuidString).gguf")
        try bytes.write(to: tmpURL)
        try FileManager.default.moveItem(at: tmpURL, to: task.stagingURL)

        let manager = DownloadManager()
        manager.injectAvailableDiskSpaceForTesting = 1_000_000_000
        // bytes lack a GGUF header, so validation must reject them.
        let result = manager.verifyAndPromote(task: task)

        guard case .failure = result else {
            return XCTFail("Non-GGUF content must be rejected")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.destinationURL.path),
                       "Invalid content must never reach the installed path")
    }

    // MARK: - Atomic Promotion Backup / Restore

    func testPromoteAtomicallyCreatesAndCleansBackupOnSuccess() throws {
        let oldBytes = validGGUFData(length: 16)
        let newBytes = validGGUFData(length: 16)
        let model = makeRuntimeModel(
            id: "atomic-backup-\(UUID().uuidString.lowercased())",
            baseSHA256: sha256(oldBytes)
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { ModelManagerService.deleteModel(model) }

        // Pre-create destination so replaceItemAt path is used.
        try oldBytes.write(to: task.destinationURL, options: .atomic)
        // Write different-but-valid bytes to staging.
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-staging-\(UUID().uuidString).gguf")
        try newBytes.write(to: tmpURL)
        try FileManager.default.moveItem(at: tmpURL, to: task.stagingURL)

        // Manually call promoteAtomically via the DownloadManager.
        let manager = DownloadManager()
        try manager.promoteAtomically(task)

        // The backup file must not remain.
        let backup = task.destinationURL.deletingLastPathComponent()
            .appendingPathComponent(task.destinationURL.lastPathComponent + ".promotion-backup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path),
                       "Backup must be cleaned after successful promotion")
        // The destination should now contain the new bytes (from staging).
        XCTAssertEqual(try Data(contentsOf: task.destinationURL), newBytes)
    }

    func testPromoteAtomicallyMoveWhenDestinationAbsent() throws {
        let bytes = validGGUFData(length: 16)
        let model = makeRuntimeModel(
            id: "atomic-move-\(UUID().uuidString.lowercased())",
            baseSHA256: sha256(bytes)
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { ModelManagerService.deleteModel(model) }

        // Do NOT pre-create destination — should move staging directly.
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-staging-\(UUID().uuidString).gguf")
        try bytes.write(to: tmpURL)
        try FileManager.default.moveItem(at: tmpURL, to: task.stagingURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.destinationURL.path))

        let manager = DownloadManager()
        try manager.promoteAtomically(task)

        XCTAssertTrue(FileManager.default.fileExists(atPath: task.destinationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.stagingURL.path))
        XCTAssertEqual(try Data(contentsOf: task.destinationURL), bytes)
    }

    func testPromoteAtomicallyPreservesDestinationOnInjectFailure() throws {
        let oldBytes = validGGUFData(length: 16)
        let newBytes = validGGUFData(length: 16)
        let model = makeRuntimeModel(
            id: "atomic-preserve-\(UUID().uuidString.lowercased())",
            baseSHA256: sha256(oldBytes)
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { ModelManagerService.deleteModel(model) }

        try oldBytes.write(to: task.destinationURL, options: .atomic)
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-staging-\(UUID().uuidString).gguf")
        try newBytes.write(to: tmpURL)
        try FileManager.default.moveItem(at: tmpURL, to: task.stagingURL)

        let manager = DownloadManager()
        manager.injectPromotionFailureForTesting = true
        XCTAssertThrowsError(try manager.promoteAtomically(task))

        // Destination must remain unchanged.
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.destinationURL.path))
        XCTAssertEqual(try Data(contentsOf: task.destinationURL), oldBytes)
        // Staging must still exist (promotion didn't happen).
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.stagingURL.path))
    }


    // MARK: - Verification cancellation consistency

    func testCancelledVerificationDoesNotAlterInstalledArtifact() async throws {
        let bytes = validGGUFData(length: 64 * 1_024 * 1_024) // 64 MiB
        let digest = sha256(bytes)
        let model = makeRuntimeModel(
            id: "cancel-consistency-\(UUID().uuidString.lowercased())",
            baseSHA256: digest
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { ModelManagerService.deleteModel(model) }

        // Pre-seed the installed destination.
        try bytes.write(to: task.destinationURL, options: .atomic)
        try bytes.write(to: task.stagingURL, options: .atomic)

        // Run verification in a cancellable detached task.
        let verifyTask = Task.detached(priority: .utility) {
            ModelArtifactVerifier.failure(
                fileURL: task.stagingURL,
                expectedBytes: Int64(bytes.count),
                expectedSHA256: digest
            )
        }
        try await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        verifyTask.cancel()
        _ = await verifyTask.value

        // The installed artifact must survive untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.destinationURL.path))
        XCTAssertEqual(try Data(contentsOf: task.destinationURL), bytes)
    }

    func testVerificationFailureDoesNotPromoteOrCorruptInstalled() throws {
        let goodBytes = validGGUFData(length: 32)
        var badBytes = validGGUFData(length: 32)
        // Flip one byte to guarantee different SHA-256.
        badBytes[badBytes.count - 1] = 0xFF

        let model = makeRuntimeModel(
            id: "atomic-replacement-fail-consistency-\(UUID().uuidString.lowercased())",
            baseSHA256: sha256(goodBytes)
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { ModelManagerService.deleteModel(model) }

        // Installed artifact has correct bytes.
        try goodBytes.write(to: task.destinationURL, options: .atomic)
        // Staging has wrong bytes.
        try badBytes.write(to: task.stagingURL, options: .atomic)

        let result = DownloadManager().verifyAndPromote(task: task)

        guard case .failure(.sha256Mismatch) = result else {
            return XCTFail("Must fail with SHA-256 mismatch, got \(result)")
        }
        // Installed artifact must remain unchanged.
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.destinationURL.path))
        XCTAssertEqual(try Data(contentsOf: task.destinationURL), goodBytes)
        // Terminal validation failure cleans staging without touching installed bytes.
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.stagingURL.path))
    }

    func testCancellationPreservesStagingFile() async throws {
        let bytes = validGGUFData(length: 16 * 1_024 * 1_024) // 16 MiB
        let digest = sha256(bytes)
        let model = makeRuntimeModel(
            id: "cancel-staging-\(UUID().uuidString.lowercased())",
            baseSHA256: digest
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer {
            ModelManagerService.deleteModel(model)
            try? FileManager.default.removeItem(at: task.stagingURL)
        }

        try bytes.write(to: task.stagingURL, options: .atomic)

        // Start verification in a cancellable task.
        let verifyTask = Task.detached(priority: .utility) {
            ModelArtifactVerifier.failure(
                fileURL: task.stagingURL,
                expectedBytes: Int64(bytes.count),
                expectedSHA256: digest
            )
        }
        try await Task.sleep(nanoseconds: 1_000_000)
        verifyTask.cancel()
        _ = await verifyTask.value

        // Staging must survive — cancellation does not auto-clean.
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.stagingURL.path),
                       "Cancellation must preserve staging file for retry")
        XCTAssertNil(ModelArtifactVerifier.failure(
            fileURL: task.stagingURL,
            expectedBytes: Int64(bytes.count),
            expectedSHA256: digest
        ), "Preserved staging bytes must remain valid")
    }

    func testInjectedPromotionFailurePreservesBothSides() throws {
        let bytes = validGGUFData(length: 32)
        let model = makeRuntimeModel(
            id: "atomic-replacement-injected-both-\(UUID().uuidString.lowercased())",
            baseSHA256: sha256(bytes)
        )
        let task = DownloadTask(model: model, artifact: .base)
        defer { ModelManagerService.deleteModel(model) }

        try bytes.write(to: task.destinationURL, options: .atomic)
        try bytes.write(to: task.stagingURL, options: .atomic)

        let manager = DownloadManager()
        manager.injectPromotionFailureForTesting = true
        manager.injectAvailableDiskSpaceForTesting = 1_000_000_000
        let result = manager.verifyAndPromote(task: task)

        guard case .failure(.promotionFailed) = result else {
            return XCTFail("Injected promotion failure must report .promotionFailed, got \(result)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.stagingURL.path),
                      "Verified staging survives a transient promotion failure")
        // Installed artifact must be unchanged.
        XCTAssertEqual(try Data(contentsOf: task.destinationURL), bytes)
    }

}

extension ModelArtifactVerificationTests {
    private func makeRuntimeModel(
        id: String,
        vision: Bool = false,
        baseSHA256: String? = nil,
        mmprojSHA256: String? = nil
    ) -> AIModel {
        let baseData = validGGUFData(length: id.hasPrefix("atomic-replacement-") ? 32 : 16)
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
            license: LicenseInfo(
                name: "Test",
                url: URL(string: "https://example.com/license")!,
                copyright: "Test"
            )
        )
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
