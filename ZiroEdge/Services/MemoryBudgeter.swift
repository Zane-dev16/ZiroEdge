// MemoryBudgeter.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Pre-load RAM checking. Uses host_statistics64 to get actual free + inactive
// + purgeable pages. Prevents OOM crashes from loading models that won't fit.

import Foundation
import os

protocol MemoryMetricsProviding: Sendable {
    func availableRAM() -> UInt64
    func totalRAM() -> UInt64
}

struct FixedMemoryMetricsProvider: MemoryMetricsProviding {
    let available: UInt64
    let total: UInt64
    func availableRAM() -> UInt64 { available }
    func totalRAM() -> UInt64 { total }
}

struct SystemMemoryMetricsProvider: MemoryMetricsProviding {
    func availableRAM() -> UInt64 {
        var stats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count))
            * UInt64(vm_kernel_page_size)
    }

    func totalRAM() -> UInt64 {
        var size: UInt64 = 0
        var sizeSize = MemoryLayout<UInt64>.size
        return sysctlbyname("hw.memsize", &size, &sizeSize, nil, 0) == 0 ? size : 0
    }
}

/// Memory budget checker. Reports available RAM and recommends whether a model can load.
actor MemoryBudgeter {

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "memory")
    private let metrics: any MemoryMetricsProviding

    init(metrics: any MemoryMetricsProviding = SystemMemoryMetricsProvider()) {
        self.metrics = metrics
    }

    /// Headroom required beyond the model's file size for working set (KV cache, activations, etc.).
    /// Spec says: model.fileSize + 1.5 GB headroom.
    private let headroomBytes: Int64 = 1_500_000_000  // 1.5 GB

    // MARK: - RAM Query

    /// Returns actual free + inactive + purgeable pages in bytes.
    /// This is the real available memory, not what UIKit reports.
    func availableRAM() -> UInt64 {
        let available = metrics.availableRAM()
        logger.info("RAM available=\(available / 1_048_576)MB")
        return available
    }

    /// Total physical device RAM in bytes.
    func totalDeviceRAM() -> UInt64 {
        metrics.totalRAM()
    }

    // MARK: - Model Fit Check

    /// Returns true if the model can load safely given current RAM.
    /// Requires: model.fileSize + headroom for working set.
    func canLoad(_ model: AIModel) -> Bool {
        let available = availableRAM()
        let required = UInt64(model.baseFileSizeBytes + (model.mmprojFileSizeBytes ?? 0)) + UInt64(headroomBytes)

        let canFit = available >= required
        logger.info("canLoad(\(model.id, privacy: .public)): available=\(available / 1_048_576)MB required=\(required / 1_048_576)MB → \(canFit ? "YES" : "NO")")

        return canFit
    }

    /// Recommended action when memory is tight.
    func recommendation(for model: AIModel) -> MemoryRecommendation {
        let available = availableRAM()
        let modelSize = UInt64(model.baseFileSizeBytes + (model.mmprojFileSizeBytes ?? 0))
        let required = modelSize + UInt64(headroomBytes)

        if available >= required {
            return .proceed
        }

        // Check if unloading the current model would free enough.
        // If the model alone fits but headroom doesn't, suggest unloading first.
        if available >= modelSize {
            return .unloadCurrentFirst
        }

        // Model won't fit even alone.
        return .insufficientRAM
    }

    // MARK: - Eviction Guidance

    /// How much RAM would be freed by unloading a specific model.
    func memoryReclaimable(from model: AIModel) -> UInt64 {
        UInt64(model.baseFileSizeBytes + (model.mmprojFileSizeBytes ?? 0))
    }

    /// Formatted available RAM string for UI display.
    func formattedAvailableRAM() -> String {
        let bytes = availableRAM()
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// Formatted total device RAM string for UI display.
    func formattedTotalRAM() -> String {
        let bytes = totalDeviceRAM()
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

// MARK: - Memory Recommendation

enum MemoryRecommendation: Sendable {
    /// Plenty of RAM — go ahead and load.
    case proceed
    /// Model fits but headroom is tight — unload current model first.
    case unloadCurrentFirst
    /// Model won't fit even if nothing else is loaded.
    case insufficientRAM
}
