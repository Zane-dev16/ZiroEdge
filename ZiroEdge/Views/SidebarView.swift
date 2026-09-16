// SidebarView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Conversation list sidebar. Brand mark and destination rows (Chats,
// Models) up top, recent conversations below, New chat / Settings quiet
// actions pinned to the bottom. The full searchable archive lives on the Chats
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        // List parity: the animation rides the mutating value (row count),
        // so inserts/deletes fade instead of snapping. Transitions live on
        // the rows themselves; nothing blanket on the List.
        .ziroAnimation(ZiroMotion.appear, value: viewModel.conversations.count)
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
            // Dead-button guard (MEDIUM): an empty title commits nothing —
            // disable instead of tapping into a silent `commitRename` guard.
            .disabled(!ConversationListViewModel.canCommitRename(title: renameText))
            .accessibilityIdentifier(ModelEvictionPresentation.renameSaveButtonID)
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
                ZiroBrandMark(size: 40)
                Text("ZIROEDGE")
                    .font(ZiroType.face(.orbitronSemiBold, .headline))
                    .tracking(1.4)
                    .foregroundStyle(ZiroTheme.secondaryText)
                Spacer()
            }
            .padding(.horizontal, ZiroTheme.Spacing.medium)
            .padding(.top, ZiroTheme.Spacing.medium)
            .padding(.bottom, ZiroTheme.Spacing.medium)
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
        .padding(.bottom, ZiroTheme.Spacing.medium)
        .background(ZiroTheme.pageBackground)
    }

    /// One plain navigation row: icon + title, no chevron. The whole row
    /// is the button — a trailing arrow adds chrome without information.
    private func sidebarDestinationRow(
        title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: ZiroTheme.Spacing.small) {
                Image(systemName: systemImage)
                    // Match the row title voice (.body, regular) — one set
                    // per surface. Directional glyphs (bubble.left.*, branch)
                    // mirror in RTL; vertical/circular ones ignore the flip.
                    .font(.body)
                    .foregroundStyle(ZiroTheme.secondaryText)
                    .flipsForRightToLeft(systemImageNeedsRTLFlip(systemImage))
                    .frame(width: 24)
                Text(title)
                    .font(ZiroType.face(.orbitronSemiBold, .footnote))
                    .tracking(0.8)
                    .foregroundStyle(ZiroTheme.primaryText)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.horizontal, ZiroTheme.Spacing.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(ZiroSubtlePressButtonStyle())
        .accessibilityIdentifier(identifier)
    }

    /// Directional symbols mirror in RTL; vertical/circular ones
    /// (arrow.down.circle, arrow.clockwise, chevron.down) do not.
    private func systemImageNeedsRTLFlip(_ name: String) -> Bool {
        name.contains("chevron.right")
            || name.contains("bubble.left")
            || name.contains("text.bubble")
            || name.contains("arrow.triangle.branch")
    }

    // MARK: - Bottom Bar

    /// Fixed bottom bar: New chat and Settings side by side, separated
    /// from the list by a full-bleed 1px hairline. The list itself carries
    /// only conversations — no section headers compete for attention and
    /// no large navigation title is needed.
    private var sidebarBottomBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(ZiroTheme.hairline)
                .frame(height: 1)
            HStack(spacing: ZiroTheme.Spacing.small) {
                Button(action: onNewConversation) {
                    Label("New chat", systemImage: "square.and.pencil")
                        .font(ZiroType.face(.orbitronSemiBold, .footnote))
                        .tracking(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .foregroundStyle(ZiroTheme.primaryText)
                        .background(ZiroTheme.wellBackground, in: Capsule())
                        .overlay(Capsule().stroke(ZiroTheme.hairline, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(ZiroSubtlePressButtonStyle())
                .accessibilityHint("Creates a private on-device chat")
                .accessibilityIdentifier("new-chat-button")

                Button {
                    onOpenRoute(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(ZiroType.face(.orbitronSemiBold, .footnote))
                        .tracking(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .foregroundStyle(ZiroTheme.primaryText)
                        .background(ZiroTheme.wellBackground, in: Capsule())
                        .overlay(Capsule().stroke(ZiroTheme.hairline, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(ZiroSubtlePressButtonStyle())
                .accessibilityIdentifier("sidebar-settings-button")
            }
            .padding(.horizontal, ZiroTheme.Spacing.medium)
            .padding(.top, ZiroTheme.Spacing.small)
            .padding(.bottom, ZiroTheme.Spacing.medium)
        }
        .background(ZiroTheme.pageBackground)
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
                .transition(.opacity)
                // Directional hero glyph — mirror in RTL.
                .flipsForRightToLeft(true)
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
                            .font(ZiroType.face(.orbitronSemiBold, .caption2))
                            .textCase(.uppercase)
                            .tracking(0.8)
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
            // Row insert/delete rides the count-keyed appear above:
            // opacity-only in Reduce Motion, subtle scale + fade otherwise.
            .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
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
    /// Selected rows (sidebar `List(selection:)`) fill with the subtle
    /// selection tone and carry no edge — the quiet row itself carries no
    /// fill and no stroke, so selection is projected explicitly and only
    /// when selected.
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: ZiroTheme.Spacing.medium) {
            // Title + one meta line (message count and recency) so every
            // row reads sensibly even when titles truncate. No thumbnail
            // tile and no trailing timestamp column — both were bulk that
            // fought the title for space.
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
                Text(conversation.title)
                    .font(ZiroType.body)
                    .foregroundStyle(ZiroTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.9)

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
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: ZiroTheme.Radius.small, style: .continuous)
                .fill(isSelected ? ZiroTheme.selectedBackground : Color.clear)
        )
        // Selection fill cross-fades on the press curve instead of flipping.
        .ziroAnimation(ZiroMotion.press, value: isSelected)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var conversationToRename: ConversationPayload?
    @State private var renameText: String = ""
    @State private var showDeleteConfirmation = false
    @State private var conversationToDelete: ConversationPayload?

    /// Archive rows: every chat (no 50-row cap), title-searched and
    /// bucketed into recency sections like the sidebar. No scope filter —
    /// the list runs straight.
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

    /// The toolbar's New-chat control: exactly ONE capsule (fill-only
    /// quiet canon — no ring overlay, scale-only press style, and the iOS 26
    /// shared toolbar background hidden at the call site). Extracted so the
    /// pre/post-iOS 26 toolbar branches share one definition.
    private var newChatToolbarButton: some View {
        Button(action: onNewConversation) {
            HStack(spacing: ZiroTheme.Spacing.xSmall) {
                Text("New chat")
                    .font(ZiroType.footnote)
                    .foregroundStyle(ZiroTheme.primaryText)
                Image(systemName: "plus")
                    .font(ZiroType.footnote)
                    .foregroundStyle(ZiroTheme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, ZiroTheme.Spacing.medium)
            .frame(minHeight: 33)
            .background(ZiroTheme.wellBackground, in: Capsule())
            .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(ZiroSubtlePressButtonStyle())
        .accessibilityLabel("New chat")
        .accessibilityIdentifier("chats-new-chat-button")
    }

    /// One archive row: quiet treatment with rename/delete affordances.
    /// Delete funnels through the shell so an in-flight stream is cancelled
    /// first (mirrors the sidebar row).
    private func archiveRow(_ conversation: ConversationPayload) -> some View {
        ConversationRow(conversation: conversation)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
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
                    .scrollContentBackground(.hidden)
                    .background(ZiroTheme.pageBackground)
                } else if viewModel.conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Create a conversation to get started.")
                    )
                    .transition(.opacity)
                    // Directional hero glyph — mirror in RTL.
                    .flipsForRightToLeft(true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleSections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .transition(.opacity)
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
                                        .font(ZiroType.face(.orbitronSemiBold, .caption2))
                                        .textCase(.uppercase)
                                        .tracking(0.8)
                                        .foregroundStyle(ZiroTheme.tertiaryText)
                                }
                            }
                        }
                    }
                    .listSectionSpacing(ZiroTheme.Spacing.small)
                    .scrollContentBackground(.hidden)
                    .background(ZiroTheme.pageBackground)
                    // Archive parity: count drives inserts/deletes, search
                    // text drives the filter — same row transition as above.
                    .ziroAnimation(ZiroMotion.appear, value: viewModel.conversations.count)
                    .ziroAnimation(ZiroMotion.appear, value: searchText)
                }
        }
        .background(ZiroTheme.pageBackground)
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search chats")
        .autocorrectionDisabled()
        .refreshable { await viewModel.loadConversations() }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Chats")
                    .font(ZiroType.face(.orbitronBold, .title3))
                    .foregroundStyle(ZiroTheme.primaryText)
            }
            // Custom capsule (not the system glass): hide the iOS 26 shared
            // background or it renders a second pill behind the fill.
            // Same pattern as the chat toolbar's sidebar toggle.
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarTrailing) {
                    newChatToolbarButton
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    newChatToolbarButton
                }
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
            // Dead-button guard (MEDIUM): mirrors the sidebar rename — an
            // empty title commits nothing, so disable instead of tapping
            // into a silent `commitRename` guard.
            .disabled(!ConversationListViewModel.canCommitRename(title: renameText))
            .accessibilityIdentifier(ModelEvictionPresentation.renameSaveButtonID)
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
