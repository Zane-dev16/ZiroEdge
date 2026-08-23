// ChatViewModel.swift
// ZiroEdge — Privacy-first local AI assistant
//
// ViewModel for the main chat interface. Bridges ChatSessionActor with SwiftUI.

import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import os

/// Protocol for checking model download status. Enables testability.
protocol ModelDownloadStatusProvider: AnyObject {
    func status(for model: AIModel) -> ModelDownloadStatus
}

extension DownloadManager: @preconcurrency ModelDownloadStatusProvider {}

@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published State

    @Published var messages: [ChatMessagePayload] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var streamingText: String = ""
    @Published var isLoadingConversation = false
    @Published var isStartingConversation = false
    @Published var isStartupError = false
    @Published private(set) var activeConversationSystemPrompt: String?
    @Published private(set) var hasPersistenceRecovery = false
    @Published private(set) var recoveryExportURL: URL?
    @Published private(set) var unavailableConversationModelID: String?

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

    // MARK: - Dependencies

    private let persistence: any PersistenceProviding
    private let inferenceService: any InferenceServiceProtocol
    private let sessionActor: ChatSessionActor
    private let lifecycleManager: ModelLifecycleManager
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
    }

    // MARK: - Conversation Management

    // MARK: - Model Selection

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
    func autoSelectModel() {
        let downloaded = availableModels

        guard !downloaded.isEmpty else {
            selectedModel = nil
            needsModelRedirect = true
            return
        }

        needsModelRedirect = false

        // Try last used model.
        if let lastID = UserDefaults.standard.string(forKey: DefaultsKeys.lastUsedModelID),
           let lastModel = downloaded.first(where: { $0.id == lastID }) {
            selectedModel = lastModel
            return
        }

        // Fallback: first available model.
        selectedModel = downloaded.first
    }

    /// Select a model and persist the choice. Loads it if not already loaded.
    /// Returns false when selection is waiting for explicit first-use consent.
    @discardableResult
    func selectModel(_ model: AIModel) async -> Bool {
        guard model.runtimeEligibility != .experimental
                || ExperimentalModelConsent.isGranted(for: model) else {
            pendingExperimentalModel = model
            showingExperimentalConsent = true
            return false
        }

        let previousSelection = selectedModel
        selectedModel = model

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
            if case .failure(let failure) = messageResult {
                errorMessage = failure.localizedDescription
            } else if case .failure(let failure) = conversationResult {
                errorMessage = failure.localizedDescription
            } else {
                errorMessage = "The selected conversation is no longer available."
            }
            showError = true
            conversationListViewModel?.selectedConversationID = previousConversationID
            return
        }

        // Commit identity and content together so a failed fetch can never pair the
        // previous transcript with the newly selected conversation.
        activeConversationID = conversationID
        messages = fetched
        activeConversationSystemPrompt = conversation.systemPrompt
        tokenCount = min(
            contextWindowSize,
            fetched.reduce(0) { $0 + max(1, $1.content.count / 4) }
        )
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
    }

    /// Clear transient transcript state when the selected conversation disappears.
    func clearActiveConversation() {
        // Detach any live generation before wiping state so stale token and
        // completion callbacks cannot write into cleared buffers; the actor
        // cancel finishes asynchronously without touching UI identity here.
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
        if wasStreaming {
            Task { await self.cancelStream() }
        }
    }

    /// Single-flight startup covering model readiness, persistence creation,
    /// and transcript loading. Loading feedback is published before the first await.
    func startNewConversation(model: AIModel) async -> UUID? {
        guard !isStartingConversation else { return nil }
        isStartingConversation = true
        isLoadingConversation = true
        isStartupError = false
        errorMessage = nil
        defer {
            isStartingConversation = false
            if activeConversationID == nil { isLoadingConversation = false }
        }

        guard await selectModel(model) else {
            if showingExperimentalConsent { return nil }
            errorMessage = "\(model.displayName) could not be loaded. Repair it or choose another model, then retry."
            showError = true
            isStartupError = true
            return nil
        }
        guard lifecycleManager.activeModel?.id == model.id else {
            errorMessage = "\(model.displayName) could not be loaded. Repair it or choose another model, then retry."
            showError = true
            isStartupError = true
            return nil
        }

        let defaultPrompt = UserDefaults.standard.string(forKey: DefaultsKeys.defaultSystemPrompt)
        let result = await persistence.createConversationResult(
            id: UUID(),
            title: "New Conversation",
            modelID: model.id,
            systemPrompt: defaultPrompt?.nilIfBlank
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
        return await createNewConversation()
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
        guard !isLoadingConversation else { return nil }

        if selectedModel == nil { autoSelectModel() }
        guard let selectedModel else { needsModelRedirect = true; return nil }

        if hasImages && !isVisionModel {
            visionWarning = "Vision not supported with text-only model. Switch to a vision model."
            return nil
        }
        guard let conversationID = activeConversationID else {
            errorMessage = "No active conversation."; showError = true; return nil
        }
        if lifecycleManager.activeModel?.id != selectedModel.id {
            let selected = await selectModel(selectedModel)
            if !selected, showingExperimentalConsent { return nil }
        }
        guard lifecycleManager.activeModel?.id == selectedModel.id else {
            errorMessage = "\(selectedModel.displayName) could not be loaded. Choose another downloaded model."
            showError = true
            return nil
        }
        return conversationID
    }

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = !pendingImages.isEmpty

        guard let conversationID = await validateSendPreconditions(
            text: text, hasImages: hasImages
        ) else { return }

        // Snapshot and atomically drop only the prefix that is being sent.
        // This makes the window between snapshot and the first await safe: any
        // addImage that runs while we are suspended will append after the
        // removed prefix and therefore survive the post-streaming cleanup.
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
                // Restore the snapshot in front of any interleaved adds
                // that arrived during the insert await.
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
        // Snapshot was already removed before the first await. Do not use
        // removeAll which would wipe interleaved adds that arrived during
        // either await window. Keep any pending images that appeared after
        // the snapshot and just clear the transient warning.
        if snapshotCount > 0 {
            visionWarning = nil
        }
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
                self.streamingFlushTask?.cancel()
                self.flushStreamingChunks()
                self.activeGenerationID = nil
                self.isStreaming = false
                self.streamedConversationID = nil
                let trimmed = self.streamingText.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    self.messages.append(ChatMessagePayload(role: .assistant, content: trimmed))
                }
                self.streamingText = ""
                self.resetStreamingBuffer()
                await self.loadConversation(conversationID)
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
                self.streamingFlushTask?.cancel()
                self.flushStreamingChunks()
                self.activeGenerationID = nil
                self.isStreaming = false
                self.streamedConversationID = nil
                self.hasPersistenceRecovery = await self.sessionActor.recoveryHandle != nil
                if !self.hasPersistenceRecovery {
                    self.streamingText = ""
                    self.resetStreamingBuffer()
                }
                self.errorMessage = error.localizedDescription; self.showError = true
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                if !self.hasPersistenceRecovery { await self.loadConversation(conversationID) }
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
        isStreaming = false
        hasPersistenceRecovery = await sessionActor.recoveryHandle != nil
        if !hasPersistenceRecovery {
            streamingText = ""
            resetStreamingBuffer()
            if let conversationID = activeConversationID { await loadConversation(conversationID) }
        }
    }

    func retryPersistenceRecovery() async {
        switch await sessionActor.retryRecoverySave() {
        case .success:
            hasPersistenceRecovery = false
            streamingText = ""
            resetStreamingBuffer()
            errorMessage = nil
            showError = false
            if let activeConversationID { await loadConversation(activeConversationID) }
        case .failure(let failure):
            errorMessage = failure.localizedDescription
            showError = true
        }
    }

    func exportPersistenceRecovery() async {
        switch await sessionActor.exportRecovery() {
        case .success(let data):
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ZiroEdge-partial-response-\(UUID().uuidString).json")
                try data.write(to: url, options: .atomic)
                recoveryExportURL = url
            } catch {
                errorMessage = PersistenceFailure.map(error, operation: .export).localizedDescription
                showError = true
            }
        case .failure(let failure):
            errorMessage = failure.localizedDescription
            showError = true
        }
    }

    func discardPersistenceRecovery() async {
        switch await sessionActor.discardRecovery() {
        case .success:
            hasPersistenceRecovery = false
            streamingText = ""
            resetStreamingBuffer()
            recoveryExportURL = nil
            if let activeConversationID { await loadConversation(activeConversationID) }
        case .failure(let failure):
            errorMessage = failure.localizedDescription
            showError = true
        }
    }

    func presentBackgroundPersistenceFailure(_ failure: PersistenceFailure) {
        errorMessage = failure.localizedDescription
        showError = true
    }

    var effectiveSystemPrompt: String? {
        activeConversationSystemPrompt?.nilIfBlank
            ?? UserDefaults.standard.string(forKey: DefaultsKeys.defaultSystemPrompt)?.nilIfBlank
    }

    func updateSystemPrompt(_ prompt: String?) async -> Bool {
        guard let activeConversationID else { return false }
        let normalized = prompt?.nilIfBlank
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

extension ChatViewModel {
    // MARK: - Image Attachment

    /// Maximum image dimension (width or height) in pixels.
    nonisolated static let maxImageDimension: CGFloat = 1024
    /// Maximum raw image data size before forced downsample (10 MB).
    private nonisolated static let maxImageBytes = 10 * 1024 * 1024

    /// Outcome of attachment preprocessing (legacy validation semantics).
    enum AttachmentPreparation: Equatable {
        /// Final bytes to attach (downsampled JPEG or pass-through original).
        case ready(Data)
        /// Oversize payload that could not be read as an image.
        case unreadable
        /// Oversize payload that was readable but could not be re-encoded.
        case downsampleFailed
        /// Small payload over the pixel budget whose re-encode failed; dropped silently.
        case dropped
    }

    /// Result of running the attachment pipeline, including the executor it ran on.
    struct AttachmentPipelineOutput {
        let preparation: AttachmentPreparation
        /// True iff preprocessing executed on the main thread. Must always be false;
        /// exposed for tests and diagnostics.
        let ranOnMainThread: Bool
    }

    /// Add an image to the pending attachments. Validates size and downsamples if needed.
    /// Decoding/downsampling runs off the main actor via ImageIO, so multi-megabyte
    /// photos never freeze the UI.
    func addImage(_ data: Data) async {
        let output = await Self.prepareAttachment(data)
        switch output.preparation {
        case .ready(let bytes):
            pendingImages.append(bytes)
            visionWarning = nil
        case .unreadable:
            visionWarning = "Could not read image data."
        case .downsampleFailed:
            visionWarning = "Image is too large and could not be resized."
        case .dropped:
            break // Legacy behavior: silently drop.
        }
    }

    /// Decode, validate, and downsample attachment data using ImageIO.
    ///
    /// Nonisolated async functions execute on the cooperative thread pool, never on
    /// the main thread, so full-resolution bitmaps are never materialized for the UI.
    nonisolated static func prepareAttachment(_ data: Data) async -> AttachmentPipelineOutput {
        let startedOnMainThread = isExecutingOnMainThread

        // Read pixel bounds without decoding the bitmap.
        let dimensions = Self.pixelDimensions(of: data)
        let exceedsPixelBudget = dimensions.map {
            $0.width > Int(Self.maxImageDimension) || $0.height > Int(Self.maxImageDimension)
        } ?? false

        let preparation: AttachmentPreparation
        if !exceedsPixelBudget && data.count <= Self.maxImageBytes {
            // Small enough already: attach as-is (matches legacy pass-through,
            // including undecodable payloads, which report no dimensions).
            preparation = .ready(data)
        } else if let cgImage = Self.downsampledCGImage(from: data, maxPixelSize: Int(Self.maxImageDimension)),
                  let jpeg = Self.jpegData(from: cgImage, quality: 0.8) {
            preparation = .ready(jpeg)
        } else if data.count > Self.maxImageBytes {
            preparation = dimensions == nil ? .unreadable : .downsampleFailed
        } else {
            preparation = .dropped
        }

        return AttachmentPipelineOutput(preparation: preparation, ranOnMainThread: startedOnMainThread)
    }

    /// Synchronous accessor avoids the async-context availability warning on
    /// `Thread.isMainThread` while still reporting the actually-executing thread.
    private nonisolated static var isExecutingOnMainThread: Bool { Thread.isMainThread }

    /// Create a thumbnail bounded by `maxPixelSize` on the long edge, preserving
    /// aspect ratio and baking in EXIF orientation. Returns nil when undecodable.
    private nonisolated static func downsampledCGImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Read pixel width/height from image metadata without decoding the bitmap.
    private nonisolated static func pixelDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Encode a CGImage as JPEG entirely in CoreGraphics (no UIKit round-trip).
    private nonisolated static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Remove an image at the specified index.
    func removeImage(at index: Int) {
        guard pendingImages.indices.contains(index) else { return }
        pendingImages.remove(at: index)
    }

    /// Clear all pending images.
    func clearImages() {
        pendingImages.removeAll()
        visionWarning = nil
    }

    /// Attempt to paste an image from the clipboard.
    /// Returns true if an image was found and added.
    @discardableResult
    func pasteImage() async -> Bool {
        guard UIPasteboard.general.hasImages,
              let image = UIPasteboard.general.image,
              let data = image.pngData() else {
            return false
        }
        await addImage(data)
        return true
    }

    /// Whether the currently selected model supports vision.
    var isVisionModel: Bool {
        selectedModel?.modelType == .vision
    }
}
