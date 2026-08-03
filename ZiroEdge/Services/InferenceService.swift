// InferenceService.swift
// ZiroEdge — Privacy-first local AI assistant
//
// The single public interface for all LLM operations.
// No llama.cpp types leak past this boundary.
// Wraps the local swift-llama-cpp package (LlamaEngine).

import Foundation
import SwiftLlama
import os

// MARK: - Inference Service Protocol

/// Public API for LLM operations. All consumers (ViewModels, ChatSessionActor)
/// interact with the model through this protocol. No llama types leak.
protocol InferenceServiceProtocol: Sendable {
    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws
    func unloadModel() async
    var isModelLoaded: Bool { get async }
    var loadedModelID: String? { get async }

    func streamChat(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error>

    func streamVisionChat(
        messages: [ChatMessagePayload],
        images: [Data],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error>

    func cancelCurrentStream() async
}

// MARK: - Inference Service

private final class MemoryPeakAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: MemorySnapshot

    init(initial: MemorySnapshot) {
        peak = initial
    }

    func record(_ snapshot: MemorySnapshot) {
        lock.lock()
        defer { lock.unlock() }
        if snapshot.physicalFootprintBytes > peak.physicalFootprintBytes {
            peak = snapshot
        }
    }

    func snapshot() -> MemorySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

/// Production implementation of InferenceServiceProtocol.
/// Manages the lifecycle of the underlying LlamaEngine.
actor InferenceService: InferenceServiceProtocol {

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "inference")

    /// The underlying LlamaEngine. Nil when no model is loaded.
    private var engine: LlamaEngine?

    /// The currently loaded model ID.
    private var _loadedModelID: String?
#if DEBUG
    private var hermeticModelLoaded = false
#endif

    /// The current model configuration.
    private var currentConfig: ModelConfiguration?

    /// Current model reference (for reloads).
    private var currentModel: AIModel?

    /// Pending unload task — awaited before loading a new model to prevent race conditions.
    private var pendingUnload: Task<Void, Never>?

    /// Pending stream cancellation — awaited before starting more engine work.
    private var pendingCancellation: Task<Void, Never>?

    private let loadSafetyStore: LoadSafetyStore

    init(loadSafetyStore: LoadSafetyStore) {
        self.loadSafetyStore = loadSafetyStore
    }

#if DEBUG
    /// Isolated convenience for previews and tests. Production wiring must supply
    /// the throwing, persistent store created by AppRuntime.
    init() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZiroEdge-LoadSafety-\(UUID().uuidString)")
        do {
            self.loadSafetyStore = try LoadSafetyStore(directory: directory)
        } catch {
            preconditionFailure("Could not create isolated test load-safety storage")
        }
    }
#endif

    // MARK: - State

    var isModelLoaded: Bool {
#if DEBUG
        if hermeticModelLoaded { return true }
#endif
        return engine != nil
    }

    var loadedModelID: String? {
        _loadedModelID
    }

    // MARK: - Model Loading

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        // Wait for any pending cancellation or unload to complete before loading.
        await waitForPendingCancellation()
        await pendingUnload?.value
        pendingUnload = nil
        // Unload any existing model first.
        unloadInternal()

        logger.info("Loading model: \(model.id, privacy: .public)")

#if DEBUG
        if HermeticUITestRuntime.isEnabled, model.id == ModelRegistry.llama32_3B.id {
            guard let profile = MemoryProfileRegistry.profile(for: model.id) else {
                throw InferenceError.nativeFailure(kind: .contextCreation, diagnostic: "fixture-profile-missing")
            }
            try loadSafetyStore.beginLoad(profileID: profile.id)
            do {
                try loadSafetyStore.clearAfterNativeConstruction(profileID: profile.id)
            } catch {
                throw InferenceError.nativeFailure(kind: .suspectedJetsam, diagnostic: "fixture-safety-clear-failed")
            }
            hermeticModelLoaded = true
            _loadedModelID = model.id
            currentConfig = model.config
            currentModel = model
            return
        }
#endif

        // Validate file exists.
        let baseExists = FileManager.default.fileExists(atPath: baseURL.path)
        guard baseExists else {
            throw InferenceError.modelFileNotFound(path: baseURL.path)
        }

        if let mmprojURL {
            guard FileManager.default.fileExists(atPath: mmprojURL.path) else {
                throw InferenceError.mmprojFileNotFound(path: mmprojURL.path)
            }
        }

