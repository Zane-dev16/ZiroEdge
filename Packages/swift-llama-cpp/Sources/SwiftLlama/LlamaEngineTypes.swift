// LlamaEngineTypes.swift
// SwiftLlama — public configuration and error types.

import Foundation

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
            chatTemplateName: chatTemplateName
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
        chatTemplateName: String? = nil
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
    }
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
        }
    }
}
