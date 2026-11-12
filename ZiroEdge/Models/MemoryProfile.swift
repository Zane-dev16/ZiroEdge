import Foundation
import os

// Runtime memory policy, in three readable layers:
//
//   MemoryProfile        one exact runtime shape (model x context x CPU/Metal)
//                        and the evidence or estimate that sizes it.
//   MemoryProfileRegistry every shape the app knows, and which one to serve.
//   MemoryBudgeter       the admission verdict for one load attempt.
//
// A shape is admitted when it has a number to compare against device headroom.
// That number comes from measurement when measurement exists (`.validated`,
// `.experimental`) and from `ImportRAMAssessment` when it does not
// (`.estimated`). "No number at all" is not a state a shipped model may reach —
// `ModelCatalogValidator` proves it, because a catalog row the runtime refuses to
// load is a product defect that reads to the user as a broken app.

enum MemoryProfileMode: String, Codable, Sendable {
    case text
    case vision
}

enum ProjectorPolicy: String, Codable, Sendable {
    case disabled
    case required
}

enum MemoryEvidenceStatus: String, Codable, Sendable {
    case unvalidated
    case loadOnly
    case validated
}

enum RuntimeEligibility: String, Sendable {
    /// Measured full physical workload on a retained device. Strict policy.
    case validated
    /// Measured load delta only: conservative floor plus explicit consent.
    case experimental
    /// No device measurement. Admitted on ZiroEdge's own conservative estimate
    /// of what the shape costs (`MemoryProfile.estimatedLoadDeltaBytes`), which
    /// over-states on every term so it can only ever refuse a load that would
    /// have fit, never admit one that would not.
    case estimated
    /// No estimate and no measurement. Unreachable for a curated catalog row:
    /// `ModelCatalogValidator` refuses a catalog whose models resolve here.
    case unavailable

    /// Strength of the evidence behind a runtime shape. When one model has
    /// several shapes, the strongest wins before the faster one, so a measured
    /// CPU shape keeps serving instead of being replaced by an estimated Metal
    /// shape — the promise `docs/memory-profiles.md` already makes.
    var evidenceRank: Int {
        switch self {
        case .validated: 3
        case .experimental: 2
        case .estimated: 1
        case .unavailable: 0
        }
    }

    /// Whether selecting this shape must interrupt the user with a consent
    /// sheet. An estimate is ZiroEdge's own arithmetic, not a user-visible
    /// experiment, so it never asks.
    var needsExplicitConsent: Bool {
        switch self {
        case .validated, .estimated: false
        case .experimental, .unavailable: true
        }
    }

    /// Short, plain status for a model row. "Ready" means the app will try;
    /// whether it fits is decided by the memory check at load time, not here.
    var label: String {
        switch self {
        case .validated, .estimated: "Ready"
        case .experimental: "Experimental"
        case .unavailable: "Not available"
        }
    }
}

enum MemoryProfileError: Error, Equatable {
    case unvalidatedProfile
    case incompleteEvidence
    case invalidPolicy
    case arithmeticOverflow
}

/// Runtime-memory policy. Artifact byte counts intentionally do not appear here.
/// `measuredFullWorkloadPeakDeltaBytes`, when present, is the maximum across all
/// accepted runs and devices for this exact runtime shape.
struct MemoryProfile: Codable, Hashable, Sendable {
    let id: String
    let modelID: String
    let mode: MemoryProfileMode
    let contextLength: Int
    let batchSize: Int
    let microBatchSize: Int
    /// GPU offload shape. 0 = CPU-only; >0 = Metal offload (matches
    /// `ModelConfiguration.fullMetalOffloadLayers` on 8GB+ devices).
    /// A GPU run is a different runtime shape with independent evidence.
    let gpuLayers: Int
    let projectorPolicy: ProjectorPolicy
    let evidenceStatus: MemoryEvidenceStatus
    let policyVersion: Int
    let measuredFullWorkloadPeakDeltaBytes: UInt64?
    let measuredLoadDeltaBytes: UInt64?
    let safetyMultiplier: Double
    let fixedReserveBytes: UInt64
    let minimumPhysicalRAMBytes: UInt64

