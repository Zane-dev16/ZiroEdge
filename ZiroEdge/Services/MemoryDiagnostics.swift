import Foundation
import Darwin

extension ContinuousClock.Instant {
    var elapsedMilliseconds: UInt64 {
        let components = duration(to: .now).components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        return UInt64(components.seconds) * 1_000
            + UInt64(components.attoseconds / 1_000_000_000_000_000)
    }
}

/// Stable checkpoints emitted by the opt-in memory diagnostic loop.
enum MemoryCheckpoint: String, Codable, Sendable {
    case cold
    case beforeModelLoad
    case afterModelLoad
    case firstTextPrefill
    case firstImageEval
    case generationPeak
    case workloadFailure
    case afterUnload
    case memoryWarning
    case background
    case foreground
    case periodic
    case recovery
}

struct MemorySnapshot: Codable, Equatable, Sendable {
    let totalPhysicalBytes: UInt64
    let processAvailableBytes: UInt64
    let physicalFootprintBytes: UInt64
    /// Host-wide reclaimable pages. Diagnostic context only; never a load-gating input.
    let systemReclaimableBytes: UInt64
    let timestamp: Date
    let checkpoint: MemoryCheckpoint
    let elapsedMilliseconds: UInt64?
    let cycle: Int?
    let turn: Int?
    let phase: String?
    let error: String?
    let runID: String?
    let modelID: String?

    func addingDiagnosticMetadata(
        elapsedMilliseconds: UInt64? = nil,
        cycle: Int? = nil,
        turn: Int? = nil,
        phase: String? = nil,
        error: String? = nil,
        runID: String? = nil,
        modelID: String? = nil
    ) -> MemorySnapshot {
        MemorySnapshot(
            totalPhysicalBytes: totalPhysicalBytes,
            processAvailableBytes: processAvailableBytes,
            physicalFootprintBytes: physicalFootprintBytes,
            systemReclaimableBytes: systemReclaimableBytes,
            timestamp: timestamp,
            checkpoint: checkpoint,
            elapsedMilliseconds: elapsedMilliseconds ?? self.elapsedMilliseconds,
            cycle: cycle ?? self.cycle,
            turn: turn ?? self.turn,
            phase: phase ?? self.phase,
            error: error ?? self.error,
            runID: runID ?? self.runID,
            modelID: modelID ?? self.modelID
        )
    }
}

enum MemorySnapshotReader {
    static func capture(
        _ checkpoint: MemoryCheckpoint,
        elapsedMilliseconds: UInt64? = nil,
        error: String? = nil
    ) -> MemorySnapshot {
        MemorySnapshot(
            totalPhysicalBytes: totalPhysicalMemory(),
            processAvailableBytes: UInt64(os_proc_available_memory()),
            physicalFootprintBytes: physicalFootprint(),
            systemReclaimableBytes: systemReclaimableMemory(),
            timestamp: Date(),
            checkpoint: checkpoint,
            elapsedMilliseconds: elapsedMilliseconds,
            cycle: nil,
            turn: nil,
            phase: nil,
            error: error,
            runID: nil,
            modelID: nil
        )
    }

    private static func totalPhysicalMemory() -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0 ? value : 0
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func systemReclaimableMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count))
            * UInt64(vm_kernel_page_size)
    }
}

/// Opt-in JSONL recorder. Release builds can record snapshots, but cannot bypass policy.
final class MemoryDiagnosticRecorder: @unchecked Sendable {
    static let shared = MemoryDiagnosticRecorder()
#if DEBUG
    static let defaultTargetModelID = "gemma-4-e4b-q4-text-calibration"
    static let allowedTargetModelIDs = [
        defaultTargetModelID,
        "llama3.2-3b-q4",
        "gemma-4-e2b-q4",
        "gemma-4-e4b-q4"
    ]

    static var targetModelID: String {
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--memory-profile-id"),
              CommandLine.arguments.indices.contains(flagIndex + 1) else {
            return defaultTargetModelID
        }
        let requested = CommandLine.arguments[flagIndex + 1]
        return allowedTargetModelIDs.contains(requested) ? requested : defaultTargetModelID
    }
#else
    static let defaultTargetModelID = ""
    static let allowedTargetModelIDs: [String] = []
    static var targetModelID: String { "" }
#endif

    private let lock = NSLock()
    private let encoder: JSONEncoder
    private var contextCycle: Int?
    private var contextTurn: Int?
    private var contextPhase: String?
    private let runID = UUID().uuidString

    var isEnabled: Bool {
#if DEBUG
        CommandLine.arguments.contains("--memory-diagnostic")
#else
        false
#endif
    }

    var controlledWorkloadEnabled: Bool {
#if DEBUG
        Self.allowsControlledWorkload(arguments: CommandLine.arguments, isDebugBuild: true)
#else
        false
#endif
    }

    static func allowsCalibrationLoad(arguments: [String], isDebugBuild: Bool) -> Bool {
#if DEBUG
        isDebugBuild
            && arguments.contains("--memory-diagnostic")
            && arguments.contains("--calibration-memory-load")
#else
        false
#endif
    }

    static func allowsControlledWorkload(arguments: [String], isDebugBuild: Bool) -> Bool {
#if DEBUG
        allowsCalibrationLoad(arguments: arguments, isDebugBuild: isDebugBuild)
            && arguments.contains("--memory-diagnostic-workload")
#else
        false
#endif
    }

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    func setContext(cycle: Int? = nil, turn: Int? = nil, phase: String? = nil) {
        lock.lock()
        contextCycle = cycle
        contextTurn = turn
        contextPhase = phase
        lock.unlock()
    }

    @discardableResult
    func capture(
        _ checkpoint: MemoryCheckpoint,
        elapsedMilliseconds: UInt64? = nil,
        error: String? = nil
    ) -> MemorySnapshot? {
        guard isEnabled else { return nil }
        let snapshot = MemorySnapshotReader.capture(
            checkpoint,
            elapsedMilliseconds: elapsedMilliseconds,
            error: error
        )
        return persist(snapshot)
    }

    @discardableResult
    func persist(_ snapshot: MemorySnapshot) -> MemorySnapshot? {
        guard isEnabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let enriched = snapshot.addingDiagnosticMetadata(
            cycle: contextCycle,
            turn: contextTurn,
            phase: contextPhase,
            runID: runID,
            modelID: Self.targetModelID
        )
        do {
            let data = try encoder.encode(enriched)
            guard let line = String(data: data, encoding: .utf8) else {
                print("[ZIRO-MEMORY-ERROR] Failed to encode diagnostic snapshot as UTF-8")
                return nil
            }

            print("[ZIRO-MEMORY] \(line)")
            let url = Self.logURL
            DiagnosticLogRotation.rotateIfNeeded(url: url, byteLimit: Self.logRotationBytes)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
                try handle.synchronize()
            } else {
                try Data((line + "\n").utf8).write(to: url, options: .atomic)
            }
            return enriched
        } catch {
            print("[ZIRO-MEMORY-ERROR] Failed to persist diagnostic snapshot: \(error.localizedDescription)")
            return nil
        }
    }

    var exportURL: URL? {
        Self.logURLIfPresent
    }

    func resetLog() {
        guard isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: Self.logURL)
    }

    static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("memory-diagnostic.jsonl")
    }

    /// Live JSONL log cap; older bytes rotate to `.old` (one deep).
    static let logRotationBytes: Int64 = 2_048 * 1_024

    static var logURLIfPresent: URL? {
        FileManager.default.fileExists(atPath: logURL.path) ? logURL : nil
    }
}
