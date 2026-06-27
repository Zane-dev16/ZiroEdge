// ModelConfiguration.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Per-model presets: prompt format, sampling defaults, runtime flags.
// Each model in the registry carries one of these.

import Foundation

// MARK: - Prompt Path

/// How the model expects to receive input.
enum PromptPath: Sendable {
    case chatTemplate       // Uses the model's built-in chat template (e.g. Llama 3.2, Qwen)
    case raw                // Bypasses chat template, sends raw text (e.g. translation-specific models)
}

// MARK: - Sampling Configuration

/// Tunable sampling parameters. Stored per-conversation, overridable at runtime.
struct SamplingConfig: Sendable, Hashable {
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
struct ModelConfiguration: Sendable, Hashable {
    /// How to format prompts for this model.
    let promptPath: PromptPath

    /// Whether to force-add a BOS token (overrides tokenizer default).
    /// Required for Gemma-family BPE tokenizers that incorrectly report no BOS needed.
    let addBos: Bool?

    /// Stop sequences — generation halts when any of these strings appear in the output.
    let stopStrings: [String]

    /// Default sampling parameters for this model.
    let defaultSampling: SamplingConfig

    /// Context window size (n_ctx). Default 4096.
    let contextLength: Int

    /// Number of threads for CPU inference. Default 2 (battery-friendly).
    let threadCount: Int

    /// Whether to use mmap for model loading. Default true.
    let useMmap: Bool

    /// Whether to use f16 for KV cache. Default true (halves KV memory).
    let f16KV: Bool

    /// Number of GPU layers. 0 = CPU-only for v1.
    let gpuLayers: Int

    // MARK: - Presets

    /// Llama 3.2 — uses built-in chat template.
    static let llama32 = ModelConfiguration(
        promptPath: .chatTemplate,
        addBos: nil,
        stopStrings: ["<|eot_id|>", "<|end_of_text|>"],
        defaultSampling: .default,
        contextLength: 4096,
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
        threadCount: 2,
        useMmap: true,
        f16KV: true,
        gpuLayers: 0
    )

    /// Qwen 2.5-VL — vision model, chat template. (Phase 2)
    static let qwen25VL = ModelConfiguration(
        promptPath: .chatTemplate,
        addBos: nil,
        stopStrings: ["<|im_end|>"],
        defaultSampling: .default,
        contextLength: 4096,
        threadCount: 2,
        useMmap: true,
        f16KV: true,
        gpuLayers: 0
    )
}
