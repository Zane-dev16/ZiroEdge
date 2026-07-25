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

private final class MemoryPeakAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: MemorySnapshot

    init(initial: MemorySnapshot) {
        peak = initial
    }

    func record(_ snapshot: MemorySnapshot) {
        lock.lock()
        defer { lock.unlock() }
        if snapshot.physicalFootprintBytes > peak.physicalFootprintBytes {
            peak = snapshot
        }
    }

    func snapshot() -> MemorySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

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
        // Wait for any pending cancellation or unload to complete before loading.
        await waitForPendingCancellation()
        await pendingUnload?.value
        pendingUnload = nil
        // Unload any existing model first.
        unloadInternal()

        logger.info("Loading model: \(model.id, privacy: .public) from \(baseURL.path, privacy: .public)")

        // Validate file exists.
        let baseExists = FileManager.default.fileExists(atPath: baseURL.path)
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

        // Creating the engine loads the model, context, and optional multimodal projector.
        let newEngine = try LlamaEngine(config: engineConfig)
        engine = newEngine
        _loadedModelID = model.id
        currentConfig = config
        currentModel = model

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

        let prefillStarted = ContinuousClock.now
        let stream = try await eng.streamCompletion(
            prompt: prompt,
            addBos: config.addBos,
            stopStrings: config.stopStrings,
            sampling: engineSampling
        )
        return instrumentGenerationPeak(
            stream,
            firstEvaluationCheckpoint: .firstTextPrefill,
            evaluationStarted: prefillStarted
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

        let imageEvaluationStarted = ContinuousClock.now
        let stream = try await eng.streamVisionCompletion(
            prompt: visionPrompt,
            images: images,
            addBos: config.addBos,
            stopStrings: config.stopStrings,
            sampling: engineSampling
        )
        return instrumentGenerationPeak(
            stream,
            firstEvaluationCheckpoint: .firstImageEval,
            evaluationStarted: imageEvaluationStarted
        )
    }

    private func instrumentGenerationPeak(
        _ source: AsyncThrowingStream<String, Error>,
        firstEvaluationCheckpoint: MemoryCheckpoint,
        evaluationStarted: ContinuousClock.Instant
    ) -> AsyncThrowingStream<String, Error> {
        guard MemoryDiagnosticRecorder.shared.isEnabled else { return source }

        return AsyncThrowingStream { continuation in
            let task = Task {
                let accumulator = MemoryPeakAccumulator(
                    initial: MemorySnapshotReader.capture(.generationPeak)
                )
                let sampler = Task {
                    while !Task.isCancelled {
                        accumulator.record(MemorySnapshotReader.capture(.generationPeak))
                        do {
                            try await Task.sleep(for: .milliseconds(100))
                        } catch {
                            break
                        }
                    }
                }
                var generationStarted: ContinuousClock.Instant?

                do {
                    for try await token in source {
                        if generationStarted == nil {
                            generationStarted = .now
                            MemoryDiagnosticRecorder.shared.capture(
                                firstEvaluationCheckpoint,
                                elapsedMilliseconds: evaluationStarted.elapsedMilliseconds
                            )
                        }
                        accumulator.record(MemorySnapshotReader.capture(.generationPeak))
                        continuation.yield(token)
                    }
                    sampler.cancel()
                    await sampler.value
                    let elapsed = generationStarted?.elapsedMilliseconds
                        ?? evaluationStarted.elapsedMilliseconds
                    MemoryDiagnosticRecorder.shared.persist(
                        accumulator.snapshot().addingDiagnosticMetadata(elapsedMilliseconds: elapsed)
                    )
                    continuation.finish()
                } catch {
                    sampler.cancel()
                    await sampler.value
                    let elapsed = generationStarted?.elapsedMilliseconds
                        ?? evaluationStarted.elapsedMilliseconds
                    MemoryDiagnosticRecorder.shared.persist(
                        accumulator.snapshot().addingDiagnosticMetadata(
                            elapsedMilliseconds: elapsed,
                            error: error.localizedDescription
                        )
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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