    static let productionSafetyMultiplier = 1.25
    static let productionReserveBytes: UInt64 = 750_000_000
    static let roundingQuantumBytes: UInt64 = 100_000_000

    var isProductionValidated: Bool {
        evidenceStatus == .validated && measuredFullWorkloadPeakDeltaBytes != nil
    }

    /// Conservative static estimate of this exact shape's resident load cost,
    /// present only while no device measurement exists for the shape.
    ///
    /// Computed from the catalog row rather than stored per profile so the
    /// figures cannot drift from the artifact identity and a curated model
    /// cannot ship without one: a shape in the catalog always has an estimate,
    /// which is why `.unavailable` is structurally unreachable for shipped
    /// models. Delegates to `ImportRAMAssessment.residentBytes` — the same
    /// arithmetic the import wizard shows a user before they download — because
    /// two estimators that disagree is exactly how a model gets imported as
    /// "likely fits" and then refused at load time.
    ///
    /// Deliberately over-states, and the direction matters: an estimate that is
    /// too high refuses a load that would have fit (annoying, recoverable); an
    /// estimate that is too low admits one that does not (jetsam). Device
    /// evidence backs the weights term — the retained E2B full-workload peak is
    /// 798,559,232 bytes for a 3,985MB pair, below even `base/3` alone.
    var estimatedLoadDeltaBytes: UInt64? {
        guard measuredFullWorkloadPeakDeltaBytes == nil,
              measuredLoadDeltaBytes == nil,
              // Catalog rows only. The DEBUG calibration identity reuses a
              // catalog artifact but exists precisely to gather the first
              // measurement before an estimate would be needed, so sizing it
              // from its artifact bytes would defeat its purpose.
              let model = ModelRegistry.catalogModel(forID: modelID) else { return nil }
        return ImportRAMAssessment.residentBytes(
            baseBytes: model.baseFileSizeBytes,
            mmprojBytes: model.requiresMMProj ? model.mmprojFileSizeBytes : nil,
            contextLength: contextLength
        )
    }

    var runtimeEligibility: RuntimeEligibility {
        if isProductionValidated { return .validated }
        if measuredLoadDeltaBytes != nil { return .experimental }
        if estimatedLoadDeltaBytes != nil { return .estimated }
        return .unavailable
    }

    func requiredProcessHeadroomBytes() throws -> UInt64 {
        guard isProductionValidated,
              let peak = measuredFullWorkloadPeakDeltaBytes else {
            throw MemoryProfileError.unvalidatedProfile
        }
        return try requiredHeadroom(forMeasuredPeak: peak)
    }

    /// Conservative admission floor for explicit experimental consent. This uses
    /// measured runtime load evidence for the exact profile, never artifact bytes.
    func experimentalRequiredProcessHeadroomBytes() throws -> UInt64 {
        guard evidenceStatus != .validated, let peak = measuredLoadDeltaBytes else {
            throw MemoryProfileError.incompleteEvidence
        }
        return try requiredHeadroom(forMeasuredPeak: peak)
    }

    /// Admission floor for a shape with no device measurement: the same policy
    /// arithmetic as a measured profile, applied to the static estimate. Keeping
    /// one code path means the multiplier, rounding quantum, and fixed reserve
    /// cannot diverge between a measured and an estimated shape.
    func estimatedRequiredProcessHeadroomBytes() throws -> UInt64 {
        // An estimate may never stand in for retained evidence.
        guard !isProductionValidated,
              measuredLoadDeltaBytes == nil,
              let estimate = estimatedLoadDeltaBytes else {
            throw MemoryProfileError.incompleteEvidence
        }
        return try requiredHeadroom(forMeasuredPeak: estimate)
    }

