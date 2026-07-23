// ChatViewModel.swift
// ZiroEdge — Privacy-first local AI assistant
//
// ViewModel for the main chat interface. Bridges ChatSessionActor with SwiftUI.

import Foundation
import SwiftUI
import os

/// Protocol for checking model download status. Enables testability.
protocol ModelDownloadStatusProvider: AnyObject {
    func status(for model: AIModel) -> ModelDownloadStatus
}

extension DownloadManager: ModelDownloadStatusProvider {}

@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published State

    @Published var messages: [ChatMessagePayload] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var streamingText: String = ""

    // MARK: - Chat UX State

    /// Current token count from the session actor (updated during streaming).
    @Published var tokenCount: Int = 0

    // MARK: - Image Attachment State

    /// Pending images attached to the current input. Cleared after sending.
    @Published var pendingImages: [Data] = []

    /// Warning shown when user tries to send images with a text-only model.
    @Published var visionWarning: String?

    /// Context window size in tokens (default 4096).
    let contextWindowSize: Int = 4096

    /// Warning message when context window auto-truncates old messages.
    @Published var truncationWarning: String?

    /// Cancellation guard: prevents onComplete from firing after cancelStream.
    private var streamCancelled = false

    // MARK: - Model Selection

    /// The currently selected model for this chat session.
    @Published var selectedModel: AIModel?

    /// Whether we need to redirect user to the models page (no downloaded models).
    @Published var needsModelRedirect: Bool = false

    /// Whether a model switch is in progress.
    @Published var isSwitchingModel: Bool = false

    // MARK: - Dependencies

    private let persistence: PersistenceController
    private let inferenceService: InferenceService
    private let sessionActor: ChatSessionActor
    private let lifecycleManager: ModelLifecycleManager
    private let downloadStatusProvider: any ModelDownloadStatusProvider
    private let titleGenerator: TitleGenerator
    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "chat-vm")

    /// Weak reference to the conversation list ViewModel for sidebar reloads.
    weak var conversationListViewModel: ConversationListViewModel?

    private(set) var activeConversationID: UUID?
    private var loadGeneration: UInt64 = 0

    // MARK: - UserDefaults Keys

    private enum DefaultsKeys {
        static let lastUsedModelID = "lastUsedModelID"
    }

    // MARK: - Initialization

    init(
        persistence: PersistenceController,
        inferenceService: InferenceService,
        sessionActor: ChatSessionActor,
        lifecycleManager: ModelLifecycleManager,
        downloadStatusProvider: any ModelDownloadStatusProvider,
        titleGenerator: TitleGenerator? = nil
    ) {
        self.persistence = persistence
        self.inferenceService = inferenceService
        self.sessionActor = sessionActor
        self.lifecycleManager = lifecycleManager
        self.downloadStatusProvider = downloadStatusProvider
        self.titleGenerator = titleGenerator ?? TitleGenerator(inferenceService: inferenceService)
    }

    // MARK: - Conversation Management

    // MARK: - Model Selection

    /// All models that are fully downloaded and available for use.
    var availableModels: [AIModel] {
        ModelRegistry.allModels.filter { downloadStatusProvider.status(for: $0).isReady }
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
    func selectModel(_ model: AIModel) async {
        selectedModel = model
        UserDefaults.standard.set(model.id, forKey: DefaultsKeys.lastUsedModelID)

        // Switch model in lifecycle manager if different from current.
        if lifecycleManager.activeModel?.id != model.id {
            isSwitchingModel = true
            await lifecycleManager.switchToModel(model)
            isSwitchingModel = false
        }
    }

    func loadConversation(_ conversationID: UUID) async {
        activeConversationID = conversationID
        loadGeneration += 1
        let myGeneration = loadGeneration

        let fetched = await persistence.fetchMessages(conversationID: conversationID)
        guard loadGeneration == myGeneration else { return }

        messages = fetched
        truncationWarning = nil
        // Token count reset happens via resetTokenCount() when appropriate
    }

    func createNewConversation(modelID: String? = nil) async -> UUID {
        let resolvedModelID = modelID ?? selectedModel?.id ?? ModelRegistry.llama32_3B.id
        let id = await persistence.createConversation(
            title: "New Conversation",
            modelID: resolvedModelID
        )
        await loadConversation(id)
        return id
    }

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

        if selectedModel == nil { autoSelectModel() }
        guard selectedModel != nil else { needsModelRedirect = true; return nil }

        if hasImages && !isVisionModel {
            visionWarning = "Vision not supported with text-only model. Switch to a vision model."
            return nil
        }
        guard let conversationID = activeConversationID else {
            errorMessage = "No active conversation."; showError = true; return nil
        }
        guard lifecycleManager.isModelLoaded else {
            errorMessage = "No model loaded. (state=\(lifecycleManager.currentState))"
            showError = true; return nil
        }
        return conversationID
    }

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = !pendingImages.isEmpty

        guard let conversationID = await validateSendPreconditions(
            text: text, hasImages: hasImages
        ) else { return }

        inputText = ""
        let isFirstExchange = messages.isEmpty
        let firstUserMessage = text
        let imagesToSend = hasImages ? pendingImages : []

        guard await persistence.insertMessage(
            conversationID: conversationID, role: .user, content: text,
            imageData: hasImages ? pendingImages.first : nil
        ) != nil else {
            errorMessage = "Failed to save message."; showError = true; return
        }

        messages.append(ChatMessagePayload(role: .user, content: text, imageData: hasImages ? pendingImages.first : nil))
        let history = messages.map { ChatMessagePayload(role: $0.role, content: $0.content, imageData: $0.imageData) }

        isStreaming = true; streamingText = ""; errorMessage = nil; visionWarning = nil
        streamCancelled = false

        await startStreaming(
            conversationID: conversationID, history: history, images: imagesToSend,
            hasImages: hasImages, isFirstExchange: isFirstExchange,
            firstUserMessage: firstUserMessage, streamCancelled: &streamCancelled
        )
        clearImages()
    }

    private func startStreaming(
        conversationID: UUID, history: [ChatMessagePayload], images: [Data],
        hasImages: Bool, isFirstExchange: Bool, firstUserMessage: String,
        streamCancelled: Bool
    ) async {
        let onToken: @Sendable (String) -> Void = { [weak self] token in
            Task { @MainActor [weak self] in
                self?.streamingText += token; self?.tokenCount += 1
            }
        }
        let onComplete: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !streamCancelled else { return }
                self.isStreaming = false
                let trimmed = self.streamingText.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    self.messages.append(ChatMessagePayload(role: .assistant, content: trimmed))
                }
                self.streamingText = ""
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
                guard let self else { return }
                self.isStreaming = false; self.streamingText = ""
                self.errorMessage = error.localizedDescription; self.showError = true
                await self.loadConversation(conversationID)
            }
        }

        if hasImages {
            await sessionActor.startVisionStream(
                conversationID: conversationID, messages: history, images: images,
                systemPrompt: nil, sampling: .default,
                onToken: onToken, onComplete: onComplete, onError: onError
            )
        } else {
            await sessionActor.startStream(
                conversationID: conversationID, messages: history,
                systemPrompt: nil, sampling: .default,
                onToken: onToken, onComplete: onComplete, onError: onError
            )
        }
    }

    func cancelStream() async {
        streamCancelled = true
        await sessionActor.cancel()
        isStreaming = false
        streamingText = ""
        if let conversationID = activeConversationID {
            await loadConversation(conversationID)
        }
    }

    // MARK: - Branching

    func branchFromMessage(_ messageID: UUID) async {
        guard let sourceID = activeConversationID else { return }
        let newID = await persistence.branchConversation(
            sourceID: sourceID,
            fromMessageID: messageID,
            newTitle: "Branched Conversation"
        )
        if let newID {
            await loadConversation(newID)
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
        await persistence.updateConversationTitleIfStill(
            id: conversationID,
            newTitle: title,
            expectedCurrentTitle: "New Conversation"
        )

        // Reload sidebar.
        await conversationListViewModel?.loadConversations()

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
    }

    // MARK: - Message Actions

    func copyMessage(_ message: ChatMessagePayload) {
        UIPasteboard.general.string = message.content
    }

    // MARK: - Image Attachment

    /// Maximum image dimension (width or height) in pixels.
    private static let maxImageDimension: CGFloat = 1024
    /// Maximum raw image data size before forced resize (10 MB).
    private static let maxImageBytes = 10 * 1024 * 1024

    /// Add an image to the pending attachments. Validates size and resizes if needed.
    func addImage(_ data: Data) {
        // If the image is very large, resize it to prevent memory explosion.
        if data.count > Self.maxImageBytes {
            guard let image = UIImage(data: data) else {
                visionWarning = "Could not read image data."
                return
            }
            let resized = resizeImage(image, maxDimension: Self.maxImageDimension)
            guard let jpegData = resized.jpegData(compressionQuality: 0.8) else {
                visionWarning = "Image is too large and could not be resized."
                return
            }
            pendingImages.append(jpegData)
        } else if let image = UIImage(data: data),
                  (image.size.width > Self.maxImageDimension || image.size.height > Self.maxImageDimension) {
            let resized = resizeImage(image, maxDimension: Self.maxImageDimension)
            guard let jpegData = resized.jpegData(compressionQuality: 0.8) else { return }
            pendingImages.append(jpegData)
        } else {
            pendingImages.append(data)
        }
        visionWarning = nil
    }

    /// Resize a UIImage to fit within maxDimension while preserving aspect ratio.
    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let ratio = min(maxDimension / size.width, maxDimension / size.height, 1.0)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
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
    func pasteImage() -> Bool {
        guard UIPasteboard.general.hasImages,
              let image = UIPasteboard.general.image,
              let data = image.pngData() else {
            return false
        }
        addImage(data)
        return true
    }

    /// Whether the currently selected model supports vision.
    var isVisionModel: Bool {
        selectedModel?.modelType == .vision
    }
}
