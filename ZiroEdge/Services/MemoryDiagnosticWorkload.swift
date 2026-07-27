#if DEBUG
import Foundation

private final class CalibrationBreachState: @unchecked Sendable {
    private let lock = NSLock()
    private var _headroom: UInt64?

    var headroom: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return _headroom
    }

    func record(_ value: UInt64) {
        lock.lock()
        if _headroom == nil { _headroom = value }
        lock.unlock()
    }
}

/// Explicit physical-device calibration. It is unreachable without all DEBUG flags.
/// Native model construction is synchronous and cannot be interrupted once entered.
@MainActor
enum MemoryDiagnosticWorkload {
    static let minimumHeadroomBytes = MemoryProfile.productionReserveBytes
    static let cycleCount = 5
    static let promptCount = 20
    static let recoveryToleranceBytes: UInt64 = 100_000_000

    static func run(
        lifecycleManager: ModelLifecycleManager,
        inferenceService: InferenceService,
        progress: @escaping @MainActor (String) -> Void
    ) async -> String {
        let recorder = MemoryDiagnosticRecorder.shared
        guard recorder.controlledWorkloadEnabled else {
            return "workload-refused-missing-debug-flags"
        }
        guard let model = ModelRegistry.model(for: MemoryDiagnosticRecorder.targetModelID),
              ModelManagerService.isFullyDownloaded(model) else {
            return "missing-\(MemoryDiagnosticRecorder.targetModelID)"
        }

        let breach = CalibrationBreachState()
        let sampler = Task {
            while !Task.isCancelled {
                let snapshot = MemorySnapshotReader.capture(.periodic)
                recorder.persist(snapshot)
                if snapshot.processAvailableBytes < minimumHeadroomBytes {
                    breach.record(snapshot.processAvailableBytes)
                    await inferenceService.cancelCurrentStream()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { sampler.cancel() }

        do {
            try await performCycles(
                model: model,
                lifecycleManager: lifecycleManager,
                inferenceService: inferenceService,
                breach: breach,
                recorder: recorder,
                progress: progress
            )
            recorder.setContext()
            progress("workload-complete")
            return "workload-complete"
        } catch {
            recorder.capture(.workloadFailure, error: error.localizedDescription)
            await inferenceService.cancelCurrentStream()
            if lifecycleManager.isModelLoaded { await lifecycleManager.unloadCurrentModel() }
            recorder.setContext()
            let sanitized = error.localizedDescription.replacingOccurrences(of: "\n", with: " ").prefix(120)
            let outcome = "workload-failed-\(sanitized)"
            progress(outcome)
            return outcome
        }
    }

    private static func performCycles(
        model: AIModel,
        lifecycleManager: ModelLifecycleManager,
        inferenceService: InferenceService,
        breach: CalibrationBreachState,
        recorder: MemoryDiagnosticRecorder,
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        progress("workload-cycles")
        if lifecycleManager.isModelLoaded {
            await lifecycleManager.unloadCurrentModel()
            try await Task.sleep(for: .seconds(5))
        }
        let sampling = SamplingConfig(
            temperature: 0, topP: 1, topK: 1, maxTokens: 16, repeatPenalty: 1
        )
        // Prime one-time tokenizer, image-decoder, and native runtime caches before
        // measured baselines. Warm-up records use cycle 0 and are excluded by the
        // fail-closed validator; the five accepted cycles remain unchanged.
        try await warmUpRuntime(
            model: model,
            lifecycleManager: lifecycleManager,
            inferenceService: inferenceService,
            breach: breach,
            recorder: recorder,
            sampling: sampling
        )

        var recoveries: [UInt64] = []
        for cycle in 1...cycleCount {
            try requireNoBreach(breach)
            recorder.setContext(cycle: cycle, phase: "cold-baseline")
            let baseline = MemorySnapshotReader.capture(.cold)
            recorder.persist(baseline)

            await lifecycleManager.loadModel(model)
            try requireStableLoad(lifecycleManager: lifecycleManager, breach: breach)
            try await runPrompts(
                cycle: cycle,
                model: model,
                inferenceService: inferenceService,
                lifecycleManager: lifecycleManager,
                breach: breach,
                recorder: recorder,
                sampling: sampling
            )

            if cycle == cycleCount {
                recorder.setContext(cycle: cycle, phase: "background-foreground")
                progress("workload-awaiting-background")
                for _ in 0..<80 where lifecycleManager.isModelLoaded {
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard !lifecycleManager.isModelLoaded else { throw WorkloadError.backgroundDidNotUnload }
            } else {
                await lifecycleManager.unloadCurrentModel()
            }

            try await Task.sleep(for: .seconds(5))
            recorder.setContext(cycle: cycle, phase: "post-unload-recovery")
            let recovery = MemorySnapshotReader.capture(.recovery)
            recorder.persist(recovery)
            recoveries.append(recovery.physicalFootprintBytes)
            guard recovery.physicalFootprintBytes <= baseline.physicalFootprintBytes + recoveryToleranceBytes else {
                throw WorkloadError.recoveryExceeded(
                    baseline: baseline.physicalFootprintBytes,
                    recovered: recovery.physicalFootprintBytes
                )
            }
        }
        guard recoveries.count == cycleCount, !hasUpwardTrend(recoveries) else {
            throw WorkloadError.upwardRecoveryTrend
        }
        try requireNoBreach(breach)
    }

    private static func warmUpRuntime(
        model: AIModel,
        lifecycleManager: ModelLifecycleManager,
        inferenceService: InferenceService,
        breach: CalibrationBreachState,
        recorder: MemoryDiagnosticRecorder,
        sampling: SamplingConfig
    ) async throws {
        recorder.setContext(cycle: 0, phase: "runtime-warmup")
        await lifecycleManager.loadModel(model)
        try requireStableLoad(lifecycleManager: lifecycleManager, breach: breach)
        let text = try await inferenceService.streamChat(
            messages: [ChatMessagePayload(role: .user, content: "Reply with exactly the word OK.")],
            systemPrompt: nil,
            sampling: sampling
        )
        try validate(response: try await collect(text), label: "warm-up text")

        if MemoryProfileRegistry.profile(for: model.id)?.mode == .vision {
            let vision = try await inferenceService.streamVisionChat(
                messages: [ChatMessagePayload(role: .user, content: "Name the dominant color in one word.")],
                images: [try deterministicRedPNG()],
                systemPrompt: nil,
                sampling: sampling
            )
            try validate(response: try await collect(vision), label: "warm-up image")
        }
        await lifecycleManager.unloadCurrentModel()
        try await Task.sleep(for: .seconds(5))
        try requireNoBreach(breach)
    }

    private static func runPrompts(
        cycle: Int,
        model: AIModel,
        inferenceService: InferenceService,
        lifecycleManager: ModelLifecycleManager,
        breach: CalibrationBreachState,
        recorder: MemoryDiagnosticRecorder,
        sampling: SamplingConfig
    ) async throws {
        for promptInCycle in 1...4 {
            let turn = (cycle - 1) * 4 + promptInCycle
            recorder.setContext(cycle: cycle, turn: turn, phase: "text-workload")
            let prompt = promptInCycle == 4 ? longContextPressurePrompt : "Reply with exactly the word OK."
            let stream = try await inferenceService.streamChat(
                messages: [ChatMessagePayload(role: .user, content: prompt)],
                systemPrompt: nil,
                sampling: sampling
            )
            try validate(response: try await collect(stream), label: "text turn \(turn)")
            try requireStableLoad(lifecycleManager: lifecycleManager, breach: breach)
        }
        guard MemoryProfileRegistry.profile(for: model.id)?.mode == .vision else { return }
        recorder.setContext(cycle: cycle, turn: cycle, phase: "image-workload")
        let stream = try await inferenceService.streamVisionChat(
            messages: [ChatMessagePayload(role: .user, content: "Name the dominant color in one word.")],
            images: [try deterministicRedPNG()],
            systemPrompt: nil,
            sampling: sampling
        )
        try validate(response: try await collect(stream), label: "image turn \(cycle)")
        try requireStableLoad(lifecycleManager: lifecycleManager, breach: breach)
    }

    private static var longContextPressurePrompt: String {
        let sentence = "Local inference must remain stable while the prompt approaches its configured context. "
        return String(repeating: sentence, count: 14) + "Reply with OK."
    }

    private static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var response = ""
        for try await token in stream { response += token }
        return response
    }

    private static func validate(response: String, label: String) throws {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkloadError.invalidOutput("empty \(label)") }
        guard !trimmed.contains("\u{FFFD}"), !trimmed.contains("\0") else {
            throw WorkloadError.invalidOutput("corrupt \(label)")
        }
    }

    private static func requireStableLoad(
        lifecycleManager: ModelLifecycleManager,
        breach: CalibrationBreachState
    ) throws {
        try requireNoBreach(breach)
        guard lifecycleManager.isModelLoaded else { throw WorkloadError.modelNotLoaded }
        guard !lifecycleManager.showMemoryWarning else { throw WorkloadError.memoryWarning }
    }

    private static func requireNoBreach(_ breach: CalibrationBreachState) throws {
        if let bytes = breach.headroom { throw WorkloadError.lowHeadroom(bytes) }
    }

    private static func hasUpwardTrend(_ values: [UInt64]) -> Bool {
        guard values.count > 1 else { return true }
        let count = Double(values.count)
        let xs = values.indices.map(Double.init)
        let ys = values.map(Double.init)
        let xMean = xs.reduce(0, +) / count
        let yMean = ys.reduce(0, +) / count
        let numerator = zip(xs, ys).reduce(0.0) { $0 + ($1.0 - xMean) * ($1.1 - yMean) }
        let denominator = xs.reduce(0.0) { $0 + ($1 - xMean) * ($1 - xMean) }
        return denominator == 0 || numerator / denominator > 0
    }

    private static func deterministicRedPNG() throws -> Data {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlYl1sAAAAASUVORK5CYII="
        guard let data = Data(base64Encoded: base64) else { throw WorkloadError.fixtureUnavailable }
        return data
    }

    private enum WorkloadError: LocalizedError {
        case modelNotLoaded
        case memoryWarning
        case lowHeadroom(UInt64)
        case invalidOutput(String)
        case fixtureUnavailable
        case backgroundDidNotUnload
        case recoveryExceeded(baseline: UInt64, recovered: UInt64)
        case upwardRecoveryTrend

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "model-not-loaded"
            case .memoryWarning: return "memory-warning"
            case .lowHeadroom(let bytes): return "headroom-below-fixed-reserve-\(bytes)"
            case .invalidOutput(let detail): return detail
            case .fixtureUnavailable: return "deterministic-image-fixture-unavailable"
            case .backgroundDidNotUnload: return "background-did-not-unload"
            case .recoveryExceeded(let baseline, let recovered):
                return "recovery-exceeded-100MB-baseline-\(baseline)-recovered-\(recovered)"
            case .upwardRecoveryTrend: return "upward-post-unload-trend"
            }
        }
    }
}
#endif