    private func requiredHeadroom(forMeasuredPeak peak: UInt64) throws -> UInt64 {
        guard policyVersion > 0,
              safetyMultiplier == Self.productionSafetyMultiplier,
              fixedReserveBytes == Self.productionReserveBytes,
              contextLength > 0,
              batchSize > 0,
              microBatchSize > 0,
              microBatchSize <= batchSize else {
            throw MemoryProfileError.invalidPolicy
        }
        // The policy multiplier is exactly 5/4. Keep the calculation in integer
        // space so large evidence values cannot lose precision or overflow.
        let quotient = peak / 4
        let remainder = peak % 4
        let (scaledWhole, scaledWholeOverflow) = quotient.multipliedReportingOverflow(by: 5)
        let scaledRemainder = (remainder * 5 + 3) / 4
        let (scaled, scaledOverflow) = scaledWhole.addingReportingOverflow(scaledRemainder)
        guard !scaledWholeOverflow, !scaledOverflow else {
            throw MemoryProfileError.arithmeticOverflow
        }

        let quantum = Self.roundingQuantumBytes
        let roundedDown = (scaled / quantum) * quantum
        let (rounded, roundingOverflow) = scaled.isMultiple(of: quantum)
            ? (scaled, false)
            : roundedDown.addingReportingOverflow(quantum)
        guard !roundingOverflow else {
            throw MemoryProfileError.arithmeticOverflow
        }

        let (required, reserveOverflow) = rounded.addingReportingOverflow(fixedReserveBytes)
        guard !reserveOverflow else {
            throw MemoryProfileError.arithmeticOverflow
        }
        return required
    }
}

enum MemoryProfileRegistry {
    static let llama32Text = MemoryProfile(
        id: "llama32-3b-text-p1", modelID: ModelRegistry.llama32_3B.id,
        mode: .text, contextLength: 4096, batchSize: 512, microBatchSize: 128,
        gpuLayers: 0,
        projectorPolicy: .disabled, evidenceStatus: .unvalidated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: nil, measuredLoadDeltaBytes: nil,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_000_000_000
    )

    static let e2bVision = MemoryProfile(
        id: "gemma4-e2b-vision-p1", modelID: ModelRegistry.gemma4_e2b.id,
        mode: .vision, contextLength: 4096, batchSize: 512, microBatchSize: 128,
        gpuLayers: 0,
        projectorPolicy: .required, evidenceStatus: .validated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: 798_559_232, measuredLoadDeltaBytes: 790_334_488,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_054_095_872
    )

    static let e4bText = MemoryProfile(
        id: "gemma4-e4b-text-p1", modelID: ModelRegistry.gemma4_e4b_text.id,
        mode: .text, contextLength: 512, batchSize: 256, microBatchSize: 64,
        gpuLayers: 0,
        projectorPolicy: .disabled, evidenceStatus: .unvalidated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: nil, measuredLoadDeltaBytes: nil,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_054_095_872
    )

    static let e4bVision = MemoryProfile(
        id: "gemma4-e4b-vision-p1", modelID: ModelRegistry.gemma4_e4b.id,
        mode: .vision, contextLength: 4096, batchSize: 512, microBatchSize: 128,
        gpuLayers: 0,
        projectorPolicy: .required, evidenceStatus: .unvalidated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: nil, measuredLoadDeltaBytes: nil,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_054_095_872
    )

    /// Metal offload mirrors of the CPU shapes above. Unvalidated with no
    /// evidence: each GPU shape must complete physical calibration per
    /// memory-profiles.md before it admits loads (fail-closed until then).
    static let llama32TextMetal = MemoryProfile(
        id: "llama32-3b-text-metal-p1", modelID: ModelRegistry.llama32_3B.id,
        mode: .text, contextLength: 4096, batchSize: 512, microBatchSize: 128,
        gpuLayers: ModelConfiguration.fullMetalOffloadLayers,
        projectorPolicy: .disabled, evidenceStatus: .unvalidated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: nil, measuredLoadDeltaBytes: nil,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_000_000_000
    )

    static let e2bVisionMetal = MemoryProfile(
        id: "gemma4-e2b-vision-metal-p1", modelID: ModelRegistry.gemma4_e2b.id,
        mode: .vision, contextLength: 4096, batchSize: 512, microBatchSize: 128,
        gpuLayers: ModelConfiguration.fullMetalOffloadLayers,
        projectorPolicy: .required, evidenceStatus: .unvalidated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: nil, measuredLoadDeltaBytes: nil,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_054_095_872
    )

