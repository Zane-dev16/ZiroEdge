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

    /// R6: unconditional gate release for safety eviction. Idempotent with
    /// the stream's own onTermination release.
    func releaseGenerationGateForEviction() async

    /// Ensures no generation holds the engine before a new chat decode starts.
    /// Chat preempts the current holder (cancels it and waits for release).
    /// Throws `generationBusy` when the holder did not release in time so the
    /// caller surfaces feedback instead of silently queueing.
    func ensureIdleForNewChat() async throws
}

extension InferenceServiceProtocol {
    /// Default no-op so test doubles that don't model cross-generation
    /// arbitration compile unchanged.
    func ensureIdleForNewChat() async throws {}
    func releaseGenerationGateForEviction() async {}
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

    /// Single-slot mutex over the llama.cpp context. Concurrent decode loops on
    /// one engine are undefined behavior; every chat/vision stream acquisition
    /// is serialized here.
    private let generationGate = GenerationGate()

    private let loadSafetyStore: LoadSafetyStore
    /// Unified stable-settle sampler (system metrics — same source the old
    /// back-to-back resamples read). Logger only; verdict math unchanged.
    private let settleBudgeter = MemoryBudgeter()

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
        // `unloadInternal` just spawned the teardown task for the previously
        // resident engine. Await it before native construction: overlapping the
        // old engine's `llama_backend_free()` with new engine construction
        // doubles RAM and races global llama.cpp teardown against init.
        await pendingUnload?.value
        pendingUnload = nil

        logger.info("Loading model: \(model.id, privacy: .public) from \(baseURL.path, privacy: .public)")

#if DEBUG
        if try await loadHermeticIfEligible(model) { return }
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
            gpuLayers: config.gpuLayers
        )

        // Persist immediately before native construction, including direct service callers.
        guard let profile = MemoryProfileRegistry.profile(for: model) else {
            throw InferenceError.nativeFailure(
                kind: .memoryPressure,
                diagnostic: "runtime-profile-missing"
            )
        }
        do {
            try loadSafetyStore.beginLoad(profileID: profile.id)
        } catch {
            let uncleanCount = loadSafetyStore.recentUncleanAttemptCount(profileID: profile.id)
            let disabledFlag = loadSafetyStore.isDisabled(profileID: profile.id)
            // A latched-disabled profile must read distinctly from a stale
            // pending marker so the UI can route to Reset instead of Retry.
            let diagnostic = disabledFlag ? "load-safety-profile-disabled" : "load-safety-circuit-open"
            let gateError = String(describing: error)
            logger.error("Safety gate threw for \(profile.id, privacy: .public): \(gateError, privacy: .private)")
            logger.error("Safety state unclean=\(uncleanCount, privacy: .public) disabled=\(disabledFlag, privacy: .public)")
            throw InferenceError.nativeFailure(
                kind: .suspectedJetsam,
                diagnostic: diagnostic
            )
        }

        // P1-1 fresh sample immediately pre-mmap: the caller's budget decision
        // may be stale after teardown sleep. Retry-once inside; on refusal
        // withdraw the just-set marker so the slot isn't burned and the next
        // begin isn't blocked (admission refusal, not a construction attempt).
        do {
            try await enforcePreLoadReserve(for: model, profile: profile)
        } catch {
            _ = loadSafetyStore.withdrawPendingLoad()
            throw error
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
        // P1-3 coalesce: actor-serialized second unload joins in-flight teardown
        // instead of spawning a duplicate backend_free. Idempotent when idle.
#if DEBUG
        let hasHermetic = hermeticModelLoaded
#else
        let hasHermetic = false
#endif
        if engine == nil && pendingUnload == nil && !hasHermetic { return }
        unloadInternal()
        await pendingUnload?.value
        pendingUnload = nil
    }

    private func unloadInternal() {
#if DEBUG
        hermeticModelLoaded = false
#endif
        if let eng = engine {
            // Join in-flight teardown instead of overwriting (and leaking) it.
            if pendingUnload == nil {
                pendingUnload = Task { await eng.unload() }
            }
        }
        engine = nil
        _loadedModelID = nil
        currentConfig = nil
        currentModel = nil
        logger.info("Model unloaded")
    }

