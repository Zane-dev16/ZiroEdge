import XCTest
@testable import ZiroEdge

/// Regression tests for the A→B switch false-OOM:
/// (1) pre-import size estimation now clamps context and weights the vision
/// projector fully, matching MemoryProfile.importedProfile, so qwen2-class
/// estimates order below gemma4-class as their disk sizes do;
/// (2) pre-teardown budget gates credit the reclaimable resident
/// (projected availability) instead of demanding transient A+B coexistence,
/// so a direct switch succeeds exactly when manual-offload-then-load does.
@MainActor
final class MemoryBudgeterProjectedAvailabilityTests: XCTestCase {
    private let totalRAM: UInt64 = 8_054_095_872

    // MARK: - Fixtures

    private func makeImportedModel(
        id: String,
        baseBytes: Int64,
        mmprojBytes: Int64?,
        rawContext: Int,
        vision: Bool
    ) -> AIModel {
        let provenance = HuggingFaceProvenance(
            repositoryID: "acme/switch-fixture",
            revision: String(repeating: "c", count: 40),
            baseFilename: "\(id)-model.gguf",
            baseSHA256: String(repeating: "d", count: 64),
            architecture: vision ? "qwen2vl" : "llama",
            projectorFilename: mmprojBytes == nil ? nil : "\(id)-mmproj.gguf",
            projectorSHA256: mmprojBytes == nil ? nil : String(repeating: "e", count: 64)
        )
        let baseString = "https://huggingface.co/acme/switch-fixture/resolve/\(provenance.revision)/\(id)-model.gguf"
        let mmprojString = "https://huggingface.co/acme/switch-fixture/resolve/\(provenance.revision)/\(id)-mmproj.gguf"
        return AIModel(
            id: id,
            displayName: id,
            description: "Projected-availability fixture",
            modelType: vision ? .vision : .text,
            baseURL: URL(string: baseString)!,
            mmprojURL: vision ? URL(string: mmprojString)! : nil,
            baseFileSizeBytes: baseBytes,
            mmprojFileSizeBytes: mmprojBytes,
            baseSHA256: provenance.baseSHA256,
            mmprojSHA256: provenance.projectorSHA256,
            quantization: "Q4_K_M",
            config: .imported(promptPath: .chatTemplate, contextLength: rawContext),
            license: LicenseInfo(name: "MIT", url: URL(string: "https://example.com")!, copyright: ""),
            source: .huggingFace(provenance)
        )
    }

    private func makeArtifact(
        _ filename: String,
        size: Int64,
        rawContext: Int?,
        role: HFArtifact.Role = .base
    ) -> HFArtifact {
        HFArtifact(
            filename: filename,
            size: size,
            sha256: String(repeating: "a", count: 64),
            quantization: "Q4_K_M",
            architecture: role == .base ? "qwen2" : "clip",
            role: role,
            metadata: HFGGUFMetadata(architecture: "qwen2", contextLength: rawContext)
        )
    }

    private func requiredHeadroom(for model: AIModel) throws -> UInt64 {
        try XCTUnwrap(MemoryProfileRegistry.profile(for: model))
            .experimentalRequiredProcessHeadroomBytes()
    }

    // MARK: - Projected-availability math

    func testNilPriorYieldsZeroCreditAndIdenticalBehavior() {
        XCTAssertEqual(MemoryBudgeter.reclaimableBytes(for: nil), 0)
        XCTAssertEqual(
            MemoryBudgeter.projectedAvailableAfterEviction(currentAvailable: 1_234, reclaimableBytes: 0),
            1_234
        )
    }

    func testProjectedAddSaturatesWithoutTrapping() {
        XCTAssertEqual(
            MemoryBudgeter.projectedAvailableAfterEviction(currentAvailable: .max, reclaimableBytes: 1),
            .max
        )
    }

