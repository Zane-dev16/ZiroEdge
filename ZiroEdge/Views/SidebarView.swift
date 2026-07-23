// SidebarView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Conversation list sidebar. Create, select, rename, delete conversations.
// Split view on iPad/macOS, NavigationStack on iPhone.

import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: ConversationListViewModel
    let onNewConversation: () -> Void
    let onSelectConversation: (UUID) -> Void

    @State private var conversationToRename: ConversationPayload?
    @State private var renameText: String = ""
    @State private var showDeleteConfirmation = false
    @State private var conversationToDelete: ConversationPayload?

    var body: some View {
        List(selection: $viewModel.selectedConversationID) {
            // New conversation button.
            Section {
                Button(action: onNewConversation) {
                    Label("New Conversation", systemImage: "plus.circle.fill")
                        .font(.body.weight(.medium))
                }
            }

            // Conversation list.
            Section("Conversations") {
                ForEach(viewModel.conversations) { conversation in
                    ConversationRow(conversation: conversation)
                        .tag(conversation.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelectConversation(conversation.id)
                        }
                        .contextMenu {
                            Button(action: {
                                conversationToRename = conversation
                                renameText = conversation.title
                            }) {
                                Label("Rename", systemImage: "pencil")
                            }

                            Button(role: .destructive, action: {
                                conversationToDelete = conversation
                                showDeleteConfirmation = true
                            }) {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                conversationToDelete = conversation
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("ZiroEdge")
        .alert("Rename Conversation", isPresented: Binding(
            get: { conversationToRename != nil },
            set: { if !$0 { conversationToRename = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let conversation = conversationToRename {
                    viewModel.editingTitle = renameText
                    Task { await viewModel.commitRename(conversation.id) }
                }
            }
            Button("Cancel", role: .cancel) {
                conversationToRename = nil
            }
        } message: {
            Text("Enter a new name for this conversation.")
        }
        .alert("Delete Conversation?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let conversation = conversationToDelete {
                    Task { await viewModel.deleteConversation(conversation.id) }
                }
            }
            Button("Cancel", role: .cancel) {
                conversationToDelete = nil
            }
        } message: {
            Text("This will permanently delete the conversation and all its messages.")
        }
        .task {
            await viewModel.loadConversations()
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: ConversationPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.body)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text("\(conversation.messageCount) messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text(ConversationListViewModel.formattedDate(conversation.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SidebarView(
            viewModel: ConversationListViewModel(persistence: PersistenceController(inMemory: true)),
            onNewConversation: {},
            onSelectConversation: { _ in }
        )
    }
}
