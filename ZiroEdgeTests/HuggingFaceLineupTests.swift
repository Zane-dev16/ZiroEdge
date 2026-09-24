import XCTest
@testable import ZiroEdge

/// Metal-aware lineup slice tests (LFM2.5 / Qwen3.5 / Bonsai Q1_0).
/// Split from HuggingFaceImportTests to respect the 350-line class cap.
/// SHAs below are HF API LFS digests re-verified 2026-09-23 (device inspection
/// confirmed b1b3de11… on-hardware; the etag-sourced Qwen SHAs were corrected
/// to bd258782… / aaf42c8b… after a live mismatch).
final class HuggingFaceLineupTests: XCTestCase {
    private func response(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://huggingface.co/api/models/acme/model")!,
            statusCode: status, httpVersion: nil, headerFields: nil)!
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

    private func artifact(
        _ name: String,
        digest: String = String(repeating: "a", count: 64),
        size: Int64 = 16
    ) -> [String: Any] {
        ["rfilename": name, "size": size, "lfs": ["sha256": digest]]
    }

    func testLFM25InspectorEndToEndMakesExperimentalDigestRecords() async throws {
        // LFM2.5 import slice: the inspector seam must accept both LiquidAI
        // GGUF repos (live discovery 2026-09-22: x-linked-etag = SHA-256,
        // HEAD 200) and the factory records must carry digest storage with
        // consent-gated experimental eligibility and distinct stable IDs.
        struct Fixture { let repo: String; let file: String; let bytes: Int64; let sha: String }
        let cases: [Fixture] = [
            Fixture(
                repo: "LiquidAI/LFM2.5-1.2B-Instruct-GGUF", file: "LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
                bytes: 730_895_168, sha: "b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5"),
            Fixture(
                repo: "LiquidAI/LFM2.5-2.6B-GGUF", file: "LFM2.5-2.6B-Q4_K_M.gguf",
                bytes: 1_674_455_040, sha: "02a8b7e17487d326e46d68ce0ba24211e1b80a14c4cd0597fa73c1cd697f52ed"),
        ]
        var ids = Set<String>()
        for entry in cases {
            let data = try payload(
                architecture: "lfm2",
                siblings: [artifact(entry.file, digest: entry.sha, size: entry.bytes)]
            )
            let review = try await HFRepositoryInspector { _ in (data, self.response()) }.inspect(entry.repo)
            XCTAssertEqual(review.repositoryID, entry.repo)
            let base = try XCTUnwrap(review.baseArtifacts.first)
            XCTAssertEqual(base.architecture, "lfm2")
            XCTAssertEqual(base.quantization, "Q4_K_M")
            let record = ImportedModelFactory.makeRecord(review: review, base: base)
            XCTAssertTrue(record.model.isImported, "\(entry.repo) should be imported")
            XCTAssertEqual(record.model.runtimeEligibility, .experimental, "\(entry.repo) needs consent-gated experimental")
            XCTAssertEqual(record.model.baseArtifactStorageID, "hf-\(entry.sha.prefix(24))")
            XCTAssertNil(record.model.catalogUnavailableReason, "\(entry.repo) catalog row should validate")
            XCTAssertTrue(record.id.hasPrefix("hf-"))
            XCTAssertTrue(ids.insert(record.id).inserted, "stable IDs must be distinct per provenance")
        }
        XCTAssertEqual(ids.count, 2)
    }

    func testBonsaiImportSliceEndToEndLabelsQ10AndMakesExperimentalRecords() async throws {
        // Bonsai import slice (prism-ml, qwen3, Q1_0 1-bit): stock b9821
        // supports Q1_0 (upstream #21273, verified via nm on the pinned
        // ios-arm64 binary) — no fork, no exclusion. Only ternary
        // TQ1_0/TQ2_0 needs the fork and is not in this lineup.
        struct Fixture { let repo: String; let file: String; let bytes: Int64; let sha: String }
        let cases: [Fixture] = [
            Fixture(
                repo: "prism-ml/Bonsai-8B-gguf", file: "Bonsai-8B-Q1_0.gguf",
                bytes: 1_158_654_496, sha: "284a335aa3fb2ced3b1b01fcb40b08aa783e3b70832767f0dd2e3fdfa134bd54"),
            Fixture(
                repo: "prism-ml/Bonsai-4B-gguf", file: "Bonsai-4B-Q1_0.gguf",
                bytes: 572_270_624, sha: "4524b3f997f0f06444e568d1f26e2efd69effa3218c7ad3047432fb171e42168"),
        ]
        var ids = Set<String>()
        for entry in cases {
            let data = try payload(
                architecture: "qwen3",
                siblings: [artifact(entry.file, digest: entry.sha, size: entry.bytes)]
            )
            let review = try await HFRepositoryInspector { _ in (data, self.response()) }.inspect(entry.repo)
            let base = try XCTUnwrap(review.baseArtifacts.first)
            XCTAssertEqual(base.architecture, "qwen3")
            XCTAssertEqual(base.quantization, "Q1_0", "\(entry.file) must label Q1_0, not Unknown")
            let record = ImportedModelFactory.makeRecord(review: review, base: base)
            XCTAssertTrue(record.model.isImported)
            XCTAssertEqual(record.model.runtimeEligibility, .experimental)
            XCTAssertEqual(record.model.baseArtifactStorageID, "hf-\(entry.sha.prefix(24))")
            XCTAssertNil(record.model.catalogUnavailableReason)
            XCTAssertTrue(ids.insert(record.id).inserted, "stable IDs must be distinct per provenance")
        }
        XCTAssertEqual(ids.count, 2)
    }