    // The E4B rows (vision and text) deliberately have no Metal shape. Their
    // base is 4.97 GB and full offload dies at the first decode with a GPU
    // out-of-memory on an 8 GB iPhone — memory admission cannot see it, because
    // the weights are not in the process footprint. Both runtime presets pin
    // `gpuLayers: 0`; registering a Metal shape here would advertise an offload
    // the runtime no longer performs. Restore one only alongside a measured
    // size-aware tier (docs/memory-profiles.md).

#if DEBUG
    static let hermeticLlamaText = MemoryProfile(
        id: "uitest-llama-text-p1", modelID: ModelRegistry.llama32_3B.id,
        mode: .text, contextLength: 4096, batchSize: 512, microBatchSize: 128,
        gpuLayers: 0,
        projectorPolicy: .disabled, evidenceStatus: .validated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: 1, measuredLoadDeltaBytes: 1,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 1
    )

    static let e4bTextCalibration = MemoryProfile(
        id: "gemma4-e4b-text-calibration-p1", modelID: ModelRegistry.gemma4E4BTextCalibration.id,
        mode: .text, contextLength: 512, batchSize: 256, microBatchSize: 64,
        gpuLayers: 0,
        projectorPolicy: .disabled, evidenceStatus: .unvalidated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: nil, measuredLoadDeltaBytes: nil,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_054_095_872
    )
#endif

    /// Shapes generated from the curated catalog rather than hand-written.
    ///
    /// The lineup rows (LFM 2.5, Qwen 3.5, Bonsai) carry no device measurement,
    /// so they were previously absent from this registry — which made
    /// `MemoryProfileRegistry.profile(for:)` return nil for six of the ten
    /// shipped models and refused every load with "no runtime profile exists".
    /// Building them from the catalog row means adding a model to
    /// `ModelRegistry.lineupText` can no longer leave the runtime blind: each
    /// row gets a CPU and a Metal shape automatically.
    static var lineupTextProfiles: [MemoryProfile] {
        ModelRegistry.lineupText.flatMap { model in
            [0, ModelConfiguration.fullMetalOffloadLayers].map { layers in
                curatedEstimatedProfile(for: model, gpuLayers: layers)
            }
        }
    }

    /// Build the CPU/Metal shape for a catalog row that has no measurement.
    /// Evidence stays `.unvalidated`; eligibility comes from the estimate alone
    /// (`RuntimeEligibility.estimated`), and the physical floor uses the same
    /// rule as imports.
    private static func curatedEstimatedProfile(for model: AIModel, gpuLayers: Int) -> MemoryProfile {
        let mode: MemoryProfileMode = model.modelType == .vision ? .vision : .text
        let projectorBytes = model.requiresMMProj ? model.mmprojFileSizeBytes : nil
        // The profile id keys both experimental consent and load-safety history,
        // so it must be unique per shape and stable across launches.
        let shape = gpuLayers > 0 ? "metal" : "cpu"
        return MemoryProfile(
            id: "\(model.id)-\(mode.rawValue)-\(shape)-ctx\(model.config.contextLength)-p1",
            modelID: model.id,
            mode: mode,
            contextLength: model.config.contextLength,
            batchSize: model.config.batchSize,
            microBatchSize: model.config.microBatchSize,
            gpuLayers: gpuLayers,
            projectorPolicy: model.requiresMMProj ? .required : .disabled,
            evidenceStatus: .unvalidated,
            policyVersion: 1,
            measuredFullWorkloadPeakDeltaBytes: nil,
            measuredLoadDeltaBytes: nil,
            safetyMultiplier: MemoryProfile.productionSafetyMultiplier,
            fixedReserveBytes: MemoryProfile.productionReserveBytes,
            minimumPhysicalRAMBytes: ImportRAMAssessment.physicalFloorBytes(
                baseBytes: model.baseFileSizeBytes,
                mmprojBytes: projectorBytes,
                contextLength: model.config.contextLength
            )
        )
    }

