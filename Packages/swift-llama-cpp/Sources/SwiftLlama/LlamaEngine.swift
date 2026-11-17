// LlamaEngine.swift
// SwiftLlama — Swift wrapper for llama.cpp b12000
//
// Actor-isolated engine wrapping the llama.cpp C API.
// All C API calls are isolated to this actor for thread safety.
// Targets upstream release b12000 — sampler chain API, memory API.

import Foundation
import llama
import os

// MARK: - Llama Engine

/// The core engine wrapping llama.cpp. Actor-isolated for thread safety.
public actor LlamaEngine {

    // MARK: - Properties

    let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "llama-engine")

    var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocabulary: OpaquePointer?
    private var mtmdCtx: OpaquePointer?
    /// Jinja template set for an artefact-declared template. Nil when the row
    /// declares a built-in family name instead (the heuristic formatter owns
    /// that case, because those families exist only as C++ builders).
    /// Engine-owned; the prompt-path decisions live in LlamaEngineChatTemplate.
    var chatTemplates: LlamaChatTemplates?
    let config: LlamaConfigSwift
    /// Lock-protected cancel flag: the sync decode loop monopolizes the actor,
    /// so cancellation must land nonisolated at the next token boundary.
    private let cancelFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var eosTokenID: llama_token = -1
    private var isBackendInitialized = false

    // MARK: - Initialization

    public init(config: LlamaConfigSwift) throws {
        // Metal-fail -> CPU-retry: a GPU OOM or Metal init failure falls back
        // to CPU once, never leaving the profile unloadable when CPU could
        // serve. CPU-only configs throw through untouched. Construction runs
        // in a nonisolated static so no self access precedes full init.
        let handles: NativeHandles
        let effective: LlamaConfigSwift
        let firstError: Error?
        do {
            handles = try Self.construct(config: config)
            effective = config
            firstError = nil
        } catch {
            guard config.gpuLayers > 0 else { throw error }
            let cpuConfig = config.cpuFallback
            handles = try Self.construct(config: cpuConfig)
            effective = cpuConfig
            firstError = error
        }
        self.config = effective
        self.model = handles.model
        self.vocabulary = handles.vocabulary
        self.context = handles.context
        self.mtmdCtx = handles.mtmdCtx
        self.eosTokenID = handles.eosTokenID
        self.isBackendInitialized = true
        // Parse the artefact's own template once per load: it owns prompt
        // rendering and the reply parser for every turn.
        if effective.chatTemplateName == nil {
            self.chatTemplates = LlamaChatTemplates(model: handles.model)
        }
        if let firstError {
            logger.error("Metal GPU init failed, running CPU-only: \(firstError.localizedDescription, privacy: .public)")
        }
        if effective.mmprojPath != nil {
            logger.info("Multimodal context initialized")
        }
        logger.info("Model loaded: \(effective.modelPath, privacy: .public) ctx=\(effective.contextLength) threads=\(effective.threadCount) gpu=\(effective.gpuLayers)")
    }

    /// One native construction attempt; frees the backend on failure.
    private nonisolated static func construct(config: LlamaConfigSwift) throws -> NativeHandles {
        llama_backend_init()

        // Load model.
        var modelParams = llama_model_default_params()
        modelParams.load_mode = config.useMmap ? LLAMA_LOAD_MODE_MMAP : LLAMA_LOAD_MODE_NONE
        modelParams.n_gpu_layers = Int32(config.gpuLayers)

        guard let loadedModel = llama_model_load_from_file(config.modelPath, modelParams) else {
            llama_backend_free()
            throw LlamaError.modelLoadFailed(path: config.modelPath)
        }
        guard let vocab = llama_model_get_vocab(loadedModel) else {
            llama_model_free(loadedModel)
            llama_backend_free()
            throw LlamaError.modelLoadFailed(path: config.modelPath)
        }
        let eos = llama_vocab_eos(vocab)

        // Create context.
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(config.contextLength)
        ctxParams.n_batch = UInt32(config.batchSize)
        ctxParams.n_ubatch = UInt32(config.microBatchSize)
        ctxParams.n_threads = Int32(config.threadCount)
        ctxParams.n_threads_batch = Int32(config.threadCount)
        ctxParams.flash_attn_type = config.f16KV ? LLAMA_FLASH_ATTN_TYPE_ENABLED : LLAMA_FLASH_ATTN_TYPE_DISABLED

        guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            llama_backend_free()
            throw LlamaError.contextCreationFailed
        }

        // Initialize multimodal context if mmprojPath is provided.
        var mtmdCtx: OpaquePointer?
        if let mmprojPath = config.mmprojPath {
            var mtmdParams = mtmd_context_params_default()
            mtmdParams.n_threads = Int32(config.threadCount)
            mtmdParams.use_gpu = config.gpuLayers > 0
            mtmdCtx = mtmd_init_from_file(mmprojPath, loadedModel, mtmdParams)
            guard mtmdCtx != nil else {
                llama_free(ctx)
                llama_model_free(loadedModel)
                llama_backend_free()
                throw LlamaError.projectorInitializationFailed
            }
        }

        return NativeHandles(
            model: loadedModel,
            vocabulary: vocab,
            context: ctx,
            mtmdCtx: mtmdCtx,
            eosTokenID: eos
        )
    }

    /// Constructed native handles. Matches the engine's stored properties.
    private struct NativeHandles {
        let model: OpaquePointer
        let vocabulary: OpaquePointer
        let context: OpaquePointer
        let mtmdCtx: OpaquePointer?
        let eosTokenID: llama_token
    }

    deinit {
        // Destruction cannot race actor work because in-flight tasks retain the engine.
        // Use the same idempotent pointer-nulling primitive as explicit unload.
        Self.releaseNativeResources(
            mtmdCtx: &mtmdCtx,
            context: &context,
            model: &model,
            vocabulary: &vocabulary,
            isBackendInitialized: &isBackendInitialized
        )
    }

    // MARK: - Load Verification

    /// One-token preflight decode. Native construction can succeed while the first
    /// decode fails — the known upstream class is a fatal Metal OOM that still
    /// reports "model loaded", after which every request fails. Running this before
    /// the service commits the load makes a dead-on-arrival model fail where refusal
    /// copy lives. The KV state is cleared afterwards so the first real turn starts
    /// from the same empty state as before.
    public func verifyLoad() throws {
        guard let ctx = context, let vocab = vocabulary else {
            throw LlamaError.modelNotLoaded
        }

        let tokens = try tokenize(
            prompt: Self.preflightPrompt,
            addBos: true,
            parseSpecial: false,
            vocab: vocab
        )
        guard !tokens.isEmpty else { throw LlamaError.tokenizationFailed }

        let memory = llama_get_memory(ctx)
        llama_memory_clear(memory, true)

        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        for (index, token) in tokens.enumerated() {
            batch.token[index] = token
            batch.pos[index] = Int32(index)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]![0] = 0
            batch.logits[index] = index == tokens.count - 1 ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)
        guard llama_decode(ctx, batch) == 0 else { throw LlamaError.decodeFailed }

        // Sample one token so the output path runs too. The token is discarded.
        guard let sampler = llama_sampler_init_greedy() else {
            throw LlamaError.samplerCreationFailed
        }
        defer { llama_sampler_free(sampler) }
        _ = llama_sampler_sample(sampler, ctx, -1)

        llama_memory_clear(memory, true)
    }

    /// Short, ASCII-only, no special tokens: tokenizes under every tokenizer.
    static let preflightPrompt = "ok"

    // MARK: - Unload

    public func unload() {
        unloadSync()
    }

    private func unloadSync() {
        // The template set is only valid for the model that produced it.
        chatTemplates = nil
        Self.releaseNativeResources(
            mtmdCtx: &mtmdCtx,
            context: &context,
            model: &model,
            vocabulary: &vocabulary,
            isBackendInitialized: &isBackendInitialized
        )
        logger.info("Model unloaded")
    }

    private nonisolated static func releaseNativeResources(
        mtmdCtx: inout OpaquePointer?,
        context: inout OpaquePointer?,
        model: inout OpaquePointer?,
        vocabulary: inout OpaquePointer?,
        isBackendInitialized: inout Bool
    ) {
        if let mctx = mtmdCtx {
            mtmd_free(mctx)
            mtmdCtx = nil
        }
        if let ctx = context {
            llama_free(ctx)
            context = nil
        }
        if let mdl = model {
            llama_model_free(mdl)
            model = nil
        }
        vocabulary = nil
        if isBackendInitialized {
            llama_backend_free()
            isBackendInitialized = false
        }
    }

}