    func testProjectedDecisionCapsAtTotalRAM() async throws {
        // Tiny text import: raw 1GB fails, but unbounded credit must still cap
        // the projection at total RAM rather than saturating.
        let target = makeImportedModel(
            id: "hf-projected-cap-target", baseBytes: 600_000_000,
            mmprojBytes: nil, rawContext: 2_048, vision: false
        )
        let required = try requiredHeadroom(for: target)
        XCTAssertGreaterThan(required, 1_000_000_000)
        let decision = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: 1_000_000_000, total: totalRAM
        )).decision(for: target, allowUnvalidatedCalibration: true, reclaimableBytes: .max)
        XCTAssertEqual(decision.recommendation, .unloadCurrentFirst)
        XCTAssertEqual(decision.projectedAvailableBytes, totalRAM)
        XCTAssertEqual(decision.reclaimableBytes, .max)
    }

    // MARK: - Switch regression (raw fails, projected passes)

    func testSwitchPreTeardownReturnsUnloadCurrentFirstInsteadOfRefusal() async throws {
        let resident = makeImportedModel(
            id: "hf-projected-resident", baseBytes: 2_000_000_000,
            mmprojBytes: 200_000_000, rawContext: 32_768, vision: true
        )
        let target = makeImportedModel(
            id: "hf-projected-target", baseBytes: 2_000_000_000,
            mmprojBytes: 200_000_000, rawContext: 32_768, vision: true
        )
        let required = try requiredHeadroom(for: target)
        let reclaimable = MemoryBudgeter.reclaimableBytes(for: resident)
        XCTAssertEqual(reclaimable, required, "identical fixtures must agree on credit")
        // Straddle window: raw headroom alone cannot fit B, but evicting A frees it.
        let available = required - reclaimable / 2
        XCTAssertLessThan(available, required)
        XCTAssertGreaterThanOrEqual(available + reclaimable, required)

        let preTeardown = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: available, total: totalRAM
        )).decision(for: target, allowUnvalidatedCalibration: true, reclaimableBytes: reclaimable)
        XCTAssertEqual(preTeardown.recommendation, .unloadCurrentFirst)
        XCTAssertNil(preTeardown.reason)

        // Without credit (the old admit-before-teardown behavior) this refuses.
        let legacy = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: available, total: totalRAM
        )).decision(for: target, allowUnvalidatedCalibration: true)
        XCTAssertEqual(legacy.recommendation, .insufficientRAM)
        XCTAssertEqual(legacy.reason, .insufficientProcessHeadroom)

        // Post-teardown resample with zero credit (freed memory visible) proceeds,
        // matching the manual-offload-then-load path exactly.
        let postTeardown = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: available + reclaimable, total: totalRAM
        )).decision(for: target, allowUnvalidatedCalibration: true)
        XCTAssertEqual(postTeardown.recommendation, .proceed)
        let manualOffload = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: available + reclaimable, total: totalRAM
        )).decision(for: target, allowUnvalidatedCalibration: true)
        XCTAssertEqual(postTeardown.recommendation, manualOffload.recommendation)
    }

    func testTrueOOMStillRefusesPreAndPostTeardown() async throws {
        let resident = makeImportedModel(
            id: "hf-oom-resident", baseBytes: 600_000_000,
            mmprojBytes: nil, rawContext: 2_048, vision: false
        )
        let target = makeImportedModel(
            id: "hf-oom-target", baseBytes: 2_000_000_000,
            mmprojBytes: 200_000_000, rawContext: 32_768, vision: true
        )
        let required = try requiredHeadroom(for: target)
        let reclaimable = MemoryBudgeter.reclaimableBytes(for: resident)
        let available = required - reclaimable - 1
        let pre = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: available, total: totalRAM
        )).decision(for: target, allowUnvalidatedCalibration: true, reclaimableBytes: reclaimable)
        XCTAssertEqual(pre.recommendation, .insufficientRAM)
        XCTAssertEqual(pre.reason, .insufficientProcessHeadroom)
        // Even after teardown the footprint cannot fit.
        let post = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: available + reclaimable, total: totalRAM
        )).decision(for: target, allowUnvalidatedCalibration: true)
        XCTAssertEqual(post.recommendation, .insufficientRAM)
    }

    // MARK: - Non-memory refusals ignore credit

    func testPhysicalFloorRefusesEvenWithCredit() async {
        let target = makeImportedModel(
            id: "hf-floor-target", baseBytes: 600_000_000,
            mmprojBytes: nil, rawContext: 2_048, vision: false
        )
        let decision = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: 16_000_000_000, total: 1_000_000_000
        )).decision(for: target, allowUnvalidatedCalibration: true, reclaimableBytes: .max)
        XCTAssertEqual(decision.recommendation, .insufficientRAM)
        XCTAssertEqual(decision.reason, .physicalRAMBelowMinimum)
    }

    func testMetricsZeroRefusesEvenWithCredit() async {
        let target = makeImportedModel(
            id: "hf-metrics-target", baseBytes: 600_000_000,
            mmprojBytes: nil, rawContext: 2_048, vision: false
        )
        let decision = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: 0, total: totalRAM
        )).decision(for: target, allowUnvalidatedCalibration: true, reclaimableBytes: .max)
        XCTAssertEqual(decision.recommendation, .insufficientRAM)
        XCTAssertEqual(decision.reason, .metricsUnavailable)
    }

    func testMalformedSizesRefuseEvenWithCredit() async {
        let bad = makeImportedModel(
            id: "hf-malformed-target", baseBytes: 600_000_000,
            mmprojBytes: nil, rawContext: 2_048, vision: false
        )
        let broken = AIModel(
            id: bad.id, displayName: bad.displayName, description: bad.description,
            modelType: .vision, baseURL: bad.baseURL,
            mmprojURL: URL(string: "https://example.com/mmproj.gguf")!,
            baseFileSizeBytes: bad.baseFileSizeBytes, mmprojFileSizeBytes: 0,
            baseSHA256: bad.baseSHA256, mmprojSHA256: nil,
            quantization: bad.quantization, config: bad.config,
            license: bad.license, source: bad.source
        )
        let decision = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: 16_000_000_000, total: 32_000_000_000
        )).decision(for: broken, allowUnvalidatedCalibration: true, reclaimableBytes: .max)
        XCTAssertEqual(decision.recommendation, .insufficientRAM)
        XCTAssertEqual(decision.reason, .profileUnvalidated)
    }

    func testUnvalidatedWithoutConsentRefusesEvenWithCredit() async {
        let target = makeImportedModel(
            id: "hf-consent-target", baseBytes: 600_000_000,
            mmprojBytes: nil, rawContext: 2_048, vision: false
        )
        let decision = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
            processAvailable: 16_000_000_000, total: 32_000_000_000
        )).decision(for: target, reclaimableBytes: .max)
        XCTAssertEqual(decision.recommendation, .insufficientRAM)
        XCTAssertEqual(decision.reason, .profileUnvalidated)
    }

    // MARK: - Estimator unity (H1): clamp + full projector weight

    func testRaw32kContextClampsTo4096() {
        let raw32k = ImportRAMAssessment.estimatedBytes(
            baseBytes: 2_000_000_000, mmprojBytes: 200_000_000, contextLength: 32_768
        )
        let clamped = ImportRAMAssessment.estimatedBytes(
            baseBytes: 2_000_000_000, mmprojBytes: 200_000_000, contextLength: 4_096
        )
        XCTAssertEqual(raw32k, clamped)
        // The removed inflation equals (32768-4096)*256000 = 7.34GB.
        XCTAssertEqual((32_768 - 4_096) * 256_000, 7_340_032_000)
    }

    func testDiskOrderingMatchesRAMEstimateOrderingAtClampedCtx() {
        // Probe-class disk sizes: smol 550MB < qwen 2.2GB < gemma-e2b 3.99GB < gemma-e4b 5.9GB.
        let smol = ImportRAMAssessment.estimatedBytes(
            baseBytes: 550_000_000, mmprojBytes: nil, contextLength: 2_048)
        let qwen = ImportRAMAssessment.estimatedBytes(
            baseBytes: 2_000_000_000, mmprojBytes: 200_000_000, contextLength: 32_768)
        let e2b = ImportRAMAssessment.estimatedBytes(
            baseBytes: 3_430_000_000, mmprojBytes: 560_000_000, contextLength: 4_096)
        let e4b = ImportRAMAssessment.estimatedBytes(
            baseBytes: 5_300_000_000, mmprojBytes: 600_000_000, contextLength: 4_096)
        XCTAssertLessThan(smol, qwen)
        XCTAssertLessThan(qwen, e2b)
        XCTAssertLessThan(e2b, e4b)
    }

    func testWizardPickerAndImportedProfileConverge() throws {
        // Picker (base + pair-resolved projector), wizard (base + projector),
        // and the post-import profile must agree to the byte.
        let base = makeArtifact("qwen2-vl-7b-Q4_K_M.gguf", size: 3_000_000_000, rawContext: 32_768)
        let projector = makeArtifact("mmproj.gguf", size: 600_000_000, rawContext: nil, role: .projector)
        let picker = VariantCapabilityEstimate(
            artifact: base, candidates: [base],
            physicalRAM: 8_000_000_000,
            contextLength: base.metadata.contextLength ?? 2_048,
            projector: projector
        )
        let wizardBytes = ImportRAMAssessment.estimatedBytes(
            baseBytes: base.size, mmprojBytes: projector.size,
            contextLength: base.metadata.contextLength ?? 2_048
        )
        let profileBytes = try XCTUnwrap(MemoryProfileRegistry.importedProfile(for: makeImportedModel(
            id: "hf-converge", baseBytes: base.size, mmprojBytes: projector.size,
            rawContext: 32_768, vision: true
        )).measuredLoadDeltaBytes)
        // Wizard estimate includes the fixed production reserve (ImportedModel.swift
        // estimatedBytes adds productionReserveBytes); the profile's measured load
        // delta is the raw resident estimate without reserve (MemoryProfile.swift
        // importedProfile: estimated; reserve only folds into physicalFloor).
        XCTAssertEqual(wizardBytes, profileBytes + MemoryProfile.productionReserveBytes)
        // Picker and wizard share one number, so their classifications agree
        // at the same physical RAM — strictly inside the old 7.34GB inflation
        // gap, where the unclamped math would have said risky.
        let physical: UInt64 = 8_000_000_000
        XCTAssertEqual(picker.memoryFit, .likelyFits)
        XCTAssertEqual(wizardBytes < physical ? .likelyFits : .mayExceed, picker.memoryFit)
        // The retired combined/3 split understated this projector by 2/3*mmproj.
        let retiredCombined = UInt64(clamping: (base.size + projector.size) / 3)
            + UInt64(clamping: ImportRAMAssessment.clampedContextLength(32_768)) * 256_000
            + MemoryProfile.productionReserveBytes
        XCTAssertEqual(wizardBytes - retiredCombined, 400_000_000)
    }

    // MARK: - End-to-end A→B switch

    func testDirectSwitchSucceedsWhenManualOffloadSucceeds() async throws {
        let modelA = makeImportedModel(
            id: "hf-switch-a", baseBytes: 600_000_000,
            mmprojBytes: nil, rawContext: 2_048, vision: false
        )
        let modelB = makeImportedModel(
            id: "hf-switch-b", baseBytes: 2_000_000_000,
            mmprojBytes: 200_000_000, rawContext: 32_768, vision: true
        )
        let requiredA = try requiredHeadroom(for: modelA)
        let requiredB = try requiredHeadroom(for: modelB)
        // Straddle: A fits raw, B fits only after evicting A.
        let available = max(requiredA, requiredB - requiredA) + 250_000_000
        XCTAssertGreaterThanOrEqual(available, requiredA)
        XCTAssertLessThan(available, requiredB)
        XCTAssertGreaterThanOrEqual(available + requiredA, requiredB)

        for model in [modelA, modelB] {
            ExperimentalModelConsent.setGranted(true, for: model)
        }
        defer {
            for model in [modelA, modelB] {
                ExperimentalModelConsent.setGranted(false, for: model)
            }
        }

        let metrics = ReclaimOnUnloadMetrics(base: available, bonus: requiredA, total: totalRAM)
        let inference = ProjectedAvailabilityStub(onUnload: { metrics.releaseBonus() })
        let manager = ModelLifecycleManager(
            inferenceService: inference,
            memoryBudgeter: MemoryBudgeter(metrics: metrics),
            loadSafetyStore: try LoadSafetyStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            ),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )

        let loadA = await manager.loadModel(modelA)
        XCTAssertEqual(loadA, .loaded)
        // Direct switch must succeed via the unloadCurrentFirst path.
        let switchResult = await manager.switchToModel(modelB)
        XCTAssertEqual(switchResult, .loaded)
        XCTAssertEqual(manager.activeModel?.id, modelB.id)
        let unloadCount = await inference.unloadCount
        XCTAssertGreaterThanOrEqual(unloadCount, 1)
        // Same-model reselect short-circuits without re-gating.
        let reloadB = await manager.loadModel(modelB)
        XCTAssertEqual(reloadB, .alreadyLoaded)
    }

    func testOversizedSwitchRefusesWhilePreservingResident() async throws {
        let modelA = makeImportedModel(
            id: "hf-keep-a", baseBytes: 600_000_000,
            mmprojBytes: nil, rawContext: 2_048, vision: false
        )
        let modelC = makeImportedModel(
            id: "hf-keep-c", baseBytes: 14_000_000_000,
            mmprojBytes: nil, rawContext: 2_048, vision: false
        )
        let requiredA = try requiredHeadroom(for: modelA)
        let requiredC = try requiredHeadroom(for: modelC)
        let available = requiredA + 250_000_000
        XCTAssertLessThan(available + requiredA, requiredC)

        for model in [modelA, modelC] {
            ExperimentalModelConsent.setGranted(true, for: model)
        }
        defer {
            for model in [modelA, modelC] {
                ExperimentalModelConsent.setGranted(false, for: model)
            }
        }

        let metrics = ReclaimOnUnloadMetrics(base: available, bonus: requiredA, total: totalRAM)
        let manager = ModelLifecycleManager(
            inferenceService: ProjectedAvailabilityStub(onUnload: { metrics.releaseBonus() }),
            memoryBudgeter: MemoryBudgeter(metrics: metrics),
            loadSafetyStore: try LoadSafetyStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            ),
            availabilityProvider: { _ in .ready },
            recoveryDelay: .zero
        )

        let keepLoadA = await manager.loadModel(modelA)
        XCTAssertEqual(keepLoadA, .loaded)
        let result = await manager.switchToModel(modelC)
        guard case .failed(let failure) = result else {
            return XCTFail("oversized switch must refuse, got \(result)")
        }
        XCTAssertEqual(failure.kind, .insufficientMemory)
        XCTAssertEqual(manager.activeModel?.id, modelA.id)
        XCTAssertEqual(manager.currentState, .loaded)
        XCTAssertTrue(manager.showInsufficientMemoryWarning)
    }

}

