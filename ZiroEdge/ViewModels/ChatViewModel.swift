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
    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "chat-vm")

    private(set) var activeConversationID: UUID?

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
        downloadStatusProvider: any ModelDownloadStatusProvider
    ) {
        self.persistence = persistence
        self.inferenceService = inferenceService
        self.sessionActor = sessionActor
        self.lifecycleManager = lifecycleManager
        self.downloadStatusProvider = downloadStatusProvider
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
            defer { isSwitchingModel = false }
            await lifecycleManager.switchToModel(model)
        }
    }

    func loadConversation(_ conversationID: UUID) async {
        activeConversationID = conversationID
        let fetched = await persistence.fetchMessages(conversationID: conversationID)
        messages = fetched.map { msg in
            ChatMessagePayload(
                id: msg.id ?? UUID(),
                role: msg.messageRole,
                content: msg.content ?? "",
                imageData: msg.imageData
            )
        }
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

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Auto-select model if none selected.
        if selectedModel == nil {
            autoSelectModel()
        }

        guard selectedModel != nil else {
            needsModelRedirect = true
            return
        }

        guard let conversationID = activeConversationID else {
            errorMessage = "No active conversation."
            showError = true
            return
        }

        guard lifecycleManager.isModelLoaded else {
            errorMessage = "No model loaded. Please download and load a model from Settings."
            showError = true
            return
        }

        inputText = ""

        guard await persistence.insertMessage(
            conversationID: conversationID,
            role: .user,
            content: text
        ) != nil else {
            errorMessage = "Failed to save message."
            showError = true
            return
        }

        let userPayload = ChatMessagePayload(role: .user, content: text)
        messages.append(userPayload)

        let history = messages.map { msg in
            ChatMessagePayload(role: msg.role, content: msg.content, imageData: msg.imageData)
        }

        isStreaming = true
        streamingText = ""
        errorMessage = nil

        await sessionActor.startStream(
            conversationID: conversationID,
            messages: history,
            systemPrompt: nil,
            sampling: .default,
            onToken: { [weak self] token in
                Task { @MainActor [weak self] in
                    self?.streamingText += token
                }
            },
            onComplete: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isStreaming = false
                    if !self.streamingText.isEmpty {
                        let assistantPayload = ChatMessagePayload(role: .assistant, content: self.streamingText)
                        self.messages.append(assistantPayload)
                    }
                    self.streamingText = ""
                    await self.loadConversation(conversationID)
                }
            },
            onError: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isStreaming = false
                    self.streamingText = ""
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                    await self.loadConversation(conversationID)
                }
            }
        )
    }

    func cancelStream() async {
        await sessionActor.cancel()
        isStreaming = false
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

    // MARK: - Message Actions

    func copyMessage(_ message: ChatMessagePayload) {
        UIPasteboard.general.string = message.content
    }
}
