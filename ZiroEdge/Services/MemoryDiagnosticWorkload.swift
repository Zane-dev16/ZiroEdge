#if DEBUG
import Foundation

/// Automated, opt-in physical-device workload for measuring an intentionally
/// unsafe Gemma load. It is unreachable unless both diagnostic override flags
/// have already enabled `controlledWorkloadEnabled`.
@MainActor
enum MemoryDiagnosticWorkload {
    static let minimumHeadroomBytes: UInt64 = 512 * 1_024 * 1_024

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

        do {
            progress("workload-cycles")
            if lifecycleManager.isModelLoaded {
                recorder.setContext(cycle: 0, phase: "baseline-cleanup")
                await lifecycleManager.unloadCurrentModel()
                try await Task.sleep(for: .seconds(1))
            }

            for cycle in 1...5 {
                recorder.setContext(cycle: cycle, phase: "cold-load-cycle")
                await lifecycleManager.loadModel(model)
                try requireStableLoad(lifecycleManager: lifecycleManager)
                await lifecycleManager.unloadCurrentModel()
                try await Task.sleep(for: .seconds(1))
            }

            recorder.setContext(phase: "text-workload")
            await lifecycleManager.loadModel(model)
            try requireStableLoad(lifecycleManager: lifecycleManager)

            progress("workload-text")
            let sampling = SamplingConfig(
                temperature: 0,
                topP: 1,
                topK: 1,
                maxTokens: 16,
                repeatPenalty: 1
            )
            for turn in 1...10 {
                recorder.setContext(turn: turn, phase: "text-workload")
                let stream = try await inferenceService.streamChat(
                    messages: [ChatMessagePayload(role: .user, content: "Reply with exactly the word OK.")],
                    systemPrompt: nil,
                    sampling: sampling
                )
                let response = try await collect(stream)
                try validate(response: response, label: "text turn \(turn)")
                try requireStableLoad(lifecycleManager: lifecycleManager)
            }

            progress("workload-image")
            recorder.setContext(turn: 1, phase: "image-workload")
            let imageStream = try await inferenceService.streamVisionChat(
                messages: [ChatMessagePayload(role: .user, content: "Name the dominant color in one word.")],
                images: [try deterministicRedPNG()],
                systemPrompt: nil,
                sampling: sampling
            )
            let imageResponse = try await collect(imageStream)
            try validate(response: imageResponse, label: "image turn 1")
            try requireStableLoad(lifecycleManager: lifecycleManager)

            recorder.setContext(phase: "background-foreground")
            progress("workload-awaiting-background")
            // The UI test backgrounds and reactivates the app during this window.
            try await Task.sleep(for: .seconds(8))
            try requireStableLoad(lifecycleManager: lifecycleManager)

            recorder.setContext(phase: "final-unload")
            await lifecycleManager.unloadCurrentModel()
            recorder.setContext()
            progress("workload-complete")
            return "workload-complete"
        } catch {
            recorder.capture(.workloadFailure, error: error.localizedDescription)
            if lifecycleManager.isModelLoaded {
                await lifecycleManager.unloadCurrentModel()
            }
            recorder.setContext()
            let sanitized = error.localizedDescription
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(120)
            let outcome = "workload-failed-\(sanitized)"
            progress(outcome)
            return outcome
        }
    }

    private static func collect(
        _ stream: AsyncThrowingStream<String, Error>
    ) async throws -> String {
        var response = ""
        for try await token in stream {
            response += token
        }
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
        lifecycleManager: ModelLifecycleManager
    ) throws {
        guard lifecycleManager.isModelLoaded else { throw WorkloadError.modelNotLoaded }
        guard !lifecycleManager.showMemoryWarning else { throw WorkloadError.memoryWarning }
        let snapshot = MemorySnapshotReader.capture(.generationPeak)
        guard snapshot.processAvailableBytes >= minimumHeadroomBytes else {
            throw WorkloadError.lowHeadroom(snapshot.processAvailableBytes)
        }
    }

    private static func deterministicRedPNG() throws -> Data {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlYl1sAAAAASUVORK5CYII="
        guard let data = Data(base64Encoded: base64) else {
            throw WorkloadError.fixtureUnavailable
        }
        return data
    }

    private enum WorkloadError: LocalizedError {
        case modelNotLoaded
        case memoryWarning
        case lowHeadroom(UInt64)
        case invalidOutput(String)
        case fixtureUnavailable

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "model-not-loaded"
            case .memoryWarning: return "memory-warning"
            case .lowHeadroom(let bytes): return "headroom-below-512MiB-\(bytes)"
            case .invalidOutput(let detail): return detail
            case .fixtureUnavailable: return "deterministic-image-fixture-unavailable"
            }
        }
    }
}
#endif
