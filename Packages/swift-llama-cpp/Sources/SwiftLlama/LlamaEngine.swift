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
                        batch.seq_id[i] = UnsafeMutablePointer.allocate(capacity: 1)
                        batch.seq_id[i]!.pointee = 0
                        batch.logits[i] = (i == tokens.count - 1) ? 1 : 0
                    }
                    batch.n_tokens = Int32(tokens.count)

                    if llama_decode(ctx, batch) != 0 {
                        // Free seq_id pointers.
                        for i in 0..<Int(batch.n_tokens) {
                            batch.seq_id[i]?.deallocate()
                        }
                        llama_batch_free(batch)
                        throw LlamaError.decodeFailed
                    }

                    // Free seq_id pointers from prompt batch.
                    for i in 0..<Int(batch.n_tokens) {
                        batch.seq_id[i]?.deallocate()
                    }
                    llama_batch_free(batch)

                    // Create sampler chain.
                    let sampler = try createSamplerChain(sampling: sampling, vocab: vocab)
                    defer { llama_sampler_free(sampler) }

                    // Generate tokens.
                    var nPos = Int32(tokens.count)
                    var generatedText = ""

                    while nPos < Int32(config.contextLength) {
                        if self.isCancelled || Task.isCancelled { break }

                        // Sample next token.
                        let newTokenID = llama_sampler_sample(sampler, ctx, -1)

                        // Check EOS.
                        if newTokenID == self.eosTokenID { break }

                        // Decode token to text.
                        let tokenText = tokenToText(token: newTokenID, vocab: vocab)
                        generatedText += tokenText

                        // Check stop strings.
                        var shouldStop = false
                        for stop in stopStrings {
                            if generatedText.hasSuffix(stop) {
                                shouldStop = true
                                break
                            }
                        }
                        if shouldStop { break }

                        // Yield token.
                        continuation.yield(tokenText)

                        // Evaluate single token.
                        var evalBatch = llama_batch_init(1, 0, 1)
                        evalBatch.token[0] = newTokenID
                        evalBatch.pos[0] = nPos
                        evalBatch.n_seq_id[0] = 1
                        evalBatch.seq_id[0] = UnsafeMutablePointer.allocate(capacity: 1)
                        evalBatch.seq_id[0]!.pointee = 0
                        evalBatch.logits[0] = 1
                        evalBatch.n_tokens = 1

                        if llama_decode(ctx, evalBatch) != 0 {
                            evalBatch.seq_id[0]?.deallocate()
                            llama_batch_free(evalBatch)
                            throw LlamaError.decodeFailed
                        }

                        evalBatch.seq_id[0]?.deallocate()
                        llama_batch_free(evalBatch)
                        nPos += 1
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

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path): return "Failed to load model from: \(path)"
        case .contextCreationFailed: return "Failed to create inference context."
        case .modelNotLoaded: return "No model is loaded."
        case .tokenizationFailed: return "Failed to tokenize input text."
        case .decodeFailed: return "Token decoding failed."
        case .samplerCreationFailed: return "Failed to create sampler chain."
        }
    }
}
