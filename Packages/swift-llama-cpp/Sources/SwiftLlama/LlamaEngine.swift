// LlamaEngine.swift
// SwiftLlama — Swift wrapper for llama.cpp b9821
//
// Actor-isolated engine wrapping the llama.cpp C API.
// All C API calls are isolated to this actor for thread safety.
// Targets upstream release b9821 — sampler chain API, memory API.

import Foundation
import llama
import os

// MARK: - Llama Engine

/// The core engine wrapping llama.cpp. Actor-isolated for thread safety.
public actor LlamaEngine {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "llama-engine")

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocabulary: OpaquePointer?
    private var mtmdCtx: OpaquePointer?
    private let config: LlamaConfigSwift
    /// Nonisolated cancellation flag. The decode loop is fully synchronous, so
    /// an actor-isolated flag could only be observed by work queued *behind*
    /// the entire generation — `cancel()` would be a no-op until it finished.
    /// A lock-protected flag lets cancellation reach the loop at the next token
    /// boundary. Reset at stream start (never at end) so a stale cancel cannot
    /// kill a subsequent generation.
    private let cancelFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var eosTokenID: llama_token = -1
    private var isBackendInitialized = false

    // MARK: - Initialization

    public init(config: LlamaConfigSwift) throws {
        self.config = config

        llama_backend_init()
        isBackendInitialized = true

        // Load model.
        var modelParams = llama_model_default_params()
        modelParams.use_mmap = config.useMmap
        modelParams.n_gpu_layers = Int32(config.gpuLayers)

        guard let loadedModel = llama_model_load_from_file(config.modelPath, modelParams) else {
            llama_backend_free()
            isBackendInitialized = false
            throw LlamaError.modelLoadFailed(path: config.modelPath)
        }
        model = loadedModel
        vocabulary = llama_model_get_vocab(loadedModel)

        guard let vocab = vocabulary else {
            llama_model_free(loadedModel)
            model = nil
            llama_backend_free()
            isBackendInitialized = false
            throw LlamaError.modelLoadFailed(path: config.modelPath)
        }
        eosTokenID = llama_vocab_eos(vocab)

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
            model = nil
            llama_backend_free()
            isBackendInitialized = false
            throw LlamaError.contextCreationFailed
        }
        context = ctx

        // Initialize multimodal context if mmprojPath is provided.
        if let mmprojPath = config.mmprojPath {
            var mtmdParams = mtmd_context_params_default()
            mtmdParams.n_threads = Int32(config.threadCount)
            mtmdParams.use_gpu = false  // CPU-only for v1
            mtmdCtx = mtmd_init_from_file(mmprojPath, loadedModel, mtmdParams)
            guard mtmdCtx != nil else {
                llama_free(ctx)
                context = nil
                llama_model_free(loadedModel)
                model = nil
                vocabulary = nil
                llama_backend_free()
                isBackendInitialized = false
                throw LlamaError.projectorInitializationFailed
            }
            logger.info("Multimodal context initialized")
        }

        logger.info("Model loaded: \(config.modelPath, privacy: .public) ctx=\(config.contextLength) threads=\(config.threadCount)")
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

    // MARK: - Unload

    public func unload() {
        unloadSync()
    }

    private func unloadSync() {
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
    // MARK: - Chat Template Formatting

    /// Apply the model's built-in chat template to format messages.
    /// Uses llama_chat_apply_template which auto-detects the template from the model.
    /// Pass nil as tmpl to use the model's own template.
    public func applyChatTemplate(
        messages: [(role: String, content: String)],
        model: OpaquePointer?,
        addAssistant: Bool = true
    ) -> String {
        guard let model, let template = llama_model_chat_template(model, nil) else {
            return ""
        }

        // Own every C string for the complete native call. Passing Swift String
        // conversions directly would leave dangling pointers in this array.
        let roles = messages.map { strdup($0.role) }
        let contents = messages.map { strdup($0.content) }
        defer {
            roles.forEach { free($0) }
            contents.forEach { free($0) }
        }
        guard !roles.contains(where: { $0 == nil }),
              !contents.contains(where: { $0 == nil }) else { return "" }
        let chatMessages = messages.indices.map { index in
            llama_chat_message(role: roles[index], content: contents[index])
        }

        // Calculate buffer size: 2x total characters of all messages.
        let totalChars = messages.reduce(0) { $0 + $1.content.count + $1.role.count + 10 }
        let bufferSize = max(totalChars * 2, 1024)

        let formatted = chatMessages.withUnsafeBufferPointer { ptr -> String in
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let nBytes = llama_chat_apply_template(
                template, ptr.baseAddress, chatMessages.count,
                addAssistant, &buffer, Int32(bufferSize)
            )
            if nBytes > 0 && nBytes <= Int32(bufferSize) {
                return String(
                    decoding: buffer.prefix(Int(nBytes)).map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
            }
            // If buffer too small, retry with larger buffer.
            if nBytes > Int32(bufferSize) {
                let largerSize = Int(nBytes) + 1
                var largerBuffer = [CChar](repeating: 0, count: largerSize)
                let nBytes2 = llama_chat_apply_template(
                    template, ptr.baseAddress, chatMessages.count,
                    addAssistant, &largerBuffer, Int32(largerSize)
                )
                if nBytes2 > 0 && nBytes2 <= Int32(largerSize) {
                    return String(
                        decoding: largerBuffer.prefix(Int(nBytes2)).map { UInt8(bitPattern: $0) },
                        as: UTF8.self
                    )
                }
            }
            // Fallback: empty string (will cause tokenization to fail).
            return ""
        }

        return formatted
    }

    // MARK: - Streaming Chat Completion (with template)

    /// Stream a chat completion, applying the model's built-in chat template.
    /// Takes raw messages (role + content) instead of a pre-formatted prompt.
    public func streamChatCompletion(
        messages: [(role: String, content: String)],
        addBos: Bool?,
        stopStrings: [String],
        sampling: SamplingConfigSwift
    ) throws -> AsyncThrowingStream<String, Error> {
        // Apply the model's chat template to format the prompt.
        let prompt = applyChatTemplate(messages: messages, model: model, addAssistant: true)
        guard !prompt.isEmpty else {
            throw LlamaError.tokenizationFailed
        }
        logger.info("Chat template applied, prompt length: \(prompt.count, privacy: .public)")
        return try streamCompletion(
            prompt: prompt,
            addBos: addBos,
            parseSpecial: true,
            stopStrings: stopStrings,
            sampling: sampling
        )
    }

    // MARK: - Streaming Completion

    public func streamCompletion(
        prompt: String,
        addBos: Bool?,
        parseSpecial: Bool = false,
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

                    // Clear memory.
                    let mem = llama_get_memory(ctx)
                    llama_memory_clear(mem, true)

                    // Bound logical prompt batches; llama.cpp further splits these at n_ubatch.
                    for range in try Self.promptBatchRanges(
                        tokenCount: tokens.count,
                        batchSize: config.batchSize
                    ) {
                        var batch = llama_batch_init(Int32(range.count), 0, 1)
                        for (localIndex, tokenIndex) in range.enumerated() {
                            batch.token[localIndex] = tokens[tokenIndex]
                            batch.pos[localIndex] = Int32(tokenIndex)
                            batch.n_seq_id[localIndex] = 1
                            batch.seq_id[localIndex]![0] = 0
                            batch.logits[localIndex] = tokenIndex == tokens.count - 1 ? 1 : 0
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
                    try generateTokens(
                        startPos: Int32(tokens.count), sampler: sampler, vocab: vocab,
                        stopStrings: stopStrings, sampling: sampling, continuation: continuation
                    )
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
        let prompt = applyChatTemplate(messages: messages, model: model, addAssistant: true)
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
                                    false
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
                        return bitmapPtrs.withUnsafeMutableBufferPointer { bufPtr in
                            mtmd_tokenize(mCtx, chunks, &inputText, bufPtr.baseAddress, images.count)
                        }
                    }

                    guard tokenizeResult == 0 else {
                        throw LlamaError.tokenizationFailed
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

                    // Create sampler chain.
                    let sampler = try createSamplerChain(sampling: sampling, vocab: vocab)
                    defer { llama_sampler_free(sampler) }

                    // Generate tokens using shared generation loop.
                    try generateTokens(
                        startPos: newNPast, sampler: sampler, vocab: vocab,
                        stopStrings: stopStrings, sampling: sampling, continuation: continuation
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

        if sampling.temperature == 0 {
            // Greedy decoding.
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

            // Repeat penalty (prevents looping and repetitive phrases).
            if sampling.repeatPenalty != 1.0 {
                let penalty = llama_sampler_init_penalties(
                    64,                      // penalty last N tokens
                    sampling.repeatPenalty,    // repeat penalty
                    0.0,                       // frequency penalty
                    0.0                        // presence penalty
                )
                llama_sampler_chain_add(chain, penalty)
            }

            // Distribution sampling (random from remaining candidates).
            let dist = llama_sampler_init_dist(0)
            llama_sampler_chain_add(chain, dist)
        }

        return chain
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

    /// Shared autoregressive generation loop used by both text and vision streaming.
    private func generateTokens(
        startPos: llama_pos,
        sampler: UnsafeMutablePointer<llama_sampler>,
        vocab: OpaquePointer,
        stopStrings: [String],
        sampling: SamplingConfigSwift,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws {
        guard let ctx = context else { throw LlamaError.modelNotLoaded }

        var nPos = startPos
        var pendingBuffer = ""
        var nGenerated = 0
        let maxTokens = sampling.maxTokens > 0 ? sampling.maxTokens : 2048

        while nPos < Int32(config.contextLength) && nGenerated < maxTokens {
            if isGenerationCancelled || Task.isCancelled { break }

            let newTokenID = llama_sampler_sample(sampler, ctx, -1)
            if newTokenID == self.eosTokenID { break }

            let tokenText = tokenToText(token: newTokenID, vocab: vocab)
            pendingBuffer += tokenText

            // Check stop strings.
            var shouldStop = false
            for stop in stopStrings where !stop.isEmpty {
                if pendingBuffer.hasSuffix(stop) {
                    let clean = String(pendingBuffer.dropLast(stop.count))
                    if !clean.isEmpty { continuation.yield(clean) }
                    pendingBuffer = ""
                    shouldStop = true
                    break
                }
            }
            if shouldStop { break }

            // Check if buffer could be start of a stop string.
            var mightBeStop = false
            for stop in stopStrings where !stop.isEmpty {
                if stop.hasPrefix(pendingBuffer) { mightBeStop = true; break }
            }
            if !mightBeStop { continuation.yield(pendingBuffer); pendingBuffer = "" }

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

        if !pendingBuffer.isEmpty { continuation.yield(pendingBuffer) }
    }
}

// MARK: - Configuration (Public)

public struct LlamaConfigSwift: Sendable {
    public let modelPath: String
    public let mmprojPath: String?
    public let contextLength: Int
    public let batchSize: Int
    public let microBatchSize: Int
    public let threadCount: Int
    public let useMmap: Bool
    public let f16KV: Bool
    public let gpuLayers: Int

    public init(
        modelPath: String,
        mmprojPath: String? = nil,
        contextLength: Int = 4096,
        batchSize: Int = 512,
        microBatchSize: Int = 128,
        threadCount: Int = 2,
        useMmap: Bool = true,
        f16KV: Bool = true,
        gpuLayers: Int = 0
    ) {
        self.modelPath = modelPath
        self.mmprojPath = mmprojPath
        precondition(contextLength > 0)
        precondition(batchSize > 0)
        precondition(microBatchSize > 0 && microBatchSize <= batchSize)
        self.contextLength = contextLength
        self.batchSize = batchSize
        self.microBatchSize = microBatchSize
        self.threadCount = threadCount
        self.useMmap = useMmap
        self.f16KV = f16KV
        self.gpuLayers = gpuLayers
    }
}

public struct SamplingConfigSwift: Sendable {
    public let temperature: Float
    public let topP: Float
    public let topK: Int
    public let maxTokens: Int
    public let repeatPenalty: Float

    public init(
        temperature: Float = 0.7,
        topP: Float = 0.9,
        topK: Int = 40,
        maxTokens: Int = 2048,
        repeatPenalty: Float = 1.1
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxTokens = maxTokens
        self.repeatPenalty = repeatPenalty
    }
}

// MARK: - Errors

public enum LlamaError: Error, LocalizedError {
    case modelLoadFailed(path: String)
    case contextCreationFailed
    case projectorInitializationFailed
    case invalidConfiguration
    case modelNotLoaded
    case tokenizationFailed
    case decodeFailed
    case samplerCreationFailed
    case visionNotSupported
    case visionImageLoadFailed

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "Failed to map the model artifact."
        case .contextCreationFailed: return "Failed to create inference context."
        case .projectorInitializationFailed: return "Failed to initialize the vision projector."
        case .invalidConfiguration: return "The inference runtime configuration is invalid."
        case .modelNotLoaded: return "No model is loaded."
        case .tokenizationFailed: return "Failed to tokenize input text."
        case .decodeFailed: return "Token decoding failed."
        case .samplerCreationFailed: return "Failed to create sampler chain."
        case .visionNotSupported: return "Vision inference is not supported. No multimodal projector loaded."
        case .visionImageLoadFailed: return "Failed to load image for vision inference."
        }
    }
}