// MARK: - Fix verify (a)(b)(c) (extension keeps the test class
// body within the type_body_length gate; same-file extension
// retains private access).
@MainActor
extension MemoryBudgeterProjectedAvailabilityTests {

func testUnvalidatedPriorYieldsZeroCreditWithExplanation() async {
    // Curated llama32-3B is unvalidated with nil measured peaks, so its
    // eviction credits nothing: projected==raw by construction (genuine
    // refuse, not a math bug). The details helper names the cause.
    let prior = ModelRegistry.llama32_3B
    XCTAssertEqual(MemoryBudgeter.reclaimableBytes(for: prior), 0)
    let details = MemoryBudgeter.reclaimableCreditDetails(for: prior)
    XCTAssertEqual(details.bytes, 0)
    XCTAssertEqual(details.evidenceStatus, MemoryEvidenceStatus.unvalidated.rawValue)
    XCTAssertNotNil(details.profileID)
    XCTAssertNil(MemoryBudgeter.reclaimableCreditDetails(for: nil).profileID)
}

func testConsentMissingSurfacesProfileUnvalidatedNotHeadroom() async {
    // Imported targets are always .experimental: without consent the
    // experimentalRequired floor is never compared, so required stays
    // nil and the reason must read profileUnvalidated — never a headroom
    // number that would masquerade as a RAM shortfall.
    let target = makeImportedModel(
        id: "hf-consent-cause", baseBytes: 600_000_000,
        mmprojBytes: nil, rawContext: 2_048, vision: false
    )
    ExperimentalModelConsent.setGranted(false, for: target)
    let decision = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
        processAvailable: 16_000_000_000, total: 32_000_000_000
    )).decision(for: target, reclaimableBytes: .max)
    XCTAssertEqual(decision.recommendation, .insufficientRAM)
    XCTAssertEqual(decision.reason, .profileUnvalidated)
    XCTAssertNil(decision.requiredBytes)
    XCTAssertTrue(decision.alertMessage(modelName: "Fixture").contains("explicit consent"))
    XCTAssertTrue(decision.logSummary.contains("profileUnvalidated"))
}

