// ChatSessionActor.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Manages one inference session with generation-scoped, awaited cancellation.

import Foundation
import os

actor ChatSessionActor {

    private enum StreamKind {
        case text
        case vision([Data])
    }

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "chat-session")
    private let inferenceService: any InferenceServiceProtocol
    private let persistence: PersistenceController

    private var currentStream: Task<Void, Never>?
    private var activeGenerationID: UUID?
    private var activeMessageID: UUID?
    private(set) var recoveryHandle: RecoveryHandle?
    private(set) var isStreaming = false
    private var processedTokenCount = 0

    init(inferenceService: any InferenceServiceProtocol, persistence: PersistenceController) {
        self.inferenceService = inferenceService
        self.persistence = persistence
    }

    func startStream(
        conversationID: UUID,
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig,
        onToken: @Sendable @escaping (String) -> Void,
        onComplete: @Sendable @escaping () -> Void,
        onError: @Sendable @escaping (Error) -> Void
    ) async {
        await start(
            kind: .text,
            conversationID: conversationID,
            messages: messages,
            systemPrompt: systemPrompt,
            sampling: sampling,
            onToken: onToken,
            onComplete: onComplete,
            onError: onError
        )
    }

    func startVisionStream(
        conversationID: UUID,
        messages: [ChatMessagePayload],
        images: [Data],
        systemPrompt: String?,
        sampling: SamplingConfig,
        onToken: @Sendable @escaping (String) -> Void,
        onComplete: @Sendable @escaping () -> Void,
        onError: @Sendable @escaping (Error) -> Void
    ) async {
        await start(
            kind: .vision(images),
            conversationID: conversationID,
            messages: messages,
            systemPrompt: systemPrompt,
            sampling: sampling,
            onToken: onToken,
            onComplete: onComplete,
            onError: onError
        )
    }

    private func start(
        kind: StreamKind,
        conversationID: UUID,
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig,
        onToken: @Sendable @escaping (String) -> Void,
        onComplete: @Sendable @escaping () -> Void,
        onError: @Sendable @escaping (Error) -> Void
    ) async {
        await cancelInternal()
        guard recoveryHandle == nil else {
            await MainActor.run { onError(PersistenceFailure.recoveryBufferFull) }
            return
        }

        let generationID = UUID()
        activeGenerationID = generationID
        isStreaming = true
        let inferenceService = self.inferenceService
        let persistence = self.persistence

        currentStream = Task { [weak self] in
            guard let self else { return }
            let beginResult = await persistence.beginStreamingMessageResult(conversationID: conversationID)
            guard case .success(let messageID) = beginResult else {
                if await self.finishIfCurrent(generationID), case .failure(let failure) = beginResult {
                    await MainActor.run { onError(failure) }
                }
                return
            }

            guard await self.register(messageID: messageID, for: generationID) else {
                await persistence.cancelStreamingMessage(messageID: messageID)
                return
            }

            do {
                let stream: AsyncThrowingStream<String, Error>
                switch kind {
                case .text:
                    stream = try await inferenceService.streamChat(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        sampling: sampling
                    )
                case .vision(let images):
                    stream = try await inferenceService.streamVisionChat(
                        messages: messages,
                        images: images,
                        systemPrompt: systemPrompt,
                        sampling: sampling
                    )
                }

                var tokenBatch = ""
                var lastBatchTime = Date()
                for try await token in stream {
                    guard !Task.isCancelled, await self.isCurrent(generationID) else { return }
                    let buffering = await persistence.bufferTokens(messageID: messageID, tokens: token)
                    if case .failure(let error) = buffering { throw error }
                    tokenBatch += token

                    let now = Date()
                    if tokenBatch.count >= 20 || now.timeIntervalSince(lastBatchTime) >= 0.5 {
                        let batch = tokenBatch
                        tokenBatch = ""
                        lastBatchTime = now
                        await MainActor.run { onToken(batch) }
                        await self.incrementTokenCount()
                    }
                }

                guard !Task.isCancelled, await self.isCurrent(generationID) else { return }
                if !tokenBatch.isEmpty {
                    let finalBatch = tokenBatch
                    await MainActor.run { onToken(finalBatch) }
                }
                let finalization = await persistence.endStreamingMessage(messageID: messageID)
                if await self.finishIfCurrent(generationID) {
                    switch finalization {
                    case .success:
                        await MainActor.run { onComplete() }
                    case .failure(let error):
                        await self.retainRecovery(messageID: messageID)
                        await MainActor.run { onError(error) }
                    }
                }
            } catch {
                guard await self.isCurrent(generationID) else { return }
                self.logger.error("Stream error: \(error.localizedDescription, privacy: .public)")
                if error is PersistenceFailure {
                    // A failed flush owns unsaved bytes; do not consume them via cancellation.
                    await self.retainRecovery(messageID: messageID)
                } else {
                    let cancelResult = await persistence.cancelStreamingMessage(messageID: messageID)
                    if case .failure = cancelResult {
                        // Cancellation finalization failed; retain recovery so the UI can
                        // reach retry/export/discard instead of silently deadlocking.
                        await self.retainRecovery(messageID: messageID)
                    }
                }
                if await self.finishIfCurrent(generationID) {
                    await MainActor.run { onError(error) }
                }
            }
        }
    }

    func retryRecoverySave() async -> Result<Void, PersistenceFailure> {
        guard let recoveryHandle else { return .failure(.notFound(operation: .save)) }
        let result = await persistence.retryStreamingSave(recoveryHandle)
        if case .success = result { self.recoveryHandle = nil }
        return result
    }

    func exportRecovery() async -> Result<Data, PersistenceFailure> {
        guard let recoveryHandle else { return .failure(.notFound(operation: .export)) }
        return await persistence.exportPartialResponse(recoveryHandle)
    }

    func discardRecovery() async -> Result<Void, PersistenceFailure> {
        guard let recoveryHandle else { return .failure(.notFound(operation: .save)) }
        let result = await persistence.discardRecovery(recoveryHandle)
        if case .success = result { self.recoveryHandle = nil }
        return result
    }

    private func retainRecovery(messageID: UUID) async {
        recoveryHandle = await persistence.recoveryHandle(messageID: messageID)
    }

    /// Cancels producer and consumer, then finalizes the captured message once.
    func cancel() async {
        await cancelInternal()
    }

    private func cancelInternal() async {
        guard activeGenerationID != nil || currentStream != nil || activeMessageID != nil else { return }

        // Invalidate first so stale callbacks/tasks cannot mutate a newer generation.
        activeGenerationID = nil
        let task = currentStream
        let messageID = activeMessageID
        currentStream = nil
        activeMessageID = nil
        isStreaming = false

        task?.cancel()
        await inferenceService.cancelCurrentStream()
        if let messageID {
            let result = await persistence.cancelStreamingMessage(messageID: messageID)
            if case .failure(let error) = result {
                await retainRecovery(messageID: messageID)
                logger.error("Cancellation persistence failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await task?.value
    }

    private func register(messageID: UUID, for generationID: UUID) -> Bool {
        guard activeGenerationID == generationID else { return false }
        activeMessageID = messageID
        return true
    }

    private func isCurrent(_ generationID: UUID) -> Bool {
        activeGenerationID == generationID
    }

    @discardableResult
    private func finishIfCurrent(_ generationID: UUID) -> Bool {
        guard activeGenerationID == generationID else { return false }
        activeGenerationID = nil
        activeMessageID = nil
        currentStream = nil
        isStreaming = false
        return true
    }

    private func incrementTokenCount() {
        processedTokenCount += 1
    }

    var tokenCount: Int { processedTokenCount }

    func resetTokenCount() {
        processedTokenCount = 0
    }
}

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
