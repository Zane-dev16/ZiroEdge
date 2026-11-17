// LlamaEngineTypes.swift
// SwiftLlama — public configuration and error types.

import Foundation
import llama

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
    /// Declared built-in template name for a GGUF with no embedded template.
    /// Nil means the model's own template wins.
    public let chatTemplateName: String?
    /// What the row wants done with the model's own reasoning. Only meaningful
    /// on the embedded-template path, which is the only path that can pass
    /// template kwargs.
    public let thinking: ChatThinkingPolicy

    /// True when any layer is offloaded to Metal.
    public var usesGPU: Bool { gpuLayers > 0 }

    /// CPU-only copy of this config: the Metal-fail retry target.
    public var cpuFallback: LlamaConfigSwift {
        LlamaConfigSwift(
            modelPath: modelPath,
            mmprojPath: mmprojPath,
            contextLength: contextLength,
            batchSize: batchSize,
            microBatchSize: microBatchSize,
            threadCount: threadCount,
            useMmap: useMmap,
            f16KV: f16KV,
            gpuLayers: 0,
            chatTemplateName: chatTemplateName,
            thinking: thinking
        )
    }

    public init(
        modelPath: String,
        mmprojPath: String? = nil,
        contextLength: Int = 4096,
        batchSize: Int = 512,
        microBatchSize: Int = 128,
        threadCount: Int = 2,
        useMmap: Bool = true,
        f16KV: Bool = true,
        gpuLayers: Int = 0,
        chatTemplateName: String? = nil,
        thinking: ChatThinkingPolicy = .templateDefault
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
        self.chatTemplateName = chatTemplateName
        self.thinking = thinking
    }
}

// MARK: - Thinking Policy

/// How a row wants the model's own reasoning handled.
///
/// The heuristic formatter has no template kwargs, so this only has meaning on
/// the embedded-template path. A row that asks for one of the explicit policies
/// on a template that ignores the switch must not load: a thinker with no
/// switch is a blocked row, not a catalog row.
public enum ChatThinkingPolicy: String, Sendable, Hashable, Codable, CaseIterable {
    /// Leave the template's own default in place. Rows that predate the switch
    /// use this and keep their previously verified output.
    case templateDefault
    /// Ask the template to suppress the reasoning block (`enable_thinking` false).
    case disabled
    /// Ask the template to reason before answering (`enable_thinking` true).
    case enabled

    /// Tri-state handed to the native session; `-1` means "template default".
    var nativeValue: Int32 {
        switch self {
        case .templateDefault: return ZIRO_CHAT_THINKING_DEFAULT
        case .disabled: return 0
        case .enabled: return 1
        }
    }

    /// Whether this policy needs a template that reads `enable_thinking`.
    public var requiresTemplateSupport: Bool {
        self != .templateDefault
    }
}

/// Load-time verdict on whether this row can be prompted at all.
public enum ChatTemplateGate: Sendable, Equatable {
    /// The row's declared policy is honorable: prompt it.
    case ready
    /// No template the runtime can render. There is no fallback syntax by design.
    case missing
    /// The row asks for a thinking policy on a template that ignores the switch.
    /// Loading it would produce a row that reasons forever with no way to stop it.
    case thinkingUnsupported
}

public struct SamplingConfigSwift: Sendable {
    public let temperature: Float
    public let topP: Float
    public let topK: Int
    public let maxTokens: Int
    public let repeatPenalty: Float
    public let penaltyLastN: Int
    public let frequencyPenalty: Float
    public let presencePenalty: Float

    public init(
        temperature: Float = 0.7,
        topP: Float = 0.9,
        topK: Int = 40,
        maxTokens: Int = 2048,
        repeatPenalty: Float = 1.1,
        penaltyLastN: Int = 64,
        frequencyPenalty: Float = 0.0,
        presencePenalty: Float = 0.0
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxTokens = maxTokens
        self.repeatPenalty = repeatPenalty
        self.penaltyLastN = penaltyLastN
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
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
    case contextWindowExceeded
    /// The embedded template could not be rendered for this conversation.
    case chatTemplateUnrenderable
    /// The row asked for a thinking policy this template cannot honor.
    case chatTemplateCannotControlThinking

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
        case .contextWindowExceeded: return "The conversation is too long for the context window."
        case .chatTemplateUnrenderable: return "This model's chat template could not be rendered."
        case .chatTemplateCannotControlThinking: return "This model cannot turn its reasoning off."
        }
    }
}
