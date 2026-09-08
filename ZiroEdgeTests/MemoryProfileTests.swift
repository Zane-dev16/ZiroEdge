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

    // MARK: - P1-4 imported weights / floor / fail-closed

    /// Vision projector is fully resident while mmap'd base is ~1/3: the
    /// vision-text delta equals the full projector size, not a third.
    func testP1ImportedSeparatesBaseAndProjectorWeights() {
        let baseBytes: Int64 = 3_000_000_000
        let mmprojBytes: Int64 = 600_000_000
        let context = 2048
        let contextScale = UInt64(context) * 256_000
        let text = MemoryProfileRegistry.importedProfile(for: Self.makeImported(
            baseBytes: baseBytes, mmprojBytes: nil, contextLength: context, modelType: .text))
        let vision = MemoryProfileRegistry.importedProfile(for: Self.makeImported(
            baseBytes: baseBytes, mmprojBytes: mmprojBytes, contextLength: context, modelType: .vision))
        XCTAssertEqual(text.measuredLoadDeltaBytes, UInt64(baseBytes / 3) + contextScale)
        XCTAssertEqual(vision.measuredLoadDeltaBytes, UInt64(baseBytes / 3) + UInt64(mmprojBytes) + contextScale)
        XCTAssertEqual(
            vision.measuredLoadDeltaBytes! - text.measuredLoadDeltaBytes!,
            UInt64(mmprojBytes),
            "projector weight must be full size, not a third"
        )
    }

    /// Tiny imports still demand a real device: absolute 4GB floor.
    func testP1ImportedPhysicalFloorEnforced() {
        let profile = MemoryProfileRegistry.importedProfile(for: Self.makeImported(
            baseBytes: 100_000_000, mmprojBytes: nil, contextLength: 512, modelType: .text))
        XCTAssertEqual(profile.minimumPhysicalRAMBytes, 4_000_000_000)
    }

    /// Non-positive catalog sizes fail closed: nil evidence plus .max floor
    /// so admission can never proceed.
    func testP1ImportedNegativeSizeFailsClosed() {
        let badBase = MemoryProfileRegistry.importedProfile(for: Self.makeImported(
            baseBytes: -5, mmprojBytes: nil, contextLength: 2048, modelType: .text))
        XCTAssertNil(badBase.measuredLoadDeltaBytes)
        XCTAssertEqual(badBase.minimumPhysicalRAMBytes, .max)
        XCTAssertThrowsError(try badBase.experimentalRequiredProcessHeadroomBytes())

        let badProjector = MemoryProfileRegistry.importedProfile(for: Self.makeImported(
            baseBytes: 3_000_000_000, mmprojBytes: 0, contextLength: 2048, modelType: .vision))
        XCTAssertNil(badProjector.measuredLoadDeltaBytes)
        XCTAssertEqual(badProjector.minimumPhysicalRAMBytes, .max)
    }

    private static func makeImported(
        baseBytes: Int64,
        mmprojBytes: Int64?,
        contextLength: Int,
        modelType: ModelType
    ) -> AIModel {
        let provenance = HuggingFaceProvenance(
            repositoryID: "acme/p1-fixture",
            revision: String(repeating: "c", count: 40),
            baseFilename: "model.gguf",
            baseSHA256: String(repeating: "d", count: 64),
            architecture: "llama",
            projectorFilename: mmprojBytes == nil ? nil : "mmproj.gguf",
            projectorSHA256: mmprojBytes == nil ? nil : String(repeating: "e", count: 64)
        )
        let isVision = modelType == .vision
        let baseString = "https://huggingface.co/acme/p1-fixture/resolve/\(provenance.revision)/model.gguf"
        let mmprojString = "https://huggingface.co/acme/p1-fixture/resolve/\(provenance.revision)/mmproj.gguf"
        return AIModel(
            id: "hf-p1-\(baseBytes)-\(mmprojBytes ?? 0)",
            displayName: "P1",
            description: "Fixture",
            modelType: modelType,
            baseURL: URL(string: baseString)!,
            mmprojURL: isVision ? URL(string: mmprojString)! : nil,
            baseFileSizeBytes: baseBytes,
            mmprojFileSizeBytes: mmprojBytes,
            baseSHA256: provenance.baseSHA256,
            mmprojSHA256: provenance.projectorSHA256,
            quantization: "Q4_K_M",
            config: .imported(promptPath: .raw, contextLength: contextLength),
            license: LicenseInfo(name: "MIT", url: URL(string: "https://example.com")!, copyright: ""),
            source: .huggingFace(provenance)
        )
    }
}