func testConsentGrantedComparesExperimentalRequiredAgainstProjection() async throws {
    // With consent granted, the same fixture compares its experimental
    // floor against the projection: raw miss + projected hit yields
    // unloadCurrentFirst instead of a refusal.
    let resident = makeImportedModel(
        id: "hf-consent-resident", baseBytes: 2_000_000_000,
        mmprojBytes: 200_000_000, rawContext: 32_768, vision: true
    )
    let target = makeImportedModel(
        id: "hf-consent-target2", baseBytes: 2_000_000_000,
        mmprojBytes: 200_000_000, rawContext: 32_768, vision: true
    )
    ExperimentalModelConsent.setGranted(true, for: target)
    defer { ExperimentalModelConsent.setGranted(false, for: target) }
    let required = try requiredHeadroom(for: target)
    let reclaimable = MemoryBudgeter.reclaimableBytes(for: resident)
    XCTAssertGreaterThan(reclaimable, 0)
    let available = required - reclaimable / 2
    let decision = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
        processAvailable: available, total: totalRAM
    )).decision(for: target, allowUnvalidatedCalibration: true, reclaimableBytes: reclaimable)
    XCTAssertEqual(decision.recommendation, .unloadCurrentFirst)
    XCTAssertNil(decision.reason)
    XCTAssertEqual(decision.requiredBytes, required)
}

