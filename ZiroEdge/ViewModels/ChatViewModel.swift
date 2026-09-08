// ChatViewModel.swift
// ZiroEdge — Privacy-first local AI assistant
//
// ViewModel for the main chat interface. Bridges ChatSessionActor with SwiftUI.

import Combine
import Foundation
import SwiftUI
import os

/// Protocol for checking model download status. Enables testability.
protocol ModelDownloadStatusProvider: AnyObject {
    func status(for model: AIModel) -> ModelDownloadStatus
}

extension DownloadManager: @preconcurrency ModelDownloadStatusProvider {}

/// User-facing residency state of the chat's selected model.
/// A pure projection of `ModelLifecycleManager` state (see `refreshModelLoadPhase`).
enum ModelLoadPhase: Equatable {
    /// Decided nothing yet — the brief window before the deferred load begins.
    case idle
    /// No downloaded candidate exists at all; CTA pushes the models catalog.
    case needsDownload
    /// Lifecycle `.loading`, or switching between models.
    case loading
    /// The selected model is resident and accepting work.
    case ready
    /// Evicted / memory-pressure unload; may be retried automatically on appear.
    case evicted
    /// Last load failure with its user-visible message.
    case failed(String)
}

@MainActor
final class ChatViewModel: ObservableObject {

    /// Terminal reason for the most recent generation, recorded wherever
    /// `isStreaming` is set false. `completed` is a natural end; `stopped` is
    /// user/internal cancellation; `failed` is an error termination (its
    /// banner announces itself, so the completion cue stays silent).
    /// `truncated` is a natural end whose prompt was shortened to fit the
    /// context window (message-drop preflight and/or engine sliding-window).
    enum StreamEndReason {
        case completed
        case stopped
        case failed
        case truncated
    }

    // MARK: - Published State

    @Published var messages: [ChatMessagePayload] = []
    @Published var inputText: String = ""
    /// Per-conversation draft text, keyed by conversation ID. Saved on every
    /// successful conversation switch and new-draft reset, restored after the
    /// target transcript loads — the text twin of the pendingImages clear on
    /// real switches, so a half-typed message never migrates into the wrong
    /// chat. Memory-only by design (drafts are unsent); attachments are
    /// deliberately NOT restored (cleared together with the parked text).
    /// Internal (not private): the composer-state extension in
    /// ChatAttachmentPipeline.swift parks/persists it.
    var draftStore: [UUID: String] = [:]
    /// Parked text for the unsaved draft chat (no conversation row yet, so no
    /// `draftStore` key). Preserved across switches/backgrounding and flushed
    /// to UserDefaults with the rest of the store (P2-8); cleared whenever a
    /// fresh draft is explicitly started or the draft materializes on send.
    /// Internal (not private): see `draftStore`.
    var draftForNewChat: String = ""
    /// Focus-reset generation (P2-6): bumped via `requestComposerResign` every
    /// time the shell navigates away from the composer (sidebar open,
    /// conversation switch, new draft, route push). ChatView observes it and
    /// clears its `@FocusState` so the keyboard and focus ring never linger
    /// over the pushed surface — the chat stays mounted beneath it, so no
    /// disappear/appear cycle resigns for us. Internal setter: bumped via
    /// `requestComposerResign` from the composer-state extension.
    @Published var composerResignGeneration: UInt64 = 0
    @Published var isStreaming: Bool = false
    /// Why the most recent stream ended. Drives the VoiceOver end-of-stream
    /// cue (ChatView's onChange(of: isStreaming)): every termination funnels
    /// through the same isStreaming flip, so without a recorded reason a
    /// user-initiated Stop or an error would announce a false "complete".
    /// Not published — read alongside the isStreaming flip in the view.
    /// Internal setter: the generation-slot extension in
    /// ChatViewModel+TranscriptActions.swift writes it via finishGeneration.
    var lastStreamEndReason: StreamEndReason?
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var streamingText: String = ""
    @Published var isLoadingConversation = false
    @Published var isStartingConversation = false
    /// Draft-path single-flight: guards `materializeDraftForSend` against
    /// re-entry while a first send is suspended creating the conversation
    /// row (`startNewConversation`'s guard covers only the legacy path).
    /// Not published — no UI observes draft materialization directly.
    private var isMaterializingDraft = false
    @Published var isStartupError = false
    @Published private(set) var activeConversationSystemPrompt: String?
    @Published private(set) var hasPersistenceRecovery = false
    /// Conversation the retained partial response belongs to. Set alongside
    /// `hasPersistenceRecovery`; cleared with it. The banner renders only
    /// when `activeConversationID == recoveryConversationID` so a recovery
    /// retained for one chat never surfaces on another chat or a fresh
    /// draft (P1-5 scoping).
    @Published private(set) var recoveryConversationID: UUID?
    /// True when the recovery banner may render on the visible surface.
    var shouldShowPersistenceRecovery: Bool {
        hasPersistenceRecovery && recoveryConversationID != nil
            && recoveryConversationID == activeConversationID
    }
    /// In-place reason the last manual `retryModelLoad` refused to start
    /// (P1-4): shown as a hint under the disabled Retry row instead of a
    /// silent guard return. Nil when retry is available or never attempted.
    /// Internal setter: written by the loading extension in
    /// ChatModelLoading.swift, read by the chat surface and tests.
    @Published var retryIneligibilityHint: String?
    /// True while a model load is genuinely in flight (lifecycle attempt
    /// or deferred autoload task): Retry/Reload disable + spinner here.
    var isModelRetryInFlight: Bool {
        lifecycleManager.isLoadAttemptInFlight || deferredLoadTask != nil
    }
    @Published private(set) var recoveryExportURL: URL?
    /// staged transcript file for the share sheet. Rebuilt on each export.
    @Published var transcriptExportURL: URL?
    @Published private(set) var unavailableConversationModelID: String?

