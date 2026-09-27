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

    /// Terminal reason for the most recent generation (owned by
    /// ChatSessionCoordinator; aliased here for source compatibility).
    /// Recorded wherever `isStreaming` is set false.
    typealias StreamEndReason = ChatSessionCoordinator.StreamEndReason

    // MARK: - Published State

    /// Deep owner for draft, generation-slot, and streaming-buffer state.
    /// This ViewModel keeps the @Published SwiftUI surface and delegates
    /// session transitions to it.
    let sessionCoordinator = ChatSessionCoordinator()

    @Published var messages: [ChatMessagePayload] = []
    @Published var inputText: String = ""
    /// Per-conversation draft text, keyed by conversation ID. Saved on every
    /// successful conversation switch and new-draft reset, restored after the
    /// target transcript loads — the text twin of the pendingImages clear on
    /// real switches, so a half-typed message never migrates into the wrong
    /// chat. Memory-only by design (drafts are unsent); attachments are
    /// deliberately NOT restored (cleared together with the parked text).
    /// Forwarded: owned by ChatSessionCoordinator (single draft owner).
    var draftStore: [UUID: String] {
        get { sessionCoordinator.draftsByConversation }
        set { sessionCoordinator.draftsByConversation = newValue }
    }
    /// Parked text for the unsaved draft chat (no conversation row yet, so no
    /// `draftStore` key). Preserved across switches/backgrounding and flushed
    /// to UserDefaults with the rest of the store (P2-8); cleared whenever a
    /// fresh draft is explicitly started or the draft materializes on send.
    /// Forwarded: owned by ChatSessionCoordinator. See `draftStore`.
    var draftForNewChat: String {
        get { sessionCoordinator.newChatDraft }
        set { sessionCoordinator.newChatDraft = newValue }
    }
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
    /// Forwarded: owned by ChatSessionCoordinator; written via finishGeneration.
    var lastStreamEndReason: StreamEndReason? {
        get { sessionCoordinator.lastStreamEndReason }
        set { sessionCoordinator.lastStreamEndReason = newValue }
    }
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var streamingText: String = ""
    @Published var isLoadingConversation = false
    @Published var isStartingConversation = false
    /// Forwarded: owned by ChatSessionCoordinator (single-flight slot store).
    var isMaterializingDraft: Bool {
        get { sessionCoordinator.isMaterializingDraft }
        set { sessionCoordinator.isMaterializingDraft = newValue }
    } // internal: engine-selection extension materializes FM drafts
    @Published var isStartupError = false
    @Published var activeConversationSystemPrompt: String? // internal(set): FM draft path stages prompts
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
    @Published var unavailableConversationModelID: String?

    /// Observable projection of the model residency bridging ModelLifecycleManager:
    /// drives the chat header pill and composer gating. Written only by the
    /// loading extensions in ChatModelLoading.swift and selection mutations.
    @Published var modelLoadPhase: ModelLoadPhase = .idle

    /// True while the visible surface is an unsaved chat. Drafts exist purely
    /// in memory — no persistence row until first send (`materializeDraftForSend`).
    @Published var isDraftConversation: Bool // internal(set): FM draft path consumes the draft slot

    // MARK: - Chat UX State

    /// Current token count from the session actor (updated during streaming).
    @Published var tokenCount: Int = 0

    // MARK: - Image Attachment State

    /// Pending images attached to the current input. Cleared after sending.
    @Published var pendingImages: [Data] = []

    /// Warning shown when user tries to send images with a text-only model.
    @Published var visionWarning: String?
    /// Pending attach-time vision choice (nil when no choice is outstanding).
    /// Cleared with the staged attachments on conversation switch.
    @Published var visionDownscaleOffer: VisionDownscaleOffer?

#if DEBUG
    /// Test hook injected between the two awaits in sendMessage to simulate
    /// the pendingImages lost-update race deterministically.
    var testHookBetweenAwaits: (() async -> Void)?
#endif

    /// Context window size in tokens (default 4096).
    let contextWindowSize: Int = 4096

    /// Warning message when context window auto-truncates old messages.
    @Published var truncationWarning: String?

    /// Forwarded: owned by ChatSessionCoordinator (generation slot).
    var activeGenerationID: UUID? {
        get { sessionCoordinator.activeGenerationID }
        set { sessionCoordinator.activeGenerationID = newValue }
    }
    /// Forwarded: owned by ChatSessionCoordinator (generation slot).
    var streamedConversationID: UUID? {
        get { sessionCoordinator.streamedConversationID }
        set { sessionCoordinator.streamedConversationID = newValue }
    }

    // MARK: - Model Selection

    /// The currently selected model for this chat session (llama path).
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
    /// Read-shared with the conversation-lifecycle extension in
    /// ChatSessionCoordinator.swift.
    let modelProvider: () -> [AIModel]
    let titleGenerator: TitleGenerator
    /// Read-shared with the send-preflight helper in ChatModelLoading.swift.
    let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "chat-vm")

    /// Weak reference to the conversation list ViewModel for sidebar reloads.
    weak var conversationListViewModel: ConversationListViewModel?

    var activeConversationID: UUID? // internal(set): FM draft path commits identity
    /// The active conversation's title for the nav bar. Nil for unsaved
    /// drafts — the bar reads "New chat" instead of a placeholder.
    @Published var activeConversationTitle: String?
    /// Read-shared with the conversation-lifecycle extension in
    /// ChatSessionCoordinator.swift.
    var loadGeneration: UInt64 = 0

    // Streaming buffer + debounce state live in ChatSessionCoordinator.

    // MARK: - UserDefaults Keys

    enum DefaultsKeys {
        static let lastUsedModelID = "lastUsedModelID"
        static let defaultSystemPrompt = "defaultSystemPrompt"
        /// Per-conversation drafts parked for kill-recovery (P2-8).
        /// Aliases ChatSessionCoordinator (single source of truth).
        static let draftsByConversation = ChatSessionCoordinator.draftsByConversationKey
        /// Parked text for the unsaved draft chat (P2-8); absent when blank.
        static let newChatDraft = ChatSessionCoordinator.newChatDraftKey
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
        EngineStore.lastEngine = .llama // Naming a GGUF means llama answers.
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

    // Conversation lifecycle (beginNewDraft/materialize/load/clear) lives in
    // ChatSessionCoordinator.swift, next to the draft/slot state it coordinates.

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
            print("[FM-SEND] dropped: already streaming")
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
        // FM has no resident model — availability is the residency.
        if !isAppleEngineActive {
            guard lifecycleManager.activeModel?.id == selectedModel?.id,
                  lifecycleManager.isModelLoaded else {
                logger.info("Send aborted: residency lost post-validate")
                errorMessage = "The model is no longer loaded. Retry once it reloads."
                showError = true; releaseSendSlot(); return
            }
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
        let generationID = sessionCoordinator.claim(conversationID: sendConversationID)

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
        sessionCoordinator.detachSlot()
        sessionCoordinator.cancelPendingFlush()
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

