// SidebarView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Conversation list sidebar. Create, select, rename, delete conversations,
// and reach the app's secondary destinations (Models, Settings). Rendered
// inside the split-view sidebar column on regular widths and inside the
// drawer sheet on compact widths.

import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: ConversationListViewModel
    var onNewConversation: () -> Void = {}
    var onSelectConversation: (UUID) -> Void = { _ in }
    /// Library row tap (Models / Settings). The shell dismisses the drawer
    /// (compact) and pushes the destination onto the shared detail stack.
    var onOpenRoute: (ShellRoute) -> Void = { _ in }
    /// Confirmed-delete handoff. The shell owns the whole delete so it can
    /// cancel an in-flight chat stream targeting the doomed conversation
    /// first, before the list model's delete cascades the streaming row.
    var onDeleteConversation: (UUID) -> Void = { _ in }

    @State private var conversationToRename: ConversationPayload?
    @State private var renameText: String = ""
    @State private var showDeleteConfirmation = false
    @State private var conversationToDelete: ConversationPayload?

    var body: some View {
        List(selection: $viewModel.selectedConversationID) {
            Section {
                Button(action: onNewConversation) {
                    Label("New Conversation", systemImage: "square.and.pencil")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ZiroTheme.accent)
                }
                .accessibilityHint("Creates a private on-device chat")
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(ZiroType.supporting)
                        .foregroundStyle(ZiroTheme.warningText)
                        // The row mounts silently otherwise; VoiceOver users
                        // only find it by browsing the list.
                        .announcingOnAppear("Conversation list error. \(error)")
                }
            }

            conversationSections

            Section {
                Button {
                    onOpenRoute(.models)
                } label: {
                    Label("Models", systemImage: "arrow.down.circle")
                }
                Button {
                    onOpenRoute(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } header: {
                ZiroSectionHeader(title: "Library", systemImage: "books.vertical")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Conversations")
        .refreshable { await viewModel.loadConversations() }
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
                    conversationToDelete = nil
                    onDeleteConversation(conversation.id)
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

    // MARK: - Conversation Sections

    @ViewBuilder
    private var conversationSections: some View {
        if viewModel.isLoading && viewModel.conversations.isEmpty {
            Section {
                ForEach(0..<4, id: \.self) { _ in
                    ConversationRow.placeholder
                        .redacted(reason: .placeholder)
                        .accessibilityHidden(true)
                }
            }
        } else if viewModel.conversations.isEmpty {
            Section {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Create a conversation to get started.")
                )
                .listRowBackground(Color.clear)
            }
        } else {
            ForEach(viewModel.groupedConversations()) { group in
                Section {
                    ForEach(group.items) { conversation in
                        conversationRow(conversation)
                    }
                } header: {
                    if let title = group.title {
                        Text(title)
                    }
                }
            }
        }
    }

    private func conversationRow(_ conversation: ConversationPayload) -> some View {
        ConversationRow(conversation: conversation)
            .tag(conversation.id)
            .contentShape(Rectangle())
            .onTapGesture {
                onSelectConversation(conversation.id)
            }
            .contextMenu {
                Button {
                    conversationToRename = conversation
                    renameText = conversation.title
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    conversationToDelete = conversation
                    showDeleteConfirmation = true
                } label: {
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

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: ConversationPayload

    var body: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            Text(conversation.title)
                .font(ZiroType.body)
                .foregroundStyle(ZiroTheme.primaryText)
                .lineLimit(1)

            HStack(spacing: ZiroTheme.Spacing.small) {
                // The message count is engineering metadata — technical voice.
                Text("\(conversation.messageCount) messages")
                    .font(ZiroType.technical(.caption))
                    .foregroundStyle(ZiroTheme.secondaryText)

                Text("·")
                    .font(ZiroType.caption)
                    .foregroundStyle(ZiroTheme.tertiaryText)

                Text(ConversationListViewModel.formattedDate(conversation.updatedAt))
                    .font(ZiroType.caption)
                    .foregroundStyle(ZiroTheme.secondaryText)
            }
        }
        .padding(.vertical, ZiroTheme.Spacing.xSmall)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let count = conversation.messageCount
        let date = ConversationListViewModel.formattedDate(conversation.updatedAt)
        return "\(conversation.title), \(count) \(count == 1 ? "message" : "messages"), updated \(date)"
    }

    static var placeholder: ConversationRow {
        ConversationRow(conversation: ConversationPayload(
            id: UUID(),
            title: "Loading conversation title",
            modelID: "placeholder",
            updatedAt: Date(),
            createdAt: Date(),
            systemPrompt: nil,
            temperature: 0.7,
            topP: 0.9,
            topK: 40,
            messageCount: 3,
            isBranch: false,
            parentBranchID: nil,
            branchPointMessageID: nil
        ))
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SidebarView(
            viewModel: ConversationListViewModel(persistence: PersistenceController(inMemory: true))
        )
    }
}
