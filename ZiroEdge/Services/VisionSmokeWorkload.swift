#if DEBUG
import Foundation

struct VisionSmokeResult: Sendable {
    let outcome: String
    let response: String
}

@MainActor
enum VisionSmokeWorkload {
    static var isEnabled: Bool {
        CommandLine.arguments.contains("--vision-physical-smoke")
    }

    static func run(
        lifecycleManager: ModelLifecycleManager,
        inferenceService: InferenceService
    ) async -> VisionSmokeResult {
        guard isEnabled else { return VisionSmokeResult(outcome: "smoke-refused", response: "") }
        let model = ModelRegistry.gemma4_e4b
        guard ModelManagerService.isFullyDownloaded(model) else {
            return VisionSmokeResult(outcome: "smoke-missing-artifacts", response: "")
        }

        let loadResult = await lifecycleManager.loadModel(model)
        guard loadResult == .loaded || loadResult == .alreadyLoaded else {
            return VisionSmokeResult(outcome: "smoke-load-failed", response: "")
        }

        do {
            let stream = try await inferenceService.streamVisionChat(
                messages: [ChatMessagePayload(
                    role: .user,
                    content: "Describe this image in one short sentence."
                )],
                images: [try deterministicImage()],
                systemPrompt: nil,
                sampling: SamplingConfig(
                    temperature: 0,
                    topP: 1,
                    topK: 1,
                    maxTokens: 48,
                    repeatPenalty: 1
                )
            )
            var response = ""
            for try await piece in stream { response += piece }
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return VisionSmokeResult(outcome: "smoke-empty-response", response: "")
            }

            let events = try InferenceDiagnosticRecorder.shared.readEvents()
                .filter { $0.modelID == model.id }
            guard let requestID = events.compactMap(\.requestID).last else {
                return VisionSmokeResult(outcome: "smoke-missing-request-log", response: "")
            }
            let requestEvents = events.filter { $0.requestID == requestID }
            let required: [(InferenceDiagnosticStage, InferenceDiagnosticState)] = [
                (.imageDecode, .end),
                (.imagePreprocess, .end),
                (.imageEmbedding, .end),
                (.imageEvaluation, .end),
                (.promptTokenization, .end),
                (.promptPrefill, .end),
                (.firstToken, .event),
                (.completion, .end)
            ]
            guard required.allSatisfy({ checkpoint in
                requestEvents.contains { $0.stage == checkpoint.0 && $0.state == checkpoint.1 }
            }) else {
                return VisionSmokeResult(outcome: "smoke-incomplete-checkpoints", response: "")
            }
            return VisionSmokeResult(outcome: "smoke-success", response: trimmed)
        } catch {
            return VisionSmokeResult(outcome: "smoke-inference-failed", response: "")
        }
    }

    /// A deterministic red image generated in-process with no user data.
    private static func deterministicImage() throws -> Data {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlYl1sAAAAASUVORK5CYII="
        guard let data = Data(base64Encoded: base64) else { throw SmokeError.fixtureUnavailable }
        return data
    }

    private enum SmokeError: Error {
        case fixtureUnavailable
    }
}
#endif