    /// Observable projection of the model residency bridging ModelLifecycleManager:
    /// drives the chat header pill and composer gating. Written only by the
    /// loading extensions in ChatModelLoading.swift and selection mutations.
    @Published var modelLoadPhase: ModelLoadPhase = .idle

    /// True while the visible surface is an unsaved chat. Drafts exist purely
    /// in memory — no persistence row until first send (`materializeDraftForSend`).
    @Published private(set) var isDraftConversation: Bool

    // MARK: - Chat UX State

    /// Current token count from the session actor (updated during streaming).
    @Published var tokenCount: Int = 0

    // MARK: - Image Attachment State

    /// Pending images attached to the current input. Cleared after sending.
    @Published var pendingImages: [Data] = []

    /// Warning shown when user tries to send images with a text-only model.
    @Published var visionWarning: String?

#if DEBUG
    /// Test hook injected between the two awaits in sendMessage to simulate
    /// the pendingImages lost-update race deterministically.
    var testHookBetweenAwaits: (() async -> Void)?
#endif

    /// Context window size in tokens (default 4096).
    let contextWindowSize: Int = 4096

    /// Warning message when context window auto-truncates old messages.
    @Published var truncationWarning: String?

    /// Identity of the generation allowed to mutate streaming UI.
    var activeGenerationID: UUID?
    /// Conversation the live generation is writing into; lets conversation
    /// switches detect and cancel a stream that belongs elsewhere.
    var streamedConversationID: UUID?

    // MARK: - Model Selection

    /// The currently selected model for this chat session.
    @Published var selectedModel: AIModel?

    /// Whether we need to redirect user to the models page (no downloaded models).
    @Published var needsModelRedirect: Bool = false

    /// Whether a model switch is in progress.
    @Published var isSwitchingModel: Bool = false

