// ChatView.swift
// ZiroEdge — Privacy-first local AI assistant

import PhotosUI
import SwiftUI

/// The chat surface. Identity/loading feedback lives in the composer model
/// picker (`ComposerModelPicker`); the composer enables only while the model is resident;
/// load failures surface as inline retry rows, not alerts (master plan §B).
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    /// Compact shells render the sidebar toggle inside the chat toolbar.
    var showsSidebarToggle: Bool = false
    /// Opens a shell route (e.g. the models catalog) from header CTA states.
    var onNavigateToRoute: ((ShellRoute) -> Void)? = nil
    /// Presents the sidebar drawer; nil hides the toggle even when requested.
    var onOpenSidebar: (() -> Void)? = nil
    /// Deletes the active conversation (shell-owned: cancels any in-flight
    /// stream first). Nil hides the ... menu's Delete row.
    var onDeleteConversation: (() -> Void)? = nil

    @FocusState var isInputFocused: Bool
    @State private var hasScrolledUp = false
    // Composer hit targets: scale with Dynamic Type so glyphs never overflow
    // their frames at accessibility sizes, while meeting the repo's 44×44
    // minimum hit-target standard at the default size.
    @ScaledMetric(relativeTo: .title3) private var composerControlSide: CGFloat = 44
    @ScaledMetric(relativeTo: .title) private var sendControlSide: CGFloat = 44
    @ScaledMetric(relativeTo: .title3) private var imageRemoveControlSide: CGFloat = 44
    // Pending-attachment thumbnail: decorative image size that grows with
    // Dynamic Type (design-system §6.2 — Radius.small corners, no shadow).
    @ScaledMetric(relativeTo: .body) private var pendingImageSide: CGFloat = 68
    /// Pull-back distance that keeps the remove glyph anchored on the
    /// thumbnail corner as its hit-target frame scales with Dynamic Type:
    /// half the frame minus the 8pt glyph margin (14pt at the 44pt default).
    private var imageRemoveCornerInset: CGFloat { imageRemoveControlSide / 2 - 8 }
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var canPasteImage = UIPasteboard.general.hasImages
    @State private var showDeleteChatConfirmation = false
    // BATCH-04: throttle scrollToBottom to avoid stacked withAnimation per token
    @State private var lastScrollTime: Date = .distantPast
    @State private var pendingScrollTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            messageList
            banners
            modelRetryRow
            inputBar
        }
        .background(ZiroTheme.pageBackground)
        // The bar names the conversation (or the draft), never a placeholder.
        .navigationTitle(viewModel.activeConversationTitle ?? "New chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { chatToolbar }
        .onAppear {
            refreshPasteboardState()
            // Deferred autoload lives here rather than at startup: reaching
            // the chat never waits on model work (master plan §B).
            viewModel.startDeferredModelLoadIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            // The chat stays mounted across backgrounding (compact shell base
            // layer / split detail), so onAppear never re-fires on return.
            // Re-kick the same idempotent loader so a system-evicted model
            // auto-reloads; user-unload intent stays parked via the existing
            // gate inside startDeferredModelLoadIfNeeded.
            if phase == .active {
                viewModel.handleForegroundTransition()
            }
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
        .alert("Delete Conversation?", isPresented: $showDeleteChatConfirmation) {
            Button("Delete", role: .destructive) {
                showDeleteChatConfirmation = false
                onDeleteConversation?()
            }
            Button("Cancel", role: .cancel) {
                showDeleteChatConfirmation = false
            }
        } message: {
            Text("This will permanently delete the conversation and all its messages.")
        }
    }

    /// Attachment cluster (photo picker + paste): always in the composer
    /// row so the affordance never jumps layout as models load or vision
    /// capability changes. Gating stays logic-only — the controls disable
    /// (dimmed to the `tertiaryText` disabled voice, with a spoken reason)
    /// when there is no resident vision-capable model, instead of leaving
    /// the hierarchy. The text field and send keep their own `chatReady`
    /// gating; this cluster adds the vision-capable requirement on top.
    var attachmentButtons: some View {
        HStack(spacing: ZiroTheme.Spacing.medium) {
            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 10, matching: .images) {
                Image(systemName: "photo.on.rectangle")
                    .font(.title3)
                    .frame(width: composerControlSide, height: composerControlSide)
                    .contentShape(Rectangle())
            }
            .disabled(!attachmentsEnabled)
            .accessibilityLabel("Add photos")
            .accessibilityHint(
                attachmentsEnabled
                    ? "Attach up to 10 images to this message"
                    : "Attach images, unavailable until a vision-capable model is loaded"
            )
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
                Image(systemName: "doc.on.clipboard")
                    .font(.title3)
                    // Match sendTint's disabled treatment: the HStack-level
                    // accent tint below keeps plain buttons full-color when
                    // disabled, so the paste glyph must dim itself explicitly.
                    // `tertiaryText` is the quiet-metadata token — the closest
                    // verified "disabled voice" in the design system.
                    .foregroundStyle(pasteTint)
                    .frame(width: composerControlSide, height: composerControlSide)
                    .contentShape(Rectangle())
            }
            .disabled(!canPasteImage || !attachmentsEnabled)
            .accessibilityLabel("Paste image")
            .accessibilityHint(
                attachmentsEnabled
                    ? "Paste an image from the clipboard"
                    : "Paste image, unavailable until a vision-capable model is loaded"
            )
        }
        .foregroundStyle(attachmentsEnabled ? Color.accentColor : ZiroTheme.tertiaryText)
    }

    /// Attachment gating: resident AND vision-capable. The cluster renders
    /// always-visible-but-disabled otherwise (see `inputBar`) so the row
    /// never reflows and VoiceOver keeps a stable landmark.
    private var attachmentsEnabled: Bool { chatReady && viewModel.isVisionModel }

    private var pasteTint: Color {
        (canPasteImage && attachmentsEnabled) ? Color.accentColor : ZiroTheme.tertiaryText
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
                .frame(width: sendControlSide, height: sendControlSide)
                .contentShape(Rectangle())
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
        (canSend && chatReady) || viewModel.isStreaming ? Color.accentColor : ZiroTheme.tertiaryText
    }

    var imagePreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZiroTheme.Spacing.small) {
                ForEach(Array(viewModel.pendingImages.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: image)
                                .resizable().scaledToFill()
                                .frame(width: pendingImageSide, height: pendingImageSide)
                                .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.small, style: .continuous))
                                .accessibilityLabel("Attached image \(index + 1)")
                            Button { viewModel.removeImage(at: index) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3).foregroundStyle(.white)
                                    // Depth without a shadow (shadows only ever
                                    // accompany a hairline): the hairline-strong
                                    // edge keeps the white disc legible over
                                    // bright photo content in both appearances.
                                    .overlay(Circle().stroke(ZiroTheme.hairlineStrong, lineWidth: 1))
                                    .frame(width: imageRemoveControlSide, height: imageRemoveControlSide)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Remove attached image \(index + 1)")
                            // The scaled 44×44 hit target centers the glyph in
                            // a frame whose top-trailing corner is pinned to
                            // the thumbnail's; the inset keeps the glyph itself
                            // anchored on the corner instead of pulled half a
                            // frame inside by the enlarged hit area.
                            .offset(x: imageRemoveCornerInset, y: -imageRemoveCornerInset)
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

    /// One transcript row. Extracted so the LazyVStack body stays within
    /// the compiler's type-check budget with four action closures.
    private func messageRow(_ message: ChatMessagePayload) -> some View {
        let messageID = message.id
        return MessageBubble(
            message: message,
            onBranch: { Task { await viewModel.branchFromMessage(messageID) } },
            onCopy: { [content = message.content] in viewModel.copyMessageText(content) },
            onDelete: { Task { await viewModel.deleteMessage(messageID) } }
        )
        .id(messageID)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.isLoadingConversation {
                        loadingTranscript
                    } else if viewModel.messages.isEmpty && !viewModel.isStreaming {
                        emptyState
                    }

                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                        if let divider = dayDividerText(at: index) {
                            DayDivider(label: divider)
                        }
                        messageRow(message)
                    }

                    if viewModel.canRetryLastResponse && !viewModel.messages.isEmpty {
                        // Quiet text button under the failed turn — not a
                        // full-width capsule in the transcript.
                        Button {
                            Task { await viewModel.retryLastResponse() }
                        } label: {
                            Label("Retry response", systemImage: "arrow.clockwise")
                                .font(ZiroType.footnote.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                        .padding(.horizontal, ZiroTheme.Spacing.large)
                        .padding(.vertical, ZiroTheme.Spacing.small)
                        .accessibilityHint("Generates a new response to your last message")
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
                // Transcript column: the widest allowed content cap (760),
                // centered by the full-width frame — ZiroMeasure.full.
                .frame(maxWidth: ZiroMeasure.full)
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
            .ziroAnimation(ZiroMotion.appear, value: hasScrolledUp)
            .onChange(of: viewModel.messages.count) { _, _ in throttledScrollToBottom(proxy) }
            .onChange(of: viewModel.streamingText) { _, _ in
                guard !hasScrolledUp else { return }
                throttledScrollToBottom(proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                if streaming {
                    throttledScrollToBottom(proxy)
                } else {
                    // Completion cue (r5): the streaming bubble is created
                    // with isStreaming constantly true and torn down the
                    // moment this flips false, so it can never announce its
                    // own finish — post the announcement from this choke
                    // point instead. The recorded end reason branches the
                    // wording: only a natural completion may say "complete";
                    // a stop says "stopped"; an error stays silent because
                    // its banner announces the failure itself.
                    switch viewModel.lastStreamEndReason {
                    case .completed:
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Assistant response complete"
                        )
                    case .stopped:
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Response stopped"
                        )
                    case .failed, nil:
                        break
                    }
                }
            }
        }
    }

    var loadingTranscript: some View {
        VStack(spacing: ZiroTheme.Spacing.large) {
            ProgressView()
            Text("Loading conversation…")
                .font(ZiroType.supporting)
                .foregroundStyle(ZiroTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .accessibilityElement(children: .combine)
    }

    /// Centered hello moment: greeting title, working sample-prompt cards,
    /// and — only when nothing is installed — the catalog CTA (no Browse
    /// Models wall when a model is ready). No subtitle message: the title is
    /// the moment; `ZiroEmptyState` renders its message line only when non-empty.
    var emptyState: some View {
        ZiroEmptyState(
            title: "Hello, Ask Me Anything",
            message: "",
            suggestionItems: viewModel.availableModels.isEmpty ? [] : Self.samplePrompts,
            onSuggestion: { suggestion in
                // Reuses the existing send flow: the prompt lands in the
                // composer (trailing space so typing continues naturally)
                // and the field takes focus. No new ViewModel API.
                let existing = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.inputText = existing.isEmpty
                    ? suggestion + " "
                    : existing + " " + suggestion + " "
                isInputFocused = true
            }
        ) {
            // A.2: with no models installed, the empty state gains a direct
            // CTA into the catalog (same shell route the composer picker's
            // Browse action uses). Chips are withheld in that state — the
            // composer is disabled with nothing to load, so the guided
            // prompts could not actually work.
            if viewModel.availableModels.isEmpty {
                Button {
                    navigateToRoute(.models)
                } label: {
                    Label("Browse Models", systemImage: "arrow.down.circle")
                }
                .buttonStyle(ZiroPrimaryButtonStyle())
                .accessibilityIdentifier("browse-models-button")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ZiroTheme.Spacing.xLarge)
        .padding(.top, ZiroTheme.Spacing.heroTop)
    }

    /// Guided starting points rendered by `ZiroEmptyState`'s capability
    /// cards (reference-style rows with per-card tinted dot + chevron).
    /// Same prompt strings as before — only the presentation changed — so
    /// the send flow (append + focus) is untouched.
    private static let samplePrompts = [
        ZiroSuggestion(
            text: "Explain quantum computing in simple terms",
            dot: ZiroTheme.accentPurpleText
        ),
        ZiroSuggestion(
            text: "How do I make an HTTP request in JavaScript?",
            dot: ZiroTheme.infoText
        ),
        ZiroSuggestion(
            text: "Summarize my notes",
            dot: ZiroTheme.accentIndigoText
        )
    ]

    // MARK: Scrolling

    func jumpToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.bold))
                .padding(ZiroTheme.Spacing.medium)
                .foregroundStyle(ZiroTheme.accentForeground)
                .background(ZiroTheme.accent, in: Circle())
                .ziroShadow(.floating)
        }
        .accessibilityLabel("Jump to latest message")
    }

    var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.pendingImages.isEmpty
    }

    // MARK: Day Dividers

    /// Day-separator label for the message at `index`, or nil when the
    /// message continues the previous message's day. Messages without a
    /// timestamp never open a divider — they join the running day.
    private func dayDividerText(at index: Int) -> String? {
        let messages = viewModel.messages
        guard messages.indices.contains(index),
              let date = messages[index].createdAt else { return nil }
        if index > 0,
           let previous = messages[index - 1].createdAt,
           Calendar.current.isDate(previous, inSameDayAs: date) {
            return nil
        }
        return Self.dayDividerFormatter.string(from: date)
    }

    private static let dayDividerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    func scrollToBottom(_ proxy: ScrollViewProxy) {
        let scroll = {
            if viewModel.isStreaming {
                proxy.scrollTo(viewModel.streamingText.isEmpty ? "thinking" : "streaming", anchor: .bottom)
            } else {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
        }
        if reduceMotion { scroll() } else { withAnimation(ZiroMotion.stream, scroll) }
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
        // The toolbar carries no model control: the Claude-style composer
        // picker above the message field is the single identity surface
        // (same phases, menu, and VoiceOver labels — no redundant pill).
        // Explicit "More" menu instead of `.secondaryAction` overflow: on
        // iPhone the system collapses secondary actions behind a "..."
        // button that was not presenting anything when tapped. An explicit
        // Menu in `.topBarTrailing` always opens. System prompt lives
        // globally in Settings (Default Instructions) — this menu carries
        // only Share and Delete for the active chat.
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    viewModel.exportTranscript()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.messages.isEmpty)
                if let transcriptURL = viewModel.transcriptExportURL {
                    ShareLink(item: transcriptURL) {
                        Label("Share transcript file", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                Divider()
                if onDeleteConversation != nil {
                    Button(role: .destructive) {
                        showDeleteChatConfirmation = true
                    } label: {
                        Label("Delete chat", systemImage: "trash")
                    }
                    .disabled(viewModel.activeConversationID == nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More actions")
            .accessibilityIdentifier("more-actions-menu")
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

// MARK: - Day Divider

/// Lightweight centered day separator for the transcript: a single
/// `tertiaryText`/`micro` label flanked by dashed hairline rules. Static by
/// construction (Reduce Motion safe); never carded.
private struct DayDivider: View {
    let label: String

    var body: some View {
        HStack(spacing: ZiroTheme.Spacing.small) {
            DashedRule()
            Text(label)
                .font(ZiroType.micro)
                .foregroundStyle(ZiroTheme.tertiaryText)
                .fixedSize()
            DashedRule()
        }
        .padding(.horizontal, ZiroTheme.Spacing.large)
        .padding(.vertical, ZiroTheme.Spacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// 1pt dashed hairline that stretches to fill its container.
private struct DashedRule: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: proxy.size.width, y: 0.5))
            }
            .stroke(ZiroTheme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .frame(height: 1)
        .accessibilityHidden(true)
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