func testZeroCreditRefusalCarriesUnloadFirstGuidance() async throws {
    // Zero-credit headroom miss with an unvalidated prior appends the
    // unload-first remedy; the same miss without a prior stays bare.
    // Admission math is unchanged — purely presentational.
    let target = makeImportedModel(
        id: "hf-zero-guidance", baseBytes: 2_000_000_000,
        mmprojBytes: 200_000_000, rawContext: 32_768, vision: true
    )
    ExperimentalModelConsent.setGranted(true, for: target)
    defer { ExperimentalModelConsent.setGranted(false, for: target) }
    let required = try requiredHeadroom(for: target)
    let available = required - 100_000_000
    let prior = ModelRegistry.llama32_3B
    XCTAssertEqual(MemoryBudgeter.reclaimableBytes(for: prior), 0)
    let withPrior = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
        processAvailable: available, total: totalRAM
    )).decision(for: target, allowUnvalidatedCalibration: true, reclaimableBytes: 0)
    XCTAssertEqual(withPrior.reason, .insufficientProcessHeadroom)
    XCTAssertTrue(withPrior.alertMessage(modelName: "Target", priorActive: prior).contains("unloading it first"))
    XCTAssertFalse(withPrior.alertMessage(modelName: "Target").contains("unloading it first"))
}