    /// First-use consent for an installed Hugging Face import is requested from
    /// the picker instead of hiding the model until consent is granted elsewhere.
    @Published var showingExperimentalConsent = false
    @Published private(set) var pendingExperimentalModel: AIModel?

    /// In-flight asynchronous autoload started from ChatView appearing. Owned
    /// by the loading extensions in ChatModelLoading.swift.
    var deferredLoadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Dependencies

    let persistence: any PersistenceProviding
    private let inferenceService: any InferenceServiceProtocol
    /// Read-shared with the persistence-recovery extension in
    /// ChatPersistenceRecovery.swift.
    let sessionActor: ChatSessionActor
    /// Read-shared with the deferred-load extensions in
    /// ChatModelLoading.swift.
    let lifecycleManager: ModelLifecycleManager
    /// Read-shared with the send-preflight helper in ChatModelLoading.swift.
    let downloadStatusProvider: any ModelDownloadStatusProvider
    private let modelProvider: () -> [AIModel]
    let titleGenerator: TitleGenerator
    /// Read-shared with the send-preflight helper in ChatModelLoading.swift.
    let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "chat-vm")

    /// Weak reference to the conversation list ViewModel for sidebar reloads.
    weak var conversationListViewModel: ConversationListViewModel?

    private(set) var activeConversationID: UUID?
    /// The active conversation's title for the nav bar. Nil for unsaved
    /// drafts — the bar reads "New chat" instead of a placeholder.
    @Published private(set) var activeConversationTitle: String?
    private var loadGeneration: UInt64 = 0

    // BATCH-04: buffered streaming — avoids O(n) copy per token and debounces Published churn
    var streamingChunks: [String] = []
    var streamedCharacterCount = 0
    var streamingFlushTask: Task<Void, Never>?
    var lastStreamingFlushMs: UInt64 = 0
    let streamingFlushIntervalMs: UInt64 = 80
    let streamingChunkThreshold = 20

    // MARK: - UserDefaults Keys

    enum DefaultsKeys {
        static let lastUsedModelID = "lastUsedModelID"
        static let defaultSystemPrompt = "defaultSystemPrompt"
        /// Per-conversation drafts parked for kill-recovery (P2-8):
        /// `[conversationUUIDString: draftText]`, blanks omitted.
        static let draftsByConversation = "ZiroEdge.chatDraftsByConversation.v1"
        /// Parked text for the unsaved draft chat (P2-8); absent when blank.
        static let newChatDraft = "ZiroEdge.chatDraftForNewChat.v1"
    }

    // MARK: - Initialization

    init(
        persistence: any PersistenceProviding,
        inferenceService: any InferenceServiceProtocol,
        sessionActor: ChatSessionActor,
        lifecycleManager: ModelLifecycleManager,
        downloadStatusProvider: any ModelDownloadStatusProvider,
        titleGenerator: TitleGenerator? = nil,
        modelProvider: @escaping () -> [AIModel] = { ModelRegistry.libraryModels }
    ) {
        self.persistence = persistence
        self.inferenceService = inferenceService
        self.sessionActor = sessionActor
        self.lifecycleManager = lifecycleManager
        self.downloadStatusProvider = downloadStatusProvider
        self.modelProvider = modelProvider
        self.titleGenerator = titleGenerator ?? TitleGenerator(inferenceService: inferenceService)
        // The visible chat surface always starts as an untitled draft; opening
        // a persisted conversation clears the flag again.
        self.isDraftConversation = true

        // Keep the load-phase projection live without polling: every publish
        // from the lifecycle manager re-derives the observable phase.
        lifecycleManager.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshModelLoadPhase() }
            }
            .store(in: &cancellables)

        // A completed download can resolve a stale .needsDownload/.idle phase.
        // Observe the concrete DownloadManager (production wiring) and
        // re-derive the phase plus re-kick the deferred loader when a
        // candidate appears. Test doubles conform to
        // ModelDownloadStatusProvider without being ObservableObjects, so this
        // cast no-ops in unit tests and preserves the init signature.
        if let downloadManager = downloadStatusProvider as? DownloadManager {
            downloadManager.objectWillChange
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.refreshModelLoadPhase()
                        self.startDeferredModelLoadIfNeeded()
                    }
                }
                .store(in: &cancellables)
        }

        // P2-8: hydrate parked drafts persisted by a previous run (background
        // kill) so the first foreground restore already sees them.
        restoreDraftsFromDefaults()
    }

    // MARK: - Conversation Management

    /// All models that are fully downloaded and available for use.
    var availableModels: [AIModel] {
        modelProvider().compactMap { model in
            switch model.runtimeEligibility {
            case .validated:
                break
            case .experimental:
                // Imported models must be discoverable in the picker before
                // first-use consent. Existing curated experimental behavior is
                // unchanged: those profiles remain hidden until enabled.
                guard model.isImported || ExperimentalModelConsent.isGranted(for: model) else {
                    return nil
                }
            case .unavailable:
                return nil
            }
            let status = downloadStatusProvider.status(for: model)
            guard status.isReady else { return nil }
            if model.allowsTextOnlyCapability && !status.isVisionReady {
                return model.textOnlyRuntimeVariant
            }
            return model
        }
    }

    /// Select a model and persist the choice. Loads it if not already loaded.
    /// Returns false when selection is waiting for explicit first-use consent.
    @discardableResult
    func selectModel(_ model: AIModel) async -> Bool {
        defer { refreshModelLoadPhase() }
        guard model.runtimeEligibility != .experimental
                || ExperimentalModelConsent.isGranted(for: model) else {
            pendingExperimentalModel = model
            showingExperimentalConsent = true
            return false
        }

        let previousSelection = selectedModel
        selectedModel = model
        // Explicit selection consumes a prior user-unload intent (Settings →
        // Unload Model): the user is naming a model to work with again.
        lifecycleManager.consumeUserUnloadIntent()

        // An automatic load may already be in flight — e.g. the appear-time
        // deferred load racing a conversation opened from the drawer during
        // the startup window. Two concurrent loadModel calls unload the
        // shared engine, race currentState through both attempts, and can
        // leave the selection and residency mismatched until a later
        // interaction, so queue the switch until the in-flight attempt
        // settles. Re-evaluated on every wake: the settling load (or another
        // waiter) may have already loaded the requested model, which makes
        // the switch below a no-op.
        while lifecycleManager.activeModel?.id != model.id,
              lifecycleManager.isLoadAttemptInFlight {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                // Cancelled mid-wait: leave the in-flight attempt as the sole
                // loader instead of starting a switch from a dead task, and
                // restore the prior selection so the phase projection cannot
                // park on a mismatched "loading" state nothing will resolve.
                selectedModel = lifecycleManager.activeModel ?? previousSelection
                return false
            }
        }

        if lifecycleManager.activeModel?.id != model.id {
            isSwitchingModel = true
            await lifecycleManager.switchToModel(model)
            isSwitchingModel = false
        }

        if lifecycleManager.activeModel?.id == model.id {
            selectedModel = model
            UserDefaults.standard.set(model.id, forKey: DefaultsKeys.lastUsedModelID)
            // Repairing an unavailable-model conversation must stick: reassign
            // the persisted modelID so the post-stream reload does not re-enter
            // the unavailable branch and wipe the just-made selection. Only
            // clears on durable success; a persistence failure keeps the banner
            // so the user can retry.
            if let activeID = activeConversationID, unavailableConversationModelID != nil {
                if case .success = await persistence.updateConversationModelID(id: activeID, modelID: model.id) {
                    unavailableConversationModelID = nil
                    needsModelRedirect = false
                }
            }
            UISelectionFeedbackGenerator().selectionChanged()
            return true
        }

        // Failed switch: when nothing is resident, pin the failed target (not a
        // stale/nil selection) so the .loadFailed projection keeps .failed for
        // THIS model and Retry retries it. When the manager restored the prior
        // resident (post-teardown bring-back) or a pre-teardown refusal kept it,
        // fall back to the resident so the composer reads .ready again.
        selectedModel = lifecycleManager.activeModel ?? model
        return false
    }

    func confirmExperimentalConsent() async {
        guard let model = pendingExperimentalModel else { return }
        ExperimentalModelConsent.setGranted(true, for: model)
        pendingExperimentalModel = nil
        showingExperimentalConsent = false
        await selectModel(model)
    }

    func cancelExperimentalConsent() {
        pendingExperimentalModel = nil
        showingExperimentalConsent = false
    }

    // MARK: - Draft Conversation

    /// Reset the surface to an unsaved, untitled chat. Cheap and synchronous:
    /// no persistence row exists until first send. Nominates a display
    /// candidate for the header pill when nothing is chosen yet.
    func beginNewDraft() {
        clearActiveConversation()
        // A tapped New Conversation is an explicit fresh start (P2-8): drop
        // any parked unsaved-draft text so a later foreground restore cannot
        // resurrect it into the empty composer, and flush the removal.
        draftForNewChat = ""
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
        draftForNewChat = ""
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
        }
        activeConversationID = conversationID
        activeConversationTitle = conversation.title
        isDraftConversation = false
        inputText = draftStore[conversationID] ?? ""
        messages = fetched
        activeConversationSystemPrompt = conversation.systemPrompt
        tokenCount = min(contextWindowSize, fetched.reduce(0) { $0 + max(1, $1.content.count / 4) })
        truncationWarning = nil
        errorMessage = nil

        if let model = modelProvider().first(where: { $0.id == conversation.modelID }) {
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
        activeGenerationID = nil
        streamedConversationID = nil
        loadGeneration += 1
        activeConversationID = nil
        activeConversationTitle = nil
        messages = []
        inputText = ""
        streamingText = ""
        resetStreamingBuffer()
        tokenCount = 0
        streamedCharacterCount = 0
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

    /// Single-flight startup covering model readiness, persistence creation,
    /// and transcript loading. Loading feedback is published before the first await.
    func startNewConversation(model: AIModel) async -> UUID? {
        func failStartup(_ model: AIModel) -> UUID? {
            errorMessage = "\(model.displayName) could not be loaded. Repair it or choose another model, then retry."
            showError = true
            isStartupError = true
            return nil
        }

        guard !isStartingConversation else { return nil }
        isStartingConversation = true
        isLoadingConversation = true
        isStartupError = false
        errorMessage = nil
        defer {
            isStartingConversation = false
            if activeConversationID == nil { isLoadingConversation = false }
            refreshModelLoadPhase()
        }

        guard await selectModel(model) else {
            if showingExperimentalConsent { return nil }
            return failStartup(model)
        }
        guard lifecycleManager.activeModel?.id == model.id else { return failStartup(model) }

        // Mirror materializeDraftForSend: preserve instructions staged on a
        // draft (e.g. a retry after a failed first-send materialization) so
        // the editor's contents survive; fall back to the global default.
        let stagedPrompt = isDraftConversation ? activeConversationSystemPrompt : nil
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
        await loadConversation(id)
        return activeConversationID == id ? id : nil
    }

    /// Retry a failed conversation startup using the last selected model.
    func retryStartup() async -> UUID? {
        guard isStartupError else { return nil }
        isStartupError = false
        showError = false
        errorMessage = nil
        let id = await createNewConversation()
        refreshModelLoadPhase()
        return id
    }

    func createNewConversation(modelID: String? = nil) async -> UUID? {
        let resolvedID = modelID ?? selectedModel?.id ?? ModelRegistry.llama32_3B.id
        guard let model = ModelRegistry.model(for: resolvedID) else {
            errorMessage = "The selected model is no longer available. Choose a model and retry."
            showError = true
            return nil
        }
        return await startNewConversation(model: model)
    }

}

