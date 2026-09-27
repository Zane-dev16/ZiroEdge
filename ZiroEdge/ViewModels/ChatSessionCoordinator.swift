// ChatSessionCoordinator.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Deep module owning the chat session's entangled mutable state: draft
// parking, the single-flight generation slot, and the buffered streaming
// accumulator. ChatViewModel keeps the @Published SwiftUI surface and
// delegates here, so send/retry/cancel vs. conversation-switch interactions
// funnel through one owner instead of scattered cross-extension vars.

import Foundation
import os

/// Single owner for draft, generation-slot, and streaming-buffer state.
/// `@MainActor`: every caller is already `@MainActor`.
@MainActor
final class ChatSessionCoordinator {

    /// Terminal reason for the most recent generation. Moved here from
    /// ChatViewModel (which typealiases it for source compatibility).
    enum StreamEndReason {
        case completed
        case stopped
        case failed
        case truncated
    }

    // MARK: - Draft storage keys (single source; ChatViewModel.DefaultsKeys aliases these)

    static let draftsByConversationKey = "ZiroEdge.chatDraftsByConversation.v1"
    static let newChatDraftKey = "ZiroEdge.chatDraftForNewChat.v1"

    // MARK: - Draft state

    /// Per-conversation draft text, keyed by conversation ID. Memory-only by
    /// design (drafts are unsent); attachments are never restored with text.
    var draftsByConversation: [UUID: String] = [:]
    /// Parked text for the unsaved draft chat (no conversation row yet, so no
    /// dictionary key). Cleared on fresh-draft start and on send.
    var newChatDraft = ""

    // MARK: - Generation slot

    /// Identity of the generation allowed to mutate streaming UI.
    var activeGenerationID: UUID?
    /// Conversation the live generation is writing into; lets switches
    /// detect and cancel a stream that belongs elsewhere.
    var streamedConversationID: UUID?
    /// Draft-path single-flight: guards draft materialization against
    /// re-entry while a first send is suspended creating the row.
    var isMaterializingDraft = false
    /// Why the most recent stream ended. Read alongside the isStreaming flip.
    var lastStreamEndReason: StreamEndReason?

    // MARK: - Streaming buffer (BATCH-04: avoids O(n) copy per token)

