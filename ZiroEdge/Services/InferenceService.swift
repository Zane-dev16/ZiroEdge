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
    func unloadModel()
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

    func cancelCurrentStream()
}

// MARK: - Inference Service

/// Production implementation of InferenceServiceProtocol.
/// Manages the lifecycle of the underlying LlamaEngine.
actor InferenceService {

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "inference")

    /// The underlying LlamaEngine. Nil when no model is loaded.
    private var engine: LlamaEngine?

    /// The currently loaded model ID.
    private var _loadedModelID: String?

    /// The current model configuration.
    private var currentConfig: ModelConfiguration?

    /// Current model reference (for reloads).
    private var currentModel: AIModel?

    // MARK: - State

    var isModelLoaded: Bool {
        engine != nil
    }

    var loadedModelID: String? {
        _loadedModelID
    }

    // MARK: - Model Loading

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        // Unload any existing model first.
        unloadInternal()

        logger.info("Loading model: \(model.id, privacy: .public) from \(baseURL.path, privacy: .public)")

        // Validate file exists.
        guard FileManager.default.fileExists(atPath: baseURL.path) else {
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
            threadCount: config.threadCount,
            useMmap: config.useMmap,
            f16KV: config.f16KV,
            gpuLayers: config.gpuLayers
        )

        // Create the engine.
        let newEngine = try await LlamaEngine(config: engineConfig)
        engine = newEngine
        _loadedModelID = model.id
        currentConfig = config
        currentModel = model

        logger.info("Model loaded successfully: \(model.id, privacy: .public)")
    }

    func unloadModel() {
        unloadInternal()
    }

    private func unloadInternal() {
        if let eng = engine {
            Task {
                await eng.unload()
            }
        }
        engine = nil
        _loadedModelID = nil
        currentConfig = nil
        currentModel = nil
        logger.info("Model unloaded")
    }

    // MARK: - Text Chat

    func streamChat(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let eng = engine else {
            throw InferenceError.modelNotLoaded
        }

        guard let config = currentConfig else {
            throw InferenceError.modelNotLoaded
        }

        // Format the prompt.
        let prompt = formatChatPrompt(
            messages: messages,
            systemPrompt: systemPrompt,
            config: config
        )

        // Convert sampling config to SwiftLlama format.
        let engineSampling = SamplingConfigSwift(
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            maxTokens: sampling.maxTokens,
            repeatPenalty: sampling.repeatPenalty
        )

        // Stream from the engine.
        return try await eng.streamCompletion(
            prompt: prompt,
            addBos: config.addBos,
            stopStrings: config.stopStrings,
            sampling: engineSampling
        )
    }

    // MARK: - Vision Chat

    func streamVisionChat(
        messages: [ChatMessagePayload],
        images: [Data],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let eng = engine else {
            throw InferenceError.modelNotLoaded
        }

        guard let config = currentConfig else {
            throw InferenceError.modelNotLoaded
        }

        // Format prompt with <__media__> markers for each image.
        let marker = "<__media__>"
        let imageMarkers = images.map { _ in marker }.joined(separator: "\n")

        // Format user messages, inserting image markers before user text.
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

            if message.role == .user && !images.isEmpty {
                // Insert image markers before the first user message.
                parts.append("\(rolePrefix): \(imageMarkers)\n\(message.content)")
            } else {
                parts.append("\(rolePrefix): \(message.content)")
            }
        }
        parts.append("Assistant:")
        let visionPrompt = parts.joined(separator: "\n")

        // Convert sampling config to SwiftLlama format.
        let engineSampling = SamplingConfigSwift(
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            maxTokens: sampling.maxTokens,
            repeatPenalty: sampling.repeatPenalty
        )

        // Stream from the engine using vision completion.
        return try await eng.streamVisionCompletion(
            prompt: visionPrompt,
            images: images,
            addBos: config.addBos,
            stopStrings: config.stopStrings,
            sampling: engineSampling
        )
    }

    // MARK: - Cancellation

    func cancelCurrentStream() {
        if let eng = engine {
            Task {
                await eng.cancel()
            }
        }
    }

    // MARK: - Prompt Formatting

    /// Format messages into a prompt string for the model.
    private func formatChatPrompt(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        config: ModelConfiguration
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

enum InferenceError: Error, LocalizedError {
    case modelNotLoaded
    case modelFileNotFound(path: String)
    case mmprojFileNotFound(path: String)
    case visionNotSupported
    case inferenceFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No model is loaded. Please download and load a model first."
        case .modelFileNotFound(let path):
            return "Model file not found at: \(path)"
        case .mmprojFileNotFound(let path):
            return "Multimodal projector file not found at: \(path)"
        case .visionNotSupported:
            return "Vision chat is not yet supported. Coming in Phase 2."
        case .inferenceFailed(let error):
            return "Inference failed: \(error.localizedDescription)"
        }
    }
}
