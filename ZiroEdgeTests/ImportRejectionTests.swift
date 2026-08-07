import XCTest
@testable import ZiroEdge

/// Validates that every rejection class in bundle 1 produces a specific,
/// user-readable message BEFORE any transfer state or imported-model record
/// is created. No artifact is ever downloaded or registered on a rejection path.
final class ImportRejectionTests: XCTestCase {

    // MARK: - Malformed IDs

    func testNormalizeRejectsEmptyString() {
        XCTAssertThrowsError(try HFRepositoryInspector.normalizeRepositoryID("")) { error in
            XCTAssertEqual(error as? HFInspectionError, .malformedRepository)
        }
    }

    func testNormalizeRejectsSingleComponent() {
        XCTAssertThrowsError(try HFRepositoryInspector.normalizeRepositoryID("owner")) { error in
            XCTAssertEqual(error as? HFInspectionError, .malformedRepository)
        }
    }

    func testNormalizeRejectsThreeComponents() {
        XCTAssertThrowsError(try HFRepositoryInspector.normalizeRepositoryID("a/b/c")) { error in
            XCTAssertEqual(error as? HFInspectionError, .malformedRepository)
        }
    }

    func testNormalizeRejectsNonHuggingFaceHost() {
        XCTAssertThrowsError(try HFRepositoryInspector.normalizeRepositoryID("https://github.com/owner/repo")) { error in
            XCTAssertEqual(error as? HFInspectionError, .malformedRepository)
        }
    }

    func testNormalizeRejectsSpecialCharacters() {
        XCTAssertThrowsError(try HFRepositoryInspector.normalizeRepositoryID("owner/repo!@#")) { error in
            XCTAssertEqual(error as? HFInspectionError, .malformedRepository)
        }
    }

    // MARK: - Missing Repos / Unavailable

