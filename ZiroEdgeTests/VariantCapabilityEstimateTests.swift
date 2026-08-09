import XCTest
@testable import ZiroEdge

final class VariantCapabilityEstimateTests: XCTestCase {
    func testCanonicalQuantizationPrecisionMapping() {
        let cases: [(String, Int?)] = [
            ("Q2_K", 2), ("Q3_K_M", 3), ("Q4_0", 4), ("Q5_K_M", 5),
            ("Q6_K", 6), ("Q7_K", 7), ("Q8_0", 8), ("F16", 16),
            ("BF16", 16), ("Unknown", nil),
        ]
        for (quantization, expected) in cases {
            XCTAssertEqual(VariantCapabilityEstimate.precisionBits(for: quantization), expected)
        }
    }

    func testFootprintRankingTiesAndSoleCandidate() {
        let small = artifact("small.gguf", size: 100)
        let middle = artifact("middle.gguf", size: 200)
        let large = artifact("large.gguf", size: 300)
        let candidates = [small, middle, large]
        XCTAssertEqual(estimate(small, candidates).footprint, .smallest(total: 3))
        XCTAssertEqual(estimate(middle, candidates).footprint, .intermediate(total: 3))
        XCTAssertEqual(estimate(large, candidates).footprint, .largest(total: 3))

        let tied = artifact("tied.gguf", size: 100)
        XCTAssertEqual(estimate(small, [small, tied, large]).footprint, .intermediate(total: 3))
        XCTAssertNil(estimate(small, [small]).footprint)
    }

    func testMemoryFitEqualToPhysicalRAMMayExceed() {
        let model = artifact("model.gguf", size: 3)
        let bytes = ImportRAMAssessment.estimatedBytes(artifactBytes: model.size, contextLength: 512)
        let value = VariantCapabilityEstimate(
            artifact: model,
            candidates: [model],
            physicalRAM: bytes,
            contextLength: 512
        )
        XCTAssertEqual(value.memoryFit, .mayExceed)
    }

    func testCaptionIsDeterministicAndMakesNoQualityClaims() {
        let small = artifact("model-Q4_K_M.gguf", size: 100, quantization: "Q4_K_M")
        let large = artifact("model-Q8_0.gguf", size: 300, quantization: "Q8_0")
        let value = VariantCapabilityEstimate(
            artifact: small,
            candidates: [small, large],
            physicalRAM: 1,
            contextLength: 2048
        )
        XCTAssertEqual(
            value.caption,
            "4-bit precision · smallest of 2 variants · may exceed device memory"
        )
        let forbidden = ["quality", "speed", "accuracy", "fidelity", "perplexity"]
        XCTAssertFalse(forbidden.contains { value.caption?.localizedCaseInsensitiveContains($0) == true })
    }

    @MainActor
    func testImportViewModelCapabilityUsesInjectedPhysicalRAM() {
        let model = artifact("model-Q4_K_M.gguf", size: 100)
        let review = HFRepositoryReview(
            repositoryID: "acme/model",
            revision: String(repeating: "a", count: 40),
            licenseName: "MIT",
            licenseURL: URL(string: "https://example.com/license")!,
            artifacts: [model]
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = ImportViewModel(
            inspector: HFRepositoryInspector { _ in throw URLError(.badServerResponse) },
            store: ImportedModelStore(directory: root),
            downloadManager: DownloadManager(availableDiskSpaceProvider: { .max }),
            physicalRAM: { 1 }
        )
        viewModel.review = review
        XCTAssertEqual(viewModel.capabilityEstimate(for: model).memoryFit, .mayExceed)
    }

    private func estimate(_ artifact: HFArtifact, _ candidates: [HFArtifact]) -> VariantCapabilityEstimate {
        VariantCapabilityEstimate(
            artifact: artifact,
            candidates: candidates,
            physicalRAM: nil,
            contextLength: 2048
        )
    }

    private func artifact(
        _ filename: String,
        size: Int64,
        quantization: String = "Q4_K_M"
    ) -> HFArtifact {
        HFArtifact(
            filename: filename,
            size: size,
            sha256: String(repeating: "a", count: 64),
            quantization: quantization,
            architecture: "llama",
            role: .base,
            metadata: HFGGUFMetadata(architecture: "llama", contextLength: 2048)
        )
    }
}
