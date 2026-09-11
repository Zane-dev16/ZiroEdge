// ChatViewModel+TranscriptActions.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Transcript-level message actions: branching, retry, export, and delete.
// Split from ChatViewModel.swift to keep the main file within limits.

import Foundation
import UIKit

extension ChatViewModel {
    // MARK: - Branching

    func branchFromMessage(_ messageID: UUID) async {
        guard let sourceID = activeConversationID else { return }
        switch await persistence.branchConversationResult(
            sourceID: sourceID,
            fromMessageID: messageID,
            newTitle: "Branched Conversation"
        ) {
        case .success(let newID):
            await loadConversation(newID)
            // Mirror draft materialization/sendtest: refresh the sidebar and
            // select the new branch so the highlighted row matches the
            // visible transcript. The shell's onChange load is a no-op here
            // because activeConversationID already == newID.
            await conversationListViewModel?.loadConversations()
            conversationListViewModel?.selectedConversationID = newID
        case .failure(let failure):
            errorMessage = failure.localizedDescription
            showError = true
        }
    }

    // MARK: - Retry

    /// Retry is available when a user message exists and no stream is running.
    var canRetryLastResponse: Bool {
        !isStreaming && !isLoadingConversation
            && messages.contains(where: { $0.role == .user })
    }

    /// Regenerate the response to the last user message without duplicating
    /// it: history is truncated to that message and a fresh assistant reply
    /// is streamed and persisted by the normal completion path.
    /// R7: single-flight slot claimed before the first suspension plus a
    /// recovery pre-check (actor's recoveryBufferFull would refuse start).
    func retryLastResponse() async {
        guard !isStreaming, !isLoadingConversation else {
            logger.info("Retry dropped: already streaming or loading")
            return
        }
        // R7: claim synchronously; every early exit below must release.
        isStreaming = true
        // R7: recovery pre-check covers both the actor handle and the staged
        // VM flag (hermetic seam stages VM-only). Either blocks retry.
        let actorHasRecovery = await sessionActor.recoveryHandle != nil
        if hasPersistenceRecovery || actorHasRecovery {
            logger.info("Retry blocked: recovery pending")
            errorMessage = "A response is awaiting recovery. Retry, export, or discard it first."
            showError = true; isStreaming = false; return
        }
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            isStreaming = false; return
        }
        let snapshotID = activeConversationID
        let lastUser = messages[lastUserIndex]
        guard let conversationID = await validateSendPreconditions(
            text: lastUser.content, hasImages: !lastUser.attachments.isEmpty
        ) else { isStreaming = false; return }
        // R3: abort when a switch landed during validate's suspensions.
        guard activeConversationID == snapshotID,
              activeConversationID == conversationID else {
            logger.info("Retry aborted: conversation switched during validate")
            isStreaming = false; return
        }
        // R2/R8: residency + vision may have moved while suspended.
        guard lifecycleManager.activeModel?.id == selectedModel?.id,
              lifecycleManager.isModelLoaded else {
            logger.info("Retry aborted: residency lost post-validate")
            errorMessage = "The model is no longer loaded. Retry once it reloads."
            showError = true; isStreaming = false; return
        }
        let images = lastUser.attachments
        if !images.isEmpty, !isVisionModel {
            logger.info("Retry aborted: vision lost post-suspension")
            visionWarning = "Vision not supported with text-only model. Switch to a vision model."
            isStreaming = false; return
        }
        // REPLACE not duplicate: drop the previous assistant reply
        // (everything after the last user message) from disk + memory
        // before regenerating, so the transcript ends with one reply.
        if lastUserIndex + 1 < messages.count {
            for stale in messages[(lastUserIndex + 1)...] {
                _ = await persistence.deleteMessageResult(messageID: stale.id)
            }
            messages.removeSubrange((lastUserIndex + 1)...)
        }
        let history = Array(messages[...lastUserIndex])
        streamingText = ""; errorMessage = nil; visionWarning = nil
        resetStreamingBuffer()
        let generationID = UUID()
        activeGenerationID = generationID
        streamedConversationID = conversationID
        await startStreaming(
            generationID: generationID,
            conversationID: conversationID, history: history, images: images,
            hasImages: !images.isEmpty, isFirstExchange: false,
            firstUserMessage: lastUser.content
        )
    }

    // MARK: - Export

    /// Write the visible transcript as Markdown and stage it for ShareLink.
    func exportTranscript() {
        var lines = ["# Conversation", ""]
        for message in messages {
            lines.append(message.role == .user ? "## You" : "## Assistant")
            lines.append(message.content)
            lines.append("")
        }
        let text = lines.joined(separator: "\n")
        let name: String
        if let conversationID = activeConversationID {
            name = "ziroedge-transcript-\(conversationID.uuidString.prefix(8)).md"
        } else {
            name = "ziroedge-transcript.md"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            transcriptExportURL = url
        } catch {
            errorMessage = "Could not write transcript export."
            showError = true
        }
    }

    // MARK: - Delete

    /// Copy helper taking plain text so SwiftUI rows can capture the string
    /// instead of the whole payload in action closures.
    func copyMessageText(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// Delete a single message from disk and the visible transcript.
    func deleteMessage(_ messageID: UUID) async {
        switch await persistence.deleteMessageResult(messageID: messageID) {
        case .success:
            messages.removeAll { $0.id == messageID }
            await conversationListViewModel?.loadConversations()
        case .failure(let failure):
            errorMessage = failure.localizedDescription
            showError = true
        }
    }
}

