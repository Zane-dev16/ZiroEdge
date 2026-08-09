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

    func testExtremeImportedContextEstimateSaturatesWithoutTrapping() {
        let config = ModelConfiguration(
            promptPath: .raw,
            addBos: nil,
            stopStrings: [],
            defaultSampling: .default,
            contextLength: Int.max,
            batchSize: 256,
            microBatchSize: 64,
            threadCount: 2,
            useMmap: true,
            f16KV: true,
            gpuLayers: 0
        )
        let provenance = HuggingFaceProvenance(
            repositoryID: "acme/extreme",
            revision: String(repeating: "a", count: 40),
            baseFilename: "model.gguf",
            baseSHA256: String(repeating: "b", count: 64),
            architecture: "llama",
            projectorFilename: nil,
            projectorSHA256: nil
        )
        let model = AIModel(
            id: "hf-memory-extreme",
            displayName: "Extreme",
            description: "Fixture",
            modelType: .text,
            baseURL: URL(string: "https://huggingface.co/acme/extreme/resolve/\(provenance.revision)/model.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64.max,
            mmprojFileSizeBytes: nil,
            baseSHA256: provenance.baseSHA256,
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: config,
            license: LicenseInfo(name: "MIT", url: URL(string: "https://example.com")!, copyright: ""),
            source: .huggingFace(provenance)
        )

        XCTAssertEqual(
            MemoryProfileRegistry.importedProfile(for: model).measuredLoadDeltaBytes,
            UInt64.max
        )
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

    func testE4BVariantsAreNotProductionModelsUntilIndividuallyValidated() {
        XCTAssertFalse(ModelRegistry.productionModels.contains { $0.id == ModelRegistry.gemma4_e4b.id })
        XCTAssertFalse(ModelRegistry.productionModels.contains { $0.id == ModelRegistry.gemma4_e4b_text.id })
        XCTAssertFalse(ModelRegistry.productionModels.contains { $0.id == ModelRegistry.gemma4E4BTextCalibration.id })
        XCTAssertTrue(ModelRegistry.calibrationModels.contains { $0.id == ModelRegistry.gemma4E4BTextCalibration.id })
        XCTAssertEqual(
            ModelManagerService.baseModelPath(for: ModelRegistry.gemma4_e4b),
            ModelManagerService.baseModelPath(for: ModelRegistry.gemma4_e4b_text)
        )
        XCTAssertEqual(MemoryProfileRegistry.e4bText.projectorPolicy, .disabled)
        XCTAssertEqual(MemoryProfileRegistry.e4bText.mode, .text)
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