func testTransientDipSettleRetryRecoversFirstLoad() async throws {
    // Transient jetsam dip: preflight passes on high, the pre-teardown
    // gate dips low (shortfall inside the 1GB window), settles 1s, and
    // the resample recovers on high. Without the settle the dip refuses.
    let target = makeImportedModel(
        id: "hf-dip-target", baseBytes: 2_000_000_000,
        mmprojBytes: 200_000_000, rawContext: 32_768, vision: true
    )
    ExperimentalModelConsent.setGranted(true, for: target)
    defer { ExperimentalModelConsent.setGranted(false, for: target) }
    let required = try requiredHeadroom(for: target)
    let high = required + 200_000_000
    let low = required - 500_000_000
    XCTAssertLessThan(required - low, MemoryBudgeter.transientDipSettleWindowBytes)
    let metrics = DipRecoveryMetrics(values: [high, low, high, high], total: totalRAM)
    let manager = ModelLifecycleManager(
        inferenceService: ProjectedAvailabilityStub(onUnload: {}),
        memoryBudgeter: MemoryBudgeter(metrics: metrics),
        loadSafetyStore: try LoadSafetyStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        ),
        availabilityProvider: { _ in .ready },
        recoveryDelay: .zero
    )
    let result = await manager.loadModel(target)
    XCTAssertEqual(result, .loaded)
    XCTAssertEqual(manager.activeModel?.id, target.id)
    // Preflight(1) + pre-teardown dip(1) + settle retry(1) + pre-mmap(1)
    // + post-load reserve(1).
    XCTAssertEqual(metrics.processAvailableCallCount, 5)
}