extension LlamaEngine {
    // MARK: - Streaming Completion

    public func streamCompletion(
        prompt: String,
        addBos: Bool?,
        parseSpecial: Bool = false,
        stopStrings: [String],
        sampling: SamplingConfigSwift
    ) throws -> AsyncThrowingStream<String, Error> {
        try streamCompletion(
            prompt: prompt,
            splitter: nil,
            addBos: addBos,
            parseSpecial: parseSpecial,
            stopStrings: stopStrings,
            sampling: sampling
        )
    }

    /// Shared body: `splitter` decides whether raw text becomes visible content
    /// through the runtime's reply parser or is emitted verbatim.
    func streamCompletion(
        prompt: String,
        splitter: ReplySplitter?,
        addBos: Bool?,
        parseSpecial: Bool,
        stopStrings: [String],
        sampling: SamplingConfigSwift
    ) throws -> AsyncThrowingStream<String, Error> {
        guard let ctx = context, let vocab = vocabulary else {
            throw LlamaError.modelNotLoaded
        }

        beginGenerationScope()

        return AsyncThrowingStream<String, Error> { continuation in
            // Consumer termination (task cancelled, stream dropped) must stop
            // the producer at the next token boundary instead of decoding on.
            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
            Task {
                do {
                    // Tokenize prompt.
                    let tokens = try tokenize(
                        prompt: prompt,
                        addBos: addBos,
                        parseSpecial: parseSpecial,
                        vocab: vocab
                    )
                    guard !tokens.isEmpty else {
                        throw LlamaError.tokenizationFailed
                    }

                    // P3 context-window preflight: sliding-window truncation
                    // keeps the instruction prefix + recent tail that fits
                    // alongside the generation reserve. Counts are public;
                    // prompt content never leaves the device logs.
                    let preflight = Self.truncatedPromptTokens(
                        tokens,
                        contextLength: config.contextLength,
                        maxTokens: sampling.maxTokens
                    )
                    if preflight.didTruncate {
                        let promptCount = tokens.count
                        let keptCount = preflight.tokens.count
                        let ctxSize = self.config.contextLength
                        logger.fault("Prompt truncated promptTokens=\(promptCount, privacy: .public) kept=\(keptCount, privacy: .public) ctx=\(ctxSize, privacy: .public)")
                    }
                    let promptTokens = preflight.tokens

                    // Clear memory.
                    let mem = llama_get_memory(ctx)
                    llama_memory_clear(mem, true)

                    // Bound logical prompt batches; llama.cpp further splits these at n_ubatch.
                    for range in try Self.promptBatchRanges(
                        tokenCount: promptTokens.count,
                        batchSize: config.batchSize
                    ) {
                        var batch = llama_batch_init(Int32(range.count), 0, 1)
                        for (localIndex, tokenIndex) in range.enumerated() {
                            batch.token[localIndex] = promptTokens[tokenIndex]
                            batch.pos[localIndex] = Int32(tokenIndex)
                            batch.n_seq_id[localIndex] = 1
                            batch.seq_id[localIndex]![0] = 0
                            batch.logits[localIndex] = tokenIndex == promptTokens.count - 1 ? 1 : 0
                        }
                        batch.n_tokens = Int32(range.count)
                        let decodeResult = llama_decode(ctx, batch)
                        llama_batch_free(batch)
                        guard decodeResult == 0 else { throw LlamaError.decodeFailed }
                    }

                    // Create sampler chain.
                    let sampler = try createSamplerChain(sampling: sampling, vocab: vocab)
                    defer { llama_sampler_free(sampler) }

                    // Generate tokens using shared generation loop.
                    let termination = try await generateTokens(
                        startPos: Int32(promptTokens.count), sampler: sampler, vocab: vocab,
                        stopStrings: stopStrings, sampling: sampling,
                        splitter: splitter, continuation: continuation
                    )
                    Self.logReasoning(splitter, termination: String(describing: termination), logger: logger)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Streaming Vision Completion

    /// Stream a vision chat after applying the model's embedded chat template.
    /// Image markers must already be present in the appropriate message content.
    public func streamVisionChatCompletion(
        messages: [(role: String, content: String)],
        images: [Data],
        addBos: Bool?,
        stopStrings: [String],
        sampling: SamplingConfigSwift
    ) throws -> AsyncThrowingStream<String, Error> {
        let prompt = applyChatTemplate(
            messages: messages,
            model: model,
            addAssistant: true,
            templateName: config.chatTemplateName
        )
        guard !prompt.isEmpty else {
            throw LlamaError.tokenizationFailed
        }
        logger.info("Vision chat template applied, prompt length: \(prompt.count, privacy: .public)")
        return try streamVisionCompletion(
            prompt: prompt,
            images: images,
            addBos: addBos,
            stopStrings: stopStrings,
            sampling: sampling
        )
    }

    public func streamVisionCompletion(
        prompt: String,
        images: [Data],
        addBos: Bool?,
        stopStrings: [String],
        sampling: SamplingConfigSwift
    ) throws -> AsyncThrowingStream<String, Error> {
        guard let ctx = context, let vocab = vocabulary else {
            throw LlamaError.modelNotLoaded
        }
        guard let mCtx = mtmdCtx else {
            throw LlamaError.visionNotSupported
        }

        beginGenerationScope()

        return AsyncThrowingStream<String, Error> { continuation in
            // Consumer termination (task cancelled, stream dropped) must stop
            // the producer at the next token boundary instead of decoding on.
            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
            Task {
                do {
                    // Create bitmaps from image data.
                    var bitmaps: [OpaquePointer?] = []
                    defer {
                        for bitmapPtr in bitmaps {
                            if let bmp = bitmapPtr { mtmd_bitmap_free(bmp) }
                        }
                    }

                    for imageData in images {
                        var wrapper = mtmd_helper_bitmap_wrapper(bitmap: nil, video_ctx: nil)
                        imageData.withUnsafeBytes { rawPtr in
                            if let addr = rawPtr.baseAddress {
                                wrapper = mtmd_helper_bitmap_init_from_buf(
                                    mCtx,
                                    addr.assumingMemoryBound(to: UInt8.self),
                                    imageData.count,
                                    false,
                                    mtmd_helper_init_opt_default()
                                )
                            }
                        }
                        guard let bitmap = wrapper.bitmap else {
                            throw LlamaError.visionImageLoadFailed
                        }
                        bitmaps.append(bitmap)
                    }

                    // Build input text struct.
                    var inputText = mtmd_input_text(
                        text: nil,
                        text_len: 0,
                        add_special: addBos ?? true,
                        parse_special: true
                    )

                    // Create input chunks.
                    guard let chunks = mtmd_input_chunks_init() else {
                        throw LlamaError.tokenizationFailed
                    }
                    defer { mtmd_input_chunks_free(chunks) }

                    // Tokenize prompt with image markers.
                    var bitmapPtrs = bitmaps
                    let tokenizeResult = prompt.withCString { cstr in
                        inputText.text = cstr
                        inputText.text_len = prompt.utf8.count
                        return bitmapPtrs.withUnsafeMutableBufferPointer { bufPtr in
                            mtmd_tokenize(mCtx, chunks, &inputText, bufPtr.baseAddress, images.count)
                        }
                    }

                    guard tokenizeResult == 0 else {
                        throw LlamaError.tokenizationFailed
                    }

                    // Pre-eval preflight: eval_chunks -> llama_decode -> ggml_abort
                    // (SIGABRT, uncatchable) on n_ctx overflow. Fail closed here.
                    // ponytail: no downscale/per-chunk loop without token-census evidence.
                    let chunkPositions = Int(mtmd_helper_get_n_pos(chunks))
                    Self.lastVisionChunkPositions = chunkPositions
                    print("[VISION-BUDGET] n_pos=\(chunkPositions) ctx=\(config.contextLength) maxTokens=\(sampling.maxTokens)")
                    if !Self.visionPrefixFits(chunkPositions: chunkPositions, contextLength: config.contextLength, maxTokens: sampling.maxTokens) {
                        logger.fault("Vision prefix exceeds context window nPos=\(chunkPositions, privacy: .public) ctx=\(self.config.contextLength, privacy: .public)")
                        throw LlamaError.contextWindowExceeded
                    }

                    // Clear KV memory.
                    let mem = llama_get_memory(ctx)
                    llama_memory_clear(mem, true)

                    // Evaluate all chunks (text + image embeddings).
                    var newNPast: llama_pos = 0
                    let evalResult = mtmd_helper_eval_chunks(
                        mCtx,
                        ctx,
                        chunks,
                        0,                           // n_past = 0 (fresh start)
                        0,                           // seq_id = 0
                        Int32(config.batchSize),      // configured logical n_batch
                        true,                        // logits_last = true
                        &newNPast
                    )

                    guard evalResult == 0 else {
                        throw LlamaError.decodeFailed
                    }

                    // P3 vision preflight: no token array to sliding-window,
                    // so fail closed when the evaluated prefix already fills
                    // the window instead of spinning a zero-step loop.
                    if newNPast >= Int32(config.contextLength) {
                        logger.fault("Vision prefix exceeds context window nPast=\(newNPast, privacy: .public) ctx=\(self.config.contextLength, privacy: .public)")
                        throw LlamaError.contextWindowExceeded
                    }

                    // Create sampler chain.
                    let sampler = try createSamplerChain(sampling: sampling, vocab: vocab)
                    defer { llama_sampler_free(sampler) }

                    // Generate tokens using shared generation loop.
                    _ = try await generateTokens(
                        startPos: newNPast, sampler: sampler, vocab: vocab,
                        stopStrings: stopStrings, sampling: sampling,
                        splitter: nil, continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Cancellation

    /// Nonisolated so cancellation lands while the synchronous decode loop
    /// monopolizes this actor. Idempotent; safe to call from any thread.
    public nonisolated func cancel() {
        cancelFlag.withLock { $0 = true }
    }

    /// Opens a fresh generation scope: any cancel recorded before this stream
    /// started is dropped so it cannot kill the new generation. Called on the
    /// actor at stream start; the decode loop cannot have begun yet.
    private func beginGenerationScope() {
        cancelFlag.withLock { $0 = false }
    }

    private var isGenerationCancelled: Bool {
        cancelFlag.withLock { $0 }
    }

    public nonisolated static func promptBatchRanges(
        tokenCount: Int,
        batchSize: Int
    ) throws -> [Range<Int>] {
        guard tokenCount >= 0, batchSize > 0 else { throw LlamaError.invalidConfiguration }
        return stride(from: 0, to: tokenCount, by: batchSize).map {
            $0..<min($0 + batchSize, tokenCount)
        }
    }
}

private extension LlamaEngine {
    // MARK: - Sampler Chain

    private func createSamplerChain(
        sampling: SamplingConfigSwift,
        vocab: OpaquePointer
    ) throws -> UnsafeMutablePointer<llama_sampler> {
        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else {
            throw LlamaError.samplerCreationFailed
        }

        // P3: penalty parameters are shared by both paths. A repeat of 1.0
        // with zero freq/presence (or N == 0) is a no-op — skip the sampler
        // so the chain stays minimal.
        func appendPenaltiesIfNeeded() {
            guard let params = Self.penaltyChainParameters(for: sampling) else { return }
            let penalty = llama_sampler_init_penalties(
                llama_vocab_n_tokens(vocab),
                params.lastN,
                params.repeatPenalty,
                params.frequencyPenalty,
                params.presencePenalty
            )
            llama_sampler_chain_add(chain, penalty)
        }

        if sampling.temperature == 0 {
            // Greedy decoding (penalties still apply — they shape logits
            // before the argmax, preventing greedy loops).
            appendPenaltiesIfNeeded()
            let greedy = llama_sampler_init_greedy()
            llama_sampler_chain_add(chain, greedy)
        } else {
            // Top-K.
            if sampling.topK > 0 {
                let topK = llama_sampler_init_top_k(Int32(sampling.topK))
                llama_sampler_chain_add(chain, topK)
            }

            // Top-P (nucleus sampling).
            if sampling.topP < 1.0 {
                let topP = llama_sampler_init_top_p(sampling.topP, 1)
                llama_sampler_chain_add(chain, topP)
            }

            // Temperature.
            let temp = llama_sampler_init_temp(sampling.temperature)
            llama_sampler_chain_add(chain, temp)

            // Repeat/frequency/presence penalties (prevents looping).
            appendPenaltiesIfNeeded()

            // Distribution sampling (random from remaining candidates).
            let dist = llama_sampler_init_dist(0)
            llama_sampler_chain_add(chain, dist)
        }

        return chain
    }

    // MARK: - P3 Pure Helpers (hermetic, no native calls)

    /// Penalty sampler parameters. Nil means "no penalty sampler".
    public struct PenaltyParameters: Sendable, Equatable {
        public let lastN: Int32
        public let repeatPenalty: Float
        public let frequencyPenalty: Float
        public let presencePenalty: Float
    }

    /// Penalty params, or nil when all penalties are disabled.
    public nonisolated static func penaltyChainParameters(
        for sampling: SamplingConfigSwift
    ) -> PenaltyParameters? {
        guard sampling.penaltyLastN != 0 else { return nil }
        let hasRepeat = sampling.repeatPenalty != 1.0
        let hasFreq = sampling.frequencyPenalty != 0.0
        let hasPresence = sampling.presencePenalty != 0.0
        guard hasRepeat || hasFreq || hasPresence else { return nil }
        return PenaltyParameters(
            lastN: Int32(max(0, sampling.penaltyLastN)),
            repeatPenalty: sampling.repeatPenalty,
            frequencyPenalty: sampling.frequencyPenalty,
            presencePenalty: sampling.presencePenalty
        )
    }

    /// True when `buffer` ends with a strict prefix of any stop string.
    public nonisolated static func isPotentialStopPrefix(
        _ buffer: String,
        stopStrings: [String]
    ) -> Bool {
        guard !buffer.isEmpty else { return false }
        for stop in stopStrings where !stop.isEmpty {
            // Full buffer shorter than stop: classic prefix case.
            if stop.hasPrefix(buffer) { return true }
            // Buffer longer than stop: check whether any suffix of the
            // buffer is a prefix of the stop (partial stop at the tail).
            let maxOverlap = min(buffer.count, stop.count - 1)
            guard maxOverlap > 0 else { continue }
            for length in 1...maxOverlap {
                if stop.hasPrefix(String(buffer.suffix(length))) { return true }
            }
        }
        return false
    }

    /// Tail-flush gate: never emit a buffer that could still become a stop.
    public nonisolated static func shouldFlushTail(
        _ buffer: String,
        stopStrings: [String]
    ) -> Bool {
        guard !buffer.isEmpty else { return false }
        return !isPotentialStopPrefix(buffer, stopStrings: stopStrings)
    }

    /// Sliding-window truncation for an over-long prompt. Keeps the first
    /// `keepPrefix` tokens (system/instruction anchor) plus the most recent
    /// tail that fits alongside the generation reserve. Pure for tests.
    public nonisolated static func truncatedPromptTokens(
        _ tokens: [llama_token],
        contextLength: Int,
        maxTokens: Int,
        keepPrefix: Int = 256
    ) -> (tokens: [llama_token], didTruncate: Bool) {
        let reserve = max(1, maxTokens)
        let capacity = contextLength - reserve - 1
        guard capacity > 0, tokens.count > capacity else {
            return (tokens, false)
        }
        let prefix = min(max(0, keepPrefix), capacity / 2, tokens.count)
        let tailCount = max(0, capacity - prefix)
        let kept = Array(tokens.prefix(prefix)) + Array(tokens.suffix(tailCount))
        return (kept, true)
    }

    /// Vision preflight: true when chunk positions + generation reserve fit n_ctx.
    /// Callers pass n_pos (M-RoPE-aware), not n_tokens. Pure for tests.
    public nonisolated static func visionPrefixFits(chunkPositions: Int, contextLength: Int, maxTokens: Int) -> Bool {
        chunkPositions + max(1, maxTokens) + 1 <= contextLength
    }

    // Conservative gate: fitted census math (441 positions fits 512) APPROVED
    // a 1024px image that SIGABRTd in eval — positions-predict-safety is
    // falsified. Cap to visionSafeMaxPixels; refuse only when history alone
    // fills the window. `visionPrefixFits` stays the backstop.
    /// Safe long edge: 512px fixtures pass, 1024px aborts; SPEC-typical input.
    /// UNMEASURED: the device threshold phase produced no artifacts (phone
    /// locked, run blocked pre-probe), so this stays conservative. Device
    /// phase raises with proof.
    public nonisolated static let visionSafeMaxPixels = 512
    /// Silent-downscale floor: a downscale whose short edge stays at/above
    /// this attaches without asking; below it (panorama slivers) the attach
    /// offers a choice instead of silently degrading to a thumbnail.
    public nonisolated static let visionUsefulMinPixels = 256
    private nonisolated static let visionMarkerTokens = 3
    /// Token margin: chars/4 noise + template drift.
    /// Named constant, test-overridable per call only.
    public nonisolated static let visionTokenMargin = 64
    /// Last observed mtmd n_pos (M-RoPE-aware chunk positions) from a vision eval.
    /// Updated on every vision eval (success or preflight refusal); read by the
    /// DEBUG-only budget-proof harness. Starts at 0 (no eval yet this launch).
    public nonisolated(unsafe) static var lastVisionChunkPositions: Int = 0

    /// Typed attach outcome for UI. Pure for tests.
    public enum VisionGateResult: Equatable, Sendable {
        case fits, downscaledTo(width: Int, height: Int), refused(reason: VisionGateReason)
    }
    public enum VisionGateReason: Equatable, Sendable { case historyTooHeavy, invalidDimensions }

    /// One image: refuse when history alone fills the window or dims are
    /// invalid; downscale over-safe long edges TO safe (aspect-preserved,
    /// never upscaled). Multi-image callers divide first and gate one here.
    public nonisolated static func visionGate(imageWidth: Int, imageHeight: Int, promptTokens: Int, contextLength: Int, maxTokens: Int, margin: Int = visionTokenMargin) -> VisionGateResult {
        guard imageWidth > 0, imageHeight > 0 else { return .refused(reason: .invalidDimensions) }
        guard contextLength - promptTokens - max(1, maxTokens) - 1 - margin > visionMarkerTokens else { return .refused(reason: .historyTooHeavy) }
        let longEdge = max(imageWidth, imageHeight)
        guard longEdge > visionSafeMaxPixels else { return .fits }
        let safe = visionSafeDownscale(imageWidth: imageWidth, imageHeight: imageHeight)
        return .downscaledTo(width: safe.width, height: safe.height)
    }

    /// Single admission decision (sibling-split + gate) shared by attach-
    /// time and send-time callers. `promptTokens` is raw history; `imageCount`
    /// includes the candidate. Pure for tests.
    public nonisolated static func admit(
        imageWidth: Int, imageHeight: Int, promptTokens: Int, imageCount: Int,
        contextLength: Int, maxTokens: Int, margin: Int = visionTokenMargin
    ) -> VisionGateResult {
        let adjusted = adjustedVisionPromptTokens(
            promptTokens: promptTokens, contextLength: contextLength,
            maxTokens: maxTokens, imageCount: imageCount)
        return visionGate(
            imageWidth: imageWidth, imageHeight: imageHeight, promptTokens: adjusted,
            contextLength: contextLength, maxTokens: maxTokens, margin: margin)
    }

    /// Sibling-split budget: single owner for budget math (margin and marker
    /// tokens live here with the gate). Pure for tests.
    public nonisolated static func adjustedVisionPromptTokens(promptTokens: Int, contextLength: Int, maxTokens: Int, imageCount: Int) -> Int {
        let count = max(1, imageCount)
        let reserve = max(1, maxTokens)
        let available = contextLength - promptTokens - reserve - 1 - visionTokenMargin - 3
        let perImage = (available - 3 * count) / count
        return contextLength - reserve - 1 - visionTokenMargin - 3 - perImage
    }

    /// Aspect-preserved fit of valid dims to the safe long edge. Never
    /// upscales; shared by the gate and the refused-path choice offer so the
    /// "smaller version" copy cannot diverge from gate math.
    public nonisolated static func visionSafeDownscale(imageWidth: Int, imageHeight: Int) -> (width: Int, height: Int) {
        let scale = min(1.0, Double(visionSafeMaxPixels) / Double(max(imageWidth, imageHeight)))
        return (
            width: max(1, Int((Double(imageWidth) * scale).rounded(.down))),
            height: max(1, Int((Double(imageHeight) * scale).rounded(.down)))
        )
    }

    /// Compat (DEBUG harness): gate as an optional target size. Never upscales.
    public nonisolated static func visionTargetSize(imageWidth: Int, imageHeight: Int, promptTokens: Int, contextLength: Int, maxTokens: Int, margin: Int = visionTokenMargin
    ) -> (width: Int, height: Int)? {
        switch visionGate(imageWidth: imageWidth, imageHeight: imageHeight, promptTokens: promptTokens, contextLength: contextLength, maxTokens: maxTokens, margin: margin) {
        case .fits: return (imageWidth, imageHeight)
        case .downscaledTo(let outWidth, let outHeight): return (outWidth, outHeight)
        case .refused: return nil
        }
    }

    // MARK: - Tokenization

    private func tokenize(
        prompt: String,
        addBos: Bool?,
        parseSpecial: Bool,
        vocab: OpaquePointer
    ) throws -> [llama_token] {
        let utf8 = Array(prompt.utf8)
        guard !utf8.isEmpty, utf8.count <= Int(Int32.max) else {
            throw LlamaError.tokenizationFailed
        }
        let shouldAddBos = addBos ?? true

        return try utf8.withUnsafeBufferPointer { bytes in
            guard let baseAddress = bytes.baseAddress else { throw LlamaError.tokenizationFailed }
            let text = UnsafeRawPointer(baseAddress).assumingMemoryBound(to: CChar.self)
            let required = llama_tokenize(
                vocab,
                text,
                Int32(bytes.count),
                nil,
                0,
                shouldAddBos,
                parseSpecial
            )
            guard required < 0, required != Int32.min else {
                throw LlamaError.tokenizationFailed
            }

            let capacity = Int(-required)
            var tokens = [llama_token](repeating: 0, count: capacity)
            let count = tokens.withUnsafeMutableBufferPointer { tokenBuffer in
                llama_tokenize(
                    vocab,
                    text,
                    Int32(bytes.count),
                    tokenBuffer.baseAddress,
                    Int32(capacity),
                    shouldAddBos,
                    parseSpecial
                )
            }
            guard count > 0, count <= Int32(capacity) else {
                throw LlamaError.tokenizationFailed
            }
            return Array(tokens.prefix(Int(count)))
        }
    }

    // MARK: - Token to Text

    private func tokenToText(token: llama_token, vocab: OpaquePointer) -> String {
        let bufferSize = 256
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let nChars = llama_token_to_piece(vocab, token, &buffer, Int32(bufferSize), 0, false)
        guard nChars > 0 else { return "" }
        return buffer.prefix(Int(nChars)).withUnsafeBufferPointer { ptr in
            String(cString: ptr.baseAddress!)
        }
    }

    // MARK: - Shared Generation Loop

    /// How the shared generation loop terminated. Surfaced for logging and
    /// tests; the stream itself just ends (callers map contextFull to the
    /// UI-level truncated reason where appropriate).
    enum GenerationTermination: Sendable, Equatable {
        case completed
        case stoppedOnString
        case maxTokens
        case contextFull
        case cancelled
    }

    /// Shared autoregressive generation loop used by both text and vision streaming.
    ///
    /// `splitter` (present only on the jinja chat path) turns raw decoded text into
    /// visible content using the template's reply parser: reasoning is separated by
    /// the runtime, never by slicing markup out of the reply here.
    private func generateTokens(
        startPos: llama_pos,
        sampler: UnsafeMutablePointer<llama_sampler>,
        vocab: OpaquePointer,
        stopStrings: [String],
        sampling: SamplingConfigSwift,
        splitter: ReplySplitter?,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> GenerationTermination {
        guard let ctx = context else { throw LlamaError.modelNotLoaded }

        var nPos = startPos
        var pendingBuffer = ""
        var nGenerated = 0
        let maxTokens = sampling.maxTokens > 0 ? sampling.maxTokens : 2048
        var termination: GenerationTermination = .completed

        while true {
            if isGenerationCancelled || Task.isCancelled {
                termination = .cancelled
                break
            }
            if nGenerated >= maxTokens {
                termination = .maxTokens
                break
            }
            if nPos >= Int32(config.contextLength) {
                termination = .contextFull
                break
            }
            // P3 perf: cooperative yield outside the native decode call so
            // the actor stays responsive during long synchronous generations.
            if nGenerated > 0, nGenerated % 16 == 0 {
                await Task.yield()
            }

            let newTokenID = llama_sampler_sample(sampler, ctx, -1)
            // P3 multi-EOS: any end-of-generation token (EOS, EOT, etc.)
            // terminates — not just the single cached EOS id.
            if newTokenID == self.eosTokenID || llama_vocab_is_eog(vocab, newTokenID) {
                termination = .completed
                break
            }

            let tokenText = tokenToText(token: newTokenID, vocab: vocab)
            pendingBuffer += tokenText

            // Check stop strings.
            var shouldStop = false
            for stop in stopStrings where !stop.isEmpty {
                if pendingBuffer.hasSuffix(stop) {
                    let clean = String(pendingBuffer.dropLast(stop.count))
                    emit(clean, splitter: splitter, continuation: continuation)
                    pendingBuffer = ""
                    shouldStop = true
                    break
                }
            }
            if shouldStop {
                termination = .stoppedOnString
                break
            }

            // Withhold buffers that could still grow into a stop string
            // (suffix-prefix overlap, not just full-buffer prefix).
            if !Self.isPotentialStopPrefix(pendingBuffer, stopStrings: stopStrings) {
                emit(pendingBuffer, splitter: splitter, continuation: continuation)
                pendingBuffer = ""
            }

            // Evaluate single token.
            var evalBatch = llama_batch_init(1, 0, 1)
            evalBatch.token[0] = newTokenID
            evalBatch.pos[0] = nPos
            evalBatch.n_seq_id[0] = 1
            evalBatch.seq_id[0]![0] = 0
            evalBatch.logits[0] = 1
            evalBatch.n_tokens = 1

            if llama_decode(ctx, evalBatch) != 0 {
                llama_batch_free(evalBatch)
                throw LlamaError.decodeFailed
            }
            llama_batch_free(evalBatch)
            nPos += 1
            nGenerated += 1
        }

        // P3: never flush a partial-stop prefix on maxTokens/n_ctx/cancel —
        // it is an artifact of withholding, not user-visible text.
        if Self.shouldFlushTail(pendingBuffer, stopStrings: stopStrings) {
            emit(pendingBuffer, splitter: splitter, continuation: continuation)
        }
        // Close the reply so a trailing open block resolves: the parser withholds
        // partial content until it knows the block ended.
        if let trailing = splitter?.finish(), !trailing.isEmpty {
            continuation.yield(trailing)
        }
        if termination == .contextFull {
            logger.fault("Generation hit context window nPos=\(nPos, privacy: .public) ctx=\(self.config.contextLength, privacy: .public)")
        }
        return termination
    }

    /// Route one decoded piece to the consumer. Without a splitter the text is
    /// the answer; with one, only the parser's content is.
    private func emit(
        _ text: String,
        splitter: ReplySplitter?,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        guard !text.isEmpty else { return }
        guard let splitter else {
            continuation.yield(text)
            return
        }
        if let visible = splitter.append(text), !visible.isEmpty {
            continuation.yield(visible)
        }
    }

}
