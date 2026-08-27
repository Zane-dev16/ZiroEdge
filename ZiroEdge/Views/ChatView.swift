// ChatView.swift
// ZiroEdge — Privacy-first local AI assistant

import PhotosUI
import SwiftUI

/// The chat surface. Identity/loading feedback lives in the header pill
/// (`ChatHeaderPill`); the composer enables only while the model is resident;
/// load failures surface as inline retry rows, not alerts (master plan §B).
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    /// Compact shells render the sidebar toggle inside the chat toolbar.
    var showsSidebarToggle: Bool = false
    /// Opens a shell route (e.g. the models catalog) from header CTA states.
    var onNavigateToRoute: ((ShellRoute) -> Void)? = nil
    /// Presents the sidebar drawer; nil hides the toggle even when requested.
    var onOpenSidebar: (() -> Void)? = nil

    @FocusState var isInputFocused: Bool
    @State private var hasScrolledUp = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var canPasteImage = UIPasteboard.general.hasImages
    @State private var showSystemPromptEditor = false
    @State private var systemPromptDraft = ""
    // BATCH-04: throttle scrollToBottom to avoid stacked withAnimation per token
    @State private var lastScrollTime: Date = .distantPast
    @State private var pendingScrollTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            banners
            modelRetryRow
            inputBar
        }
        .background(ZiroTheme.pageBackground)
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { chatToolbar }
        .onAppear {
            refreshPasteboardState()
            // Deferred autoload lives here rather than at startup: reaching
            // the chat never waits on model work (master plan §B).
            viewModel.startDeferredModelLoadIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshPasteboardState()
        }
        .alert("Enable Experimental Runtime?", isPresented: $viewModel.showingExperimentalConsent) {
            Button("Enable Experimental Use") {
                Task { await viewModel.confirmExperimentalConsent() }
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelExperimentalConsent()
            }
        } message: {
            Text("This imported profile has not passed the full physical workload. ZiroEdge will still enforce its measured admission floor and reserve.")
        }
        .sheet(isPresented: $showSystemPromptEditor) {
            ConversationSystemPromptEditor(
                prompt: $systemPromptDraft,
                defaultPrompt: UserDefaults.standard.string(
                    forKey: ChatViewModel.DefaultsKeys.defaultSystemPrompt
                ) ?? "",
                onSave: {
                    if await viewModel.updateSystemPrompt(systemPromptDraft) {
                        showSystemPromptEditor = false
                    }
                },
                onUseDefault: {
                    if await viewModel.updateSystemPrompt(nil) {
                        systemPromptDraft = ""
                        showSystemPromptEditor = false
                    }
                }
            )
        }
    }

    var attachmentButtons: some View {
        HStack(spacing: ZiroTheme.Spacing.medium) {
            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 10, matching: .images) {
                Image(systemName: "photo.on.rectangle")
                    .font(.title3)
                    .frame(width: 32, height: 40)
            }
            .accessibilityLabel("Add photos")
            .accessibilityHint("Attach up to 10 images to this message")
            .onChange(of: selectedPhotos) { _, items in
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) { await viewModel.addImage(data) }
                    }
                    selectedPhotos.removeAll()
                }
            }

            Button {
                Task {
                    if await viewModel.pasteImage() { refreshPasteboardState() }
                }
            } label: {
                Image(systemName: "doc.on.clipboard").font(.title3).frame(width: 32, height: 40)
            }
            .disabled(!canPasteImage)
            .accessibilityLabel("Paste image")
        }
        .foregroundStyle(Color.accentColor)
    }

    var sendButton: some View {
        Button {
            Task {
                if viewModel.isStreaming { await viewModel.cancelStream() }
                else { await viewModel.sendMessage() }
            }
        } label: {
            Image(systemName: viewModel.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(.title)
                .foregroundStyle(sendTint)
                .frame(width: 38, height: 42)
        }
        .disabled(sendDisabled)
        .accessibilityLabel(viewModel.isStreaming ? "Stop generating" : "Send message")
        .accessibilityHint(viewModel.isStreaming ? "Stops the current response" : "Sends your message to the local model")
    }

    /// Streaming stays interruptible; sending requires residency (`chatReady`).
    private var sendDisabled: Bool {
        (!chatReady || !canSend || viewModel.isLoadingConversation) && !viewModel.isStreaming
    }

    private var sendTint: Color {
        (canSend && chatReady) || viewModel.isStreaming ? Color.accentColor : Color.secondary.opacity(0.45)
    }

    var imagePreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZiroTheme.Spacing.small) {
                ForEach(Array(viewModel.pendingImages.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: image)
                                .resizable().scaledToFill()
                                .frame(width: 68, height: 68)
                                .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.control))
                                .accessibilityLabel("Attached image \(index + 1)")
                            Button { viewModel.removeImage(at: index) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3).foregroundStyle(.white)
                                    .shadow(radius: 2)
                            }
                            .accessibilityLabel("Remove attached image \(index + 1)")
                            .offset(x: 5, y: -5)
                        }
                    }
                }
            }
            .padding(.horizontal, ZiroTheme.Spacing.large)
            .padding(.vertical, ZiroTheme.Spacing.small)
        }
    }
}

