// ConversationListViewModel.swift
// ZiroEdge — Privacy-first local AI assistant
//
// ViewModel for the sidebar conversation list. Manages conversation
// CRUD operations and selection state.

import Foundation
import SwiftUI
import os

@MainActor
final class ConversationListViewModel: ObservableObject {

    // MARK: - Published State

    @Published var conversations: [ConversationPayload] = []
    @Published private(set) var isLoading = false
    @Published var selectedConversationID: UUID?
    @Published var isEditingTitle: Bool = false
    @Published var editingTitle: String = ""
    @Published var errorMessage: String?

    // MARK: - Dependencies

    private let persistence: PersistenceController
    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "conversation-list")

    // MARK: - Initialization

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    // MARK: - Load

    /// Fetch all conversations from persistence.
    func loadConversations() async {
        isLoading = true
        defer { isLoading = false }
        switch await persistence.fetchConversationsResult(historyEligibleOnly: true) {
        case .success(let fetched):
            conversations = fetched
            errorMessage = nil
        case .failure(let failure):
            // Preserve the last known rows and selection while recovery remains available.
            errorMessage = failure.localizedDescription
        }
    }

    // MARK: - Create

    /// Create a new conversation with the given model.
    @discardableResult
    func createConversation(modelID: String, title: String = "New Conversation") async -> UUID? {
        let defaultPrompt = UserDefaults.standard.string(
            forKey: ChatViewModel.DefaultsKeys.defaultSystemPrompt
        )
        let normalizedPrompt = defaultPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await persistence.createConversationResult(
            title: title,
            modelID: modelID,
            systemPrompt: normalizedPrompt?.isEmpty == false ? normalizedPrompt : nil
        )
        guard case .success(let id) = result else {
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            return nil
        }
        errorMessage = nil
        await loadConversations()
        selectedConversationID = id
        return id
    }

    // MARK: - Delete

    /// Delete a conversation by ID. If it was selected, clear selection.
    func deleteConversation(_ id: UUID) async {
        switch await persistence.deleteConversation(id: id) {
        case .success:
            if selectedConversationID == id { selectedConversationID = nil }
            await loadConversations()
        case .failure(let failure):
            errorMessage = failure.localizedDescription
        }
    }

    /// Commit the title rename.
    func commitRename(_ conversationID: UUID) async {
        let newTitle = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else {
            isEditingTitle = false
            return
        }
        switch await persistence.updateConversationTitle(id: conversationID, title: newTitle) {
        case .success:
            isEditingTitle = false
            await loadConversations()
        case .failure(let failure):
            errorMessage = failure.localizedDescription
        }
    }
    // MARK: - Selection

    /// Select a conversation.
    func selectConversation(_ id: UUID) {
        selectedConversationID = id
    }

    // MARK: - Helpers

    /// Formatted date for display in the sidebar.
    static func formattedDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
