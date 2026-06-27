// ChatSessionActor.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Manages a single inference session. Actor-isolated for thread safety.
// Handles token streaming, cooperative cancellation, and Core Data batch flushing.

import Foundation
import os

actor ChatSessionActor {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "chat-session")
    private let inferenceService: InferenceService
    private let persistence: PersistenceController

    /// Current streaming task.
    private var currentStream: Task<Void, Never>?

    /// Cancellation flag.
    private var isCancelled = false

    /// Whether a stream is active.
    private(set) var isStreaming = false

    /// The message ID being streamed into.
    private var activeMessageID: UUID?

    /// Token count for context window tracking.
    private var processedTokenCount = 0

    // MARK: - Initialization

    init(inferenceService: InferenceService, persistence: PersistenceController) {
        self.inferenceService = inferenceService
        self.persistence = persistence
    }

    // MARK: - Stream Management

    /// Start streaming a response. Cancels any in-progress stream.
    func startStream(
        conversationID: UUID,
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig,
        onToken: @Sendable @escaping (String) -> Void,
        onComplete: @Sendable @escaping () -> Void,
        onError: @Sendable @escaping (Error) -> Void
    ) {
        // Cancel existing stream.
        cancelInternal()

        isCancelled = false
        isStreaming = true

        // Begin streaming message in Core Data.
        let infService = inferenceService
        let persist = persistence
        let selfRef = self

        currentStream = Task { [weak self] in
            guard let self else { return }

            // Create the streaming message.
            let messageID = await persist.beginStreamingMessage(conversationID: conversationID)

            guard let messageID else {
                await MainActor.run { onError(ChatSessionError.persistenceFailure) }
                await selfRef.setStreaming(false)
                return
            }

            await selfRef.setActiveMessageID(messageID)

            do {
                let stream = try await infService.streamChat(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    sampling: sampling
                )

                for try await token in stream {
                    // Check cancellation.
                    let cancelled = await selfRef.getIsCancelled()
                    if Task.isCancelled || cancelled {
                        await persist.cancelStreamingMessage(messageID: messageID)
                        await MainActor.run { onComplete() }
                        await selfRef.setStreaming(false)
                        await selfRef.setActiveMessageID(nil)
                        return
                    }

                    // Buffer token.
                    await persist.bufferTokens(messageID: messageID, tokens: token)

                    // Notify UI.
                    await MainActor.run { onToken(token) }

                    await selfRef.incrementTokenCount()
                }

                // Stream completed.
                await persist.endStreamingMessage(messageID: messageID)
                await selfRef.setActiveMessageID(nil)
                await selfRef.setStreaming(false)
                await MainActor.run { onComplete() }

            } catch {
                let cancelled = await selfRef.getIsCancelled()
                if Task.isCancelled || cancelled {
                    await persist.cancelStreamingMessage(messageID: messageID)
                    await MainActor.run { onComplete() }
                } else {
                    self.logger.error("Stream error: \(error.localizedDescription, privacy: .public)")
                    await persist.cancelStreamingMessage(messageID: messageID)
                    await MainActor.run { onError(error) }
                }
                await selfRef.setActiveMessageID(nil)
                await selfRef.setStreaming(false)
            }
        }
    }

    /// Cancel the current stream.
    func cancel() {
        cancelInternal()
    }

    // MARK: - Actor-isolated helpers

    private func cancelInternal() {
        isCancelled = true
        currentStream?.cancel()
        currentStream = nil

        if let messageID = activeMessageID {
            Task {
                await persistence.cancelStreamingMessage(messageID: messageID)
            }
            activeMessageID = nil
        }

        isStreaming = false
    }

    /// Set streaming state (called from Task context).
    private func setStreaming(_ value: Bool) {
        isStreaming = value
    }

    /// Set active message ID.
    private func setActiveMessageID(_ value: UUID?) {
        activeMessageID = value
    }

    /// Get cancellation state.
    private func getIsCancelled() -> Bool {
        isCancelled
    }

    /// Increment token count.
    private func incrementTokenCount() {
        processedTokenCount += 1
    }

    // MARK: - Context Window

    var tokenCount: Int {
        processedTokenCount
    }

    func resetTokenCount() {
        processedTokenCount = 0
    }
}

// MARK: - Errors

enum ChatSessionError: Error, LocalizedError {
    case persistenceFailure
    case modelNotLoaded
    case streamCancelled

    var errorDescription: String? {
        switch self {
        case .persistenceFailure: return "Failed to create streaming message in database."
        case .modelNotLoaded: return "No model is loaded. Please download and load a model first."
        case .streamCancelled: return "Stream was cancelled."
        }
    }
}