    private var chunks: [String] = []
    var streamedCharacterCount = 0
    private var pendingFlush: Task<Void, Never>?
    private var lastFlushMs: UInt64 = Self.nowMs()
    /// Flush when this many tokens accumulate (legacy streamingChunkThreshold).
    private static let chunkThreshold = 20
    /// Or when this many ms elapsed (legacy streamingFlushIntervalMs).
    private static let flushIntervalMs: UInt64 = 80

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "chat-coordinator")

    // MARK: - Draft transitions

    /// Park live composer text: persisted conversations keep their UUID key;
    /// the unsaved draft lands in the new-chat slot instead of being dropped.
    func park(input: String, activeID: UUID?) {
        if let id = activeID {
            draftsByConversation[id] = input
        } else {
            newChatDraft = input
        }
    }

    /// Parked text for a conversation, nil when none/blank.
    func parkedText(for conversationID: UUID) -> String? {
        guard let text = draftsByConversation[conversationID],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Draft text to restore into an empty composer for the given context.
    func draftForRestoring(activeID: UUID?) -> String? {
        if let id = activeID { return parkedText(for: id) }
        return newChatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newChatDraft
    }

    /// Consume the unsaved-draft slot (fresh start or first send).
    func consumeNewChatDraft() {
        newChatDraft = ""
    }

    /// Flush non-blank drafts to UserDefaults. Blanks remove their key.
    /// Content is never logged — counts only.
    func persist(defaults: UserDefaults = .standard) {
        let nonBlank = draftsByConversation.filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if nonBlank.isEmpty {
            defaults.removeObject(forKey: Self.draftsByConversationKey)
        } else {
            defaults.set(
                Dictionary(uniqueKeysWithValues: nonBlank.map { ($0.key.uuidString, $0.value) }),
                forKey: Self.draftsByConversationKey
            )
        }
        if newChatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: Self.newChatDraftKey)
        } else {
            defaults.set(newChatDraft, forKey: Self.newChatDraftKey)
        }
        let hasNewChat = newChatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        logger.info("Drafts persisted conversations=\(nonBlank.count, privacy: .public) newChat=\(hasNewChat, privacy: .public)")
    }

    /// Merge persisted drafts into memory: fills only absent keys so live
    /// (fresher) state always wins within a session, while a fresh launch
    /// hydrates everything the previous run flushed.
    func restore(defaults: UserDefaults = .standard) {
        var restored = 0
        if let stored = defaults.dictionary(forKey: Self.draftsByConversationKey) {
            for (key, value) in stored {
                guard let id = UUID(uuidString: key),
                      let text = value as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      draftsByConversation[id] == nil else { continue }
                draftsByConversation[id] = text
                restored += 1
            }
        }
        if newChatDraft.isEmpty,
           let newChat = defaults.string(forKey: Self.newChatDraftKey),
           !newChat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newChatDraft = newChat
            restored += 1
        }
        if restored > 0 {
            logger.info("Drafts restored count=\(restored, privacy: .public)")
        }
    }

    // MARK: - Generation-slot transitions

    /// Claim the slot for a new generation; returns its identity.
    func claim(conversationID: UUID) -> UUID {
        let id = UUID()
        activeGenerationID = id
        streamedConversationID = conversationID
        return id
    }

    /// True when this generation still owns the slot.
    func owns(_ generationID: UUID) -> Bool {
        activeGenerationID == generationID
    }

    /// Release the slot without recording a reason (switch/clear paths).
    func detachSlot() {
        activeGenerationID = nil
        streamedConversationID = nil
    }

    /// Shared completion of a generation slot: cancel the pending flush,
    /// drain the buffer tail, detach, and record the reason. Returns the
    /// drained tail for the caller to apply to its published text.
    @discardableResult
    func finish(_ generationID: UUID, reason: StreamEndReason) -> String {
        cancelPendingFlush()
        let tail = drain()
        detachSlot()
        lastStreamEndReason = reason
        return tail
    }

    // MARK: - Streaming-buffer transitions

    func appendToken(_ token: String) {
        chunks.append(token)
        streamedCharacterCount += token.count
    }

    /// Drain buffered chunks into one string. Stamps the flush clock only
    /// when non-empty (matches the legacy flushStreamingChunks gate).
    @discardableResult
    func drain() -> String {
        guard !chunks.isEmpty else { return "" }
        let out = chunks.joined()
        chunks.removeAll(keepingCapacity: true)
        lastFlushMs = Self.nowMs()
        return out
    }

    func resetBuffer() {
        cancelPendingFlush()
        chunks.removeAll(keepingCapacity: true)
        lastFlushMs = Self.nowMs()
        streamedCharacterCount = 0
    }

    func cancelPendingFlush() {
        pendingFlush?.cancel()
        pendingFlush = nil
    }

    func shouldFlushNow() -> Bool {
        chunks.count >= Self.chunkThreshold || Self.nowMs() - lastFlushMs >= Self.flushIntervalMs
    }

    /// Debounced flush firing `work` after 80ms (legacy interval, verbatim
    /// semantics: cancellation shortens the sleep; ownership is re-checked
    /// by the work closure itself).
    func scheduleDelayedFlush(_ work: @escaping @MainActor @Sendable () -> Void) {
        pendingFlush?.cancel()
        pendingFlush = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            work()
        }
    }

    private static func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - Conversation Lifecycle (ChatViewModel adapter)

/// Conversation lifecycle owned alongside the draft/slot state above:
/// draft start, just-in-time materialization, transcript loading, and
/// clearing. Moved verbatim from ChatViewModel.swift to hold that file
/// within its type-body-length gate; behavior unchanged.
extension ChatViewModel {
    /// Reset the surface to an unsaved, untitled chat. Cheap and synchronous:
    /// no persistence row exists until first send. Nominates a display
    /// candidate for the header pill when nothing is chosen yet.
    func beginNewDraft() {
        clearActiveConversation()
        // A tapped New Conversation is an explicit fresh start (P2-8): drop
        // any parked unsaved-draft text so a later foreground restore cannot
        // resurrect it into the empty composer, and flush the removal.
        sessionCoordinator.consumeNewChatDraft()
        persistDraftsToDefaults()
        isDraftConversation = true
        // Starting a fresh draft consumes a prior user-unload intent (Settings
        // → Unload Model): nominating a display candidate here is a deliberate
        // step toward loading again.
        lifecycleManager.consumeUserUnloadIntent()
        conversationListViewModel?.selectedConversationID = nil
        if selectedModel == nil, let candidate = preferredAutoLoadCandidate() {
            selectedModel = candidate
        }
        refreshModelLoadPhase()
        startDeferredModelLoadIfNeeded()
    }