extension ChatViewModel {
    // MARK: - P3 Context-Window Preflight (message-drop)

    /// Estimated tokens for one transcript payload (~4 chars/token).
    nonisolated static func estimatedMessageTokens(_ message: ChatMessagePayload) -> Int {
        max(1, message.content.count / 4)
    }

    /// Drop oldest messages until the estimated prompt fits `contextWindowSize
    /// - reserveTokens`. Newest messages are always kept. Pure for tests.
    /// Returns the kept suffix and the number dropped.
    nonisolated static func truncatedHistoryForContextWindow(
        _ history: [ChatMessagePayload],
        systemPrompt: String?,
        contextWindowSize: Int,
        reserveTokens: Int = 1024
    ) -> (kept: [ChatMessagePayload], dropped: Int) {
        let budget = contextWindowSize - max(0, reserveTokens)
        guard budget > 0 else { return (Array(history.suffix(1)), max(0, history.count - 1)) }
        let systemTokens = max(0, (systemPrompt ?? "").count / 4)
        var kept = history
        while kept.count > 1 {
            let total = systemTokens + kept.reduce(0) { $0 + estimatedMessageTokens($1) }
            guard total > budget else { break }
            kept.removeFirst()
        }
        return (kept, history.count - kept.count)
    }
}

extension ChatViewModel {
    // MARK: - Load Helpers (moved from ChatViewModel.swift to keep that file
    // within the type-body-length gate; behavior unchanged).

    /// First failure message from a `Result`, for surfacing load errors to the user.
    func resultFailureText<T, E: Error>(_ result: Result<T, E>) -> String? {
        guard case .failure(let error) = result else { return nil }
        return error.localizedDescription
    }

