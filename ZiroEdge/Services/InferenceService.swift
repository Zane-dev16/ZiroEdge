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
}

// MARK: - Inference Service

/// Production implementation of InferenceServiceProtocol.
/// Manages the lifecycle of the underlying LlamaEngine.
actor InferenceService: InferenceServiceProtocol {

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "inference")

    /// The underlying LlamaEngine. Nil when no model is loaded.
    private var engine: LlamaEngine?

    /// The currently loaded model ID.
    private var _loadedModelID: String?

    /// The current model configuration.
    private var currentConfig: ModelConfiguration?

    /// Current model reference (for reloads).
    private var currentModel: AIModel?

    /// Pending unload task — awaited before loading a new model to prevent race conditions.
    private var pendingUnload: Task<Void, Never>?

    /// Pending stream cancellation — awaited before starting more engine work.
    private var pendingCancellation: Task<Void, Never>?

    // MARK: - State

    var isModelLoaded: Bool {
        engine != nil
    }

    var loadedModelID: String? {
        _loadedModelID
    }

    // MARK: - Model Loading

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        print("[INFERENCE-LOAD] loadModel(\(model.id)) from \(baseURL.path)")
        // Wait for any pending cancellation or unload to complete before loading.
        await waitForPendingCancellation()
        await pendingUnload?.value
        pendingUnload = nil
        // Unload any existing model first.
        unloadInternal()

        logger.info("Loading model: \(model.id, privacy: .public) from \(baseURL.path, privacy: .public)")

        // Validate file exists.
        let baseExists = FileManager.default.fileExists(atPath: baseURL.path)
        print("[INFERENCE-LOAD] base file exists: \(baseExists), size: \(baseExists ? (try? FileManager.default.attributesOfItem(atPath: baseURL.path)[.size] as? Int64) ?? 0 : 0)")
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
            threadCount: config.threadCount,
            useMmap: config.useMmap,
            f16KV: config.f16KV,
            gpuLayers: config.gpuLayers
        )

        // Create the engine.
        print("[INFERENCE-LOAD] Creating LlamaEngine...")
        let startTime = Date()
        let newEngine = try LlamaEngine(config: engineConfig)
        let elapsed = Date().timeIntervalSince(startTime)
        print("[INFERENCE-LOAD] Engine created in \(String(format: "%.1f", elapsed))s")
        engine = newEngine
        _loadedModelID = model.id
        currentConfig = config
        currentModel = model

        print("[INFERENCE-LOAD] SUCCESS — engine set, modelID=\(model.id)")
        logger.info("Model loaded successfully: \(model.id, privacy: .public)")
    }

    func unloadModel() async {
        unloadInternal()
        await pendingUnload?.value
        pendingUnload = nil
    }

    private func unloadInternal() {
        if let eng = engine {
            pendingUnload = Task { await eng.unload() }
        }
        engine = nil
        _loadedModelID = nil
        currentConfig = nil
        currentModel = nil
        logger.info("Model unloaded")
    }

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
        guard let eng = engine else {
            throw InferenceError.modelNotLoaded
        }
        let engineSampling = SamplingConfigSwift(
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            maxTokens: sampling.maxTokens,
            repeatPenalty: sampling.repeatPenalty
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
        await waitForPendingCancellation()
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

    func cancelCurrentStream() async {
        if let pendingCancellation {
            await pendingCancellation.value
            return
        }
        guard let eng = engine else { return }

        let cancellationTask = Task {
            await eng.cancel()
        }
        pendingCancellation = cancellationTask
        await cancellationTask.value
        pendingCancellation = nil
    }

    private func waitForPendingCancellation() async {
        guard let pendingCancellation else { return }
        await pendingCancellation.value
        self.pendingCancellation = nil
    }

    // MARK: - Prompt Formatting

    /// Format messages into a prompt string for the model.
    /// Handles chat template and raw format paths.
    private func formatChatPrompt(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        config: ModelConfiguration
    ) -> String {
        switch config.promptPath {
        case .chatTemplate:
            // Gemma chat format: <start_of_turn>ROLE\nCONTENT<end_of_turn>\n
            var parts: [String] = []
            if let systemPrompt, !systemPrompt.isEmpty {
                parts.append("<start_of_turn>system\n\(systemPrompt)<end_of_turn>")
            }
            for message in messages {
                let role = message.role.rawValue
                parts.append("<start_of_turn>\(role)\n\(message.content)<end_of_turn>")
            }
            parts.append("<start_of_turn>model\n")
            return parts.joined(separator: "\n")

        case .raw:
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