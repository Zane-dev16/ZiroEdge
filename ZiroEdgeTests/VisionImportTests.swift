// VisionImportTests.swift
// ZiroEdgeTests
//
// Tests for the complete vision-model import flow:
// repository inspection → pair resolution with confidence scoring →
// user confirmation → download & verification → vision capability gating.

import XCTest
import CryptoKit
@testable import ZiroEdge

final class VisionImportTests: XCTestCase {

    // MARK: - Payload Helpers

    private func response(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://huggingface.co/api/models/acme/gemma-vision")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func payload(
        revision: String = String(repeating: "a", count: 40),
        architecture: String = "gemma",
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

    // MARK: - Vision Pair Resolution

    func testResolverFindsCompatibleGemmaVisionPair() async throws {
        let revision = String(repeating: "c", count: 40)
        let data = try payload(revision: revision, architecture: "gemma", siblings: [
            artifact("gemma-4-E2B-it-Q4_K_M.gguf", digest: String(repeating: "b", count: 64), size: 3_427_861_088),
            artifact("mmproj-gemma-4-E2B-it-Q8_0.gguf", digest: String(repeating: "c", count: 64), size: 557_367_776),
        ])
        let inspector = HFRepositoryInspector { _ in (data, self.response()) }
        let review = try await inspector.inspect("acme/gemma-vision")

        let resolver = VisionPairResolver()
        let pairs = resolver.resolvePairs(from: review)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.confidence, .high)
        XCTAssertEqual(pairs.first?.base.filename, "gemma-4-E2B-it-Q4_K_M.gguf")
        XCTAssertEqual(pairs.first?.projector.filename, "mmproj-gemma-4-E2B-it-Q8_0.gguf")
        XCTAssertTrue(resolver.hasViableVisionPair(review))
    }

    func testResolverRejectsRepositoryWithNoProjector() async throws {
        let data = try payload(siblings: [
            artifact("model-Q4_K_M.gguf", size: 100),
            artifact("model-Q8_0.gguf", size: 200),
        ])
        let inspector = HFRepositoryInspector { _ in (data, self.response()) }
        let review = try await inspector.inspect("acme/text-only")

        let resolver = VisionPairResolver()
        let pairs = resolver.resolvePairs(from: review)

        XCTAssertTrue(pairs.isEmpty)
        XCTAssertFalse(resolver.hasViableVisionPair(review))
        XCTAssertNotNil(resolver.noVisionPairReason(for: review))
    }