    /// A send that lands while a conversation is still loading is dropped —
    /// surface it through the transient warning banner instead of failing
    /// silently. The load path clears transient banners when it settles, so
    /// the message is posted after the in-flight load finishes.
    func surfaceSendBlockedDuringConversationLoad() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isLoadingConversation {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
            // A stream started after the load means the retry already happened.
            guard !self.isStreaming else { return }
            self.truncationWarning = "The conversation was still loading, so your message wasn't sent. Try again now that it's open."
        }
    }

    var effectiveSystemPrompt: String? {
        activeConversationSystemPrompt?.nilIfBlank
            ?? UserDefaults.standard.string(forKey: DefaultsKeys.defaultSystemPrompt)?.nilIfBlank
    }

    // MARK: - Title Generation

    /// Generate a title for the conversation after the first exchange.
    /// Only runs if the conversation title is still the default "New Conversation".
    func generateTitleIfNeeded(
        conversationID: UUID,
        userMessage: String,
        assistantResponse: String
    ) async {
        logger.info("Generating title for first exchange")
        let title = await titleGenerator.generateTitle(
            userMessage: userMessage,
            assistantResponse: assistantResponse
        )

        // Update only if the user has not renamed the conversation while the title was generated.
        switch await persistence.updateConversationTitleIfStill(
            id: conversationID,
            newTitle: title,
            expectedCurrentTitle: "New Conversation"
        ) {
        case .success:
            await conversationListViewModel?.loadConversations()
        case .failure(let failure):
            errorMessage = failure.localizedDescription
            showError = true
            return
        }

        logger.info("Title updated to: \(title, privacy: .public)")
    }

    // MARK: - Truncation Warning

    /// Called by the persistence layer when context window auto-truncates old messages.
    func notifyTruncation(messageCount: Int) {
        truncationWarning = "To stay within the context window, \(messageCount) older message\(messageCount == 1 ? " was" : "s were") removed."
    }

    /// Dismiss the truncation warning banner.
    func dismissTruncationWarning() {
        truncationWarning = nil
    }

    // MARK: - Token Count

    /// Reset the token count (called on new conversation or model switch).
    func resetTokenCount() {
        tokenCount = 0
        streamedCharacterCount = 0
    }

    // MARK: - Message Actions

    func copyMessage(_ message: ChatMessagePayload) {
        UIPasteboard.general.string = message.content
    }

    // MARK: - BATCH-04 Buffered Streaming Helpers

    private func currentTimeMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    func flushStreamingChunks() {
        guard !streamingChunks.isEmpty else { return }
        let chunk = streamingChunks.joined()
        streamingChunks.removeAll(keepingCapacity: true)
        if streamingText.isEmpty {
            streamingText = chunk
        } else {
            streamingText.append(chunk)
        }
        lastStreamingFlushMs = currentTimeMs()
    }

    /// ~4 characters per generated token is the standard heuristic for LLM output.
    nonisolated static func estimatedTokens(characterCount: Int) -> Int {
        guard characterCount > 0 else { return 0 }
        return max(1, characterCount / 4)
    }

    func appendStreamingToken(_ token: String, generationID: UUID) {
        guard activeGenerationID == generationID else { return }
        streamingChunks.append(token)
        streamedCharacterCount += token.count
        tokenCount = Self.estimatedTokens(characterCount: streamedCharacterCount)
        let now = currentTimeMs()
        let elapsed = now - lastStreamingFlushMs
        let shouldFlush = streamingChunks.count >= streamingChunkThreshold || elapsed >= streamingFlushIntervalMs
        if shouldFlush {
            streamingFlushTask?.cancel()
            flushStreamingChunks()
        } else {
            streamingFlushTask?.cancel()
            streamingFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard let self, self.activeGenerationID == generationID else { return }
                self.flushStreamingChunks()
            }
        }
    }

    func resetStreamingBuffer() {
        streamingFlushTask?.cancel()
        streamingFlushTask = nil
        streamingChunks.removeAll(keepingCapacity: true)
        lastStreamingFlushMs = currentTimeMs()
        streamedCharacterCount = 0
    }
}

extension ChatViewModel {
    // MARK: - P3 Generation Slot (moved from ChatViewModel.swift for length gate)

    /// Shared completion/reset of a generation slot; both success and error
    /// closures funnel through this.
    func finishGeneration(_ generationID: UUID, reason: StreamEndReason) {
        streamingFlushTask?.cancel()
        flushStreamingChunks()
        activeGenerationID = nil
        isStreaming = false
        streamedConversationID = nil
        lastStreamEndReason = reason
    }

    /// Post-stream reload gate (P3 item 9 synthesis): reload only when the
    /// completed generation still owns the visible surface, no user-unload
    /// intent is parked, and a model is still resident (eviction must not
    /// reload the just-evicted model back). IDs are public.
    func shouldReloadAfterGeneration(conversationID: UUID) -> Bool {
        guard activeConversationID == conversationID else {
            logger.info("Post-stream reload skipped: switched conversation")
            return false
        }
        guard !lifecycleManager.isUserUnloaded else { return false }
        guard lifecycleManager.activeModel != nil,
              lifecycleManager.currentState != .evicted else {
            logger.info("Post-stream reload skipped: evicted state")
            return false
        }
        return true
    }
}
