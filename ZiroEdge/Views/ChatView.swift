// ChatView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Main chat interface. Message list with auto-scroll, input bar,
// streaming display, and stop button.

import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var isInputFocused: Bool

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
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: viewModel.streamingText) { _, _ in
                    scrollToBottom(proxy)
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

            // Input bar.
            inputBar
        }
        .navigationTitle("ZiroEdge")
        .navigationBarTitleDisplayMode(.inline)
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
        .background(.bar)
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

    // MARK: - Helpers

    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if viewModel.isStreaming {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let lastID = viewModel.messages.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
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
            )
        )
    )
}