extension ChatViewModel {
    // MARK: - Message Sending (validation lives with the send preflight)

    func sendMessage() async {
        // R1: single-flight send slot — claimed synchronously before the first
        // suspension so a double-tap (or Send + keyboard submit) cannot enter
        // validate twice. Released on every early exit below.
        guard !isStreaming else {
            logger.info("Send dropped: already streaming")
            return
        }
        isStreaming = true
        let releaseSendSlot: () -> Void = { [weak self] in self?.isStreaming = false }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = !pendingImages.isEmpty

        guard let conversationID = await validateSendPreconditions(
            text: text, hasImages: hasImages
        ) else { releaseSendSlot(); return }
        // R2: residency may have moved during validate's suspensions.
        guard lifecycleManager.activeModel?.id == selectedModel?.id,
              lifecycleManager.isModelLoaded else {
            logger.info("Send aborted: residency lost post-validate")
            errorMessage = "The model is no longer loaded. Retry once it reloads."
            showError = true; releaseSendSlot(); return
        }
        // R3: snapshot identity pre-await; a switch during insert aborts.
        let sendConversationID = conversationID
        // Snapshot and atomically drop only the prefix being sent, making the
        // suspend-window between snapshot and first await safe: any addImage
        // running while suspended appends after the removed prefix and survives
        // post-streaming cleanup.
        let imagesToSend = pendingImages
        let snapshotCount = imagesToSend.count
        if snapshotCount > 0 {
            pendingImages.removeFirst(snapshotCount)
        }
        let hasImagesToSend = !imagesToSend.isEmpty
        inputText = ""
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let isFirstExchange = messages.isEmpty
        let firstUserMessage = text

        let insertResult = await persistence.insertMessageResult(
            conversationID: sendConversationID,
            role: .user,
            content: text,
            imageData: nil,
            attachments: imagesToSend
        )
        if case .failure(let error) = insertResult {
            inputText = text
            if snapshotCount > 0 {
                // Restore snapshot ahead of any interleaved adds from insert await.
                pendingImages.insert(contentsOf: imagesToSend, at: 0)
            }
            errorMessage = error.localizedDescription
            showError = true; releaseSendSlot()
            return
        }
        // R3: abort when a switch landed during the insert suspension — the
        // row belongs to the outgoing chat; never stream it into the new one.
        guard activeConversationID == sendConversationID else {
            logger.info("Send aborted: conversation switched during insert")
            releaseSendSlot(); return
        }
        // R8: re-gate vision after the suspension — the model may have
        // switched to text-only while suspended.
        if hasImagesToSend, !isVisionModel {
            logger.info("Send aborted: vision lost post-suspension")
            visionWarning = "Vision not supported with text-only model. Switch to a vision model."
            if snapshotCount > 0 { pendingImages.insert(contentsOf: imagesToSend, at: 0) }
            inputText = text; releaseSendSlot(); return
        }

        messages.append(ChatMessagePayload(role: .user, content: text, attachments: imagesToSend))
        let history = messages.map {
            ChatMessagePayload(role: $0.role, content: $0.content, attachments: $0.attachments)
        }

        streamingText = ""; errorMessage = nil; visionWarning = nil
        resetStreamingBuffer()
        let generationID = UUID()
        activeGenerationID = generationID
        streamedConversationID = sendConversationID

#if DEBUG
        await testHookBetweenAwaits?()
#endif
        // R3: a switch during the hook window aborts before spawning.
        guard activeConversationID == sendConversationID else {
            logger.info("Send aborted: conversation switched pre-stream")
            activeGenerationID = nil; streamedConversationID = nil; releaseSendSlot(); return
        }
        await startStreaming(
            generationID: generationID,
            conversationID: sendConversationID, history: history, images: imagesToSend,
            hasImages: hasImagesToSend, isFirstExchange: isFirstExchange,
            firstUserMessage: firstUserMessage
        )
        // Snapshot was already removed before the first await. Do not use removeAll:
        // it would wipe interleaved adds that arrived during either await window;
        // keep any pending images that appeared after the snapshot.
        if snapshotCount > 0 {
            visionWarning = nil
        }
    }

