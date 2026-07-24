// ChatView.swift
// ZiroEdge — Privacy-first local AI assistant

import PhotosUI
import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool
    @State private var hasScrolledUp = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var canPasteImage = UIPasteboard.general.hasImages
    @State private var showSystemPromptEditor = false
    @State private var systemPromptDraft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            banners
            inputBar
        }
        .background(ZiroTheme.pageBackground)
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { chatToolbar }
        .onAppear { refreshPasteboardState() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshPasteboardState()
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

    private var messageList: some View {
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
                if reduceMotion {
                    hasScrolledUp = maxY < 0
                } else {
                    withAnimation(.snappy(duration: 0.2)) { hasScrolledUp = maxY < 0 }
                }
            }
            .overlay(alignment: .bottom) {
                if hasScrolledUp {
                    jumpToBottomButton { scrollToBottom(proxy) }
                        .padding(.bottom, ZiroTheme.Spacing.small)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: hasScrolledUp)
            .onChange(of: viewModel.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.streamingText) { _, _ in
                guard !hasScrolledUp else { return }
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                if streaming { scrollToBottom(proxy) }
            }
        }
    }

    private var loadingTranscript: some View {
        VStack(spacing: ZiroTheme.Spacing.large) {
            ProgressView()
            Text("Loading conversation…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        ZiroHero(
            symbol: "bubble.left.and.bubble.right",
            title: "Start a conversation",
            message: "Ask anything below. Your messages and the model's response stay on this device.",
            tint: .accentColor
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ZiroTheme.Spacing.xxLarge)
        .padding(.top, 96)
    }

    @ViewBuilder
    private var banners: some View {
        if viewModel.hasPersistenceRecovery {
            ZiroStatusBanner(
                icon: "externaldrive.badge.exclamationmark",
                title: "Response not saved yet",
                message: "The response is safely retained while you choose what to do.",
                tint: .orange
            ) {
                ViewThatFits(in: .horizontal) {
                    recoveryActions
                    recoveryActionsVertical
                }
            }
            .accessibilityIdentifier("persistenceRecoveryBanner")
        }

        if viewModel.showError, let error = viewModel.errorMessage {
            dismissibleBanner(
                icon: "exclamationmark.triangle.fill",
                message: error,
                tint: .red,
                identifier: "errorBanner"
            ) { viewModel.showError = false }
        }

        if let warning = viewModel.truncationWarning {
            dismissibleBanner(icon: "text.badge.minus", message: warning, tint: .orange) {
                viewModel.dismissTruncationWarning()
            }
        }

        if let warning = viewModel.visionWarning {
            dismissibleBanner(icon: "photo.badge.exclamationmark", message: warning, tint: .orange) {
                viewModel.visionWarning = nil
            }
        }
    }

    private func dismissibleBanner(
        icon: String,
        message: String,
        tint: Color,
        identifier: String? = nil,
        onDismiss: @escaping () -> Void
    ) -> some View {
        ZiroStatusBanner(icon: icon, message: message, tint: tint) {
            Button("Dismiss", action: onDismiss)
        }
        .accessibilityIdentifier(identifier ?? "statusBanner")
    }

    private var inputBar: some View {
        VStack(spacing: ZiroTheme.Spacing.xSmall) {
            HStack {
                modelPicker
                Spacer()
                tokenCountBadge
            }
            .padding(.horizontal, ZiroTheme.Spacing.large)

            if !viewModel.pendingImages.isEmpty { imagePreviewRow }

            HStack(alignment: .bottom, spacing: ZiroTheme.Spacing.medium) {
                TextField("Message ZiroEdge", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("chatInput")
                    .accessibilityHint("Enter a message for the local model")
                    .padding(.horizontal, ZiroTheme.Spacing.large)
                    .padding(.vertical, 11)
                    .background(ZiroTheme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.card))
                    .overlay {
                        RoundedRectangle(cornerRadius: ZiroTheme.Radius.card)
                            .stroke(ZiroTheme.subtleBorder)
                    }
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .disabled(viewModel.isLoadingConversation || viewModel.isSwitchingModel)
                    .onSubmit {
                        if !viewModel.isStreaming { Task { await viewModel.sendMessage() } }
                    }

                if viewModel.isVisionModel { attachmentButtons }
                sendButton
            }
            .padding(.horizontal, ZiroTheme.Spacing.large)
            .padding(.bottom, ZiroTheme.Spacing.medium)
        }
        .padding(.top, ZiroTheme.Spacing.small)
        .background(.bar)
    }

    private var attachmentButtons: some View {
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
                        if let data = try? await item.loadTransferable(type: Data.self) { viewModel.addImage(data) }
                    }
                    selectedPhotos.removeAll()
                }
            }

            Button {
                if viewModel.pasteImage() { refreshPasteboardState() }
            } label: {
                Image(systemName: "doc.on.clipboard").font(.title3).frame(width: 32, height: 40)
            }
            .disabled(!canPasteImage)
            .accessibilityLabel("Paste image")
        }
        .foregroundStyle(Color.accentColor)
    }

    private var sendButton: some View {
        Button {
            Task {
                if viewModel.isStreaming { await viewModel.cancelStream() }
                else { await viewModel.sendMessage() }
            }
        } label: {
            Image(systemName: viewModel.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(.title)
                .foregroundStyle(canSend || viewModel.isStreaming ? Color.accentColor : Color.secondary.opacity(0.45))
                .frame(width: 38, height: 42)
        }
        .disabled((!canSend || viewModel.isLoadingConversation || viewModel.isSwitchingModel) && !viewModel.isStreaming)
        .accessibilityLabel(viewModel.isStreaming ? "Stop generating" : "Send message")
        .accessibilityHint(viewModel.isStreaming ? "Stops the current response" : "Sends your message to the local model")
    }

    private var imagePreviewRow: some View {
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

    private var modelPicker: some View {
        Menu {
            if viewModel.availableModels.isEmpty {
                Button { viewModel.needsModelRedirect = true } label: {
                    Label("Download a Model…", systemImage: "arrow.down.circle")
                }
            } else {
                ForEach(viewModel.availableModels) { model in
                    Button { Task { await viewModel.selectModel(model) } } label: {
                        Label(model.displayName, systemImage: viewModel.selectedModel?.id == model.id ? "checkmark" : "cpu")
                    }
                }
            }
        } label: {
            HStack(spacing: ZiroTheme.Spacing.xSmall) {
                if viewModel.isSwitchingModel { ProgressView().controlSize(.small) }
                else { Image(systemName: "cpu").font(.caption) }
                Text(modelPickerLabel).font(.caption.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .foregroundStyle(viewModel.selectedModel != nil ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ZiroTheme.inputBackground)
            .clipShape(Capsule())
        }
        .disabled(viewModel.isSwitchingModel)
        .accessibilityLabel("Chat model, \(modelPickerLabel)")
        .accessibilityHint("Choose the local model for this conversation")
    }

    private var modelPickerLabel: String {
        if viewModel.isSwitchingModel { return "Switching…" }
        if let model = viewModel.selectedModel { return model.displayName }
        return viewModel.availableModels.isEmpty ? "Download Model" : "Select Model"
    }

    private var tokenCountBadge: some View {
        Text("~\(viewModel.tokenCount) / \(viewModel.contextWindowSize) tokens")
            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            .accessibilityLabel("Approximately \(viewModel.tokenCount) of \(viewModel.contextWindowSize) context tokens used")
    }

    private func jumpToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.bold))
                .padding(12)
                .foregroundStyle(ZiroTheme.accentForeground)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        }
        .accessibilityLabel("Jump to latest message")
    }

    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.pendingImages.isEmpty
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
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

    private func refreshPasteboardState() { canPasteImage = UIPasteboard.general.hasImages }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text("ZiroEdge").font(.headline)
                Text(viewModel.selectedModel?.displayName ?? "Private on-device chat")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
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

    private var recoveryActions: some View {
        HStack(spacing: ZiroTheme.Spacing.medium) {
            Button("Retry Save") { Task { await viewModel.retryPersistenceRecovery() } }
            Button("Export") { Task { await viewModel.exportPersistenceRecovery() } }
            if let url = viewModel.recoveryExportURL { ShareLink("Share", item: url) }
            Button("Discard", role: .destructive) { Task { await viewModel.discardPersistenceRecovery() } }
        }
    }

    private var recoveryActionsVertical: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
            Button("Retry Save") { Task { await viewModel.retryPersistenceRecovery() } }
            Button("Export") { Task { await viewModel.exportPersistenceRecovery() } }
            if let url = viewModel.recoveryExportURL { ShareLink("Share", item: url) }
            Button("Discard", role: .destructive) { Task { await viewModel.discardPersistenceRecovery() } }
        }
    }
}

