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

    @Published var conversations: [CDConversation] = []
    @Published var selectedConversationID: UUID?
    @Published var isEditingTitle: Bool = false
    @Published var editingTitle: String = ""

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
        conversations = await persistence.fetchConversations()
    }

    // MARK: - Create

    /// Create a new conversation with the given model.
    @discardableResult
    func createConversation(modelID: String, title: String = "New Conversation") async -> UUID {
        let id = await persistence.createConversation(title: title, modelID: modelID)
        await loadConversations()
        selectedConversationID = id
        return id
    }

    // MARK: - Delete

    /// Delete a conversation by ID. If it was selected, clear selection.
    func deleteConversation(_ id: UUID) async {
        await persistence.deleteConversation(id: id)
        if selectedConversationID == id {
            selectedConversationID = nil
        }
        await loadConversations()
    }

    /// Delete conversations at specific index set (for swipe-to-delete).
    func deleteConversations(at offsets: IndexSet) async {
        for index in offsets {
            let conversation = conversations[index]
            if let id = conversation.id {
                await deleteConversation(id)
            }
        }
    }

    // MARK: - Rename

    /// Begin editing a conversation title.
    func beginRename(_ conversation: CDConversation) {
        editingTitle = conversation.title ?? "Untitled"
        isEditingTitle = true
    }

    /// Commit the title rename.
    func commitRename(_ conversationID: UUID) async {
        let newTitle = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else {
            isEditingTitle = false
            return
        }
        await persistence.updateConversationTitle(id: conversationID, title: newTitle)
        isEditingTitle = false
        await loadConversations()
    }

    /// Cancel the rename.
    func cancelRename() {
        isEditingTitle = false
        editingTitle = ""
    }

    // MARK: - Selection

    /// Select a conversation.
    func selectConversation(_ id: UUID) {
        selectedConversationID = id
    }

    // MARK: - Helpers

    /// The currently selected conversation object.
    var selectedConversation: CDConversation? {
        guard let id = selectedConversationID else { return nil }
        return conversations.first { $0.id == id }
    }

    /// Formatted date for display in the sidebar.
    static func formattedDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