        // Build engine config from model configuration.
        let config = model.config
        let engineConfig = LlamaConfigSwift(
            modelPath: baseURL.path,
            mmprojPath: mmprojURL?.path,
            contextLength: config.contextLength,
            batchSize: config.batchSize,
            microBatchSize: config.microBatchSize,
            threadCount: config.threadCount,
            useMmap: config.useMmap,
            f16KV: config.f16KV,
            gpuLayers: config.gpuLayers,
            diagnosticHandler: { event in
                guard let stage = InferenceDiagnosticStage(rawValue: event.stage.rawValue),
                      let state = InferenceDiagnosticState(rawValue: event.state.rawValue) else { return }
                InferenceDiagnosticRecorder.shared.record(
                    modelID: model.id,
                    requestID: event.requestID,
                    stage: stage,
                    state: state,
                    elapsedMilliseconds: event.elapsedMilliseconds,
                    primaryCount: event.primaryCount,
                    secondaryCount: event.secondaryCount
                )
            }
        )

        // Persist immediately before native construction, including direct service callers.
        guard let profile = MemoryProfileRegistry.profile(for: model.id) else {
            throw InferenceError.nativeFailure(
                kind: .memoryPressure,
                diagnostic: "runtime-profile-missing"
            )
        }
        do {
            try loadSafetyStore.beginLoad(profileID: profile.id)
        } catch {
            throw InferenceError.nativeFailure(
                kind: .suspectedJetsam,
                diagnostic: "load-safety-circuit-open"
            )
        }

        // Native construction is synchronous and cannot be interrupted once entered.
        let newEngine: LlamaEngine
        do {
            newEngine = try LlamaEngine(config: engineConfig)
        } catch {
            // A returned native error is not an unclean termination. Preserve its
            // category even if committing marker cleanup also fails.
            let classified = Self.classifyNativeFailure(error)
            do {
                try loadSafetyStore.clearAfterNativeConstruction(profileID: profile.id)
            } catch {
                throw classified.addingSanitizedDiagnostic("load-safety-clear-failed")
            }
            throw classified
        }
        do {
            try loadSafetyStore.clearAfterNativeConstruction(profileID: profile.id)
        } catch {
            await newEngine.unload()
            throw InferenceError.nativeFailure(
                kind: .suspectedJetsam,
                diagnostic: "load-safety-clear-failed"
            )
        }
        engine = newEngine
        _loadedModelID = model.id
        currentConfig = config
        currentModel = model

        logger.info("Model loaded successfully: \(model.id, privacy: .public)")
    }

    func unloadModel() async {
        unloadInternal()
        await pendingUnload?.value
        pendingUnload = nil
    }

    private func unloadInternal() {
#if DEBUG
        hermeticModelLoaded = false
#endif
        if let eng = engine {
            pendingUnload = Task { await eng.unload() }
        }
        engine = nil
        _loadedModelID = nil
        currentConfig = nil
        currentModel = nil
        logger.info("Model unloaded")
    }

}

extension InferenceService {
    // MARK: - Raw Text Completion (bypasses chat template)

    /// Stream a raw completion with a pre-formatted prompt string.
    /// Bypasses the chat template — used for testing and debugging.
    func streamRawCompletion(
        prompt: String,
        sampling: SamplingConfig,
        stopStrings: [String],
        addBos: Bool?
    ) async throws -> AsyncThrowingStream<String, Error> {
        await waitForPendingCancellation()
#if DEBUG
        if hermeticModelLoaded { return Self.hermeticResponse() }
#endif
        guard let eng = engine else {
            throw InferenceError.modelNotLoaded
        }
        try enforcePreInferenceReserve()
        let engineSampling = SamplingConfigSwift(
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            maxTokens: sampling.maxTokens,
            repeatPenalty: sampling.repeatPenalty
        )
        return try await eng.streamCompletion(
            prompt: prompt,
            addBos: addBos,
            stopStrings: stopStrings,
            sampling: engineSampling
        )
    }

    // MARK: - Text Chat

