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
    private var isCancelled = false
    private var eosTokenID: llama_token = -1

    // MARK: - Initialization

    public init(config: LlamaConfigSwift) throws {
        self.config = config

        llama_backend_init()

        // Load model.
        var modelParams = llama_model_default_params()
        modelParams.use_mmap = config.useMmap
        modelParams.n_gpu_layers = Int32(config.gpuLayers)

        guard let loadedModel = llama_model_load_from_file(config.modelPath, modelParams) else {
            throw LlamaError.modelLoadFailed(path: config.modelPath)
        }
        model = loadedModel
        vocabulary = llama_model_get_vocab(loadedModel)

        guard let vocab = vocabulary else {
            llama_model_free(loadedModel)
            model = nil
            throw LlamaError.modelLoadFailed(path: config.modelPath)
        }
        eosTokenID = llama_vocab_eos(vocab)

        // Create context.
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(config.contextLength)
        ctxParams.n_threads = Int32(config.threadCount)
        ctxParams.n_threads_batch = Int32(config.threadCount)
        ctxParams.flash_attn_type = config.f16KV ? LLAMA_FLASH_ATTN_TYPE_ENABLED : LLAMA_FLASH_ATTN_TYPE_DISABLED

        guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            model = nil
            throw LlamaError.contextCreationFailed
        }
        context = ctx

        // Initialize multimodal context if mmprojPath is provided.
        if let mmprojPath = config.mmprojPath {
            var mtmdParams = mtmd_context_params_default()
            mtmdParams.n_threads = Int32(config.threadCount)
            mtmdParams.use_gpu = false  // CPU-only for v1
            mtmdCtx = mtmd_init_from_file(mmprojPath, loadedModel, mtmdParams)
            if mtmdCtx != nil {
                logger.info("Multimodal context initialized: \(mmprojPath, privacy: .public)")
            } else {
                logger.warning("Failed to initialize mtmd context for: \(mmprojPath, privacy: .public)")
            }
        }

        logger.info("Model loaded: \(config.modelPath, privacy: .public) ctx=\(config.contextLength) threads=\(config.threadCount)")
    }

    deinit {
        unloadSync()
    }

    // MARK: - Unload

    public func unload() {
        unloadSync()
    }

    private func unloadSync() {
        if let m = mtmdCtx {
            mtmd_free(m)
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
        logger.info("Model unloaded")
    }

    // MARK: - Chat Template Formatting

    /// Apply the model's built-in chat template to format messages.
    /// Uses llama_chat_apply_template which auto-detects the template from the model.
    /// Pass nil as tmpl to use the model's own template.
    public func applyChatTemplate(
        messages: [(role: String, content: String)],
        model: OpaquePointer?,
        addAssistant: Bool = true
    ) -> String {
        // Build llama_chat_message array.
        let chatMessages = messages.map { msg in
            llama_chat_message(role: msg.role, content: msg.content)
        }

        // Calculate buffer size: 2x total characters of all messages.
        let totalChars = messages.reduce(0) { $0 + $1.content.count + $1.role.count + 10 }
        let bufferSize = max(totalChars * 2, 1024)

        let formatted = chatMessages.withUnsafeBufferPointer { ptr -> String in
            var buffer = [CChar](repeating: 0, count: bufferSize)
            // Pass nil for tmpl to use the model's built-in template.
            let nBytes = llama_chat_apply_template(nil, ptr.baseAddress, chatMessages.count, addAssistant, &buffer, Int32(bufferSize))
            if nBytes > 0 && nBytes <= Int32(bufferSize) {
                return String(cString: buffer.prefix(Int(nBytes)).withUnsafeBufferPointer { $0.baseAddress! })
            }
            // If buffer too small, retry with larger buffer.
            if nBytes > Int32(bufferSize) {
                let largerSize = Int(nBytes) + 1
                var largerBuffer = [CChar](repeating: 0, count: largerSize)
                let nBytes2 = llama_chat_apply_template(nil, ptr.baseAddress, chatMessages.count, addAssistant, &largerBuffer, Int32(largerSize))
                if nBytes2 > 0 {
                    return String(cString: largerBuffer.prefix(Int(nBytes2)).withUnsafeBufferPointer { $0.baseAddress! })
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
        return try streamCompletion(prompt: prompt, addBos: addBos, stopStrings: stopStrings, sampling: sampling)
    }

    // MARK: - Streaming Completion

    public func streamCompletion(
        prompt: String,
        addBos: Bool?,
        stopStrings: [String],
        sampling: SamplingConfigSwift
    ) throws -> AsyncThrowingStream<String, Error> {
        guard let ctx = context, let vocab = vocabulary else {
            throw LlamaError.modelNotLoaded
        }

        isCancelled = false

        return AsyncThrowingStream<String, Error> { continuation in
            Task {
                do {
                    // Tokenize prompt.
                    let tokens = try tokenize(prompt: prompt, addBos: addBos, vocab: vocab)
                    guard !tokens.isEmpty else {
                        throw LlamaError.tokenizationFailed
                    }

                    // Clear memory.
                    let mem = llama_get_memory(ctx)
                    llama_memory_clear(mem, true)

                    // Evaluate prompt tokens using batch_get_one for sequential processing.
                    // For the prompt, we evaluate all tokens at once.
                    var batch = llama_batch_init(Int32(tokens.count), 0, 1)
                    for (i, token) in tokens.enumerated() {
                        batch.token[i] = token
                        batch.pos[i] = Int32(i)
                        batch.n_seq_id[i] = 1
                        // Use pre-allocated seq_id from llama_batch_init (no manual alloc).
                        batch.seq_id[i]![0] = 0
                        batch.logits[i] = (i == tokens.count - 1) ? 1 : 0
                    }
                    batch.n_tokens = Int32(tokens.count)

                    if llama_decode(ctx, batch) != 0 {
                        llama_batch_free(batch)
                        throw LlamaError.decodeFailed
                    }

                    llama_batch_free(batch)

                    // Create sampler chain.
                    let sampler = try createSamplerChain(sampling: sampling, vocab: vocab)
                    defer { llama_sampler_free(sampler) }

                    // Generate tokens.
                    var nPos = Int32(tokens.count)
                    var generatedText = ""
                    var pendingBuffer = ""  // Buffer to prevent stop-token leaks
                    var nGenerated = 0
                    let maxTokens = sampling.maxTokens > 0 ? sampling.maxTokens : 2048

                    while nPos < Int32(config.contextLength) && nGenerated < maxTokens {
                        if self.isCancelled || Task.isCancelled { break }

                        // Sample next token.
                        let newTokenID = llama_sampler_sample(sampler, ctx, -1)

                        // Check EOS.
                        if newTokenID == self.eosTokenID { break }

                        // Decode token to text.
                        let tokenText = tokenToText(token: newTokenID, vocab: vocab)
                        generatedText += tokenText
                        pendingBuffer += tokenText

                        // Check if buffer ends with a stop string.
                        var shouldStop = false
                        for stop in stopStrings where !stop.isEmpty {
                            if pendingBuffer.hasSuffix(stop) {
                                // Strip the stop string and yield the clean remainder.
                                let clean = String(pendingBuffer.dropLast(stop.count))
                                if !clean.isEmpty {
                                    continuation.yield(clean)
                                }
                                pendingBuffer = ""  // Clear buffer — stop consumed.
                                shouldStop = true
                                break
                            }
                        }
                        if shouldStop { break }

                        // Check if buffer could be the start of a stop string.
                        // If not, it's safe to flush to preserve streaming responsiveness.
                        var mightBeStop = false
                        for stop in stopStrings where !stop.isEmpty {
                            if stop.hasPrefix(pendingBuffer) {
                                mightBeStop = true
                                break
                            }
                        }

                        if !mightBeStop {
                            // Safe to flush — this text is not part of any stop string.
                            continuation.yield(pendingBuffer)
                            pendingBuffer = ""
                        }

                        // Evaluate single token.
                        var evalBatch = llama_batch_init(1, 0, 1)
                        evalBatch.token[0] = newTokenID
                        evalBatch.pos[0] = nPos
                        evalBatch.n_seq_id[0] = 1
                        // Use pre-allocated seq_id from llama_batch_init.
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

                    // Flush any remaining buffered tokens (EOS, maxTokens, or cancellation).
                    if !pendingBuffer.isEmpty {
                        continuation.yield(pendingBuffer)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Streaming Vision Completion

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

        isCancelled = false

        return AsyncThrowingStream<String, Error> { continuation in
            Task {
                do {
                    // Create bitmaps from image data.
                    var bitmaps: [OpaquePointer?] = []
                    defer {
                        for bmp in bitmaps {
                            if let b = bmp { mtmd_bitmap_free(b) }
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
                        Int32(config.contextLength),  // n_batch
                        true,                        // logits_last = true
                        &newNPast
                    )

                    guard evalResult == 0 else {
                        throw LlamaError.decodeFailed
                    }

                    // Create sampler chain.
                    let sampler = try createSamplerChain(sampling: sampling, vocab: vocab)
                    defer { llama_sampler_free(sampler) }

                    // Generate tokens (same autoregressive loop as streamCompletion).
                    var nPos = newNPast
                    var generatedText = ""
                    var pendingBuffer = ""  // Buffer to prevent stop-token leaks
                    var nGenerated = 0
                    let maxTokens = sampling.maxTokens > 0 ? sampling.maxTokens : 2048

                    while nPos < Int32(config.contextLength) && nGenerated < maxTokens {
                        if self.isCancelled || Task.isCancelled { break }

                        let newTokenID = llama_sampler_sample(sampler, ctx, -1)

                        if newTokenID == self.eosTokenID { break }

                        let tokenText = tokenToText(token: newTokenID, vocab: vocab)
                        generatedText += tokenText
                        pendingBuffer += tokenText

                        var shouldStop = false
                        for stop in stopStrings where !stop.isEmpty {
                            if pendingBuffer.hasSuffix(stop) {
                                let clean = String(pendingBuffer.dropLast(stop.count))
                                if !clean.isEmpty {
                                    continuation.yield(clean)
                                }
                                pendingBuffer = ""  // Clear buffer — stop consumed.
                                shouldStop = true
                                break
                            }
                        }
                        if shouldStop { break }

                        // Check if buffer could be the start of a stop string.
                        var mightBeStop = false
                        for stop in stopStrings where !stop.isEmpty {
                            if stop.hasPrefix(pendingBuffer) {
                                mightBeStop = true
                                break
                            }
                        }

                        if !mightBeStop {
                            continuation.yield(pendingBuffer)
                            pendingBuffer = ""
                        }

                        // Evaluate single token.
                        var evalBatch = llama_batch_init(1, 0, 1)
                        evalBatch.token[0] = newTokenID
                        evalBatch.pos[0] = nPos
                        evalBatch.n_seq_id[0] = 1
                        // Use pre-allocated seq_id from llama_batch_init.
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

                    // Flush any remaining buffered tokens.
                    if !pendingBuffer.isEmpty {
                        continuation.yield(pendingBuffer)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Cancellation

    public func cancel() {
        isCancelled = true
    }

    // MARK: - Sampler Chain

    private func createSamplerChain(sampling: SamplingConfigSwift, vocab: OpaquePointer) throws -> UnsafeMutablePointer<llama_sampler> {
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

            // Distribution sampling (random from remaining candidates).
            let dist = llama_sampler_init_dist(0)
            llama_sampler_chain_add(chain, dist)
        }

        return chain
    }

    // MARK: - Tokenization

    private func tokenize(prompt: String, addBos: Bool?, vocab: OpaquePointer) throws -> [llama_token] {
        let textLength = Int32(prompt.lengthOfBytes(using: .utf8))
        let maxTokens = Int(textLength * 4)
        var tokens = [llama_token](repeating: 0, count: maxTokens)

        let shouldAddBos = addBos ?? true

        let nTokens = prompt.withCString { cstr in
            llama_tokenize(vocab, cstr, textLength, &tokens, Int32(maxTokens), shouldAddBos, false)
        }

        guard nTokens > 0 else {
            throw LlamaError.tokenizationFailed
        }

        return Array(tokens.prefix(Int(nTokens)))
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
}

// MARK: - Configuration (Public)

public struct LlamaConfigSwift: Sendable {
    public let modelPath: String
    public let mmprojPath: String?
    public let contextLength: Int
    public let threadCount: Int
    public let useMmap: Bool
    public let f16KV: Bool
    public let gpuLayers: Int

    public init(
        modelPath: String,
        mmprojPath: String? = nil,
        contextLength: Int = 4096,
        threadCount: Int = 2,
        useMmap: Bool = true,
        f16KV: Bool = true,
        gpuLayers: Int = 0
    ) {
        self.modelPath = modelPath
        self.mmprojPath = mmprojPath
        self.contextLength = contextLength
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
    case modelNotLoaded
    case tokenizationFailed
    case decodeFailed
    case samplerCreationFailed
    case visionNotSupported
    case visionImageLoadFailed

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path): return "Failed to load model from: \(path)"
        case .contextCreationFailed: return "Failed to create inference context."
        case .modelNotLoaded: return "No model is loaded."
        case .tokenizationFailed: return "Failed to tokenize input text."
        case .decodeFailed: return "Token decoding failed."
        case .samplerCreationFailed: return "Failed to create sampler chain."
        case .visionNotSupported: return "Vision inference is not supported. No multimodal projector loaded."
        case .visionImageLoadFailed: return "Failed to load image for vision inference."
        }
    }
}
