import XCTest
@testable import ZiroEdge

/// The six device-validated imports, promoted to curated catalog rows so they
/// are one-tap downloadable. Load stays gated: no MemoryProfile exists for
/// these shapes yet, so eligibility is `.unavailable` (download now, load
/// after calibration) while the import path remains the loadable route.
/// URLs pin HF revisions; bytes/SHAs are the API LFS digests verified
/// on-device 2026-09-23 (LFM-1.2B b1b3de11…, Qwen-0.8B bd258782…, 2B aaf42c8b…).
final class CatalogLineupTests: XCTestCase {
    private var lineup: [AIModel] {
        ["lfm2.5-1.2b-q4", "lfm2.5-2.6b-q4", "qwen3.5-2b-q4", "qwen3.5-0.8b-q4", "bonsai-8b-q1", "bonsai-4b-q1"]
            .compactMap(ModelRegistry.model(for:))
    }

    func testLineupIsPresentInCuratedCatalog() {
        XCTAssertEqual(lineup.count, 6, "all six validated models must be catalog rows")
    }

    func testLineupRowsPassCatalogValidation() {
        XCTAssertEqual(lineup.count, 6)
        for model in lineup {
            XCTAssertNil(model.catalogUnavailableReason, "\(model.id) catalog row must validate")
        }
        XCTAssertNil(ModelCatalogValidator.catalogFailureReason(models: ModelRegistry.allModels))
    }

    func testLineupStorageIdentitiesAreDistinct() {
        let ids = lineup.map(\.baseArtifactStorageID)
        XCTAssertEqual(Set(ids).count, 6, "no shared base artifacts across the lineup")
    }

    func testLineupSizesAndQuantsMatchDeviceEvidence() {
        let expected: [String: (Int64, String)] = [
            "lfm2.5-1.2b-q4": (730_895_168, "Q4_K_M"),
            "lfm2.5-2.6b-q4": (1_674_455_040, "Q4_K_M"),
            "qwen3.5-2b-q4": (1_280_835_840, "Q4_K_M"),
            "qwen3.5-0.8b-q4": (532_517_120, "Q4_K_M"),
            "bonsai-8b-q1": (1_158_654_496, "Q1_0"),
            "bonsai-4b-q1": (572_270_624, "Q1_0"),
        ]
        XCTAssertEqual(lineup.count, 6)
        for model in lineup {
            guard let want = expected[model.id] else {
                XCTFail("no evidence row for \(model.id)")
                continue
            }
            XCTAssertEqual(model.baseFileSizeBytes, want.0, "\(model.id) size")
            XCTAssertEqual(model.quantization, want.1, "\(model.id) quant")
        }
    }

    func testLineupStaysOutOfProductionCatalog() {
        // Unavailable rows must not enter the release download-verification set.
        for model in lineup {
            XCTAssertEqual(model.runtimeEligibility, .unavailable, "\(model.id) loads only after calibration")
            XCTAssertFalse(ModelRegistry.productionModels.contains { $0.id == model.id })
        }
    }
}