private struct ConversationSystemPromptEditor: View {
    @Binding var prompt: String
    let defaultPrompt: String
    let onSave: () async -> Void
    let onUseDefault: () async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Conversation instructions")
                } header: {
                    Text("Instructions for this conversation")
                } footer: {
                    Text("These instructions are sent only to the on-device model.")
                }

                if !defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Default Instructions") {
                        Text(defaultPrompt)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Use Default") { Task { await onUseDefault() } }
                    }
                }
            }
            .navigationTitle("Conversation Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await onSave() } }
                }
            }
        }
    }
}

struct ThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                thinkingRow(text: "Thinking…")
            } else {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let dots = (Int(context.date.timeIntervalSinceReferenceDate * 2) % 3) + 1
                    thinkingRow(text: "Thinking" + String(repeating: ".", count: dots))
                }
            }
        }
        .accessibilityLabel("Model is thinking")
    }

    private func thinkingRow(text: String) -> some View {
        HStack {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
                .padding(.horizontal, ZiroTheme.Spacing.large)
                .padding(.vertical, 10)
                .background(ZiroTheme.elevatedBackground)
                .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.bubble))
            Spacer()
        }
        .padding(.horizontal, ZiroTheme.Spacing.large)
        .padding(.vertical, ZiroTheme.Spacing.xSmall)
    }
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

#Preview {
    ChatView(viewModel: ChatViewModel(
        persistence: PersistenceController(inMemory: true),
        inferenceService: InferenceService(),
        sessionActor: ChatSessionActor(inferenceService: InferenceService(), persistence: PersistenceController(inMemory: true)),
        lifecycleManager: ModelLifecycleManager(inferenceService: InferenceService(), memoryBudgeter: MemoryBudgeter()),
        downloadStatusProvider: DownloadManager()
    ))
}
