// ImportedModelConfigurationTests.swift
// ZiroEdgeTests
//
// Tests for safe configuration bounds, GGUF chat template derivation,
// and the locked-parameter guarantee for imported models.

import XCTest
@testable import ZiroEdge

final class ImportedModelConfigurationTests: XCTestCase {

    // MARK: - Configuration bounds

    func testImportedConfigurationClampsContextLengthToSafeRange() {
        let tooLow = ModelConfiguration.imported(promptPath: .chatTemplate, contextLength: 64)
        XCTAssertEqual(tooLow.contextLength, 512)

        let tooHigh = ModelConfiguration.imported(promptPath: .chatTemplate, contextLength: 100_000)
        XCTAssertEqual(tooHigh.contextLength, 4096)

        let normal = ModelConfiguration.imported(promptPath: .chatTemplate, contextLength: 2048)
        XCTAssertEqual(normal.contextLength, 2048)
    }

    func testImportedConfigurationClampsSamplingToSafeBounds() {
        let extreme = ModelConfiguration.imported(
            promptPath: .chatTemplate,
            contextLength: 2048,
            sampling: SamplingConfig(
                temperature: 9, topP: -1, topK: 900,
                maxTokens: 99_999, repeatPenalty: 5
            )
        )
        XCTAssertEqual(extreme.defaultSampling.temperature, 2)
        XCTAssertEqual(extreme.defaultSampling.topP, 0)
        XCTAssertEqual(extreme.defaultSampling.topK, 100)
        XCTAssertEqual(extreme.defaultSampling.maxTokens, 4096)
        XCTAssertEqual(extreme.defaultSampling.repeatPenalty, 2)
    }

    func testImportedConfigurationHasAppOwnedUnsafeParameters() {
        let config = ModelConfiguration.imported(promptPath: .raw, contextLength: 1024)
        // These parameters are locked — they must not be user-adjustable.
        XCTAssertEqual(config.batchSize, 256)
        XCTAssertEqual(config.microBatchSize, 64)
        XCTAssertEqual(config.threadCount, 2)
        XCTAssertEqual(config.gpuLayers, 0)
        XCTAssertTrue(config.useMmap)
        XCTAssertTrue(config.f16KV)
    }

    func testNormalSamplingValuesPassThroughUnchanged() {
        let config = ModelConfiguration.imported(
            promptPath: .chatTemplate,
            contextLength: 2048,
            sampling: SamplingConfig(
                temperature: 0.7, topP: 0.9, topK: 40,
                maxTokens: 1024, repeatPenalty: 1.1
            )
        )
        XCTAssertEqual(config.defaultSampling.temperature, 0.7)
        XCTAssertEqual(config.defaultSampling.topP, 0.9)
        XCTAssertEqual(config.defaultSampling.topK, 40)
        XCTAssertEqual(config.defaultSampling.maxTokens, 1024)
    }

    // MARK: - Chat template derivation

    func testFactoryUsesChatTemplateWhenAvailable() {
        let base = HFArtifact(
            filename: "model-Q4_K_M.gguf", size: 16,
            sha256: String(repeating: "a", count: 64),
            quantization: "Q4_K_M", architecture: "llama",
            role: .base,
            metadata: HFGGUFMetadata(
                architecture: "llama", contextLength: 4096,
                chatTemplate: "{{ bos_token }}{% for message in messages %}{{ message['content'] }}{% endfor %}",
                modelName: "Test"
            )
        )
        let review = makeReview(artifacts: [base])
        let record = ImportedModelFactory.makeRecord(review: review, base: base)
        XCTAssertEqual(record.config.promptPath, .chatTemplate)
    }

    func testFactoryFallsBackToRawWhenChatTemplateIsEmpty() {
        let base = HFArtifact(
            filename: "model-Q4_K_M.gguf", size: 16,
            sha256: String(repeating: "a", count: 64),
            quantization: "Q4_K_M", architecture: "llama",
            role: .base,
            metadata: HFGGUFMetadata(
                architecture: "llama", contextLength: 4096,
                chatTemplate: "",
                modelName: "Test"
            )
        )
        let review = makeReview(artifacts: [base])
        let record = ImportedModelFactory.makeRecord(review: review, base: base)
        XCTAssertEqual(record.config.promptPath, .raw)
    }

    func testFactoryFallsBackToRawWhenChatTemplateIsNil() {
        let base = HFArtifact(
            filename: "model-Q4_K_M.gguf", size: 16,
            sha256: String(repeating: "a", count: 64),
            quantization: "Q4_K_M", architecture: "llama",
            role: .base,
            metadata: HFGGUFMetadata(
                architecture: "llama", contextLength: 4096,
                chatTemplate: nil,
                modelName: "Test"
            )
        )
        let review = makeReview(artifacts: [base])
        let record = ImportedModelFactory.makeRecord(review: review, base: base)
        XCTAssertEqual(record.config.promptPath, .raw)
    }

    func testFactoryDerivesContextLengthFromMetadata() {
        let base = HFArtifact(
            filename: "model-Q4_K_M.gguf", size: 16,
            sha256: String(repeating: "a", count: 64),
            quantization: "Q4_K_M", architecture: "llama",
            role: .base,
            metadata: HFGGUFMetadata(
                architecture: "llama", contextLength: 8192,
                chatTemplate: "fixture",
                modelName: "Test"
            )
        )
        let review = makeReview(artifacts: [base])
        let record = ImportedModelFactory.makeRecord(review: review, base: base)
        // 8192 clamped to max 4096 by ModelConfiguration.imported
        XCTAssertEqual(record.config.contextLength, 4096)
    }

    // MARK: - Experimental labeling

    func testImportedModelsAreLabeledExperimental() {
        let base = makeArtifact("model-Q4_K_M.gguf")
        let review = makeReview(artifacts: [base])
        let record = ImportedModelFactory.makeRecord(review: review, base: base)
        XCTAssertTrue(record.model.isImported)
        XCTAssertEqual(record.model.runtimeEligibility, .experimental)
    }

    func testCatalogModelsAreNotExperimental() {
        XCTAssertEqual(ModelRegistry.llama32_3B.runtimeEligibility, .unavailable)
        XCTAssertEqual(ModelRegistry.gemma4_e2b.runtimeEligibility, .validated)
        XCTAssertFalse(ModelRegistry.llama32_3B.isImported)
    }

    // MARK: - Helpers

    private func makeArtifact(
        _ filename: String,
        digest: String = String(repeating: "a", count: 64),
        architecture: String = "llama",
        size: Int64 = 16
    ) -> HFArtifact {
        HFArtifact(
            filename: filename, size: size, sha256: digest,
            quantization: "Q4_K_M", architecture: architecture,
            role: .base,
            metadata: HFGGUFMetadata(
                architecture: architecture, contextLength: 2048,
                chatTemplate: "fixture", modelName: "Fixture"
            )
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
