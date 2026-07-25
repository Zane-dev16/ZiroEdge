import Foundation
import Darwin
import os

protocol MemoryMetricsProviding: Sendable {
    /// Process-specific allocation headroom. This is the only production gating metric.
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
    func processAvailableMemory() -> UInt64 {
        UInt64(os_proc_available_memory())
    }

    func totalRAM() -> UInt64 {
        var size: UInt64 = 0
        var sizeSize = MemoryLayout<UInt64>.size
        return sysctlbyname("hw.memsize", &size, &sizeSize, nil, 0) == 0 ? size : 0
    }
}

struct MemoryLoadDecision: Equatable, Sendable {
    let recommendation: MemoryRecommendation
    let processAvailableBytes: UInt64
    let modelBytes: UInt64
    let requiredBytes: UInt64

    var formattedAppMemoryHeadroom: String {
        Self.format(bytes: processAvailableBytes)
    }

    static func format(bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .memory
        )
    }

    var logSummary: String {
        "recommendation=\(recommendation) processHeadroomBytes=\(processAvailableBytes) modelBytes=\(modelBytes) requiredBytes=\(requiredBytes)"
    }

    func alertMessage(modelName: String) -> String {
        "\(modelName) needs more working memory than the \(formattedAppMemoryHeadroom) of App Memory Headroom currently available. Close other apps or choose a smaller model."
    }
}

/// Model-load policy based on one process-headroom sample per decision.
actor MemoryBudgeter {
    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "memory")
    private let metrics: any MemoryMetricsProviding
    private var lastDecision: MemoryLoadDecision?

    /// Fixed policy headroom for KV cache, activations, and other working memory.
    private let policyHeadroomBytes: UInt64 = 1_500_000_000

    init(metrics: any MemoryMetricsProviding = SystemMemoryMetricsProvider()) {
        self.metrics = metrics
    }

    func appMemoryHeadroom() -> UInt64 {
        metrics.processAvailableMemory()
    }

    func totalDeviceRAM() -> UInt64 {
        metrics.totalRAM()
    }

    /// Samples process headroom exactly once and owns all values used by policy, logs, and UI.
    func decision(for model: AIModel) -> MemoryLoadDecision {
        let processAvailable = metrics.processAvailableMemory()
        let modelBytes = UInt64(model.totalFileSizeBytes)
        let requiredBytes = modelBytes + policyHeadroomBytes
        let recommendation: MemoryRecommendation

        if processAvailable >= requiredBytes {
            recommendation = .proceed
        } else if processAvailable >= modelBytes {
            recommendation = .unloadCurrentFirst
        } else {
            // A zero/failed process sample deliberately fails closed. Host VM pages are diagnostics-only.
            recommendation = .insufficientRAM
        }

        let decision = MemoryLoadDecision(
            recommendation: recommendation,
            processAvailableBytes: processAvailable,
            modelBytes: modelBytes,
            requiredBytes: requiredBytes
        )
        lastDecision = decision
        logger.info("Memory load decision for \(model.id, privacy: .public): \(decision.logSummary, privacy: .public)")
        return decision
    }

    func memoryReclaimable(from model: AIModel) -> UInt64 {
        UInt64(model.totalFileSizeBytes)
    }

    /// Uses the latest load-decision sample when one exists so Settings and load feedback agree.
    func formattedAppMemoryHeadroom() -> String {
        if let lastDecision {
            return lastDecision.formattedAppMemoryHeadroom
        }
        return MemoryLoadDecision.format(bytes: appMemoryHeadroom())
    }

    func formattedTotalRAM() -> String {
        MemoryLoadDecision.format(bytes: totalDeviceRAM())
    }
}

enum MemoryRecommendation: Sendable, Equatable {
    case proceed
    case unloadCurrentFirst
    case insufficientRAM
}