    func testLFM25AndQwen35FactoryRecordsAreExperimentalWithDigestStorage() {
        // Live discovery 2026-09-22 (x-linked-etag = SHA-256, HEAD 200).
        // Bonsai Q1_0 1-bit runs on stock b9821 (upstream #21273; binary exports
        // Q1_0 kernels — verified via nm on the pinned xcframework). Ternary only
        // needs the fork, and is not in this lineup.
        struct Fixture { let repo: String; let file: String; let bytes: Int64; let sha: String; let arch: String; let quant: String }
        let cases: [Fixture] = [
            Fixture(
                repo: "LiquidAI/LFM2.5-1.2B-Instruct-GGUF", file: "LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
                bytes: 730_895_168, sha: "b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5",
                arch: "lfm2", quant: "Q4_K_M"),
            Fixture(
                repo: "LiquidAI/LFM2.5-2.6B-GGUF", file: "LFM2.5-2.6B-Q4_K_M.gguf",
                bytes: 1_674_455_040, sha: "02a8b7e17487d326e46d68ce0ba24211e1b80a14c4cd0597fa73c1cd697f52ed",
                arch: "lfm2", quant: "Q4_K_M"),
            Fixture(
                repo: "unsloth/Qwen3.5-2B-GGUF", file: "Qwen3.5-2B-Q4_K_M.gguf",
                bytes: 1_280_835_840, sha: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
                arch: "qwen35", quant: "Q4_K_M"),
            Fixture(
                repo: "unsloth/Qwen3.5-0.8B-GGUF", file: "Qwen3.5-0.8B-Q4_K_M.gguf",
                bytes: 532_517_120, sha: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
                arch: "qwen35", quant: "Q4_K_M"),
            Fixture(
                repo: "prism-ml/Bonsai-8B-gguf", file: "Bonsai-8B-Q1_0.gguf",
                bytes: 1_158_654_496, sha: "284a335aa3fb2ced3b1b01fcb40b08aa783e3b70832767f0dd2e3fdfa134bd54",
                arch: "qwen3", quant: "Q1_0"),
            Fixture(
                repo: "prism-ml/Bonsai-4B-gguf", file: "Bonsai-4B-Q1_0.gguf",
                bytes: 572_270_624, sha: "4524b3f997f0f06444e568d1f26e2efd69effa3218c7ad3047432fb171e42168",
                arch: "qwen3", quant: "Q1_0"),
        ]
        var ids = Set<String>()
        for entry in cases {
            let meta = HFGGUFMetadata(architecture: entry.arch, contextLength: 2048, chatTemplate: "fixture", modelName: entry.repo)
            let artifact = HFArtifact(filename: entry.file, size: entry.bytes, sha256: entry.sha, quantization: entry.quant, architecture: entry.arch, role: .base, metadata: meta)
            let licenseURL = URL(string: "https://example.com/license")!
            let review = HFRepositoryReview(repositoryID: entry.repo, revision: String(repeating: "a", count: 40), licenseName: "apache-2.0", licenseURL: licenseURL, artifacts: [artifact])
            let record = ImportedModelFactory.makeRecord(review: review, base: artifact)
            XCTAssertTrue(record.model.isImported, "\(entry.repo) should be imported")
            XCTAssertEqual(record.model.runtimeEligibility, .experimental, "\(entry.repo) needs consent-gated experimental")
            XCTAssertEqual(record.model.baseArtifactStorageID, "hf-\(entry.sha.prefix(24))")
            XCTAssertNil(record.model.catalogUnavailableReason, "\(entry.repo) catalog row should validate")
            XCTAssertTrue(ids.insert(record.id).inserted, "stable IDs must be distinct per provenance")
            XCTAssertTrue(record.model.baseFileSizeBytes > 0)
        }
    }
}