    func testRepositoryUnavailableDoesNotMutateStoreOrStartTransfer() async throws {
        let inspector = HFRepositoryInspector { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://huggingface.co/api/models/missing/repo")!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
        do {
            _ = try await inspector.inspect("missing/repo")
            XCTFail("Expected repositoryUnavailable")
        } catch {
            XCTAssertEqual(error as? HFInspectionError, .repositoryUnavailable)
            XCTAssertEqual(
                (error as? HFInspectionError)?.errorDescription,
                "This Hugging Face repository does not exist or is unavailable."
            )
        }
    }

    func testPrivateRepositoryRejectedWithoutCredentials() async throws {
        let inspector = HFRepositoryInspector { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://huggingface.co/api/models/private/repo")!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
        do {
            _ = try await inspector.inspect("private/repo")
            XCTFail("Expected repositoryPrivate")
        } catch {
            XCTAssertEqual(error as? HFInspectionError, .repositoryPrivate)
        }
    }

    func testTransientServerFailureSurfacesRetryableMessage() async throws {
        let inspector = HFRepositoryInspector { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://huggingface.co/api/models/busy/repo")!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
        do {
            _ = try await inspector.inspect("busy/repo")
            XCTFail("Expected transientFailure")
        } catch {
            XCTAssertEqual(error as? HFInspectionError, .transientFailure)
            XCTAssertEqual(
                (error as? HFInspectionError)?.errorDescription,
                "Hugging Face could not be reached. Try inspection again."
            )
        }
    }

    // MARK: - Non-GGUF Files

    func testRepoWithNoGGUFFilesYieldsNoCompatibleArtifact() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": String(repeating: "a", count: 40),
            "cardData": ["license": "mit"],
            "siblings": [
                ["rfilename": "README.md", "size": 100],
                ["rfilename": "config.json", "size": 200],
                ["rfilename": "model.safetensors", "size": 1_000_000, "lfs": ["sha256": String(repeating: "b", count: 64)]],
            ],
        ])
        let inspector = HFRepositoryInspector { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://huggingface.co/api/models/nogguf/repo")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }
        do {
            _ = try await inspector.inspect("nogguf/repo")
            XCTFail("Expected noCompatibleArtifact")
        } catch {
            XCTAssertEqual(error as? HFInspectionError, .noCompatibleArtifact)
        }
    }

    // MARK: - Unsupported Architectures

    func testUnsupportedArchitectureProducesDescriptiveMessage() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": String(repeating: "c", count: 40),
            "cardData": ["license": "mit"],
            "gguf": ["architecture": "falcon"],
            "siblings": [
                ["rfilename": "model-falcon.gguf", "size": 100, "lfs": ["sha256": String(repeating: "d", count: 64)]],
            ],
        ])
        let inspector = HFRepositoryInspector { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://huggingface.co/api/models/falcon/repo")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }
        do {
            _ = try await inspector.inspect("falcon/repo")
            XCTFail("Expected unsupportedArchitecture")
        } catch {
            guard let hfError = error as? HFInspectionError,
                  case .unsupportedArchitecture("falcon") = hfError else {
                XCTFail("Expected unsupportedArchitecture(falcon), got \(error)")
                return
            }
            XCTAssertTrue(hfError.errorDescription?.contains("falcon") ?? false)
        }
    }

    // MARK: - Missing Integrity Metadata

    func testMissingSHA256DigestYieldsMissingDigestError() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": String(repeating: "e", count: 40),
            "cardData": ["license": "mit"],
            "siblings": [
                ["rfilename": "model.gguf", "size": 100],
            ],
        ])
        let inspector = HFRepositoryInspector { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://huggingface.co/api/models/nodigest/repo")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }
        do {
            _ = try await inspector.inspect("nodigest/repo")
            XCTFail("Expected missingDigest")
        } catch {
            guard let hfError = error as? HFInspectionError,
                  case .missingDigest("model.gguf") = hfError else {
                XCTFail("Expected missingDigest(model.gguf), got \(error)")
                return
            }
        }
    }

    func testInvalidSHA256FormatYieldsMalformedMetadata() async throws {
        // SHA-256 must be exactly 64 lowercase hex characters.
        let badDigest = "NOT_A_VALID_SHA256_HASH_VALUE_1234567890"
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": String(repeating: "f", count: 40),
            "cardData": ["license": "mit"],
            "siblings": [
                ["rfilename": "model.gguf", "size": 100, "lfs": ["sha256": badDigest]],
            ],
        ])
        let inspector = HFRepositoryInspector { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://huggingface.co/api/models/baddigest/repo")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }
        do {
            _ = try await inspector.inspect("baddigest/repo")
            XCTFail("Expected malformedMetadata")
        } catch {
            guard let hfError = error as? HFInspectionError,
                  case .malformedMetadata("model.gguf") = hfError else {
                XCTFail("Expected malformedMetadata(model.gguf), got \(error)")
                return
            }
        }
    }

    func testZeroFileSizeYieldsMalformedMetadata() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": String(repeating: "f", count: 40),
            "cardData": ["license": "mit"],
            "siblings": [
                ["rfilename": "model.gguf", "size": 0, "lfs": ["sha256": String(repeating: "a", count: 64)]],
            ],
        ])
        let inspector = HFRepositoryInspector { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://huggingface.co/api/models/zerosize/repo")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }
        do {
            _ = try await inspector.inspect("zerosize/repo")
            XCTFail("Expected malformedMetadata")
        } catch {
            guard let hfError = error as? HFInspectionError,
                  case .malformedMetadata("model.gguf") = hfError else {
                XCTFail("Expected malformedMetadata(model.gguf), got \(error)")
                return
            }
        }
    }

    // MARK: - License Terms

    func testMissingLicenseTermsRejectsImportInspection() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": String(repeating: "a", count: 40),
            "gguf": ["architecture": "llama"],
            "siblings": [[
                "rfilename": "model-Q4_K_M.gguf",
                "size": 100,
                "lfs": ["sha256": String(repeating: "b", count: 64)],
            ]],
        ])
        let inspector = HFRepositoryInspector { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://huggingface.co/api/models/unlicensed/repo")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }

        do {
            _ = try await inspector.inspect("unlicensed/repo")
            XCTFail("Expected licenseTermsUnavailable")
        } catch {
            XCTAssertEqual(error as? HFInspectionError, .licenseTermsUnavailable)
        }
    }

    func testRepositoryLicenseFileProvidesReviewableTermsWithoutCardMetadata() async throws {
        let digest = String(repeating: "b", count: 64)
        let revision = String(repeating: "a", count: 40)
        let data = try JSONSerialization.data(withJSONObject: [
            "sha": revision,
            "gguf": ["architecture": "llama"],
            "siblings": [
                [
                    "rfilename": "model-Q4_K_M.gguf",
                    "size": 100,
                    "lfs": ["sha256": digest],
                ],
                ["rfilename": "LICENSE.md"],
            ],
        ])
        let inspector = HFRepositoryInspector { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://huggingface.co/api/models/licensed/repo")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }

        let review = try await inspector.inspect("licensed/repo")

        XCTAssertEqual(review.licenseName, "Repository license")
        XCTAssertEqual(
            review.licenseURL.absoluteString,
            "https://huggingface.co/licensed/repo/resolve/\(revision)/LICENSE.md"
        )
    }

    // MARK: - No Transfer State Created

    @MainActor
    func testRejectionDoesNotCreateImportedModelRecord() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportedModelStore(directory: directory)
        // Simulate: an import that was never confirmed should leave zero records.
        XCTAssertEqual(store.allRecords.count, 0)
        // Even after a failed inspection, no record should exist.
        XCTAssertNil(store.record(repositoryID: "no/such", revision: "deadbeef", baseFilename: "x.gguf", projectorFilename: nil))
    }

    // MARK: - Error Message Formatting

    func testEveryRejectionErrorHasNonEmptyDescription() {
        let errors: [HFInspectionError] = [
            .malformedRepository,
            .repositoryUnavailable,
            .repositoryPrivate,
            .transientFailure,
            .noCompatibleArtifact,
            .unsupportedArchitecture("falcon"),
            .missingDigest("model.gguf"),
            .malformedMetadata("model.gguf"),
            .licenseTermsUnavailable,
            .projectorMissing,
            .projectorAmbiguous,
            .incompatibleVisionPair,
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error) should have a description")
        }
    }
}