    /// Shapes declared by hand, in a fixed order. CPU and Metal for the three
    /// families that still have a Metal shape; the DEBUG calibration identity
    /// joins them only in Debug builds. `lineupTextProfiles` supplies the rest.
    private static var declaredProfiles: [MemoryProfile] {
#if DEBUG
        [
            llama32Text, e2bVision, e4bText, e4bVision,
            llama32TextMetal, e2bVisionMetal,
            e4bTextCalibration,
        ]
#else
        [
            llama32Text, e2bVision, e4bText, e4bVision,
            llama32TextMetal, e2bVisionMetal,
        ]
#endif
    }

    static var all: [MemoryProfile] {
        declaredProfiles + lineupTextProfiles
    }

    /// Shapes indexed once. `ModelCatalogValidator` asks for every model on
    /// every availability check, so this cannot be a linear scan of `all`.
    private static let shapesByModelID: [String: [MemoryProfile]] =
        Dictionary(grouping: all, by: \.modelID)
    /// Whether the curated registry can size this model at all. Disk-free and
    /// cheap by construction: it never consults the imported registry.
    static func hasCuratedShape(for modelID: String) -> Bool {
        shapesByModelID[modelID]?.isEmpty == false
    }

    static func profile(for modelID: String, usesGPU: Bool = ModelConfiguration.autoGpuLayers() > 0) -> MemoryProfile? {
#if DEBUG
        if HermeticUITestRuntime.isEnabled, modelID == ModelRegistry.llama32_3B.id {
            return hermeticLlamaText
        }
#endif
        if let curated = curatedProfile(modelID: modelID, usesGPU: usesGPU) { return curated }
        return ImportedModelStore.shared.record(id: modelID).map { importedProfile(for: $0.model) }
    }

    /// Serve-what-can-serve, now evidence-ranked. Every curated model has two
    /// runtime shapes (CPU and Metal); a device may also have two shapes with
    /// different evidence strength. The strongest evidence wins before the
    /// faster shape does, so:
    ///
    /// - a validated CPU shape keeps serving instead of being displaced by an
    ///   estimated Metal shape (today's E2B behavior, preserved verbatim);
    /// - once a Metal shape earns experimental or validated evidence it selects
    ///   automatically with no code change;
    /// - two equally-evidenced shapes pick the one the device requests.
    ///
    /// Engine execution follows the selected profile's `gpuLayers` (see
    /// InferenceService), so this choice is the real CPU/Metal switch.
    private static func curatedProfile(modelID: String, usesGPU: Bool) -> MemoryProfile? {
        guard let shapes = shapesByModelID[modelID], !shapes.isEmpty else { return nil }
        // (lower is better): strongest evidence first, then the requested shape.
        func rank(_ shape: MemoryProfile) -> (Int, Int) {
            (
                -shape.runtimeEligibility.evidenceRank,
                (shape.gpuLayers > 0) == usesGPU ? 0 : 1
            )
        }
        // `min(by:)` returns the first element of an equal-ranked run, and `all`
        // is a fixed order, so the selection is deterministic across launches.
        return shapes.min { rank($0) < rank($1) }
    }

#if DEBUG
    /// Threshold-harness override: `--vision-force-cpu` serves the CPU shape
    /// instead of auto-Metal for the CPU-vs-Metal abort comparison.
    static var forceCPUVision = false
#endif

    static func profile(for model: AIModel) -> MemoryProfile? {
        if model.isImported { return importedProfile(for: model) }
#if DEBUG
        if forceCPUVision { return profile(for: model.id, usesGPU: false) }
#endif
        return profile(for: model.id, usesGPU: model.config.gpuLayers > 0)
    }