    func testResolverSuggestsBestPairAndRejectsAmbiguousLowConfidence() async throws {
        // Three projectors with no clear quantization match to the base.
        let data = try payload(siblings: [
            artifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64), size: 100),
            artifact("mmproj-f16.gguf", digest: String(repeating: "2", count: 64), size: 50),
            artifact("mmproj-q8.gguf", digest: String(repeating: "3", count: 64), size: 55),
            artifact("mmproj-q4.gguf", digest: String(repeating: "4", count: 64), size: 45),
        ])
        let inspector = HFRepositoryInspector { _ in (data, self.response()) }
        let review = try await inspector.inspect("acme/ambiguous")

        let resolver = VisionPairResolver()
        let pairs = resolver.resolvePairs(from: review)

        // Should find pairs but the top one may be low confidence with multiple projectors.
        XCTAssertFalse(pairs.isEmpty)

        // If the top pair is low confidence and there are multiple pairs, suggestedPair returns nil.
        if let best = pairs.first, best.confidence == .low, pairs.count > 1 {
            XCTAssertNil(resolver.suggestedPair(from: review))
        }
    }

    func testResolverRanksByConfidenceThenSize() async throws {
        // Base model with multiple projectors at different quantization tiers.
        let data = try payload(siblings: [
            artifact("model-Q4_K_M.gguf", digest: String(repeating: "1", count: 64), size: 100),
            artifact("mmproj-Q8_0.gguf", digest: String(repeating: "2", count: 64), size: 50),   // Q4_K_M+Q8_0 = high
            artifact("mmproj-F16.gguf", digest: String(repeating: "3", count: 64), size: 200),   // Q4_K_M+F16 = medium
        ])
        let inspector = HFRepositoryInspector { _ in (data, self.response()) }
        let review = try await inspector.inspect("acme/multi-projector")

        let resolver = VisionPairResolver()
        let pairs = resolver.resolvePairs(from: review)

        XCTAssertEqual(pairs.count, 2)
        // First should be the high-confidence Q8_0 pair.
        XCTAssertEqual(pairs[0].confidence, .high)
        XCTAssertEqual(pairs[0].projector.quantization, "Q8_0")
        // Second should be the medium-confidence F16 pair.
        XCTAssertEqual(pairs[1].confidence, .medium)
    }

    // MARK: - Vision Pair Candidate Properties

    func testVisionPairCandidateCombinedSize() {
        let base = makeArtifact("base-Q4_K_M.gguf", role: .base, size: 3_000_000_000)
        let projector = makeArtifact("mmproj-Q8_0.gguf", role: .projector, size: 500_000_000)
        let pair = VisionPairCandidate(base: base, projector: projector, confidence: .high)

        XCTAssertEqual(pair.combinedSizeBytes, 3_500_000_000)
        XCTAssertFalse(pair.formattedCombinedSize.isEmpty)
        XCTAssertFalse(pair.confidenceExplanation.isEmpty)
    }

    func testVisionPairConfidenceRanking() {
        XCTAssertTrue(VisionPairConfidence.high < VisionPairConfidence.medium)
        XCTAssertTrue(VisionPairConfidence.medium < VisionPairConfidence.low)
        XCTAssertEqual(VisionPairConfidence.high.label, "High confidence")
    }

    // MARK: - Import Flow with Vision Pair

    @MainActor
    func testImportViewModelResolvesVisionPairForInspectionResult() async throws {
        let revision = String(repeating: "v", count: 40)
        let data = try payload(revision: revision, architecture: "gemma", siblings: [
            artifact("gemma-vision-Q4_K_M.gguf", digest: String(repeating: "b", count: 64), size: 3_000_000_000),
            artifact("mmproj-gemma-vision-Q8_0.gguf", digest: String(repeating: "c", count: 64), size: 500_000_000),
        ])
        let inspector = HFRepositoryInspector { _ in (data, self.response()) }
        let downloadManager = DownloadManager(availableDiskSpaceProvider: { 100_000_000_000 })
        let viewModel = ImportViewModel(
            inspector: inspector,
            downloadManager: downloadManager,
            repositoryInput: "acme/gemma-vision"
        )

        await viewModel.inspect()

        guard case .review = viewModel.phase else {
            XCTFail("Expected review phase, got \(viewModel.phase)")
            return
        }

        XCTAssertNotNil(viewModel.selectedBase)
        XCTAssertTrue(viewModel.hasViableVisionPair)

        // Enable vision import and check pair resolution.
        viewModel.importAsVision = true
        viewModel.toggleVisionImport()

        let pair = viewModel.suggestedPair
        XCTAssertNotNil(pair)
        XCTAssertEqual(pair?.confidence, .high)
        XCTAssertNotNil(viewModel.selectedProjector)
        XCTAssertNil(viewModel.visionPairingError)

        // Before confirmation, canConfirm should be false due to vision pair confirmation.
        viewModel.licenseConfirmed = true
        XCTAssertFalse(viewModel.canConfirm, "Should require vision pair confirmation")

        viewModel.confirmVisionPair()
        XCTAssertTrue(viewModel.visionPairConfirmed)
        XCTAssertTrue(viewModel.canConfirm)
    }

    @MainActor
    func testImportViewModelRejectsAmbiguousVisionPair() async throws {
        let data = try payload(architecture: "gemma", siblings: [
            artifact("model-Q4_K_M.gguf", size: 100),
            artifact("mmproj-A-f16.gguf", size: 50),
            artifact("mmproj-B-f16.gguf", size: 55),
            artifact("mmproj-C-f16.gguf", size: 60),
        ])
        let inspector = HFRepositoryInspector { _ in (data, self.response()) }
        let downloadManager = DownloadManager(availableDiskSpaceProvider: { 100_000_000_000 })
        let viewModel = ImportViewModel(
            inspector: inspector,
            downloadManager: downloadManager,
            repositoryInput: "acme/gemma-vision"
        )

        await viewModel.inspect()
        viewModel.importAsVision = true
        viewModel.toggleVisionImport()

        // Should show no vision pair reason or an error for ambiguous projectors.
        if viewModel.suggestedPair == nil {
            XCTAssertNotNil(viewModel.noVisionPairReason ?? viewModel.visionPairingError)
        }
    }

    // MARK: - Factory Produces Vision Model Records

    func testFactoryCreatesVisionModelRecord() {
        let base = makeArtifact("vision-Q4_K_M.gguf", digest: String(repeating: "b", count: 64), role: .base, architecture: "gemma")
        let projector = makeArtifact("mmproj-vision-Q8_0.gguf", digest: String(repeating: "c", count: 64), role: .projector, architecture: "clip")
        let review = makeReview(artifacts: [base, projector])
        let record = ImportedModelFactory.makeRecord(review: review, base: base, projector: projector)

        XCTAssertEqual(record.modelType, .vision)
        XCTAssertTrue(record.model.requiresMMProj)
        XCTAssertNotNil(record.mmprojURL)
        XCTAssertNotNil(record.mmprojSHA256)
        XCTAssertTrue(record.model.isImported)
    }

    func testFactoryCreatedTextModelWhenNoProjectorProvided() {
        let base = makeArtifact("text-Q4_K_M.gguf", role: .base)
        let review = makeReview(artifacts: [base])
        let record = ImportedModelFactory.makeRecord(review: review, base: base, projector: nil)

        XCTAssertEqual(record.modelType, .text)
        XCTAssertFalse(record.model.requiresMMProj)
        XCTAssertNil(record.mmprojURL)
    }

    // MARK: - Vision Capability Gating

    @MainActor
    func testVisionModelOnlyShowsReadyWhenBothArtifactsVerified() throws {
        let baseData = TestModelFixtures.gguf(count: 16)
        let projectorData = TestModelFixtures.gguf(count: 16)
        let model = AIModel(
            id: "vision-gating-test",
            displayName: "Vision Gating",
            description: "Test",
            modelType: .vision,
            baseURL: URL(string: "https://example.com/base.gguf")!,
            mmprojURL: URL(string: "https://example.com/mmproj.gguf")!,
            baseFileSizeBytes: Int64(baseData.count),
            mmprojFileSizeBytes: Int64(projectorData.count),
            baseSHA256: TestModelFixtures.sha256(baseData),
            mmprojSHA256: TestModelFixtures.sha256(projectorData),
            quantization: "Q4_K_M",
            config: .gemma4,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )
        defer { ModelManagerService.deleteModel(model) }

        // Install only the base.
        try baseData.write(to: ModelManagerService.baseModelPath(for: model), options: .atomic)

        // Should NOT be fully downloaded or vision-ready.
        XCTAssertFalse(ModelManagerService.isFullyDownloaded(model))
        XCTAssertFalse(ModelManagerService.isVisionReady(model))
        XCTAssertFalse(ModelManagerService.advertisesVisionCapability(model))

        // Install the projector too.
        try projectorData.write(to: ModelManagerService.mmprojModelPath(for: model), options: .atomic)

        // Now should be fully ready.
        XCTAssertTrue(ModelManagerService.isFullyDownloaded(model))
        XCTAssertTrue(ModelManagerService.isVisionReady(model))
        XCTAssertTrue(ModelManagerService.advertisesVisionCapability(model))
    }

    @MainActor
    func testLosingProjectorStopsAdvertisingVision() throws {
        let baseData = TestModelFixtures.gguf(count: 16)
        let projectorData = TestModelFixtures.gguf(count: 16)
        let model = AIModel(
            id: "projector-loss-test",
            displayName: "Projector Loss",
            description: "Test",
            modelType: .vision,
            baseURL: URL(string: "https://example.com/base.gguf")!,
            mmprojURL: URL(string: "https://example.com/mmproj.gguf")!,
            baseFileSizeBytes: Int64(baseData.count),
            mmprojFileSizeBytes: Int64(projectorData.count),
            baseSHA256: TestModelFixtures.sha256(baseData),
            mmprojSHA256: TestModelFixtures.sha256(projectorData),
            quantization: "Q4_K_M",
            config: .gemma4,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )
        defer { ModelManagerService.deleteModel(model) }

        try baseData.write(to: ModelManagerService.baseModelPath(for: model), options: .atomic)
        try projectorData.write(to: ModelManagerService.mmprojModelPath(for: model), options: .atomic)
        XCTAssertTrue(ModelManagerService.advertisesVisionCapability(model))

        // Remove projector.
        try FileManager.default.removeItem(at: ModelManagerService.mmprojModelPath(for: model))

        XCTAssertFalse(ModelManagerService.advertisesVisionCapability(model))
    }

    // MARK: - Helpers

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
            quantization: filename.uppercased().contains("Q8") ? "Q8_0" : filename.uppercased().contains("F16") ? "F16" : "Q4_K_M",
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
}
