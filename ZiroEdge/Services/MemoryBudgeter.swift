import Foundation
import Darwin
import os

protocol MemoryMetricsProviding: Sendable {
    func processAvailableMemory() -> UInt64
    func totalRAM() -> UInt64
}

struct FixedMemoryMetricsProvider: MemoryMetricsProviding {
    let processAvailable: UInt64
    let total: UInt64
    func processAvailableMemory() -> UInt64 { processAvailable }
    func totalRAM() -> UInt64 { total }
}

struct SystemMemoryMetricsProvider: MemoryMetricsProviding {
    func processAvailableMemory() -> UInt64 { UInt64(os_proc_available_memory()) }
    func totalRAM() -> UInt64 {
        var size: UInt64 = 0
        var sizeSize = MemoryLayout<UInt64>.size
        return sysctlbyname("hw.memsize", &size, &sizeSize, nil, 0) == 0 ? size : 0
    }
}

struct MemoryLoadDecision: Equatable, Sendable {
    let recommendation: MemoryRecommendation
    let processAvailableBytes: UInt64
    let totalPhysicalBytes: UInt64
    let profileID: String?
    let requiredBytes: UInt64?
    let reason: MemoryAdmissionFailure?
    /// Post-teardown projection (raw headroom + reclaimable resident) and
    /// the reclaimable credit used. Nil for pre-credit callers/tests.
    var projectedAvailableBytes: UInt64? = nil
    var reclaimableBytes: UInt64? = nil

    /// A regression sentinel: admission never consumes download/storage byte counts.
    var artifactBytesUsedForAdmission: UInt64? { nil }

    var formattedAppMemoryHeadroom: String { Self.format(bytes: processAvailableBytes) }

    static func format(bytes: UInt64) -> String {
        StorageByteFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    var logSummary: String {
        [
            "recommendation=\(recommendation)",
            "processHeadroomBytes=\(processAvailableBytes)",
            "projectedAvailableBytes=\(projectedAvailableBytes.map(String.init) ?? "none")",
            "reclaimableBytes=\(reclaimableBytes.map(String.init) ?? "none")",
            "totalPhysicalBytes=\(totalPhysicalBytes)",
            "profileID=\(profileID ?? "unknown")",
            "requiredBytes=\(requiredBytes.map(String.init) ?? "unknown")",
            "reason=\(reason?.rawValue ?? "none")",
        ].joined(separator: " ")
    }

    func alertMessage(modelName: String) -> String {
        switch reason {
        case .profileUnvalidated:
            return "\(modelName) is not validated for normal use. Experimental use requires explicit consent and measured load evidence."
        case .profileMissing:
            return "\(modelName) has no registered runtime-memory profile and cannot be loaded."
        case .profileDisabled:
            return "\(modelName) was disabled after repeated unclean loads. Reset its safety history before calibrating again."
        default:
            return "\(modelName) needs more working memory than the \(formattedAppMemoryHeadroom) of App Memory Headroom currently available."
        }
    }
}

enum MemoryAdmissionFailure: String, Sendable, Equatable {
    case metricsUnavailable
    case profileMissing
    case profileUnvalidated
    case physicalRAMBelowMinimum
    case insufficientProcessHeadroom
    case postLoadReserveBreached
    case profileDisabled
}

/// Profile-based model-load policy. The caller must complete unload/recovery before invoking `decision`.
actor MemoryBudgeter {
    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "memory")
    private let metrics: any MemoryMetricsProviding
    private var lastDecision: MemoryLoadDecision?

    init(metrics: any MemoryMetricsProviding = SystemMemoryMetricsProvider()) {
        self.metrics = metrics
    }

    func appMemoryHeadroom() -> UInt64 { metrics.processAvailableMemory() }
    func totalDeviceRAM() -> UInt64 { metrics.totalRAM() }

    /// P1-1: single fresh sample after the caller completes unload recovery.
    /// A transient zero (jetsam pressure settling) retries once immediately
    /// before failing closed as metricsUnavailable. Callers must NOT reuse a
    /// pre-teardown decision: re-invoke this immediately pre-mmap/context init
    /// (see constructAndCommit fresh resample + InferenceService pre-mmap gate).
    /// P1-4: malformed catalog sizes fail closed here as well (profileUnvalidated,
    /// artifact quantity still never used — sentinel stays nil).
    /// Pre-teardown switch callers pass the resident model's reclaimable
    /// credit: raw headroom failing while the projected (post-eviction)
    /// headroom passes returns .unloadCurrentFirst (proceed to teardown)
    /// instead of .insufficientRAM. Post-teardown gates pass reclaimable 0.
    /// Projected headroom after evicting the resident model. Saturated add:
    /// the projection never wraps and the decision caps it at total RAM.
    static func projectedAvailableAfterEviction(currentAvailable: UInt64, reclaimableBytes: UInt64) -> UInt64 {
        SaturatedArithmetic.add(currentAvailable, reclaimableBytes)
    }

    /// Reclaimable credit for evicting `priorActive`: the required headroom
    /// its own profile would demand (validated peak first, then experimental
    /// load evidence). Zero when nothing is resident or no evidence exists.
    /// Conservative by construction — it derives from the same profile the
    /// post-teardown hard gate enforces.
    static func reclaimableBytes(for priorActive: AIModel?) -> UInt64 {
        guard let priorActive,
              let profile = MemoryProfileRegistry.profile(for: priorActive) else { return 0 }
        if let required = try? profile.requiredProcessHeadroomBytes() { return required }
        return (try? profile.experimentalRequiredProcessHeadroomBytes()) ?? 0
    }

