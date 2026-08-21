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

    /// Samples os_proc_available_memory exactly once after the caller has completed unload recovery.
    func decision(for model: AIModel, allowUnvalidatedCalibration: Bool = false) -> MemoryLoadDecision {
        let processAvailable = metrics.processAvailableMemory()
        let total = metrics.totalRAM()
        let profile = MemoryProfileRegistry.profile(for: model)
        var required = try? profile?.requiredProcessHeadroomBytes()
        let reason: MemoryAdmissionFailure?

        if processAvailable == 0 || total == 0 {
            reason = .metricsUnavailable
        } else if profile == nil {
            reason = .profileMissing
        } else if let profile, total < profile.minimumPhysicalRAMBytes {
            reason = .physicalRAMBelowMinimum
        } else if let profile, required == nil, allowUnvalidatedCalibration {
            // Normal experimental consent still requires measured runtime evidence.
            // DEBUG controlled calibration is the only path that may gather first evidence.
            if let experimentalRequired = try? profile.experimentalRequiredProcessHeadroomBytes() {
                required = experimentalRequired
                reason = processAvailable < experimentalRequired ? .insufficientProcessHeadroom : nil
            } else {
#if DEBUG
                reason = MemoryDiagnosticRecorder.shared.controlledWorkloadEnabled ? nil : .profileUnvalidated
#else
                reason = .profileUnvalidated
#endif
            }
        } else if required == nil {
            reason = .profileUnvalidated
        } else if let required, processAvailable < required {
            reason = .insufficientProcessHeadroom
        } else {
            reason = nil
        }

        let decision = MemoryLoadDecision(
            recommendation: reason == nil ? .proceed : .insufficientRAM,
            processAvailableBytes: processAvailable,
            totalPhysicalBytes: total,
            profileID: profile?.id,
            requiredBytes: required,
            reason: reason
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
