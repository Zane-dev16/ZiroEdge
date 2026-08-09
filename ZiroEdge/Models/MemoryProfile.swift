import Foundation

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
        projectorPolicy: .disabled, evidenceStatus: .unvalidated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: nil, measuredLoadDeltaBytes: nil,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_000_000_000
    )

    static let e2bVision = MemoryProfile(
        id: "gemma4-e2b-vision-p1", modelID: ModelRegistry.gemma4_e2b.id,
        mode: .vision, contextLength: 4096, batchSize: 512, microBatchSize: 128,
        projectorPolicy: .required, evidenceStatus: .validated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: 798_559_232, measuredLoadDeltaBytes: 790_334_488,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_054_095_872
    )

    static let e4bText = MemoryProfile(
        id: "gemma4-e4b-text-p1", modelID: ModelRegistry.gemma4_e4b_text.id,
        mode: .text, contextLength: 512, batchSize: 256, microBatchSize: 64,
        projectorPolicy: .disabled, evidenceStatus: .unvalidated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: nil, measuredLoadDeltaBytes: nil,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_054_095_872
    )

    static let e4bVision = MemoryProfile(
        id: "gemma4-e4b-vision-p1", modelID: ModelRegistry.gemma4_e4b.id,
        mode: .vision, contextLength: 4096, batchSize: 512, microBatchSize: 128,
        projectorPolicy: .required, evidenceStatus: .unvalidated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: nil, measuredLoadDeltaBytes: nil,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_054_095_872
    )

#if DEBUG
    static let hermeticLlamaText = MemoryProfile(
        id: "uitest-llama-text-p1", modelID: ModelRegistry.llama32_3B.id,
        mode: .text, contextLength: 4096, batchSize: 512, microBatchSize: 128,
        projectorPolicy: .disabled, evidenceStatus: .validated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: 1, measuredLoadDeltaBytes: 1,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 1
    )

    static let e4bTextCalibration = MemoryProfile(
        id: "gemma4-e4b-text-calibration-p1", modelID: ModelRegistry.gemma4E4BTextCalibration.id,
        mode: .text, contextLength: 512, batchSize: 256, microBatchSize: 64,
        projectorPolicy: .disabled, evidenceStatus: .unvalidated, policyVersion: 1,
        measuredFullWorkloadPeakDeltaBytes: nil, measuredLoadDeltaBytes: nil,
        safetyMultiplier: 1.25, fixedReserveBytes: 750_000_000,
        minimumPhysicalRAMBytes: 8_054_095_872
    )
#endif

    static var all: [MemoryProfile] {
#if DEBUG
        [llama32Text, e2bVision, e4bText, e4bVision, e4bTextCalibration]
#else
        [llama32Text, e2bVision, e4bText, e4bVision]
#endif
    }

    static func profile(for modelID: String) -> MemoryProfile? {
#if DEBUG
        if HermeticUITestRuntime.isEnabled, modelID == ModelRegistry.llama32_3B.id {
            return hermeticLlamaText
        }
#endif
        if let curated = all.first(where: { $0.modelID == modelID }) { return curated }
        return ImportedModelStore.shared.record(id: modelID).map { importedProfile(for: $0.model) }
    }

    static func profile(for model: AIModel) -> MemoryProfile? {
        model.isImported ? importedProfile(for: model) : profile(for: model.id)
    }

    /// Imported models have no retained device calibration yet. The estimate is
    /// conservative and only enables the explicit experimental-consent path.
    static func importedProfile(for model: AIModel) -> MemoryProfile {
        let contextScale = SaturatedArithmetic.multiply(
            UInt64(clamping: max(model.config.contextLength, 512)),
            256_000
        )
        let artifactResidentEstimate = UInt64(clamping: model.totalFileSizeBytes / 3)
        let estimated = SaturatedArithmetic.add(artifactResidentEstimate, contextScale)
        let revision = model.huggingFaceProvenance?.revision.prefix(12) ?? "unknown"
        return MemoryProfile(
            id: "hf-\(model.id)-\(revision)-ctx\(model.config.contextLength)-p1",
            modelID: model.id,
            mode: model.modelType == .vision ? .vision : .text,
            contextLength: model.config.contextLength,
            batchSize: model.config.batchSize,
            microBatchSize: model.config.microBatchSize,
            projectorPolicy: model.requiresMMProj ? .required : .disabled,
            evidenceStatus: .unvalidated,
            policyVersion: 1,
            measuredFullWorkloadPeakDeltaBytes: nil,
            measuredLoadDeltaBytes: estimated,
            safetyMultiplier: MemoryProfile.productionSafetyMultiplier,
            fixedReserveBytes: MemoryProfile.productionReserveBytes,
            minimumPhysicalRAMBytes: 1
        )
    }
}
