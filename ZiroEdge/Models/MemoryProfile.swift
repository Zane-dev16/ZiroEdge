import Foundation
import os

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
    case validated
    case experimental
    case unavailable

    var label: String {
        switch self {
        case .validated: "Validated"
        case .experimental: "Experimental"
        case .unavailable: "Runtime unavailable"
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

    var runtimeEligibility: RuntimeEligibility {
        if isProductionValidated { return .validated }
        if measuredLoadDeltaBytes != nil { return .experimental }
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

    static let e4bTextMetal = MemoryProfile(
        id: "gemma4-e4b-text-metal-p1", modelID: ModelRegistry.gemma4_e4b_text.id,
        mode: .text, contextLength: 512, batchSize: 256, microBatchSize: 64,
        gpuLayers: ModelConfiguration.fullMetalOffloadLayers,
        projectorPolicy: .disabled, evidenceStatus: .unvalidated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: nil, measuredLoadDeltaBytes: nil,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_054_095_872
    )

    static let e4bVisionMetal = MemoryProfile(
        id: "gemma4-e4b-vision-metal-p1", modelID: ModelRegistry.gemma4_e4b.id,
        mode: .vision, contextLength: 4096, batchSize: 512, microBatchSize: 128,
        gpuLayers: ModelConfiguration.fullMetalOffloadLayers,
        projectorPolicy: .required, evidenceStatus: .unvalidated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: nil, measuredLoadDeltaBytes: nil,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_054_095_872
    )

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

    static var all: [MemoryProfile] {
#if DEBUG
        [llama32Text, e2bVision, e4bText, e4bVision, llama32TextMetal, e2bVisionMetal, e4bTextMetal, e4bVisionMetal, e4bTextCalibration]
#else
        [llama32Text, e2bVision, e4bText, e4bVision, llama32TextMetal, e2bVisionMetal, e4bTextMetal, e4bVisionMetal]
#endif
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

    /// Serve-what-can-serve: a Metal shape with zero evidence is unavailable,
    /// so resolve to the CPU shape instead of refusing a load CPU could serve
    /// (even when the CPU shape is also unavailable, it keeps execution on the
    /// conservative path). Once a Metal shape calibrates (experimental or
    /// validated) it selects automatically with no code change. Engine
    /// execution follows the selected profile's gpuLayers (see InferenceService).
    private static func curatedProfile(modelID: String, usesGPU: Bool) -> MemoryProfile? {
        let match = all.first(where: { $0.modelID == modelID && ($0.gpuLayers > 0) == usesGPU })
        if usesGPU, let metal = match, metal.runtimeEligibility == .unavailable,
           let cpu = all.first(where: { $0.modelID == modelID && $0.gpuLayers == 0 }) {
            return cpu
        }
        return match ?? all.first(where: { $0.modelID == modelID })
    }

    static func profile(for model: AIModel) -> MemoryProfile? {
        model.isImported ? importedProfile(for: model) : profile(for: model.id, usesGPU: model.config.gpuLayers > 0)
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
        let baseResident = UInt64(clamping: model.baseFileSizeBytes / 3)
        let mmprojResident: UInt64 = {
            guard let mmprojBytes = model.mmprojFileSizeBytes, mmprojBytes > 0 else { return 0 }
            return UInt64(clamping: mmprojBytes / 3)
        }()
        let contextScale = SaturatedArithmetic.multiply(
            UInt64(clamping: max(model.config.contextLength, 512)),
            256_000
        )
        let estimated = SaturatedArithmetic.add(
            SaturatedArithmetic.add(baseResident, mmprojResident),
            contextScale
        )
        // Absolute 4GB floor plus dynamic estimated+reserve so huge imports
        // demand real hardware instead of passing on any 6GB device.
        let physicalFloor = max(
            4_000_000_000,
            SaturatedArithmetic.add(estimated, MemoryProfile.productionReserveBytes)
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
            minimumPhysicalRAMBytes: physicalFloor
        )
    }
}