    func streamChat(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        await waitForPendingCancellation()
#if DEBUG
        if hermeticModelLoaded { return Self.hermeticResponse() }
#endif
        guard let eng = engine else {
            throw InferenceError.modelNotLoaded
        }

        guard let config = currentConfig else {
            throw InferenceError.modelNotLoaded
        }
        try enforcePreInferenceReserve()

        // Convert sampling config to SwiftLlama format.
        let engineSampling = SamplingConfigSwift(
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            maxTokens: sampling.maxTokens,
            repeatPenalty: sampling.repeatPenalty
        )

        let prefillStarted = ContinuousClock.now
        let stream: AsyncThrowingStream<String, Error>
        switch config.promptPath {
        case .chatTemplate:
            stream = try await eng.streamChatCompletion(
                messages: chatTemplateMessages(messages: messages, systemPrompt: systemPrompt),
                addBos: config.addBos,
                stopStrings: config.stopStrings,
                sampling: engineSampling
            )
        case .gemma:
            let prompt: String
            if currentModel?.id == ModelRegistry.gemma4_e4b_text.id {
                let generationReserve = min(max(sampling.maxTokens, 1), 64)
                prompt = try await Self.compactGemmaPrompt(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    maximumPromptTokens: config.contextLength - generationReserve
                ) { candidate in
                    try await eng.tokenCount(
                        prompt: candidate,
                        addBos: config.addBos,
                        parseSpecial: true
                    )
                }
            } else {
                prompt = Self.formatGemmaPrompt(messages: messages, systemPrompt: systemPrompt)
            }
            stream = try await eng.streamCompletion(
                prompt: prompt,
                addBos: config.addBos,
                parseSpecial: true,
                stopStrings: config.stopStrings,
                sampling: engineSampling
            )
        case .raw:
            stream = try await eng.streamCompletion(
                prompt: formatRawPrompt(messages: messages, systemPrompt: systemPrompt),
                addBos: config.addBos,
                stopStrings: config.stopStrings,
                sampling: engineSampling
            )
        }
        return instrumentGenerationPeak(
            stream,
            firstEvaluationCheckpoint: .firstTextPrefill,
            evaluationStarted: prefillStarted
        )
    }

    // MARK: - Vision Chat

    func streamVisionChat(
        messages: [ChatMessagePayload],
        images: [Data],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        await waitForPendingCancellation()
        guard let eng = engine else {
            throw InferenceError.modelNotLoaded
        }

        guard let config = currentConfig else {
            throw InferenceError.modelNotLoaded
        }
        try enforcePreInferenceReserve()

        // Format one marker per supplied image. Markers belong to the first user
        // message only; repeating them for later turns would mismatch the bitmap array.
        let imageMarkers = images.map { _ in "<__media__>" }.joined(separator: "\n")
        var templateMessages = chatTemplateMessages(messages: messages, systemPrompt: systemPrompt)
        if !imageMarkers.isEmpty,
           let firstUserIndex = templateMessages.firstIndex(where: { $0.role == "user" }) {
            templateMessages[firstUserIndex].content = imageMarkers + "\n" + templateMessages[firstUserIndex].content
        }

        // Convert sampling config to SwiftLlama format.
        let engineSampling = SamplingConfigSwift(
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            maxTokens: sampling.maxTokens,
            repeatPenalty: sampling.repeatPenalty
        )

        let imageEvaluationStarted = ContinuousClock.now
        let stream: AsyncThrowingStream<String, Error>
        switch config.promptPath {
        case .chatTemplate:
            stream = try await eng.streamVisionChatCompletion(
                messages: templateMessages,
                images: images,
                addBos: config.addBos,
                stopStrings: config.stopStrings,
                sampling: engineSampling
            )
        case .gemma:
            stream = try await eng.streamVisionCompletion(
                prompt: Self.formatGemmaPrompt(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    imageMarkers: imageMarkers
                ),
                images: images,
                addBos: config.addBos,
                stopStrings: config.stopStrings,
                sampling: engineSampling
            )
        case .raw:
            stream = try await eng.streamVisionCompletion(
                prompt: formatRawPrompt(messages: messages, systemPrompt: systemPrompt),
                images: images,
                addBos: config.addBos,
                stopStrings: config.stopStrings,
                sampling: engineSampling
            )
        }
        return instrumentGenerationPeak(
            stream,
            firstEvaluationCheckpoint: .firstImageEval,
            evaluationStarted: imageEvaluationStarted
        )
    }