    /// Create the persistence row backing an in-memory draft at first send.
    /// Mirrors the failure mapping of `startNewConversation(model:)` exactly.
    /// Internal: the send-validation extension in ChatModelLoading.swift calls it.
    func materializeDraftForSend() async -> UUID? {
        // Single-flight: inputText is only cleared by the caller after this
        // returns, so a double-tap of Send (or Send + keyboard onSubmit) can
        // re-enter while the first task is suspended inside
        // createConversationResult. Without this guard both tasks create a
        // conversation — duplicate "New Conversation" rows, an orphaned row
        // holding only the user message — and the second send overwrites
        // activeGenerationID so the first response is silently discarded.
        // Mirrors the isStartingConversation guard on the legacy path.
        guard !isMaterializingDraft else { return nil }
        isMaterializingDraft = true
        defer { isMaterializingDraft = false }

        guard let model = selectedModel else {
            needsModelRedirect = true
            return nil
        }
        // Commit any instructions staged on the draft (instructions editor
        // before first send); fall back to the global default when untouched.
        let stagedPrompt = activeConversationSystemPrompt
        let defaultPrompt = UserDefaults.standard.string(forKey: DefaultsKeys.defaultSystemPrompt)
        let result = await persistence.createConversationResult(
            id: UUID(),
            title: "New Conversation",
            modelID: model.id,
            systemPrompt: stagedPrompt ?? defaultPrompt?.nilIfBlank
        )
        guard case .success(let id) = result else {
            if case .failure(let error) = result {
                errorMessage = "Could not start the conversation. \(error.localizedDescription)"
                showError = true
                isStartupError = true
            }
            return nil
        }
        // Commit identity before returning so streaming/persistence callbacks
        // attach to this conversation even if the caller suspends immediately.
        // The unsaved-draft slot is consumed (P2-8): the text being sent now
        // lives in the message, so a stale slot must never restore over it.
        isDraftConversation = false
        sessionCoordinator.consumeNewChatDraft()
        activeConversationID = id
        activeConversationSystemPrompt = stagedPrompt ?? defaultPrompt?.nilIfBlank
        await conversationListViewModel?.loadConversations()
        conversationListViewModel?.selectedConversationID = id
        return id
    }

