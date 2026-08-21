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

    /// Immutable inputs for one streaming generation. Bundled so helper
    /// functions take a single value instead of long parameter lists.
    private struct GenerationContext {
        let kind: StreamKind
        let conversationID: UUID
        let messages: [ChatMessagePayload]
        let systemPrompt: String?
        let sampling: SamplingConfig
        let onToken: @Sendable (String) -> Void
        let onComplete: @Sendable () -> Void
        let onError: @Sendable (Error) -> Void
    }

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "chat-session")
    private let inferenceService: any InferenceServiceProtocol
    private let persistence: any PersistenceProviding

    private var currentStream: Task<Void, Never>?
    private var activeGenerationID: UUID?
    private var activeMessageID: UUID?
    private(set) var recoveryHandle: RecoveryHandle?
    private(set) var isStreaming = false
    private var processedTokenCount = 0

    init(inferenceService: any InferenceServiceProtocol, persistence: any PersistenceProviding) {
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

        // Preempt any holder of the engine (e.g. title generation) so this
        // chat decode never overlaps another decode loop on the same context.
        await inferenceService.ensureIdleForNewChat()

        let generationID = UUID()
        activeGenerationID = generationID
        isStreaming = true
        let inferenceService = self.inferenceService
        let persistence = self.persistence

        let context = GenerationContext(
            kind: kind,
            conversationID: conversationID,
            messages: messages,
            systemPrompt: systemPrompt,
            sampling: sampling,
            onToken: onToken,
            onComplete: onComplete,
            onError: onError
        )

        currentStream = Task { [weak self] in
            guard let self else { return }
            await self.runGeneration(
                generationID: generationID,
                context: context,
                inferenceService: inferenceService,
                persistence: persistence
            )
        }
    }

    /// Runs one streaming generation end-to-end: begin, pump, finalize.
    private func runGeneration(
        generationID: UUID,
        context: GenerationContext,
        inferenceService: any InferenceServiceProtocol,
        persistence: any PersistenceProviding
    ) async {
        let beginResult = await persistence.beginStreamingMessageResult(conversationID: context.conversationID)
        guard case .success(let messageID) = beginResult else {
            if await finishIfCurrent(generationID), case .failure(let failure) = beginResult {
                await MainActor.run { context.onError(failure) }
            }
            return
        }

        guard await register(messageID: messageID, for: generationID) else {
            await persistence.cancelStreamingMessage(messageID: messageID)
            return
        }

        do {
            let stream = try await Self.openStream(
                context: context,
                inferenceService: inferenceService
            )
            let completedNaturally = try await pumpTokens(
                stream,
                messageID: messageID,
                generationID: generationID,
                persistence: persistence,
                onToken: context.onToken
            )
            // Cancellation/invalidation exits the pump early; the canceller
            // owns finalization (exactly-once). Only a natural end may complete.
            guard completedNaturally else { return }
            await finalizeStream(
                messageID: messageID,
                generationID: generationID,
                persistence: persistence,
                onComplete: context.onComplete,
                onError: context.onError
            )
        } catch {
            await handleStreamFailure(
                error,
                messageID: messageID,
                generationID: generationID,
                persistence: persistence,
                onError: context.onError
            )
        }
    }

    private static func openStream(
        context: GenerationContext,
        inferenceService: any InferenceServiceProtocol
    ) async throws -> AsyncThrowingStream<String, Error> {
        switch context.kind {
        case .text:
            return try await inferenceService.streamChat(
                messages: context.messages,
                systemPrompt: context.systemPrompt,
                sampling: context.sampling
            )
        case .vision(let images):
            return try await inferenceService.streamVisionChat(
                messages: context.messages,
                images: images,
                systemPrompt: context.systemPrompt,
                sampling: context.sampling
            )
        }
    }

    /// Streams tokens into persistence and the UI callback. Throws when a
    /// token flush fails so the caller routes through failure handling.
    private func pumpTokens(
        _ stream: AsyncThrowingStream<String, Error>,
        messageID: UUID,
        generationID: UUID,
        persistence: any PersistenceProviding,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> Bool {
        var tokenBatch = ""
        var lastBatchTime = Date()
        for try await token in stream {
            guard !Task.isCancelled, await isCurrent(generationID) else { return false }
            let buffering = await persistence.bufferTokens(messageID: messageID, tokens: token)
            if case .failure(let error) = buffering { throw error }
            tokenBatch += token

            let now = Date()
            if Self.isBatchFlushDue(batchCount: tokenBatch.count, lastBatchTime: lastBatchTime, now: now) {
                let batch = tokenBatch
                tokenBatch = ""
                lastBatchTime = now
                await MainActor.run { onToken(batch) }
                await incrementTokenCount()
            }
        }

        guard !Task.isCancelled, await isCurrent(generationID) else { return false }
        if !tokenBatch.isEmpty {
            await MainActor.run { onToken(tokenBatch) }
        }
        return true
    }

    private static func isBatchFlushDue(batchCount: Int, lastBatchTime: Date, now: Date) -> Bool {
        batchCount >= 20 || now.timeIntervalSince(lastBatchTime) >= 0.5
    }

    /// Ends the persisted stream and reports completion or a failed finalization.
    private func finalizeStream(
        messageID: UUID,
        generationID: UUID,
        persistence: any PersistenceProviding,
        onComplete: @Sendable @escaping () -> Void,
        onError: @Sendable @escaping (Error) -> Void
    ) async {
        let finalization = await persistence.endStreamingMessage(messageID: messageID)
        if await finishIfCurrent(generationID) {
            switch finalization {
            case .success:
                await MainActor.run { onComplete() }
            case .failure(let error):
                await retainRecovery(messageID: messageID)
                await MainActor.run { onError(error) }
            }
        }
    }

    /// Routes stream failures: persistence failures keep their unsaved bytes
    /// for recovery; everything else cancels the captured message first.
    private func handleStreamFailure(
        _ error: Error,
        messageID: UUID,
        generationID: UUID,
        persistence: any PersistenceProviding,
        onError: @Sendable @escaping (Error) -> Void
    ) async {
        guard await isCurrent(generationID) else { return }
        logger.error("Stream error: \(error.localizedDescription, privacy: .public)")
        if error is PersistenceFailure {
            // A failed flush owns unsaved bytes; do not consume them via cancellation.
            await retainRecovery(messageID: messageID)
        } else {
            let cancelResult = await persistence.cancelStreamingMessage(messageID: messageID)
            if case .failure = cancelResult {
                // Cancellation finalization failed; retain recovery so the UI can
                // reach retry/export/discard instead of silently deadlocking.
                await retainRecovery(messageID: messageID)
            }
        }
        if await finishIfCurrent(generationID) {
            await MainActor.run { onError(error) }
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
