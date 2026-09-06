// SidebarView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Conversation list sidebar. Brand mark and destination rows (Chats,
// Models) up top, recent conversations below, New chat / Settings pills
// pinned to the bottom. The full searchable archive lives on the Chats
// screen (pushed via ShellRoute.chats). Rendered inside the split-view
// sidebar column on regular widths and inside the drawer sheet on
// compact widths.

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
        }
        .listStyle(.sidebar)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            sidebarHeader
        }
        .refreshable { await viewModel.loadConversations() }
        .safeAreaInset(edge: .bottom) {
            sidebarBottomBar
        }
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

    // MARK: - Header

    /// Brand mark top-left, then plain destination rows (no pills — pills
    /// are reserved for the bottom bar). Chats pushes the full searchable
    /// archive; Models pushes the Models page via the shell.
    private var sidebarHeader: some View {
        VStack(spacing: 0) {
            HStack {
                ZiroBrandMark(size: 36)
                Spacer()
            }
            .padding(.horizontal, ZiroTheme.Spacing.medium)
            sidebarDestinationRow(
                    title: "Chats",
                    systemImage: "bubble.left.and.bubble.right",
                    identifier: "sidebar-chats-row"
                ) {
                    onOpenRoute(.chats)
                }
                sidebarDestinationRow(
                    title: "Models",
                    systemImage: "arrow.down.circle",
                    identifier: "sidebar-models-button"
                ) {
                    onOpenRoute(.models)
                }
        }
        .padding(.bottom, ZiroTheme.Spacing.xSmall)
        .background(.bar)
    }

    /// One plain navigation row: icon, title, chevron. Deliberately not a
    /// pill — pills are reserved for the New chat / Settings bottom bar.
    private func sidebarDestinationRow(
        title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: ZiroTheme.Spacing.small) {
                Image(systemName: systemImage)
                    .foregroundStyle(ZiroTheme.secondaryText)
                    .frame(width: 24)
                Text(title)
                    .font(.body)
                    .foregroundStyle(ZiroTheme.primaryText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ZiroTheme.tertiaryText)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.horizontal, ZiroTheme.Spacing.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Bottom Bar

    /// Fixed bottom bar: New chat and Settings side by side. The list
    /// itself carries only conversations — no section headers compete
    /// for attention and no large navigation title is needed.
    private var sidebarBottomBar: some View {
        HStack(spacing: ZiroTheme.Spacing.small) {
            Button(action: onNewConversation) {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(ZiroTheme.accentForeground)
            }
            .accessibilityHint("Creates a private on-device chat")
            .accessibilityIdentifier("new-chat-button")

            Button {
                onOpenRoute(.settings)
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(ZiroTheme.accentContainer, in: Capsule())
                    .foregroundStyle(ZiroTheme.primaryText)
            }
            .accessibilityIdentifier("sidebar-settings-button")
        }
        .padding(.horizontal, ZiroTheme.Spacing.medium)
        .padding(.top, ZiroTheme.Spacing.small)
        .padding(.bottom, ZiroTheme.Spacing.medium)
        .background(.bar)
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

// MARK: - Chats Archive Screen

/// Full conversation archive pushed from the sidebar's Chats row: every
/// chat (no 50-row cap) with a search bar for title search. Selecting a
/// row hands the ID to the shell, which pops back to the chat surface and
/// loads the transcript. Rename/delete mirror the sidebar recents; delete
/// funnels through the shell so an in-flight stream is cancelled first.
struct ChatsView: View {
    @ObservedObject var viewModel: ConversationListViewModel
    var onNewConversation: () -> Void = {}
    var onSelectConversation: (UUID) -> Void = { _ in }
    var onDeleteConversation: (UUID) -> Void = { _ in }

    @State private var searchText: String = ""
    @State private var conversationToRename: ConversationPayload?
    @State private var renameText: String = ""
    @State private var showDeleteConfirmation = false
    @State private var conversationToDelete: ConversationPayload?

    private var filteredConversations: [ConversationPayload] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.conversations }
        return viewModel.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.conversations.isEmpty {
                List {
                    ForEach(0..<8, id: \.self) { _ in
                        ConversationRow.placeholder
                            .redacted(reason: .placeholder)
                            .accessibilityHidden(true)
                    }
                }
            } else if filteredConversations.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if viewModel.conversations.isEmpty {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Create a conversation to get started.")
                )
            } else {
                List(filteredConversations) { conversation in
                    ConversationRow(conversation: conversation)
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
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search chats")
        .autocorrectionDisabled()
        .refreshable { await viewModel.loadConversations() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onNewConversation) {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New chat")
                .accessibilityIdentifier("chats-new-chat-button")
                .frame(minWidth: 44, minHeight: 44)
            }
        }
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
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SidebarView(
            viewModel: ConversationListViewModel(persistence: PersistenceController(inMemory: true))
        )
    }
}
