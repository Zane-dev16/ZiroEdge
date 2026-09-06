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
        .listSectionSpacing(ZiroTheme.Spacing.small)
        .scrollContentBackground(.hidden)
        .background(ZiroTheme.pageBackground)
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

    /// Brand-mark identity row (monogram tile + wordmark). Chats pushes
    /// the full searchable archive (which carries its own search field,
    /// so no header search button); Models pushes the Models page via
    /// the shell. No subtitle under the wordmark: the empty state's
    /// privacy caption already carries that story.
    private var sidebarHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: ZiroTheme.Spacing.medium) {
                ZiroBrandMark(size: 30)
                    .padding(ZiroTheme.Spacing.xSmall)
                    .background(
                        ZiroTheme.accentContainer,
                        in: RoundedRectangle(cornerRadius: ZiroTheme.Radius.small, style: .continuous)
                    )
                Text("ZiroEdge")
                    .font(ZiroType.rowTitle)
                    .foregroundStyle(ZiroTheme.primaryText)
                Spacer()
            }
            .padding(.horizontal, ZiroTheme.Spacing.medium)
            .padding(.vertical, ZiroTheme.Spacing.small)
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
        .background(ZiroTheme.pageBackground)
    }

    /// One plain navigation row: icon + title, no chevron. The whole row
    /// is the button — a trailing arrow adds chrome without information.
    /// Deliberately not a pill — pills are reserved for the New chat /
    /// Settings bottom bar.
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
        .background(ZiroTheme.pageBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ZiroTheme.hairline)
                .frame(height: 1)
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
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    if let title = group.title {
                        Text(title)
                            .font(ZiroType.micro)
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .foregroundStyle(ZiroTheme.tertiaryText)
                    }
                }
            }
        }
    }

    private func conversationRow(_ conversation: ConversationPayload) -> some View {
        ConversationRow(
            conversation: conversation,
            isSelected: viewModel.selectedConversationID == conversation.id
        )
            .tag(conversation.id)
            .contentShape(Rectangle())
            .listRowInsets(EdgeInsets(
                top: ZiroTheme.Spacing.xSmall,
                leading: ZiroTheme.Spacing.medium,
                bottom: ZiroTheme.Spacing.xSmall,
                trailing: ZiroTheme.Spacing.medium
            ))
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
    /// Selected rows (sidebar `List(selection:)`) tint to the accent
    /// container with a 2pt accent edge — the quiet row itself carries no
    /// fill and no stroke, so selection is projected explicitly and only
    /// when selected (card OR hairline, never both at rest).
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: ZiroTheme.Spacing.medium) {
            // Title + one meta line (message count and recency) so every
            // row reads sensibly even when titles truncate. No thumbnail
            // tile and no trailing timestamp column — both were bulk that
            // fought the title for space.
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
                Text(conversation.title)
                    .font(ZiroType.body.weight(.medium))
                    .foregroundStyle(ZiroTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(metaLine)
                    .font(ZiroType.caption)
                    .foregroundStyle(ZiroTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: ZiroTheme.Spacing.small)
        }
        .padding(.horizontal, ZiroTheme.Spacing.medium)
        .padding(.vertical, ZiroTheme.Spacing.small)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: ZiroTheme.Radius.small, style: .continuous)
                .fill(isSelected ? ZiroTheme.accentContainer : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ZiroTheme.Radius.small, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// One meta line: message count plus recency, e.g. "3 messages · 2h ago".
    private var metaLine: String {
        let count = conversation.messageCount
        let date = ConversationListViewModel.formattedDate(conversation.updatedAt)
        return "\(count) \(count == 1 ? "message" : "messages") · \(date)"
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

    /// Archive scope filter — the capsule pills above the list. Recent
    /// means touched in the last 7 days; undated rows show under every scope.
    private enum ArchiveScope: String, CaseIterable {
        case all = "All"
        case recent = "Recent"
        case earlier = "Earlier"
    }
    @State private var scope: ArchiveScope = .all

    /// Archive rows: every chat (no 50-row cap), scope-filtered and
    /// title-searched, bucketed into recency sections like the sidebar.
    private var visibleSections: [(id: String, title: String?, items: [ConversationPayload])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar.current
        let now = Date()
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        var buckets: [(id: String, title: String?, items: [ConversationPayload])] = [
            ("today", "Today", []),
            ("yesterday", "Yesterday", []),
            ("previous-7-days", "Previous 7 Days", []),
            ("earlier", nil, [])
        ]
        for conversation in viewModel.conversations {
            guard isInScope(conversation, cutoff: sevenDaysAgo) else { continue }
            if !query.isEmpty,
               !conversation.title.localizedCaseInsensitiveContains(query) { continue }
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
        return buckets.filter { !$0.items.isEmpty }
    }

    private func isInScope(_ conversation: ConversationPayload, cutoff: Date) -> Bool {
        guard scope != .all else { return true }
        guard let date = conversation.updatedAt ?? conversation.createdAt else { return true }
        let isRecent = date >= cutoff
        return scope == .recent ? isRecent : !isRecent
    }

    /// One archive row: quiet treatment with rename/delete affordances.
    /// Delete funnels through the shell so an in-flight stream is cancelled
    /// first (mirrors the sidebar row).
    private func archiveRow(_ conversation: ConversationPayload) -> some View {
        ConversationRow(conversation: conversation)
            .contentShape(Rectangle())
            .listRowInsets(EdgeInsets(
                top: ZiroTheme.Spacing.xSmall,
                leading: ZiroTheme.Spacing.medium,
                bottom: ZiroTheme.Spacing.xSmall,
                trailing: ZiroTheme.Spacing.medium
            ))
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

    /// Archive scope filter: quiet capsule pills (no accent fill/stroke —
    /// the selected scope reads in the recessed-well fill with primary
    /// text). Each pill keeps the 44pt-minimum-height touch floor and grows
    /// with Dynamic Type; the selected pill carries `.isSelected` for
    /// VoiceOver.
    private var archiveScopePills: some View {
        HStack(spacing: ZiroTheme.Spacing.small) {
            ForEach(ArchiveScope.allCases, id: \.self) { item in
                Button {
                    scope = item
                } label: {
                    Text(item.rawValue)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(item == scope ? ZiroTheme.primaryText : ZiroTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            Capsule().fill(item == scope ? ZiroTheme.wellBackground : .clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.rawValue) chats")
                .accessibilityHint("Filters the chat archive")
                .accessibilityAddTraits(item == scope ? .isSelected : [])
            }
        }
        .accessibilityLabel("Archive scope")
        .padding(.horizontal, ZiroTheme.Spacing.large)
        .padding(.vertical, ZiroTheme.Spacing.small)
        .ziroAnimation(ZiroMotion.press, value: scope)
    }

    var body: some View {
        VStack(spacing: 0) {
            archiveScopePills

            Group {
                if viewModel.isLoading && viewModel.conversations.isEmpty {
                    List {
                        ForEach(0..<8, id: \.self) { _ in
                            ConversationRow.placeholder
                                .redacted(reason: .placeholder)
                                .accessibilityHidden(true)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(ZiroTheme.pageBackground)
                } else if viewModel.conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Create a conversation to get started.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleSections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(visibleSections, id: \.id) { section in
                            Section {
                                ForEach(section.items) { conversation in
                                    archiveRow(conversation)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            } header: {
                                if let title = section.title {
                                    Text(title)
                                        .font(ZiroType.micro)
                                        .textCase(.uppercase)
                                        .tracking(0.5)
                                        .foregroundStyle(ZiroTheme.tertiaryText)
                                }
                            }
                        }
                    }
                    .listSectionSpacing(ZiroTheme.Spacing.small)
                    .scrollContentBackground(.hidden)
                    .background(ZiroTheme.pageBackground)
                }
            }
        }
        .background(ZiroTheme.pageBackground)
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search chats")
        .autocorrectionDisabled()
        .refreshable { await viewModel.loadConversations() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onNewConversation) {
                    Label("New chat", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ZiroTheme.accentForeground)
                        .padding(.horizontal, ZiroTheme.Spacing.medium)
                        .frame(minHeight: 44)
                        .background(Color.accentColor, in: Capsule())
                }
                .accessibilityLabel("New chat")
                .accessibilityIdentifier("chats-new-chat-button")
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
