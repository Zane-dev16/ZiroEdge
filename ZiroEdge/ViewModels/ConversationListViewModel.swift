// ConversationListViewModel.swift
// ZiroEdge — Privacy-first local AI assistant
//
// ViewModel for the sidebar conversation list. Manages conversation
// CRUD operations and selection state.

import Foundation
import SwiftUI
import os

/// One relative-time bucket of sidebar conversations (Today / Yesterday /
/// Previous 7 Days / Earlier). `title` is nil for the open-ended earlier
/// bucket so it renders without a header.
struct ConversationGroup: Identifiable {
    let id: String
    let title: String?
    let items: [ConversationPayload]
}

@MainActor
final class ConversationListViewModel: ObservableObject {

    // MARK: - Published State

    @Published var conversations: [ConversationPayload] = []
    @Published private(set) var isLoading = false
    @Published var selectedConversationID: UUID?
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
        guard !newTitle.isEmpty else { return }
        switch await persistence.updateConversationTitle(id: conversationID, title: newTitle) {
        case .success:
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

    // MARK: - Grouping

    /// Maximum conversation rows rendered in the sidebar regardless of history size.
    static let groupedRowLimit = 50

    /// Bucket conversations into relative-time sections ordered newest first:
    /// Today → Yesterday → Previous 7 Days → Earlier. Empty buckets are omitted.
    func groupedConversations(now: Date = Date()) -> [ConversationGroup] {
        let calendar = Calendar.current
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        var buckets: [(key: String, title: String?, items: [ConversationPayload])] = [
            ("today", "Today", []),
            ("yesterday", "Yesterday", []),
            ("previous-7-days", "Previous 7 Days", []),
            ("earlier", nil, [])
        ]
        let slotByKey = ["today": 0, "yesterday": 1, "previous-7-days": 2, "earlier": 3]

        // Persistence delivers rows newest-first; cap how far back we render.
        for conversation in conversations.prefix(Self.groupedRowLimit) {
            let date = conversation.updatedAt ?? conversation.createdAt ?? now
            let slot: Int
            if calendar.isDateInToday(date) {
                slot = 0
            } else if calendar.isDateInYesterday(date) {
                slot = 1
            } else if date >= sevenDaysAgo {
                slot = 2
            } else {
                slot = 3
            }
            buckets[slot].items.append(conversation)
        }

        return buckets.compactMap { bucket in
            guard !bucket.items.isEmpty else { return nil }
            return ConversationGroup(id: bucket.key, title: bucket.title, items: bucket.items)
        }
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