extension ChatView {

    // MARK: Transcript

    var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.isLoadingConversation {
                        loadingTranscript
                    } else if viewModel.messages.isEmpty && !viewModel.isStreaming {
                        emptyState
                    }

                    ForEach(viewModel.messages, id: \.id) { message in
                        MessageBubble(
                            message: message,
                            onBranch: { Task { await viewModel.branchFromMessage(message.id) } },
                            onCopy: { viewModel.copyMessage(message) }
                        )
                        .id(message.id)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }

                    if viewModel.isStreaming && !viewModel.streamingText.isEmpty {
                        MessageBubble(
                            message: ChatMessagePayload(role: .assistant, content: viewModel.streamingText),
                            isStreaming: true
                        )
                        .id("streaming")
                    }

                    if viewModel.isStreaming && viewModel.streamingText.isEmpty {
                        ThinkingIndicator().id("thinking")
                    }

                    Color.clear.frame(height: 1).id("bottomAnchor")
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ZiroTheme.Spacing.medium)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ScrollOffsetKey.self,
                            value: geometry.frame(in: .named("scrollView")).maxY
                        )
                    }
                }
            }
            .coordinateSpace(name: "scrollView")
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { isInputFocused = false }
            .onPreferenceChange(ScrollOffsetKey.self) { maxY in
                // BATCH-04: avoid withAnimation per scroll-offset frame
                hasScrolledUp = maxY < 0
            }
            .overlay(alignment: .bottom) {
                if hasScrolledUp {
                    jumpToBottomButton { scrollToBottom(proxy) }
                        .padding(.bottom, ZiroTheme.Spacing.small)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: hasScrolledUp)
            .onChange(of: viewModel.messages.count) { _, _ in throttledScrollToBottom(proxy) }
            .onChange(of: viewModel.streamingText) { _, _ in
                guard !hasScrolledUp else { return }
                throttledScrollToBottom(proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                if streaming { throttledScrollToBottom(proxy) }
            }
        }
    }

    var loadingTranscript: some View {
        VStack(spacing: ZiroTheme.Spacing.large) {
            ProgressView()
            Text("Loading conversation…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .accessibilityElement(children: .combine)
    }

    var emptyState: some View {
        ZiroHero(
            symbol: "bubble.left.and.bubble.right",
            title: "Start a conversation",
            message: "Ask anything below. Your messages and the model's response stay on this device.",
            tint: .accentColor
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ZiroTheme.Spacing.xxLarge)
        .padding(.top, ZiroTheme.Spacing.heroTop)
    }

    // MARK: Scrolling

    func jumpToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.bold))
                .padding(ZiroTheme.Spacing.medium)
                .foregroundStyle(ZiroTheme.accentForeground)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        }
        .accessibilityLabel("Jump to latest message")
    }

    var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.pendingImages.isEmpty
    }

    func scrollToBottom(_ proxy: ScrollViewProxy) {
        let scroll = {
            if viewModel.isStreaming {
                proxy.scrollTo(viewModel.streamingText.isEmpty ? "thinking" : "streaming", anchor: .bottom)
            } else {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
        }
        if reduceMotion { scroll() } else { withAnimation(.easeOut(duration: 0.22), scroll) }
        hasScrolledUp = false
    }

    // BATCH-04: debounced scroll — at most one animated scroll per 250ms, coalesces bursts
    func throttledScrollToBottom(_ proxy: ScrollViewProxy) {
        let now = Date()
        if now.timeIntervalSince(lastScrollTime) > 0.25 {
            scrollToBottom(proxy)
            lastScrollTime = now
        } else {
            pendingScrollTask?.cancel()
            pendingScrollTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                scrollToBottom(proxy)
                lastScrollTime = Date()
            }
        }
    }

    func refreshPasteboardState() { canPasteImage = UIPasteboard.general.hasImages }

    // MARK: Routes

    /// Shell route hook when provided (AppShellView); falls back to the legacy
    /// redirect flag so previews and tests keep working bare.
    func navigateToRoute(_ route: ShellRoute) {
        if let onNavigateToRoute {
            onNavigateToRoute(route)
        } else if route == .models {
            viewModel.needsModelRedirect = true
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    var chatToolbar: some ToolbarContent {
        if showsSidebarToggle, let onOpenSidebar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenSidebar) {
                    Image(systemName: "line.3.horizontal")
                }
                .accessibilityLabel("Conversations")
                .accessibilityIdentifier("sidebar-button")
            }
        }
        ToolbarItem(placement: .principal) {
            ChatHeaderPill(
                phase: viewModel.modelLoadPhase,
                modelName: viewModel.selectedModel?.displayName,
                availableModels: viewModel.availableModels,
                onSelectModel: { model in Task { await viewModel.selectModel(model) } },
                onBrowseModels: { navigateToRoute(.models) },
                onRetryLoad: { viewModel.retryModelLoad() }
            )
        }
        ToolbarItem(placement: .secondaryAction) {
            Button {
                systemPromptDraft = viewModel.activeConversationSystemPrompt ?? ""
                showSystemPromptEditor = true
            } label: {
                Image(systemName: "text.badge.star")
            }
            .disabled(viewModel.activeConversationID == nil || viewModel.isLoadingConversation)
            .accessibilityLabel("Conversation instructions")
        }
    }

    // MARK: Recovery Actions

    var recoveryActions: some View {
        HStack(spacing: ZiroTheme.Spacing.medium) {
            Button("Retry Save") { Task { await viewModel.retryPersistenceRecovery() } }
            Button("Export") { Task { await viewModel.exportPersistenceRecovery() } }
            if let url = viewModel.recoveryExportURL { ShareLink("Share", item: url) }
            Button("Discard", role: .destructive) { Task { await viewModel.discardPersistenceRecovery() } }
        }
    }

    var recoveryActionsVertical: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
            Button("Retry Save") { Task { await viewModel.retryPersistenceRecovery() } }
            Button("Export") { Task { await viewModel.exportPersistenceRecovery() } }
            if let url = viewModel.recoveryExportURL { ShareLink("Share", item: url) }
            Button("Discard", role: .destructive) { Task { await viewModel.discardPersistenceRecovery() } }
        }
    }
}

#if DEBUG
#Preview {
    ChatView(viewModel: ChatViewModel(
        persistence: PersistenceController(inMemory: true),
        inferenceService: InferenceService(),
        sessionActor: ChatSessionActor(
            inferenceService: InferenceService(),
            persistence: PersistenceController(inMemory: true)
        ),
        lifecycleManager: ModelLifecycleManager(
            inferenceService: InferenceService(),
            memoryBudgeter: MemoryBudgeter()
        ),
        downloadStatusProvider: DownloadManager()
    ))
}
#endif
