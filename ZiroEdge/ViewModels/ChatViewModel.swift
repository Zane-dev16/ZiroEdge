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
    enum StreamEndReason {
        case completed
        case stopped
        case failed
    }

    // MARK: - Published State

    @Published var messages: [ChatMessagePayload] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    /// Why the most recent stream ended. Drives the VoiceOver end-of-stream
    /// cue (ChatView's onChange(of: isStreaming)): every termination funnels
    /// through the same isStreaming flip, so without a recorded reason a
    /// user-initiated Stop or an error would announce a false "complete".
    /// Not published — read alongside the isStreaming flip in the view.
    private(set) var lastStreamEndReason: StreamEndReason?
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
    @Published private(set) var recoveryExportURL: URL?
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
    private var activeGenerationID: UUID?
    /// Conversation the live generation is writing into; lets conversation
    /// switches detect and cancel a stream that belongs elsewhere.
    private(set) var streamedConversationID: UUID?

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

    private let persistence: any PersistenceProviding
    private let inferenceService: any InferenceServiceProtocol
    /// Read-shared with the persistence-recovery extension in
    /// ChatPersistenceRecovery.swift.
    let sessionActor: ChatSessionActor
    /// Read-shared with the deferred-load extensions in ChatModelLoading.swift.
    let lifecycleManager: ModelLifecycleManager
    private let downloadStatusProvider: any ModelDownloadStatusProvider
    private let modelProvider: () -> [AIModel]
    private let titleGenerator: TitleGenerator
    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "chat-vm")

    /// Weak reference to the conversation list ViewModel for sidebar reloads.
    weak var conversationListViewModel: ConversationListViewModel?

    private(set) var activeConversationID: UUID?
    private var loadGeneration: UInt64 = 0

    // BATCH-04: buffered streaming — avoids O(n) copy per token and debounces Published churn
    private var streamingChunks: [String] = []
    private var streamedCharacterCount = 0
    private var streamingFlushTask: Task<Void, Never>?
    private var lastStreamingFlushMs: UInt64 = 0
    private let streamingFlushIntervalMs: UInt64 = 80
    private let streamingChunkThreshold = 20

    // MARK: - UserDefaults Keys

    enum DefaultsKeys {
        static let lastUsedModelID = "lastUsedModelID"
        static let defaultSystemPrompt = "defaultSystemPrompt"
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

    /// Auto-select a model for a new conversation. Uses the fallback chain:
    /// last used model → first available → redirect to models page.
    /// Reimplemented atop `preferredAutoLoadCandidate()`; behavior (and the
    /// `needsModelRedirect` contract relied on by unit tests) is unchanged.
    func autoSelectModel() {
        guard let candidate = preferredAutoLoadCandidate() else {
            selectedModel = nil
            needsModelRedirect = true
            return
        }
        selectedModel = candidate
        needsModelRedirect = false
        refreshModelLoadPhase()
    }

    /// The best available model for the untitled draft chat's deferred load:
    /// last used model, then the first fully downloaded model.
    /// Hermetic test runtimes only ever satisfy llama32_3B paths downstream,
    /// so they are pinned to that profile. Controlled-workload diagnostics
    /// route through `lifecycleManager.autoLoadFirstModel()` instead and never
    /// consult this method.
    /// Unconsented experimental imports are excluded: `availableModels`
    /// deliberately includes them for picker discoverability, but the deferred
    /// auto-loader (launch autoload, `beginNewDraft`, Start-Chatting) must not
    /// silently load and enable chatting on a model `selectModel` would have
    /// gated behind the first-use consent dialog. They stay picker-only until
    /// consent is granted.
    func preferredAutoLoadCandidate() -> AIModel? {
        let downloaded = availableModels.filter { model in
            !(model.runtimeEligibility == .experimental
                && model.isImported
                && !ExperimentalModelConsent.isGranted(for: model))
        }
        #if DEBUG
        if HermeticUITestRuntime.isEnabled {
            return downloaded.first { $0.id == ModelRegistry.llama32_3B.id }
        }
        #endif
        if let lastID = UserDefaults.standard.string(forKey: DefaultsKeys.lastUsedModelID),
           let lastModel = downloaded.first(where: { $0.id == lastID }) {
            return lastModel
        }
        return downloaded.first
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
            UISelectionFeedbackGenerator().selectionChanged()
            return true
        }

        // Lifecycle manager may have restored the previous model after a failed switch.
        selectedModel = lifecycleManager.activeModel ?? previousSelection
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
    private func materializeDraftForSend() async -> UUID? {
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
        isDraftConversation = false
        activeConversationID = id
        activeConversationSystemPrompt = stagedPrompt ?? defaultPrompt?.nilIfBlank
        await conversationListViewModel?.loadConversations()
        conversationListViewModel?.selectedConversationID = id
        return id
    }

    func loadConversation(_ conversationID: UUID) async {
        // Switching conversations must not leave a live generation writing into
        // the wrong transcript or yanking navigation back on completion.
        if isStreaming, let streamed = streamedConversationID, streamed != conversationID {
            await cancelStream()
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

        // Commit identity and content together so a failed fetch can never pair the
        // previous transcript with the newly selected conversation.
        activeConversationID = conversationID
        isDraftConversation = false
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

    /// First failure message from a `Result`, for surfacing load errors to the user.
    private func resultFailureText<T, E: Error>(_ result: Result<T, E>) -> String? {
        guard case .failure(let error) = result else { return nil }
        return error.localizedDescription
    }

    /// Clear transient transcript state when the selected conversation disappears.
    func clearActiveConversation() {
        // Detach any live generation before wiping state so stale callbacks cannot
        // write into cleared buffers; actor cancel finishes asynchronously.
        let wasStreaming = isStreaming
        activeGenerationID = nil
        streamedConversationID = nil
        loadGeneration += 1
        activeConversationID = nil
        messages = []
        streamingText = ""
        resetStreamingBuffer()
        tokenCount = 0
        streamedCharacterCount = 0
        isLoadingConversation = false
        isStartupError = false
        truncationWarning = nil
        activeConversationSystemPrompt = nil
        unavailableConversationModelID = nil
        refreshModelLoadPhase()
        if wasStreaming {
            Task { await self.cancelStream() }
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
    // MARK: - Message Sending

    /// Validate preconditions for sending a message. Returns nil on success,
    /// or the conversationID. Sets error/warning state on failure.
    private func validateSendPreconditions(
        text: String, hasImages: Bool
    ) async -> UUID? {
        if CommandLine.arguments.contains("--uitesting-sendtest") {
            print("[UITEST] sendMessage: text='\(text)', hasImages=\(hasImages)")
            print("[UITEST] sendMessage: selectedModel=\(selectedModel?.id ?? "nil")")
            print("[UITEST] sendMessage: isModelLoaded=\(lifecycleManager.isModelLoaded)")
        }

        guard !text.isEmpty || hasImages else { return nil }
        guard !isLoadingConversation else {
            surfaceSendBlockedDuringConversationLoad()
            return nil
        }

        if selectedModel == nil { autoSelectModel() }
        guard let selectedModel else { needsModelRedirect = true; return nil }

        if hasImages && !isVisionModel {
            visionWarning = "Vision not supported with text-only model. Switch to a vision model."
            return nil
        }
        // Belt-and-braces residency gate: the composer stays disabled until
        // modelLoadPhase == .ready, so manual sends always pass this.
        if lifecycleManager.activeModel?.id != selectedModel.id {
            let selected = await selectModel(selectedModel)
            if !selected, showingExperimentalConsent { return nil }
        }
        guard lifecycleManager.activeModel?.id == selectedModel.id else {
            errorMessage = "\(selectedModel.displayName) could not be loaded. Choose another downloaded model."
            showError = true
            return nil
        }

        // Untitled drafts materialize their persistence row just-in-time — only
        // after the model is confirmed resident.
        guard let conversationID = activeConversationID else {
            guard isDraftConversation else {
                errorMessage = "No active conversation."; showError = true; return nil
            }
            return await materializeDraftForSend()
        }
        return conversationID
    }

    /// A send that lands while a conversation is still loading is dropped —
    /// surface it through the transient warning banner instead of failing
    /// silently. The load path clears transient banners when it settles, so
    /// the message is posted after the in-flight load finishes.
    private func surfaceSendBlockedDuringConversationLoad() {
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

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = !pendingImages.isEmpty

        guard let conversationID = await validateSendPreconditions(
            text: text, hasImages: hasImages
        ) else { return }

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
            conversationID: conversationID,
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
            showError = true
            return
        }

        messages.append(ChatMessagePayload(role: .user, content: text, attachments: imagesToSend))
        let history = messages.map {
            ChatMessagePayload(role: $0.role, content: $0.content, attachments: $0.attachments)
        }

        isStreaming = true; streamingText = ""; errorMessage = nil; visionWarning = nil
        resetStreamingBuffer()
        let generationID = UUID()
        activeGenerationID = generationID
        streamedConversationID = conversationID

#if DEBUG
        await testHookBetweenAwaits?()
#endif
        await startStreaming(
            generationID: generationID,
            conversationID: conversationID, history: history, images: imagesToSend,
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

    /// Shared completion/reset of a generation slot; both success and error
    /// closures funnel through this.
    private func finishGeneration(_ generationID: UUID, reason: StreamEndReason) {
        streamingFlushTask?.cancel()
        flushStreamingChunks()
        activeGenerationID = nil
        isStreaming = false
        streamedConversationID = nil
        lastStreamEndReason = reason
    }

    private func startStreaming(
        generationID: UUID,
        conversationID: UUID, history: [ChatMessagePayload], images: [Data],
        hasImages: Bool, isFirstExchange: Bool, firstUserMessage: String
    ) async {
        let onToken: @Sendable (String) -> Void = { [weak self] token in
            Task { @MainActor [weak self] in
                guard let self, self.activeGenerationID == generationID else { return }
                self.appendStreamingToken(token, generationID: generationID)
            }
        }
        let onComplete: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.activeGenerationID == generationID else { return }
                self.finishGeneration(generationID, reason: .completed)
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
                // A user-initiated unload (Settings → Unload Model) cancels
                // the engine stream and lands here: reloading the transcript
                // would selectModel the just-unloaded model back. The
                // in-memory append above already mirrors the persisted row.
                if !self.lifecycleManager.isUserUnloaded {
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
                if !self.hasPersistenceRecovery {
                    self.streamingText = ""
                    self.resetStreamingBuffer()
                }
                self.errorMessage = error.localizedDescription; self.showError = true
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                // Same user-unload guard as onComplete: an unload-driven
                // cancellation must not reload the just-unloaded model.
                if !self.hasPersistenceRecovery, !self.lifecycleManager.isUserUnloaded {
                    await self.loadConversation(conversationID)
                }
            }
        }

        let systemPrompt = effectiveSystemPrompt
        let sampling: SamplingConfig
        if let selectedModel, selectedModel.isImported {
            sampling = modelProvider().first(where: { $0.id == selectedModel.id })?.config.defaultSampling ?? .default
        } else {
            sampling = selectedModel?.config.defaultSampling ?? .default
        }
        if hasImages {
            await sessionActor.startVisionStream(
                conversationID: conversationID, messages: history, images: images,
                systemPrompt: systemPrompt, sampling: sampling,
                onToken: onToken, onComplete: onComplete, onError: onError
            )
        } else {
            await sessionActor.startStream(
                conversationID: conversationID, messages: history,
                systemPrompt: systemPrompt, sampling: sampling,
                onToken: onToken, onComplete: onComplete, onError: onError
            )
        }
    }

    func cancelStream() async {
        activeGenerationID = nil
        streamedConversationID = nil
        streamingFlushTask?.cancel()
        flushStreamingChunks()
        await sessionActor.cancel()
        lastStreamEndReason = .stopped
        isStreaming = false
        hasPersistenceRecovery = await sessionActor.recoveryHandle != nil
        if !hasPersistenceRecovery {
            streamingText = ""
            resetStreamingBuffer()
            // An unload-driven cancel must not reload the just-unloaded model
            // (same intent guard as the completion path).
            if let conversationID = activeConversationID, !lifecycleManager.isUserUnloaded {
                await loadConversation(conversationID)
            }
        }
    }

    /// Banner/buffer seams for the persistence-recovery surface in
    /// ChatPersistenceRecovery.swift: the `private(set)` recovery state and
    /// the private streaming buffer are only mutable in this file.
    func releasePersistenceRecovery() {
        hasPersistenceRecovery = false
        recoveryExportURL = nil
        streamingText = ""
        resetStreamingBuffer()
    }

    /// Stage an exported partial-response file for the share sheet.
    func stageRecoveryExport(_ url: URL) {
        recoveryExportURL = url
    }

    var effectiveSystemPrompt: String? {
        activeConversationSystemPrompt?.nilIfBlank
            ?? UserDefaults.standard.string(forKey: DefaultsKeys.defaultSystemPrompt)?.nilIfBlank
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

    // MARK: - Title Generation

    /// Generate a title for the conversation after the first exchange.
    /// Only runs if the conversation title is still the default "New Conversation".
    private func generateTitleIfNeeded(
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

    private func flushStreamingChunks() {
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

    private func appendStreamingToken(_ token: String, generationID: UUID) {
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

    private func resetStreamingBuffer() {
        streamingFlushTask?.cancel()
        streamingFlushTask = nil
        streamingChunks.removeAll(keepingCapacity: true)
        lastStreamingFlushMs = currentTimeMs()
        streamedCharacterCount = 0
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