#if DEBUG
    /// Hermetic fast-path for UI tests (extracted to hold the loadModel
    /// body-length gate). Returns true when the load was fully handled.
    private func loadHermeticIfEligible(_ model: AIModel) async throws -> Bool {
        guard HermeticUITestRuntime.isEnabled, model.id == ModelRegistry.llama32_3B.id else {
            return false
        }
        if HermeticUITestRuntime.scenario == .failedLoad {
            throw InferenceError.nativeFailure(kind: .contextCreation, diagnostic: "hermetic-load-failure")
        }
        if HermeticUITestRuntime.scenario == .loading {
            // Deterministic in-flight window for loading-UX tests: hold the
            // lifecycle in `.loading` so the composer state is observable,
            // then fall through and resolve as ready. Actor-isolated (never
            // the main thread), bounded so a stalled test can't wedge the app.
            try await Task.sleep(for: .seconds(30))
        }
        guard let profile = MemoryProfileRegistry.profile(for: model) else {
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
        return true
    }
#endif

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
        try await enforcePreInferenceReserve()
        let engineSampling = SamplingConfigSwift(
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            maxTokens: sampling.maxTokens,
            repeatPenalty: sampling.repeatPenalty,
            penaltyLastN: sampling.penaltyLastN,
            frequencyPenalty: sampling.frequencyPenalty,
            presencePenalty: sampling.presencePenalty
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
        try await enforcePreInferenceReserve()

        // Convert sampling config to SwiftLlama format.
        let engineSampling = SamplingConfigSwift(
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            maxTokens: sampling.maxTokens,
            repeatPenalty: sampling.repeatPenalty,
            penaltyLastN: sampling.penaltyLastN,
            frequencyPenalty: sampling.frequencyPenalty,
            presencePenalty: sampling.presencePenalty
        )

        let prefillStarted = ContinuousClock.now
        let stream = try await gatedGenerationStream {
            switch config.promptPath {
            case .chatTemplate:
                return try await eng.streamChatCompletion(
                    messages: chatTemplateMessages(messages: messages, systemPrompt: systemPrompt),
                    addBos: config.addBos,
                    stopStrings: config.stopStrings,
                    sampling: engineSampling
                )
            case .gemma:
                return try await eng.streamCompletion(
                    prompt: Self.formatGemmaPrompt(messages: messages, systemPrompt: systemPrompt),
                    addBos: config.addBos,
                    parseSpecial: true,
                    stopStrings: config.stopStrings,
                    sampling: engineSampling
                )
            case .raw:
                return try await eng.streamCompletion(
                    prompt: formatRawPrompt(messages: messages, systemPrompt: systemPrompt),
                    addBos: config.addBos,
                    stopStrings: config.stopStrings,
                    sampling: engineSampling
                )
            }
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
        try await enforcePreInferenceReserve()

        // Format one marker per supplied image. Markers belong to the first user
        // message only; repeating them for later turns would mismatch the bitmap array.
        let imageMarkers = images.map { _ in "<__media__>" }.joined(separator: "\n")
        var templateMessages = chatTemplateMessages(messages: messages, systemPrompt: systemPrompt)
        if !imageMarkers.isEmpty {
            if let firstUserIndex = templateMessages.firstIndex(where: { $0.role == "user" }) {
                templateMessages[firstUserIndex].content = imageMarkers + "\n" + templateMessages[firstUserIndex].content
            } else {
                // No user turn in history (e.g. a vision continuation): dropping
                // the markers while the bitmaps still reach the engine would
                // mismatch mtmd's input/template pairing. Synthesize the turn.
                templateMessages.append((role: "user", content: imageMarkers))
            }
        }

        // Convert sampling config to SwiftLlama format.
        let engineSampling = SamplingConfigSwift(
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            maxTokens: sampling.maxTokens,
            repeatPenalty: sampling.repeatPenalty,
            penaltyLastN: sampling.penaltyLastN,
            frequencyPenalty: sampling.frequencyPenalty,
            presencePenalty: sampling.presencePenalty
        )

        let imageEvaluationStarted = ContinuousClock.now
        let stream = try await gatedGenerationStream {
            switch config.promptPath {
            case .chatTemplate:
                return try await eng.streamVisionChatCompletion(
                    messages: templateMessages,
                    images: images,
                    addBos: config.addBos,
                    stopStrings: config.stopStrings,
                    sampling: engineSampling
                )
            case .gemma:
                return try await eng.streamVisionCompletion(
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
                return try await eng.streamVisionCompletion(
                    prompt: formatRawPrompt(messages: messages, systemPrompt: systemPrompt),
                    images: images,
                    addBos: config.addBos,
                    stopStrings: config.stopStrings,
                    sampling: engineSampling
                )
            }
        }
        return instrumentGenerationPeak(
            stream,
            firstEvaluationCheckpoint: .firstImageEval,
            evaluationStarted: imageEvaluationStarted
        )
    }

    /// Serializes engine-stream creation through the generation gate. Throws
    /// `generationBusy` when another generation already holds the engine.
    private func gatedGenerationStream(
        _ build: () async throws -> AsyncThrowingStream<String, Error>
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard await generationGate.acquire() else {
            throw InferenceError.generationBusy
        }
        guard let holderID = await generationGate.heldBy() else {
            // Unreachable after a successful acquire; fail closed rather than
            // pumping an untracked stream.
            throw InferenceError.generationBusy
        }
        do {
            return try gateWrapped(await build(), holderID: holderID)
        } catch {
            // Engine-stream creation failed; never leak the held slot.
            await generationGate.release(holderID)
            throw error
        }
    }

    /// Pumps `inner` into the returned stream and releases the gate once the
    /// inner stream finishes, throws, or is terminated. Release is idempotent,
    /// so termination racing natural completion is safe.
    private func gateWrapped(
        _ inner: AsyncThrowingStream<String, Error>,
        holderID: UUID
    ) -> AsyncThrowingStream<String, Error> {
        let gate = generationGate
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await token in inner { continuation.yield(token) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await gate.release(holderID)
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await gate.release(holderID) }
            }
        }
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
    /// Dip retry waits up to 500ms for settled headroom (unified sampler)
    /// instead of resampling back-to-back (~µs apart), which re-reads the
    /// same depressed value for any dip outlasting one syscall.
    private func enforcePreInferenceReserve() async throws {
        let available = await settleBudgeter.appMemoryHeadroom()
        if available >= MemoryProfile.productionReserveBytes { return }
        logger.fault("Pre-inference reserve dip available=\(available, privacy: .public) settling")
        let settled = await settleBudgeter.settledAvailable(timeout: MemoryBudgeter.reserveDipSettleTimeout)
        guard settled >= MemoryProfile.productionReserveBytes else {
            logger.fault("Pre-inference reserve breached available=\(settled, privacy: .public) reserve=\(MemoryProfile.productionReserveBytes, privacy: .public)")
            throw InferenceError.nativeFailure(
                kind: .memoryPressure,
                diagnostic: MemoryAdmissionFailure.postLoadReserveBreached.rawValue
            )
        }
        logger.info("Pre-inference retry recovered available=\(settled, privacy: .public)")
    }

    /// P1-1 fresh headroom sample immediately pre-mmap/context init. The
    /// caller's budget decision may be stale after teardown sleep, so this gate
    /// never reuses it: it derives the floor from the profile and samples now,
    /// settling up to 500ms on breach (unified sampler). No validated floor
    /// (unvalidated without consent) defers to the caller's admission refusal —
    /// this gate only enforces a known floor. IDs public; no digests here.
    private func enforcePreLoadReserve(for model: AIModel, profile: MemoryProfile) async throws {
        let required = (try? profile.requiredProcessHeadroomBytes())
            ?? (try? profile.experimentalRequiredProcessHeadroomBytes())
        guard let required else { return }
        let available = await settleBudgeter.appMemoryHeadroom()
        if available >= required { return }
        logger.fault("Pre-mmap headroom dip \(model.id, privacy: .public) available=\(available, privacy: .public) required=\(required, privacy: .public) settling")
        let settled = await settleBudgeter.settledAvailable(timeout: MemoryBudgeter.reserveDipSettleTimeout)
        guard settled >= required else {
            logger.fault("Pre-mmap reserve breached \(model.id, privacy: .public) available=\(settled, privacy: .public) required=\(required, privacy: .public)")
            throw InferenceError.nativeFailure(
                kind: .memoryPressure,
                diagnostic: MemoryAdmissionFailure.insufficientProcessHeadroom.rawValue
            )
        }
        logger.info("Pre-mmap retry recovered \(model.id, privacy: .public) available=\(settled, privacy: .public)")
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
        case .contextWindowExceeded:
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
    /// Hermetic chat reply for `--uitesting-hermetic-model`.
    /// Streams a few chunks with a small inter-chunk delay (~2s total) instead of
    /// yielding everything at once: the UI tests that exercise the streaming
    /// stop affordance need an observable `isStreaming` window, and an
    /// instant-complete stream makes the stop button race-exist for only a few
    /// milliseconds (testChatStreamingStop flip-flopped on snapshot timing).
    private static func hermeticResponse() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let chunks = ["The", " color", " blue", " is", " a", " calm", " deep", " hue."]
            let task = Task {
                for chunk in chunks {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
#endif

    // MARK: - Cancellation

    /// Chat preemption policy: before a new chat decode starts, cancel any
    /// holder (title generation, a stale reply) and wait for it to release the
    /// engine. The engine's cancellation flag stops its decode loop at the next
    /// token boundary, so this settles quickly. A holder that never releases
    /// throws `generationBusy` rather than silently queueing the new chat.
    func ensureIdleForNewChat() async throws {
        let released = await generationGate.cancelAndAwaitRelease { [weak self] in
            await self?.cancelCurrentStream()
        }
        guard released else { throw InferenceError.generationBusy }
    }

    func cancelCurrentStream() async {
        if let pendingCancellation {
            await pendingCancellation.value
            return
        }
        guard let eng = engine else { return }

        let cancellationTask = Task {
            // `LlamaEngine.cancel()` is nonisolated and synchronous — no
            // await needed from outside the engine actor.
            eng.cancel()
        }
        pendingCancellation = cancellationTask
        await cancellationTask.value
        pendingCancellation = nil
    }

    /// R6: eviction-time gate release. Called after cancelCurrentStream so a
    /// holder stuck past its decode boundary cannot wedge the next load.
    func releaseGenerationGateForEviction() async {
        await generationGate.forceReleaseAllForEviction()
        logger.info("Generation gate released for eviction")
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
    case generationBusy
    case nativeFailure(kind: NativeFailureKind, diagnostic: String)

    var sanitizedDiagnostic: String {
        switch self {
        case .modelNotLoaded: return "model-not-loaded"
        case .modelFileNotFound: return "model-artifact-missing"
        case .mmprojFileNotFound: return "projector-artifact-missing"
        case .visionNotSupported: return "vision-profile-disabled"
        case .generationBusy: return "generation-busy"
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
        case .generationBusy:
            return "A local generation is already running. Please wait or cancel it first."
        case .nativeFailure(let kind, _):
            return "Local inference failed during \(kind.rawValue)."
        }
    }
}
