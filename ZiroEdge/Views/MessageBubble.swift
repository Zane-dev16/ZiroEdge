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
                // Image attachment (if present).
                if let imageData = message.imageData,
                   let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
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
                        Text(markdown: displayContent)
                            .font(.body)
                            .textSelection(.enabled)

                        // Streaming cursor.
                        if isStreaming {
                            StreamingCursor()
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
