// ChatView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Main chat interface. Message list with auto-scroll, input bar,
// streaming display, stop button, and model picker.

import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var isInputFocused: Bool
    @State private var hasScrolledUp: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Message list.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Empty state.
                        if viewModel.messages.isEmpty && !viewModel.isStreaming {
                            emptyState
                        }

                        // Persisted messages.
                        ForEach(viewModel.messages, id: \.id) { message in
                            MessageBubble(
                                message: message,
                                onBranch: { Task { await viewModel.branchFromMessage(message.id) } },
                                onCopy: { viewModel.copyMessage(message) }
                            )
                            .id(message.id)
                        }

                        // Streaming message (live, not yet persisted).
                        if viewModel.isStreaming && !viewModel.streamingText.isEmpty {
                            MessageBubble(
                                message: ChatMessagePayload(
                                    role: .assistant,
                                    content: viewModel.streamingText
                                ),
                                isStreaming: true
                            )
                            .id("streaming")
                        }

                        // Thinking indicator — shown after sending, before first token.
                        if viewModel.isStreaming && viewModel.streamingText.isEmpty {
                            ThinkingIndicator()
                                .id("thinking")
                        }

                        // Bottom anchor for scroll position detection.
                        Color.clear
                            .frame(height: 1)
                            .id("bottomAnchor")
                    }
                    .padding(.vertical, 12)
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
                .onPreferenceChange(ScrollOffsetKey.self) { maxY in
                    // When the bottom of content is above the bottom of visible area,
                    // user has scrolled up.
                    withAnimation(.easeInOut(duration: 0.2)) {
                        hasScrolledUp = maxY < 0
                    }
                }
                .overlay(alignment: .bottom) {
                    // Jump-to-bottom button — visible when scrolled up during streaming.
                    if hasScrolledUp && viewModel.isStreaming {
                        jumpToBottomButton {
                            scrollToBottom(proxy)
                        }
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: viewModel.streamingText) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: viewModel.isStreaming) { _, isStreaming in
                    if isStreaming {
                        scrollToBottom(proxy)
                    } else {
                        withAnimation {
                            hasScrolledUp = false
                        }
                    }
                }
                .onAppear {
                    scrollProxy = proxy
                }
            }

            Divider()

            // Error banner.
            if viewModel.showError, let error = viewModel.errorMessage {
                errorBanner(error)
            }

            // Truncation warning banner.
            if let warning = viewModel.truncationWarning {
                truncationBanner(warning)
            }

            // Input bar with model picker.
            inputBar
        }
        .navigationTitle("ZiroEdge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("ZiroEdge")
                        .font(.headline)
                    if let model = viewModel.selectedModel {
                        Text(model.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Start a conversation")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Type a message below to begin chatting with your local AI.")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Model picker row.
            HStack {
                modelPicker
                Spacer()
                tokenCountBadge
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)

            // Text input + send/stop.
            HStack(alignment: .bottom, spacing: 12) {
                // Text input.
                TextField("Message ZiroEdge...", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .onSubmit {
                        if !viewModel.isStreaming {
                            Task { await viewModel.sendMessage() }
                        }
                    }

                // Send / Stop button.
                Button(action: {
                    Task {
                        if viewModel.isStreaming {
                            await viewModel.cancelStream()
                        } else {
                            await viewModel.sendMessage()
                        }
                    }
                }) {
                    Image(systemName: viewModel.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? Color.accentColor : Color(.systemGray3))
                }
                .disabled(!canSend && !viewModel.isStreaming)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    // MARK: - Model Picker

    private var modelPicker: some View {
        Menu {
            if viewModel.availableModels.isEmpty {
                Button {
                    viewModel.needsModelRedirect = true
                } label: {
                    Label("Download a Model...", systemImage: "arrow.down.circle")
                }
            } else {
                ForEach(viewModel.availableModels) { model in
                    Button {
                        Task { await viewModel.selectModel(model) }
                    } label: {
                        HStack {
                            Text(model.displayName)
                            if viewModel.selectedModel?.id == model.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if viewModel.isSwitchingModel {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "cpu")
                        .font(.caption)
                }
                Text(modelPickerLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(viewModel.selectedModel != nil ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.systemGray6))
            .clipShape(Capsule())
        }
        .disabled(viewModel.isSwitchingModel)
    }

    private var modelPickerLabel: String {
        if viewModel.isSwitchingModel {
            return "Switching..."
        }
        if let model = viewModel.selectedModel {
            return model.displayName
        }
        return "No Model"
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            Button("Dismiss") {
                viewModel.showError = false
            }
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
    }

    // MARK: - Truncation Warning Banner

    private func truncationBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
            Button("Dismiss") {
                viewModel.dismissTruncationWarning()
            }
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Token Count Badge

    private var tokenCountBadge: some View {
        Text("\(viewModel.tokenCount) / \(viewModel.contextWindowSize)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    // MARK: - Jump to Bottom Button

    private func jumpToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if viewModel.isStreaming {
                if !viewModel.streamingText.isEmpty {
                    proxy.scrollTo("streaming", anchor: .bottom)
                } else {
                    proxy.scrollTo("thinking", anchor: .bottom)
                }
            } else if let lastID = viewModel.messages.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}

// MARK: - Thinking Indicator

/// Animated "thinking..." indicator shown while waiting for the first token.
struct ThinkingIndicator: View {
    @State private var dotCount = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Text("Thinking")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(String(repeating: ".", count: dotCount % 4))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .onReceive(timer) { _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    dotCount += 1
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - Scroll Offset Preference Key

/// Preference key to track the scroll content's position relative to the scroll view.
struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Preview

#Preview {
    ChatView(
        viewModel: ChatViewModel(
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
        )
    )
}