    func decision(for model: AIModel, allowUnvalidatedCalibration: Bool = false, reclaimableBytes: UInt64 = 0) -> MemoryLoadDecision {
        // P1-4 fail-closed validity gate: quantity never admits, but malformed
        // sizes must refuse even before profile checks. IDs public.
        let needsProjector = model.requiresMMProj || model.mmprojURL != nil
        let hasValidSizes = model.baseFileSizeBytes > 0
            && (!needsProjector || (model.mmprojFileSizeBytes ?? 0) > 0)
        if !hasValidSizes {
            logger.fault("Load refused malformed artifact size \(model.id, privacy: .public)")
            let refused = MemoryLoadDecision(
                recommendation: .insufficientRAM,
                processAvailableBytes: metrics.processAvailableMemory(),
                totalPhysicalBytes: metrics.totalRAM(),
                profileID: MemoryProfileRegistry.profile(for: model)?.id,
                requiredBytes: nil,
                reason: .profileUnvalidated
            )
            lastDecision = refused
            return refused
        }
        var processAvailable = metrics.processAvailableMemory()
        var total = metrics.totalRAM()
        if processAvailable == 0 || total == 0 {
            // P1-1 retry-once: one immediate resample before failing closed.
            logger.fault("Memory metrics transient zero \(model.id, privacy: .public) retrying once")
            processAvailable = metrics.processAvailableMemory()
            total = metrics.totalRAM()
        }
        let profile = MemoryProfileRegistry.profile(for: model)
        var required = try? profile?.requiredProcessHeadroomBytes()
        // Projected post-eviction headroom: only the memory comparison may
        // use it — every fail-closed gate stays on raw samples. Capped at
        // total RAM so eviction can never free more than exists.
        let projected = min(
            Self.projectedAvailableAfterEviction(currentAvailable: processAvailable, reclaimableBytes: reclaimableBytes),
            total
        )
        // Raw pass → proceed. Raw fail but projected pass → unloadCurrentFirst
        // (proceed to teardown; the post-teardown hard gate re-samples with
        // zero credit). Both fail → insufficientRAM.
        func memoryVerdict(required: UInt64) -> (MemoryRecommendation, MemoryAdmissionFailure?) {
            if processAvailable >= required { return (.proceed, nil) }
            if projected >= required { return (.unloadCurrentFirst, nil) }
            return (.insufficientRAM, .insufficientProcessHeadroom)
        }
        let recommendation: MemoryRecommendation
        let reason: MemoryAdmissionFailure?

        if processAvailable == 0 || total == 0 {
            recommendation = .insufficientRAM
            reason = .metricsUnavailable
        } else if profile == nil {
            recommendation = .insufficientRAM
            reason = .profileMissing
        } else if let profile, total < profile.minimumPhysicalRAMBytes {
            recommendation = .insufficientRAM
            reason = .physicalRAMBelowMinimum
        } else if let profile, required == nil, allowUnvalidatedCalibration {
            // Normal experimental consent still requires measured runtime evidence.
            // DEBUG controlled calibration is the only path that may gather first evidence.
            if let experimentalRequired = try? profile.experimentalRequiredProcessHeadroomBytes() {
                required = experimentalRequired
                (recommendation, reason) = memoryVerdict(required: experimentalRequired)
            } else {
#if DEBUG
                if MemoryDiagnosticRecorder.shared.controlledWorkloadEnabled {
                    recommendation = .proceed
                    reason = nil
                } else {
                    recommendation = .insufficientRAM
                    reason = .profileUnvalidated
                }
#else
                recommendation = .insufficientRAM
                reason = .profileUnvalidated
#endif
            }
        } else if required == nil {
            recommendation = .insufficientRAM
            reason = .profileUnvalidated
        } else if let required {
            (recommendation, reason) = memoryVerdict(required: required)
        } else {
            recommendation = .proceed
            reason = nil
        }

        let decision = MemoryLoadDecision(
            recommendation: recommendation,
            processAvailableBytes: processAvailable,
            totalPhysicalBytes: total,
            profileID: profile?.id,
            requiredBytes: required,
            reason: reason,
            projectedAvailableBytes: projected,
            reclaimableBytes: reclaimableBytes
        )
        lastDecision = decision
        logger.info("Memory load decision for \(model.id, privacy: .public): \(decision.logSummary, privacy: .public)")
        return decision
    }

    /// One post-load sample; validated and calibration loads must retain the fixed reserve.
    func postLoadReserveSatisfied() -> Bool {
        metrics.processAvailableMemory() >= MemoryProfile.productionReserveBytes
    }

    func formattedAppMemoryHeadroom() -> String {
        if let lastDecision { return lastDecision.formattedAppMemoryHeadroom }
        return MemoryLoadDecision.format(bytes: appMemoryHeadroom())
    }

    func formattedTotalRAM() -> String { MemoryLoadDecision.format(bytes: totalDeviceRAM()) }
}

enum MemoryRecommendation: Sendable, Equatable {
    case proceed
    case unloadCurrentFirst
    case insufficientRAM
}