    func loadConversation(_ conversationID: UUID) async {
        // Switching conversations must not leave a live generation writing into
        // the wrong transcript or yanking navigation back on completion.
        // R4: suppress the cancel's trailing reload — this load is the reload,
        // so a second load of the outgoing ID would double-fetch and race selectModel.
        if isStreaming, let streamed = streamedConversationID, streamed != conversationID {
            logger.info("Switch cancel suppressReload streamed=\(streamed.uuidString.prefix(8), privacy: .public) target=\(conversationID.uuidString.prefix(8), privacy: .public)")
            await cancelStream(suppressReload: true)
        }
        let previousConversationID = activeConversationID
        loadGeneration += 1
        let myGeneration = loadGeneration
        isLoadingConversation = true
        truncationWarning = nil

        async let messagesResult = persistence.fetchMessagesResult(conversationID: conversationID)
        async let conversationsResult = persistence.fetchConversationsResult(historyEligibleOnly: false)
        let (messageResult, conversationResult) = await (messagesResult, conversationsResult)
        guard loadGeneration == myGeneration else { return }

        guard case .success(let fetched) = messageResult,
              case .success(let conversations) = conversationResult,
              let conversation = conversations.first(where: { $0.id == conversationID }) else {
            isLoadingConversation = false
            errorMessage = [resultFailureText(messageResult), resultFailureText(conversationResult)]
                .compactMap { $0 }.first ?? "The selected conversation is no longer available."
            showError = true
            conversationListViewModel?.selectedConversationID = previousConversationID
            return
        }

        // Park the outgoing draft before committing the switch, then restore the
        // target's parked draft together with the transcript: text moves with its
        // conversation exactly like attachments do (cleared, never migrated).
        // Unsaved-draft text parks into the new-chat slot (P2-8) instead of
        // being dropped.
        parkInputTextIntoMemory()

        // Commit identity and content together so a failed fetch can never pair the
        // previous transcript with the newly selected conversation.
        // Switching conversations must not carry staged attachments forward:
        // clear pendingImages/visionWarning only on an actual switch. A
        // same-ID reload (post-stream refresh) preserves images staged
        // mid-stream for the next message (Batch02 race guard).
        if previousConversationID != conversationID {
            pendingImages = []
            visionWarning = nil
            visionDownscaleOffer = nil
        }
        activeConversationID = conversationID
        activeConversationTitle = conversation.title
        isDraftConversation = false
        inputText = sessionCoordinator.parkedText(for: conversationID) ?? ""
        messages = fetched
        activeConversationSystemPrompt = conversation.systemPrompt
        tokenCount = min(contextWindowSize, fetched.reduce(0) { $0 + max(1, $1.content.count / 4) })
        truncationWarning = nil
        errorMessage = nil

        if conversation.modelID == AppleIntelligenceMarker.modelID {
            // FM is an engine, not a downloadable artifact: it can never be
            // "removed". Select it when ready; otherwise surface the
            // FM-aware unavailable banner (copy handled at the banner).
            unavailableConversationModelID = nil
            if selectEngine(.appleIntelligence) {
                print("[FM-CONV] opened apple-intelligence conversation, FM engine active")
                needsModelRedirect = false
            } else {
                unavailableConversationModelID = conversation.modelID
                needsModelRedirect = true
            }
        } else if let model = modelProvider().first(where: { $0.id == conversation.modelID }) {
            unavailableConversationModelID = nil
            if let readyVariant = availableModels.first(where: { $0.id == model.id }) {
                await selectModel(readyVariant)
            } else {
                selectedModel = model
                needsModelRedirect = true
            }
        } else {
            // Keep the transcript visible, but never silently replace a removed import.
            unavailableConversationModelID = conversation.modelID
            selectedModel = nil
            needsModelRedirect = true
        }
        guard loadGeneration == myGeneration else { return }
        isLoadingConversation = false
        refreshModelLoadPhase()
    }

    /// Clear transient transcript state when the selected conversation disappears.
    func clearActiveConversation() {
        // Detach any live generation before wiping state so stale callbacks cannot
        // write into cleared buffers; actor cancel finishes asynchronously.
        let wasStreaming = isStreaming
        // Park the outgoing draft (P2-8): persisted conversations keep their
        // key; unsaved-draft text lands in the new-chat slot.
        parkInputTextIntoMemory()
        sessionCoordinator.detachSlot()
        loadGeneration += 1
        activeConversationID = nil
        activeConversationTitle = nil
        messages = []
        inputText = ""
        streamingText = ""
        resetStreamingBuffer()
        tokenCount = 0
        sessionCoordinator.streamedCharacterCount = 0
        isLoadingConversation = false
        isStartupError = false
        truncationWarning = nil
        activeConversationSystemPrompt = nil
        unavailableConversationModelID = nil
        // Attachments belong to the conversation being left: without this,
        // images staged in one chat follow into the next transcript and can be
        // sent into the wrong conversation. beginNewDraft funnels through here.
        pendingImages = []
        visionWarning = nil
        visionDownscaleOffer = nil
        // A fresh draft orphans any retained partial response: release the
        // recovery outright (P1-5) so its banner can never follow onto the
        // unsaved chat. Switching between persisted conversations keeps the
        // retained recovery stored but hidden via `shouldShowPersistenceRecovery`.
        releasePersistenceRecovery()
        refreshModelLoadPhase()
        if wasStreaming {
            // Park the streaming UI synchronously so the fresh draft never shows
            // a live Stop control or thinking row while the actor cancel is in
            // flight; stale generation callbacks are already gated on the
            // generation identity nilled above, and cancelStream re-asserts
            // this state when the backend teardown lands.
            isStreaming = false
            lastStreamEndReason = .stopped
            Task { await self.cancelStream(suppressReload: true) }
        }
    }
}