func testPreMmapDipSettleRetryRecoversAfterTeardown() async throws {
    // Iterate fix: the pre-mmap sample lands after the teardown recovery
    // sleep while jetsam pressure is still settling. Preflight and
    // pre-teardown pass on high, pre-mmap dips low (shortfall inside the
    // 1GB window), settles 1s, and the resample recovers on high. Without
    // the pre-mmap settle this refuses post-teardown with the resident
    // already displaced — the false-OOM that survives a preflight-only
    // settle. Hermetic — Logger only, no sysctl/os_proc calls.
    let target = makeImportedModel(
        id: "hf-premmap-dip-target", baseBytes: 2_000_000_000,
        mmprojBytes: 200_000_000, rawContext: 32_768, vision: true
    )
    ExperimentalModelConsent.setGranted(true, for: target)
    defer { ExperimentalModelConsent.setGranted(false, for: target) }
    let required = try requiredHeadroom(for: target)
    let high = required + 200_000_000
    let low = required - 500_000_000
    XCTAssertLessThan(required - low, MemoryBudgeter.transientDipSettleWindowBytes)
    // Preflight(1)=high, pre-teardown(1)=high, pre-mmap dip(1)=low,
    // settle retry(1)=high, post-load reserve(1)=high.
    let metrics = DipRecoveryMetrics(values: [high, high, low, high, high], total: totalRAM)
    let manager = ModelLifecycleManager(
        inferenceService: ProjectedAvailabilityStub(onUnload: {}),
        memoryBudgeter: MemoryBudgeter(metrics: metrics),
        loadSafetyStore: try LoadSafetyStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        ),
        availabilityProvider: { _ in .ready },
        recoveryDelay: .zero
    )
    let result = await manager.loadModel(target)
    XCTAssertEqual(result, .loaded)
    XCTAssertEqual(manager.activeModel?.id, target.id)
    XCTAssertEqual(metrics.processAvailableCallCount, 5)
}