    private func instrumentGenerationPeak(
        _ source: AsyncThrowingStream<String, Error>,
        firstEvaluationCheckpoint: MemoryCheckpoint,
        evaluationStarted: ContinuousClock.Instant
    ) -> AsyncThrowingStream<String, Error> {
        guard MemoryDiagnosticRecorder.shared.isEnabled else {
            return instrumentSuccessfulInference(source)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                let accumulator = MemoryPeakAccumulator(
                    initial: MemorySnapshotReader.capture(.generationPeak)
                )
                let sampler = Task {
                    while !Task.isCancelled {
                        accumulator.record(MemorySnapshotReader.capture(.generationPeak))
                        do {
                            try await Task.sleep(for: .milliseconds(100))
                        } catch {
                            break
                        }
                    }
                }
                var generationStarted: ContinuousClock.Instant?

                do {
                    for try await token in source {
                        if generationStarted == nil {
                            generationStarted = .now
                            MemoryDiagnosticRecorder.shared.capture(
                                firstEvaluationCheckpoint,
                                elapsedMilliseconds: evaluationStarted.elapsedMilliseconds
                            )
                        }
                        accumulator.record(MemorySnapshotReader.capture(.generationPeak))
                        continuation.yield(token)
                    }
                    sampler.cancel()
                    await sampler.value
                    let elapsed = generationStarted?.elapsedMilliseconds
                        ?? evaluationStarted.elapsedMilliseconds
                    MemoryDiagnosticRecorder.shared.persist(
                        accumulator.snapshot().addingDiagnosticMetadata(elapsedMilliseconds: elapsed)
                    )
                    continuation.finish()
                } catch {
                    sampler.cancel()
                    await sampler.value
                    let elapsed = generationStarted?.elapsedMilliseconds
                        ?? evaluationStarted.elapsedMilliseconds
                    MemoryDiagnosticRecorder.shared.persist(
                        accumulator.snapshot().addingDiagnosticMetadata(
                            elapsedMilliseconds: elapsed,
                            error: error.localizedDescription
                        )
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func instrumentSuccessfulInference(
        _ source: AsyncThrowingStream<String, Error>
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await token in source { continuation.yield(token) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.classifyNativeFailure(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One fresh snapshot immediately before entering inference. The load-time
    /// check cannot protect a model whose headroom fell while it was idle.
    private func enforcePreInferenceReserve() throws {
        let available = UInt64(os_proc_available_memory())
        guard available >= MemoryProfile.productionReserveBytes else {
            throw InferenceError.nativeFailure(
                kind: .memoryPressure,
                diagnostic: MemoryAdmissionFailure.postLoadReserveBreached.rawValue
            )
        }
    }

    private static func classifyNativeFailure(_ error: Error) -> InferenceError {
        guard let llamaError = error as? LlamaError else {
            return .nativeFailure(kind: .inference, diagnostic: sanitize(error.localizedDescription))
        }
        let kind: NativeFailureKind
        switch llamaError {
        case .modelLoadFailed: kind = .modelMapping
        case .contextCreationFailed: kind = .contextCreation
        case .projectorInitializationFailed, .visionNotSupported, .visionImageLoadFailed:
            kind = .projectorInitialization
        case .decodeFailed, .tokenizationFailed, .samplerCreationFailed, .modelNotLoaded:
            kind = .inference
        case .invalidConfiguration: kind = .contextCreation
        }
        return .nativeFailure(kind: kind, diagnostic: sanitize(llamaError.localizedDescription))
    }

    private static func sanitize(_ diagnostic: String) -> String {
        diagnostic
            .replacingOccurrences(of: #"(?:/[^\s:]+)+"#, with: "<redacted-path>", options: .regularExpression)
            .prefix(500)
            .description
    }

#if DEBUG
    private static func hermeticResponse() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("OK")
            continuation.finish()
        }
    }
#endif

    // MARK: - Cancellation

    func cancelCurrentStream() async {
        if let pendingCancellation {
            await pendingCancellation.value
            return
        }
        guard let eng = engine else { return }

        let cancellationTask = Task {
            await eng.cancel()
        }
        pendingCancellation = cancellationTask
        await cancellationTask.value
        pendingCancellation = nil
    }

    private func waitForPendingCancellation() async {
        guard let pendingCancellation else { return }
        await pendingCancellation.value
        self.pendingCancellation = nil
    }

    // MARK: - Prompt Formatting

    /// Preserve semantic roles and let each GGUF's embedded template choose its
    /// own control tokens. Hard-coding one model family's syntax breaks the others.
    private func chatTemplateMessages(
        messages: [ChatMessagePayload],
        systemPrompt: String?
    ) -> [(role: String, content: String)] {
        var result: [(role: String, content: String)] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            result.append((role: "system", content: systemPrompt))
        }
        result.append(contentsOf: messages.map { (role: $0.role.rawValue, content: $0.content) })
        return result
    }

    static func compactGemmaPrompt(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        maximumPromptTokens: Int,
        tokenCount: (String) async throws -> Int
    ) async rethrows -> String {
        var retainedMessages = messages
        var prompt = formatGemmaPrompt(messages: retainedMessages, systemPrompt: systemPrompt)

        while try await tokenCount(prompt) > maximumPromptTokens,
              let range = oldestCompleteExchange(in: retainedMessages) {
            retainedMessages.removeSubrange(range)
            prompt = formatGemmaPrompt(messages: retainedMessages, systemPrompt: systemPrompt)
        }
        return prompt
    }

    private static func oldestCompleteExchange(
        in messages: [ChatMessagePayload]
    ) -> ClosedRange<Int>? {
        guard let newestUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return nil
        }
        for userIndex in messages.indices
        where userIndex < newestUserIndex && messages[userIndex].role == .user {
            let nextUserIndex = messages[(userIndex + 1)...]
                .firstIndex(where: { $0.role == .user }) ?? messages.endIndex
            if let assistantIndex = messages[(userIndex + 1)..<nextUserIndex]
                .firstIndex(where: { $0.role == .assistant }) {
                return userIndex...assistantIndex
            }
        }
        return nil
    }

    static func formatGemmaPrompt(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        imageMarkers: String = ""
    ) -> String {
        var rendered = ""
        var pendingSystem = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var pendingImages = imageMarkers

        for message in messages {
            let role: String
            var content = message.content
            switch message.role {
            case .system:
                pendingSystem = [pendingSystem, content]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                continue
            case .user:
                role = "user"
                content = [pendingSystem, pendingImages, content]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                pendingSystem = ""
                pendingImages = ""
            case .assistant:
                role = "model"
            }
            rendered += "<start_of_turn>\(role)\n\(content)<end_of_turn>\n"
        }
        if !pendingSystem.isEmpty || !pendingImages.isEmpty {
            rendered += "<start_of_turn>user\n"
                + [pendingSystem, pendingImages].filter { !$0.isEmpty }.joined(separator: "\n")
                + "<end_of_turn>\n"
        }
        rendered += "<start_of_turn>model\n"
        return rendered
    }

    private func formatRawPrompt(
        messages: [ChatMessagePayload],
        systemPrompt: String?
    ) -> String {
        var parts: [String] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            parts.append("System: \(systemPrompt)")
        }
        for message in messages {
            let rolePrefix: String
            switch message.role {
            case .user: rolePrefix = "User"
            case .assistant: rolePrefix = "Assistant"
            case .system: rolePrefix = "System"
            }
            parts.append("\(rolePrefix): \(message.content)")
        }
        parts.append("Assistant:")
        return parts.joined(separator: "\n")
    }
}

// MARK: - Inference Errors

enum NativeFailureKind: String, Sendable, Equatable {
    case modelMapping
    case contextCreation
    case projectorInitialization
    case inference
    case memoryPressure
    case suspectedJetsam
}

enum InferenceError: Error, LocalizedError, Equatable {
    case modelNotLoaded
    case modelFileNotFound(path: String)
    case mmprojFileNotFound(path: String)
    case visionNotSupported
    case nativeFailure(kind: NativeFailureKind, diagnostic: String)

    var sanitizedDiagnostic: String {
        switch self {
        case .modelNotLoaded: return "model-not-loaded"
        case .modelFileNotFound: return "model-artifact-missing"
        case .mmprojFileNotFound: return "projector-artifact-missing"
        case .visionNotSupported: return "vision-profile-disabled"
        case .nativeFailure(let kind, let diagnostic): return "\(kind.rawValue): \(diagnostic)"
        }
    }

    func addingSanitizedDiagnostic(_ suffix: String) -> InferenceError {
        guard case .nativeFailure(let kind, let diagnostic) = self else { return self }
        return .nativeFailure(kind: kind, diagnostic: "\(diagnostic);\(suffix)")
    }

    var nativeFailureKind: NativeFailureKind? {
        guard case .nativeFailure(let kind, _) = self else { return nil }
        return kind
    }

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No model is loaded. Please download and load a model first."
        case .modelFileNotFound:
            return "The model artifact is missing."
        case .mmprojFileNotFound:
            return "The vision projector artifact is missing."
        case .visionNotSupported:
            return "This runtime profile does not support vision."
        case .nativeFailure(let kind, _):
            return "Local inference failed during \(kind.rawValue)."
        }
    }
}
