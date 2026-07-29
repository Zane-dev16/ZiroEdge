// ModelConfiguration.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Per-model presets: prompt format, sampling defaults, runtime flags.
// Each model in the registry carries one of these.

import Foundation

// MARK: - Prompt Path

/// How the model expects to receive input.
enum PromptPath: String, Codable, Sendable {
    case chatTemplate       // Uses the model's built-in chat template (e.g. Llama 3.2, Qwen)
    case gemma              // Deterministic Gemma turn formatting with special-token parsing
    case raw                // Bypasses chat template, sends raw text (e.g. translation-specific models)
}

// MARK: - Sampling Configuration

/// Tunable sampling parameters. Stored per-conversation, overridable at runtime.
struct SamplingConfig: Codable, Sendable, Hashable {
    var temperature: Float     // 0.0 = greedy, higher = more random. Default 0.7.
    var topP: Float            // Nucleus sampling. Default 0.9.
    var topK: Int              // Top-K sampling. Default 40.
    var maxTokens: Int         // Maximum tokens to generate. Default 2048.
    var repeatPenalty: Float   // Repetition penalty. Default 1.1.

    static let `default` = SamplingConfig(
        temperature: 0.7,
        topP: 0.9,
        topK: 40,
        maxTokens: 2048,
        repeatPenalty: 1.1
    )

    /// Greedy decoding — for deterministic output.
    static let greedy = SamplingConfig(
        temperature: 0.0,
        topP: 1.0,
        topK: 1,
        maxTokens: 2048,
        repeatPenalty: 1.0
    )
}

// MARK: - Model Configuration

/// Runtime configuration preset for a specific model.
/// Encodes how the model should be loaded, prompted, and sampled.
struct ModelConfiguration: Codable, Sendable, Hashable {
    /// How to format prompts for this model.
    let promptPath: PromptPath

    /// Whether to force-add a BOS token (overrides tokenizer default).
    /// Required for Gemma-family BPE tokenizers that incorrectly report no BOS needed.
    let addBos: Bool?

    /// Stop sequences — generation halts when any of these strings appear in the output.
    let stopStrings: [String]

    /// Default sampling parameters for this model.
    let defaultSampling: SamplingConfig

    /// Context window size (n_ctx).
    let contextLength: Int

    /// Maximum logical prompt batch (n_batch).
    let batchSize: Int

    /// Maximum physical prompt microbatch (n_ubatch).
    let microBatchSize: Int

    /// Number of threads for CPU inference. Default 2 (battery-friendly).
    let threadCount: Int

    /// Whether to use mmap for model loading. Default true.
    let useMmap: Bool

    /// Whether to use f16 for KV cache. Default true (halves KV memory).
    let f16KV: Bool

    /// Number of GPU layers. 0 = CPU-only for v1.
    let gpuLayers: Int

    /// Imported models expose only these bounded controls. Unsafe runtime knobs
    /// remain app-owned constants.
    static func imported(
        promptPath: PromptPath,
        contextLength: Int,
        sampling: SamplingConfig = .default,
        addBos: Bool? = nil,
        stopStrings: [String] = []
    ) -> ModelConfiguration {
        let boundedSampling = SamplingConfig(
            temperature: min(max(sampling.temperature, 0), 2),
            topP: min(max(sampling.topP, 0), 1),
            topK: min(max(sampling.topK, 1), 100),
            maxTokens: min(max(sampling.maxTokens, 64), 4096),
            repeatPenalty: min(max(sampling.repeatPenalty, 0), 2)
        )
        return ModelConfiguration(
            promptPath: promptPath,
            addBos: addBos,
            stopStrings: stopStrings,
            defaultSampling: boundedSampling,
            contextLength: min(max(contextLength, 512), 4096),
            batchSize: 256,
            microBatchSize: 64,
            threadCount: 2,
            useMmap: true,
            f16KV: true,
            gpuLayers: 0
        )
    }

    // MARK: - Presets

    /// Llama 3.2 — uses built-in chat template.
    static let llama32 = ModelConfiguration(
        promptPath: .chatTemplate,
        addBos: nil,
        stopStrings: ["<|eot_id|>", "<|end_of_text|>"],
        defaultSampling: .default,
        contextLength: 4096,
        batchSize: 512,
        microBatchSize: 128,
        threadCount: 2,
        useMmap: true,
        f16KV: true,
        gpuLayers: 0
    )

    /// SmolVLM — vision model, raw prompt path. (Phase 2)
    static let smolVLM = ModelConfiguration(
        promptPath: .chatTemplate,
        addBos: nil,
        stopStrings: ["<end_of_utterance>"],
        defaultSampling: .default,
        contextLength: 4096,
        batchSize: 512,
        microBatchSize: 128,
        threadCount: 2,
        useMmap: true,
        f16KV: true,
        gpuLayers: 0
    )

    /// Gemma 4 — vision model, chat template. Requires BOS token.
    static let gemma4 = ModelConfiguration(
        promptPath: .gemma,
        addBos: true,  // Gemma requires BOS
        stopStrings: ["<end_of_turn>"],
        defaultSampling: .default,
        contextLength: 4096,
        batchSize: 512,
        microBatchSize: 128,
        threadCount: 2,
        useMmap: true,
        f16KV: true,
        gpuLayers: 0
    )

    /// E4B text-only runtime shape. It shares the base artifact with E4B vision
    /// but has independent evidence and never initializes a projector.
    static let gemma4E4BText = ModelConfiguration(
        promptPath: .gemma,
        addBos: true,
        stopStrings: ["<end_of_turn>"],
        defaultSampling: .default,
        contextLength: 512,
        batchSize: 256,
        microBatchSize: 64,
        threadCount: 2,
        useMmap: true,
        f16KV: true,
        gpuLayers: 0
    )

#if DEBUG
    /// Calibration-only alias of the independently selectable Release text shape.
    static let gemma4E4BTextCalibration = ModelConfiguration(
        promptPath: .gemma,
        addBos: true,
        stopStrings: ["<end_of_turn>"],
        defaultSampling: .default,
        contextLength: 512,
        batchSize: 256,
        microBatchSize: 64,
        threadCount: 2,
        useMmap: true,
        f16KV: true,
        gpuLayers: 0
    )
#endif

    /// Qwen 2.5-VL — vision model, chat template. (Phase 2)
    static let qwen25VL = ModelConfiguration(
        promptPath: .chatTemplate,
        addBos: nil,
        stopStrings: ["<|im_end|>"],
        defaultSampling: .default,
        contextLength: 4096,
        batchSize: 512,
        microBatchSize: 128,
        threadCount: 2,
        useMmap: true,
        f16KV: true,
        gpuLayers: 0
    )
}
