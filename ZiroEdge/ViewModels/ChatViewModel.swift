// ChatViewModel.swift
// ZiroEdge — Privacy-first local AI assistant
//
// ViewModel for the main chat interface. Bridges ChatSessionActor with SwiftUI.

import Foundation
import SwiftUI
import os

@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published State

    @Published var messages: [ChatMessagePayload] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var streamingText: String = ""

    // MARK: - Dependencies

    private let persistence: PersistenceController
    private let inferenceService: InferenceService
    private let sessionActor: ChatSessionActor
    private let lifecycleManager: ModelLifecycleManager
    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "chat-vm")

    private(set) var activeConversationID: UUID?

    // MARK: - Initialization

    init(
        persistence: PersistenceController,
        inferenceService: InferenceService,
        sessionActor: ChatSessionActor,
        lifecycleManager: ModelLifecycleManager
    ) {
        self.persistence = persistence
        self.inferenceService = inferenceService
        self.sessionActor = sessionActor
        self.lifecycleManager = lifecycleManager
    }

    // MARK: - Conversation Management

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

    func createNewConversation(modelID: String) async -> UUID {
        let id = await persistence.createConversation(
            title: "New Conversation",
            modelID: modelID
        )
        await loadConversation(id)
        return id
    }

    // MARK: - Message Sending

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
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
