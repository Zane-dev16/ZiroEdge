import XCTest
@testable import ZiroEdge

final class MemoryProfileTests: XCTestCase {
    func testValidatedProfileUsesMeasuredPeakFormula() throws {
        let profile = MemoryProfile(
            id: "fixture-text",
            modelID: "fixture",
            mode: .text,
            contextLength: 512,
            batchSize: 256,
            microBatchSize: 64,
            projectorPolicy: .disabled,
            evidenceStatus: .validated,
            policyVersion: 1,
            measuredFullWorkloadPeakDeltaBytes: 790_334_488,
            measuredLoadDeltaBytes: nil,
            safetyMultiplier: 1.25,
            fixedReserveBytes: 750_000_000,
            minimumPhysicalRAMBytes: 8_000_000_000
        )

        XCTAssertEqual(try profile.requiredProcessHeadroomBytes(), 1_750_000_000)
    }

    func testUnvalidatedAndUnknownProfilesFailClosed() {
        XCTAssertThrowsError(try MemoryProfileRegistry.e4bTextCalibration.requiredProcessHeadroomBytes())
        XCTAssertNil(MemoryProfileRegistry.profile(for: "does-not-exist"))
    }

    func testValidatedProfileArithmeticOverflowFailsClosed() {
        let profile = MemoryProfile(
            id: "overflow-fixture",
            modelID: "overflow-fixture",
            mode: .text,
            contextLength: 512,
            batchSize: 256,
            microBatchSize: 64,
            projectorPolicy: .disabled,
            evidenceStatus: .validated,
            policyVersion: 1,
            measuredFullWorkloadPeakDeltaBytes: .max,
            measuredLoadDeltaBytes: nil,
            safetyMultiplier: MemoryProfile.productionSafetyMultiplier,
            fixedReserveBytes: MemoryProfile.productionReserveBytes,
            minimumPhysicalRAMBytes: 1
        )

        XCTAssertThrowsError(try profile.requiredProcessHeadroomBytes()) { error in
            XCTAssertEqual(error as? MemoryProfileError, .arithmeticOverflow)
        }
    }

    func testE4BTextCalibrationHasSpecifiedSafeShapeAndNoProjector() {
        let profile = MemoryProfileRegistry.e4bTextCalibration
        XCTAssertEqual(profile.modelID, ModelRegistry.gemma4E4BTextCalibration.id)
        XCTAssertEqual(profile.mode, .text)
        XCTAssertEqual(profile.contextLength, 512)
        XCTAssertEqual(profile.batchSize, 256)
        XCTAssertEqual(profile.microBatchSize, 64)
        XCTAssertEqual(profile.projectorPolicy, .disabled)
        XCTAssertEqual(profile.evidenceStatus, .unvalidated)
        XCTAssertNil(profile.measuredFullWorkloadPeakDeltaBytes)
    }

    func testAcceptedE4BTextProfileUsesExactProductionShapeAndCalculation() throws {
        let profile = MemoryProfileRegistry.e4bText

        XCTAssertEqual(profile.modelID, ModelRegistry.gemma4_e4b_text.id)
        XCTAssertEqual(profile.mode, .text)
        XCTAssertEqual(profile.contextLength, 512)
        XCTAssertEqual(profile.batchSize, 256)
        XCTAssertEqual(profile.microBatchSize, 64)
        XCTAssertEqual(profile.projectorPolicy, .disabled)
        XCTAssertEqual(profile.evidenceStatus, .validated)
        XCTAssertEqual(profile.measuredFullWorkloadPeakDeltaBytes, 306_270_168)
        XCTAssertEqual(profile.minimumPhysicalRAMBytes, 8_054_095_872)
        XCTAssertEqual(try profile.requiredProcessHeadroomBytes(), 1_150_000_000)
    }

    func testE4BVisionUsesMemoryBoundedNativeEvaluationShape() {
        let model = ModelRegistry.gemma4_e4b
        let profile = MemoryProfileRegistry.e4bVision

        XCTAssertEqual(model.config.contextLength, 4096)
        XCTAssertEqual(model.config.batchSize, 256)
        XCTAssertEqual(model.config.microBatchSize, 64)
        XCTAssertEqual(profile.contextLength, model.config.contextLength)
        XCTAssertEqual(profile.batchSize, model.config.batchSize)
        XCTAssertEqual(profile.microBatchSize, model.config.microBatchSize)
        XCTAssertEqual(profile.evidenceStatus, .unvalidated)
    }

    func testE4BTextPromotionDoesNotPromoteVisionOrCalibrationIdentity() {
        XCTAssertTrue(ModelRegistry.productionModels.contains { $0.id == ModelRegistry.gemma4_e4b_text.id })
        XCTAssertFalse(ModelRegistry.productionModels.contains { $0.id == ModelRegistry.gemma4_e4b.id })
        XCTAssertFalse(ModelRegistry.productionModels.contains { $0.id == ModelRegistry.gemma4E4BTextCalibration.id })
        XCTAssertTrue(ModelRegistry.calibrationModels.contains { $0.id == ModelRegistry.gemma4E4BTextCalibration.id })
        XCTAssertEqual(
            ModelManagerService.baseModelPath(for: ModelRegistry.gemma4_e4b),
            ModelManagerService.baseModelPath(for: ModelRegistry.gemma4_e4b_text)
        )
        XCTAssertEqual(MemoryProfileRegistry.e4bVision.evidenceStatus, .unvalidated)
        XCTAssertEqual(MemoryProfileRegistry.e4bVision.projectorPolicy, .required)
    }

    func testArtifactSizeDoesNotChangeMemoryAdmission() async {
        let metrics = FixedMemoryMetricsProvider(processAvailable: 1_800_000_000, total: 8_054_095_872)
        let budgeter = MemoryBudgeter(metrics: metrics)
        let decision = await budgeter.decision(for: ModelRegistry.gemma4E4BTextCalibration)

        XCTAssertEqual(decision.recommendation, .insufficientRAM)
        XCTAssertEqual(decision.profileID, MemoryProfileRegistry.e4bTextCalibration.id)
        XCTAssertNil(decision.requiredBytes)
        XCTAssertNil(decision.artifactBytesUsedForAdmission)
    }
}
