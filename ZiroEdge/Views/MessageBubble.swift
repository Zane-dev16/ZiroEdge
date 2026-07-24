// MessageBubble.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Individual message bubble. User messages right-aligned blue,
// assistant messages left-aligned with markdown rendering.

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessagePayload
    let isStreaming: Bool
    let onBranch: (() -> Void)?
    let onCopy: (() -> Void)?

    init(
        message: ChatMessagePayload,
        isStreaming: Bool = false,
        onBranch: (() -> Void)? = nil,
        onCopy: (() -> Void)? = nil
    ) {
        self.message = message
        self.isStreaming = isStreaming
        self.onBranch = onBranch
        self.onCopy = onCopy
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .user {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // Ordered image attachments (including decoded legacy single images).
                if !message.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, imageData in
                                if let uiImage = UIImage(data: imageData) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: 200, maxHeight: 200)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }

                // Message content.
                if message.role == .user {
                    Text(message.content)
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        if isStreaming {
                            // Inline cursor appended to rendered text so it
                            // appears at the end of the last line, not below it.
                            let rendered: AttributedString = {
                                var attributed = MarkdownRenderer.render(displayContent)
                                var cursor = AttributedString("|")
                                cursor.font = .body
                                cursor.foregroundColor = Color.accentColor
                                attributed.append(cursor)
                                return attributed
                            }()
                            Text(rendered)
                                .font(.body)
                                .textSelection(.enabled)
                        } else {
                            Text(markdown: displayContent)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                }

                // Action buttons (assistant messages only).
                if message.role == .assistant && !isStreaming {
                    HStack(spacing: 16) {
                        Button(action: { onCopy?() }) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button(action: { onBranch?() }) {
                            Image(systemName: "arrow.branch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            if message.role == .assistant {
                Spacer(minLength: 60)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// The content to display — streaming text or final content.
    private var displayContent: String {
        if isStreaming {
            return message.content
        }
        return message.content
    }
}

// MARK: - Streaming Cursor

/// Pulsing cursor shown at the end of streaming text.
struct StreamingCursor: View {
    @State private var opacity: Double = 1.0

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: 2, height: 16)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    opacity = 0.2
                }
            }
    }
}

// MARK: - Preview

#Preview("User Message") {
    MessageBubble(
        message: ChatMessagePayload(role: .user, content: "What is SwiftUI?"),
        onBranch: nil,
        onCopy: nil
    )
    .padding()
}

#Preview("Assistant Message") {
    MessageBubble(
        message: ChatMessagePayload(
            role: .assistant,
            content: "SwiftUI is Apple's **declarative** framework for building user interfaces across all Apple platforms."
        ),
        onBranch: {},
        onCopy: {}
    )
    .padding()
}