func testPreMmapRefusalStaysBareAfterTeardown() async throws {
    // Post-teardown the resident is already evicted, so a genuine headroom
    // miss must stay a bare headroom refusal — never the unload-first
    // remedy (and never a zero-credit fault against the evicted prior).
    // Admission math is unchanged — purely presentational, fail-closed.
    let target = makeImportedModel(
        id: "hf-premmap-bare-target", baseBytes: 2_000_000_000,
        mmprojBytes: 200_000_000, rawContext: 32_768, vision: true
    )
    ExperimentalModelConsent.setGranted(true, for: target)
    defer { ExperimentalModelConsent.setGranted(false, for: target) }
    let required = try requiredHeadroom(for: target)
    let available = required - 100_000_000
    let prior = ModelRegistry.llama32_3B
    let decision = await MemoryBudgeter(metrics: FixedMemoryMetricsProvider(
        processAvailable: available, total: totalRAM
    )).decision(for: target, allowUnvalidatedCalibration: true, reclaimableBytes: 0)
    XCTAssertEqual(decision.reason, .insufficientProcessHeadroom)
    // Pre-teardown with the resident still present: unload-first guidance.
    XCTAssertTrue(decision.alertMessage(modelName: "Target", priorActive: prior).contains("unloading it first"))
    // Post-teardown (nil prior): bare headroom message.
    XCTAssertFalse(decision.alertMessage(modelName: "Target", priorActive: nil).contains("unloading it first"))
}
}

// MARK: - Hermetic helpers (Logger only, no sysctl/os_proc calls)

/// Headroom that grows by `bonus` once the engine unloads — the hermetic
/// stand-in for jetsam reclaiming the resident model's footprint.
private final class ReclaimOnUnloadMetrics: MemoryMetricsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var bonusReleased = false
    let base: UInt64
    let bonus: UInt64
    let total: UInt64

    init(base: UInt64, bonus: UInt64, total: UInt64) {
        self.base = base
        self.bonus = bonus
        self.total = total
    }

    func processAvailableMemory() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let (value, overflow) = base.addingReportingOverflow(bonusReleased ? bonus : 0)
        return overflow ? .max : value
    }

    func totalRAM() -> UInt64 { total }

    func releaseBonus() {
        lock.lock(); defer { lock.unlock() }
        bonusReleased = true
    }
}

/// Scripted headroom sequence for the transient-dip settle test: replays
/// `values` in order (one per processAvailable sample), repeating the last.
/// Hermetic — Logger only, no sysctl/os_proc calls.
private final class DipRecoveryMetrics: MemoryMetricsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let values: [UInt64]
    private(set) var processAvailableCallCount = 0
    let total: UInt64

    init(values: [UInt64], total: UInt64) {
        self.values = values
        self.total = total
    }

    func processAvailableMemory() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let index = min(processAvailableCallCount, values.count - 1)
        processAvailableCallCount += 1
        return values[index]
    }

    func totalRAM() -> UInt64 { total }
}

private actor ProjectedAvailabilityStub: InferenceServiceProtocol {
    private var loaded = false
    private(set) var unloadCount = 0
    private let onUnload: @Sendable () -> Void

    init(onUnload: @escaping @Sendable () -> Void) {
        self.onUnload = onUnload
    }

    var isModelLoaded: Bool { loaded }
    var loadedModelID: String? { loaded ? "fixture" : nil }

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        loaded = true
    }

    func unloadModel() async {
        unloadCount += 1
        loaded = false
        onUnload()
    }

    func streamChat(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        throw InferenceError.modelNotLoaded
    }

    func streamVisionChat(
        messages: [ChatMessagePayload],
        images: [Data],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        throw InferenceError.modelNotLoaded
    }

    func cancelCurrentStream() async {}
    func releaseGenerationGateForEviction() async {}
    func ensureIdleForNewChat() async throws {}
}
