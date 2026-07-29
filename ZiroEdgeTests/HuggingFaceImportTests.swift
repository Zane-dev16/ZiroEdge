import XCTest
@testable import ZiroEdge

final class HuggingFaceImportTests: XCTestCase {
    private func response(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://huggingface.co/api/models/acme/model")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func payload(
        revision: String = String(repeating: "a", count: 40),
        architecture: String = "llama",
        siblings: [[String: Any]]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "sha": revision,
            "cardData": ["license": "apache-2.0"],
            "gguf": ["architecture": architecture, "context_length": 8192, "chat_template": "fixture"],
            "siblings": siblings,
        ])
    }

    private func artifact(_ name: String, digest: String = String(repeating: "a", count: 64), size: Int64 = 16) -> [String: Any] {
        ["rfilename": name, "size": size, "lfs": ["sha256": digest]]
    }

    func testRepositoryIDNormalizationAcceptsIDAndURL() throws {
        XCTAssertEqual(try HFRepositoryInspector.normalizeRepositoryID("owner/repo"), "owner/repo")
        XCTAssertEqual(
            try HFRepositoryInspector.normalizeRepositoryID("https://huggingface.co/owner/repo/"),
            "owner/repo"
        )
    }

    func testMalformedRepositoryIsRejectedBeforeLoaderRuns() async {
        let calls = LockedCounter()
        let inspector = HFRepositoryInspector { _ in
            calls.increment()
            return (Data(), self.response())
        }
        do {
            _ = try await inspector.inspect("https://example.com/not/hugging-face")
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? HFInspectionError, .malformedRepository)
        }
        XCTAssertEqual(calls.value, 0)
    }

    func testInspectionListsEveryCompatibleGGUFAtPinnedRevision() async throws {
        let revision = String(repeating: "b", count: 40)
        let data = try payload(revision: revision, siblings: [
            artifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64), size: 100),
            artifact("model-Q8_0.gguf", digest: String(repeating: "2", count: 64), size: 200),
            artifact("README.md", size: 10),
        ])
        let inspector = HFRepositoryInspector { _ in (data, self.response()) }
        let review = try await inspector.inspect("acme/model")

        XCTAssertEqual(review.revision, revision)
        XCTAssertEqual(review.baseArtifacts.map(\.filename), ["model-Q4_K_M.gguf", "model-Q8_0.gguf"])
        XCTAssertEqual(review.baseArtifacts.map(\.quantization), ["Q4_K_M", "Q8_0"])
        XCTAssertEqual(review.licenseName, "apache-2.0")
    }

    func testUserFacingInspectionSeamClassifiesRepositoryFailures() async {
        for (status, expected) in [(401, HFInspectionError.repositoryPrivate), (404, .repositoryUnavailable), (503, .transientFailure)] {
            let inspector = HFRepositoryInspector { _ in (Data(), self.response(status)) }
            do {
                _ = try await inspector.inspect("acme/model")
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? HFInspectionError, expected)
            }
        }
    }

    func testInspectionRejectsMissingDigestMalformedSizeAndUnsupportedArchitecture() async throws {
        let cases: [(Data, HFInspectionError)] = [
            (try payload(siblings: [["rfilename": "model.gguf", "size": 16]]), .missingDigest("model.gguf")),
            (try payload(siblings: [artifact("model.gguf", size: 0)]), .malformedMetadata("model.gguf")),
            (try payload(architecture: "bert", siblings: [artifact("model.gguf")]), .unsupportedArchitecture("bert")),
        ]
        for (data, expected) in cases {
            let inspector = HFRepositoryInspector { _ in (data, self.response()) }
            do {
                _ = try await inspector.inspect("acme/model")
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? HFInspectionError, expected)
            }
        }
    }

    func testVisionPairingRequiresExactlyOneCompatibleProjector() throws {
        let base = makeArtifact("base-Q4_K_M.gguf", role: .base, architecture: "gemma")
        let projector = makeArtifact("mmproj-Q8_0.gguf", role: .projector, architecture: "clip")
        var review = makeReview(artifacts: [base, projector])
        XCTAssertEqual(try review.suggestedVisionPair(base: base).1, projector)

        review = makeReview(artifacts: [base])
        XCTAssertThrowsError(try review.suggestedVisionPair(base: base)) {
            XCTAssertEqual($0 as? HFInspectionError, .projectorMissing)
        }
        review = makeReview(artifacts: [base, projector, makeArtifact("mmproj-f16.gguf", role: .projector, architecture: "clip")])
        XCTAssertThrowsError(try review.suggestedVisionPair(base: base)) {
            XCTAssertEqual($0 as? HFInspectionError, .projectorAmbiguous)
        }
    }

    func testVisionPairingUsesTheSharedArchitecturePolicy() throws {
        let base = makeArtifact("gemma3-Q4_K_M.gguf", role: .base, architecture: "gemma3")
        let projector = makeArtifact("mmproj-Q8_0.gguf", role: .projector, architecture: "gemma2")
        let review = makeReview(artifacts: [base, projector])

        XCTAssertEqual(try review.suggestedVisionPair(base: base).1, projector)
        XCTAssertEqual(VisionPairResolver().bestPair(for: base, in: review)?.projector, projector)
    }

    func testFactoryPercentEncodesUntrustedRemoteFilenameComponents() {
        let artifact = makeArtifact("nested/model #1?.gguf")
        let record = ImportedModelFactory.makeRecord(review: makeReview(artifacts: [artifact]), base: artifact)

        XCTAssertTrue(record.baseURL.absoluteString.hasSuffix("/nested/model%20%231%3F.gguf"))
    }

    func testFactoryPinsURLsAndCreatesStableDistinctVariantIdentities() {
        let q4 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let q8 = makeArtifact("model-Q8_0.gguf", digest: String(repeating: "2", count: 64))
        let review = makeReview(artifacts: [q4, q8])
        let first = ImportedModelFactory.makeRecord(review: review, base: q4)
        let duplicate = ImportedModelFactory.makeRecord(review: review, base: q4)
        let second = ImportedModelFactory.makeRecord(review: review, base: q8)

        XCTAssertEqual(first.id, duplicate.id)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.baseURL.absoluteString.contains("/resolve/\(review.revision)/"))
        XCTAssertTrue(first.model.isImported)
        XCTAssertEqual(first.model.runtimeEligibility, .experimental)
    }

    func testRegistryDeduplicatesAndPersistsVariantsAcrossRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ImportedModelStore(directory: directory)
        let q4 = makeArtifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64))
        let q8 = makeArtifact("model-Q8_0.gguf", digest: String(repeating: "2", count: 64))
        let review = makeReview(artifacts: [q4, q8])
        let first = ImportedModelFactory.makeRecord(review: review, base: q4)
        let second = ImportedModelFactory.makeRecord(review: review, base: q8)
        _ = try store.upsert(first)
        _ = try store.upsert(first)
        _ = try store.upsert(second)

        XCTAssertEqual(store.allRecords.count, 2)
        XCTAssertEqual(ImportedModelStore(directory: directory).allRecords.map(\.id).sorted(), [first.id, second.id].sorted())
    }

    func testImportedConfigurationBoundsSafeControlsAndLocksUnsafePolicy() {
        let config = ModelConfiguration.imported(
            promptPath: .chatTemplate,
            contextLength: 100_000,
            sampling: SamplingConfig(temperature: 9, topP: -1, topK: 900, maxTokens: 99_999, repeatPenalty: 5)
        )
        XCTAssertEqual(config.contextLength, 4096)
        XCTAssertEqual(config.defaultSampling.temperature, 2)
        XCTAssertEqual(config.defaultSampling.topP, 0)
        XCTAssertEqual(config.defaultSampling.topK, 100)
        XCTAssertEqual(config.defaultSampling.maxTokens, 4096)
        XCTAssertEqual(config.batchSize, 256)
        XCTAssertEqual(config.microBatchSize, 64)
        XCTAssertEqual(config.threadCount, 2)
        XCTAssertEqual(config.gpuLayers, 0)
        XCTAssertTrue(config.useMmap)
        XCTAssertTrue(config.f16KV)
    }

    @MainActor
    func testStoragePreflightIncludesSafetyMarginAndHardBlocksBoundary() {
        let manager = DownloadManager(availableDiskSpaceProvider: { 515_000_000 })
        let model = makeRecord(size: 16_000_000).model
        XCTAssertEqual(manager.storageSafetyMargin(for: model.baseFileSizeBytes), 500_000_000)
        XCTAssertFalse(manager.hasSufficientStorage(for: model))
    }

    @MainActor
    func testRelaunchReconcilesImportedStagingAsPaused() throws {
        let model = makeRecord(size: 16).model
        ModelManagerService.ensureModelsDirectory()
        let task = DownloadTask(model: model, artifact: .base)
        try Data(repeating: 1, count: 8).write(to: task.stagingURL)
        defer { try? FileManager.default.removeItem(at: task.stagingURL) }
        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        if case .paused(let progress) = manager.status(for: model).baseState {
            XCTAssertEqual(progress, 0.5, accuracy: 0.001)
        } else {
            XCTFail("Expected paused recovery state")
        }
    }

    @MainActor
    func testVerifierRequiresGGUFStructureBeforePromotion() throws {
        let model = makeRecord(size: 16, digest: TestModelFixtures.sha256(Data(repeating: 1, count: 16))).model
        let task = DownloadTask(model: model, artifact: .base)
        try Data(repeating: 1, count: 16).write(to: task.stagingURL)
        defer { try? FileManager.default.removeItem(at: task.stagingURL) }
        let manager = DownloadManager(availableDiskSpaceProvider: { .max })
        switch manager.verifyAndPromote(task: task) {
        case .success:
            XCTFail("Malformed GGUF must not be promoted")
        case .failure(let error):
            XCTAssertEqual(error, .structureInvalid(reason: "missing GGUF magic or unsupported version"))
        }
    }

    private func makeArtifact(
        _ filename: String,
        digest: String = String(repeating: "a", count: 64),
        role: HFArtifact.Role = .base,
        architecture: String = "llama",
        size: Int64 = 16
    ) -> HFArtifact {
        HFArtifact(
            filename: filename,
            size: size,
            sha256: digest,
            quantization: filename.uppercased().contains("Q8") ? "Q8_0" : "Q4_K_M",
            architecture: architecture,
            role: role,
            metadata: HFGGUFMetadata(architecture: architecture, contextLength: 2048, chatTemplate: "fixture", modelName: "Fixture")
        )
    }

    private func makeReview(artifacts: [HFArtifact]) -> HFRepositoryReview {
        HFRepositoryReview(
            repositoryID: "acme/model",
            revision: String(repeating: "f", count: 40),
            licenseName: "apache-2.0",
            licenseURL: URL(string: "https://example.com/license")!,
            artifacts: artifacts
        )
    }

    private func makeRecord(size: Int64 = 16, digest: String = String(repeating: "a", count: 64)) -> ImportedModelRecord {
        let artifact = makeArtifact("model-Q4_K_M.gguf", digest: digest, size: size)
        return ImportedModelFactory.makeRecord(review: makeReview(artifacts: [artifact]), base: artifact)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func increment() { lock.lock(); storage += 1; lock.unlock() }
}