    // finishGeneration lives in ChatViewModel+TranscriptActions.swift (P3 length gate).

    func startStreaming(
        generationID: UUID,
        conversationID: UUID, history: [ChatMessagePayload], images: [Data],
        hasImages: Bool, isFirstExchange: Bool, firstUserMessage: String
    ) async {
        let systemPrompt = effectiveSystemPrompt
        let sampling: SamplingConfig
        if let selectedModel, selectedModel.isImported {
            sampling = modelProvider().first(where: { $0.id == selectedModel.id })?.config.defaultSampling ?? .default
        } else {
            sampling = selectedModel?.config.defaultSampling ?? .default
        }
        // P3 context-window preflight: message-drop oldest turns until the
        // estimated prompt fits alongside the generation reserve. This is the
        // first caller of notifyTruncation outside tests.
        let preflight = Self.truncatedHistoryForContextWindow(
            history,
            systemPrompt: systemPrompt,
            contextWindowSize: contextWindowSize,
            reserveTokens: max(512, sampling.maxTokens + 256)
        )
        let wasTruncated = preflight.dropped > 0
        if wasTruncated {
            logger.fault("Context preflight dropped \(preflight.dropped, privacy: .public) messages history=\(history.count, privacy: .public)")
            notifyTruncation(messageCount: preflight.dropped)
        }
        let effectiveHistory = preflight.kept
        let onToken: @Sendable (String) -> Void = { [weak self] token in
            Task { @MainActor [weak self] in
                guard let self, self.activeGenerationID == generationID else { return }
                self.appendStreamingToken(token, generationID: generationID)
            }
        }
        let onComplete: @Sendable () -> Void = { [weak self, wasTruncated] in
            Task { @MainActor [weak self] in
                guard let self, self.activeGenerationID == generationID else { return }
                self.finishGeneration(generationID, reason: wasTruncated ? .truncated : .completed)
                // endStreamingMessage persisted the assistant row before
                // onComplete ran — including whitespace-only replies that a
                // trimmed-empty check would skip. Mirror the persisted row
                // content so a user-unloaded transcript never loses a response
                // that exists on disk (the non-unloaded path reloads it anyway).
                let persistedReply = self.streamingText
                if !persistedReply.isEmpty {
                    self.messages.append(ChatMessagePayload(role: .assistant, content: persistedReply))
                }
                let trimmed = persistedReply.trimmingCharacters(in: .newlines)
                self.streamingText = ""
                self.resetStreamingBuffer()
                // R3/R6/P3-9: reload only when this generation still owns the
                // visible surface and residency survived (no yank, no evict loop).
                if self.shouldReloadAfterGeneration(conversationID: conversationID) {
                    await self.loadConversation(conversationID)
                }
                if isFirstExchange && !firstUserMessage.isEmpty {
                    await self.generateTitleIfNeeded(
                        conversationID: conversationID, userMessage: firstUserMessage, assistantResponse: trimmed
                    )
                }
            }
        }
        let onError: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.activeGenerationID == generationID else { return }
                self.finishGeneration(generationID, reason: .failed)
                self.hasPersistenceRecovery = await self.sessionActor.recoveryHandle != nil
                // Scope the retained response to the conversation it was
                // written into (P1-5): the banner renders only while that
                // conversation is still the visible one.
                self.recoveryConversationID = self.hasPersistenceRecovery ? conversationID : nil
                if !self.hasPersistenceRecovery {
                    self.streamingText = ""
                    self.resetStreamingBuffer()
                }
                self.errorMessage = error.localizedDescription; self.showError = true
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                // R3/R6/P3-9: same ownership + residency gate as onComplete.
                if !self.hasPersistenceRecovery, self.shouldReloadAfterGeneration(conversationID: conversationID) {
                    await self.loadConversation(conversationID)
                }
            }
        }

        if hasImages {
            await sessionActor.startVisionStream(
                conversationID: conversationID, messages: effectiveHistory, images: images,
                systemPrompt: systemPrompt, sampling: sampling,
                onToken: onToken, onComplete: onComplete, onError: onError
            )
        } else {
            await sessionActor.startStream(
                conversationID: conversationID, messages: effectiveHistory,
                systemPrompt: systemPrompt, sampling: sampling,
                onToken: onToken, onComplete: onComplete, onError: onError
            )
        }
    }

    /// R4: switch/delete paths pass suppressReload to skip the trailing
    /// reload (the switch load — or the doomed-row delete — owns navigation).
    func cancelStream(suppressReload: Bool = false) async {
        activeGenerationID = nil
        streamedConversationID = nil
        streamingFlushTask?.cancel()
        flushStreamingChunks()
        await sessionActor.cancel()
        lastStreamEndReason = .stopped
        isStreaming = false
        hasPersistenceRecovery = await sessionActor.recoveryHandle != nil
        recoveryConversationID = hasPersistenceRecovery ? activeConversationID : nil
        if !hasPersistenceRecovery {
            streamingText = ""
            resetStreamingBuffer()
            // R5/R6: never reload a suppressed, unloaded, or evicted surface.
            if !suppressReload, let conversationID = activeConversationID,
               !lifecycleManager.isUserUnloaded,
               lifecycleManager.activeModel != nil,
               lifecycleManager.currentState != .evicted {
                await loadConversation(conversationID)
            } else if suppressReload {
                logger.info("Cancel reload suppressed")
            }
        }
    }

    /// Banner/buffer seams for the persistence-recovery surface in
    /// ChatPersistenceRecovery.swift: the `private(set)` recovery state and
    /// the private streaming buffer are only mutable in this file.
    func releasePersistenceRecovery() {
        hasPersistenceRecovery = false
        recoveryConversationID = nil
        recoveryExportURL = nil
        streamingText = ""
        resetStreamingBuffer()
    }

    /// Drop a recovery retained for a conversation that no longer exists
    /// (sidebar delete). Called by the shell after the delete settles so a
    /// stale banner can never surface on a future conversation reusing state.
    func noteConversationDeleted(_ id: UUID) {
        if recoveryConversationID == id {
            logger.info("Clearing recovery for deleted conversation")
            releasePersistenceRecovery()
        }
    }

#if DEBUG
    /// Hermetic-test seam: stage a retained recovery without a failing
    /// stream (mirrors the `testHookBetweenAwaits` precedent).
    func stagePersistenceRecoveryForTesting(conversationID: UUID) {
        hasPersistenceRecovery = true
        recoveryConversationID = conversationID
    }
#endif

    /// Stage an exported partial-response file for the share sheet.
    func stageRecoveryExport(_ url: URL) {
        recoveryExportURL = url
    }

    func updateSystemPrompt(_ prompt: String?) async -> Bool {
        let normalized = prompt?.nilIfBlank
        // Draft chats have no persistence row yet — stage the instructions in
        // memory; `materializeDraftForSend` commits them with the row at first
        // send. Storing nil ("Use Default") clears the override so the global
        // default applies again.
        guard let activeConversationID else {
            activeConversationSystemPrompt = normalized
            return true
        }
        switch await persistence.updateConversationSystemPrompt(
            id: activeConversationID,
            systemPrompt: normalized
        ) {
        case .success:
            activeConversationSystemPrompt = normalized
            await conversationListViewModel?.loadConversations()
            return true
        case .failure(let failure):
            errorMessage = failure.localizedDescription
            showError = true
            return false
        }
    }

}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