    /// Imported models have no retained device calibration yet. The estimate is
    /// conservative and only enables the explicit experimental-consent path.
    /// P1-4: separate base/mmproj weights (both GGUFs mmap'd ~1/3 resident),
    /// an absolute 4GB + dynamic physical floor, and fail-closed nil evidence
    /// + .max floor on zero/negative catalog sizes. Artifact bytes shape the
    /// conservative estimate only — admission quantity stays nil (see sentinel).
    ///
    /// The projector weight is a third, like the base. `d68bdc9` tried this and
    /// was reverted for understating vision memory — but device evidence since
    /// proves the revert wrong: `mtmd_context_params` (bundled mtmd.h) exposes
    /// no mmap toggle, so projector weights ride the same mmap path as the base
    /// (pageable, never pinned), and the retained E2B full-workload peak delta
    /// (798MB) sits BELOW base/3 alone (1142MB) with image turns included —
    /// the 557MB projector demonstrably contributes a fraction, not its full
    /// file size. Full weight overstated Qwen2-VL-2B (710MB projector) by
    /// ~473MB, single-handedly refusing loads the device otherwise fits.
    /// Both estimators compute `base/3 + mmproj/3 + contextScale`, so the
    /// pre-import wizard estimate and the post-import admission profile
    /// cannot disagree (see `testWizardPickerAndImportedProfileConverge`).
    static func importedProfile(for model: AIModel) -> MemoryProfile {
        let revision = model.huggingFaceProvenance?.revision.prefix(12) ?? "unknown"
        func failClosedProfile() -> MemoryProfile {
            Logger(subsystem: "com.zanish-labs.ziroedge", category: "memory")
                .fault("Imported profile fail-closed malformed size \(model.id, privacy: .public)")
            return MemoryProfile(
                id: "hf-\(model.id)-\(revision)-ctx\(model.config.contextLength)-p1",
                modelID: model.id,
                mode: model.modelType == .vision ? .vision : .text,
                contextLength: model.config.contextLength,
                batchSize: model.config.batchSize,
                microBatchSize: model.config.microBatchSize,
                gpuLayers: model.config.gpuLayers,
                projectorPolicy: model.requiresMMProj ? .required : .disabled,
                evidenceStatus: .unvalidated,
                policyVersion: 1,
                measuredFullWorkloadPeakDeltaBytes: nil,
                measuredLoadDeltaBytes: nil,
                safetyMultiplier: MemoryProfile.productionSafetyMultiplier,
                fixedReserveBytes: MemoryProfile.productionReserveBytes,
                minimumPhysicalRAMBytes: .max
            )
        }
        // Fail closed: non-positive base, or a vision/projector identity with
        // missing/non-positive projector bytes, can never admit.
        guard model.baseFileSizeBytes > 0 else { return failClosedProfile() }
        let needsProjector = model.requiresMMProj || model.mmprojURL != nil
        if needsProjector {
            guard let mmprojBytes = model.mmprojFileSizeBytes, mmprojBytes > 0 else {
                return failClosedProfile()
            }
        }
        // One estimator for every consumer: the pre-import wizard, this profile,
        // and curated-shape estimates all read `ImportRAMAssessment`.
        let estimated = ImportRAMAssessment.residentBytes(
            baseBytes: model.baseFileSizeBytes,
            mmprojBytes: needsProjector ? model.mmprojFileSizeBytes : nil,
            contextLength: model.config.contextLength
        )
        return MemoryProfile(
            id: "hf-\(model.id)-\(revision)-ctx\(model.config.contextLength)-p1",
            modelID: model.id,
            mode: model.modelType == .vision ? .vision : .text,
            contextLength: model.config.contextLength,
            batchSize: model.config.batchSize,
            microBatchSize: model.config.microBatchSize,
            gpuLayers: model.config.gpuLayers,
            projectorPolicy: model.requiresMMProj ? .required : .disabled,
            evidenceStatus: .unvalidated,
            policyVersion: 1,
            measuredFullWorkloadPeakDeltaBytes: nil,
            measuredLoadDeltaBytes: estimated,
            safetyMultiplier: MemoryProfile.productionSafetyMultiplier,
            fixedReserveBytes: MemoryProfile.productionReserveBytes,
            minimumPhysicalRAMBytes: ImportRAMAssessment.physicalFloorBytes(
                baseBytes: model.baseFileSizeBytes,
                mmprojBytes: needsProjector ? model.mmprojFileSizeBytes : nil,
                contextLength: model.config.contextLength
            )
        )
    }
}
