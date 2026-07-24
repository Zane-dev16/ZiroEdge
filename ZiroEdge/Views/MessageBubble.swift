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
                Spacer(minLength: ZiroTheme.Spacing.xLarge)
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
                                        .frame(maxWidth: 240, maxHeight: 240)
                                        .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.control))
                                        .accessibilityLabel("Message attachment")
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
                        .foregroundStyle(ZiroTheme.accentForeground)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.bubble))
                        .accessibilityLabel("You said: \(message.content)")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        if isStreaming {
                            StreamingText(content: displayContent)
                                .accessibilityLabel("Assistant response: \(displayContent)")
                        } else {
                            Text(markdown: displayContent)
                                .font(.body)
                                .textSelection(.enabled)
                                .accessibilityLabel("Assistant said: \(displayContent)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(ZiroTheme.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.bubble))
                }

                // Action buttons (assistant messages only).
                if message.role == .assistant && !isStreaming {
                    HStack(spacing: 16) {
                        Button(action: { onCopy?() }) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Copy message")

                        Button(action: { onBranch?() }) {
                            Image(systemName: "arrow.branch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Branch from this message")
                    }
                    .padding(.horizontal, 4)
                }
            }

            if message.role == .assistant {
                Spacer(minLength: ZiroTheme.Spacing.xLarge)
            }
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, ZiroTheme.Spacing.large)
        .padding(.vertical, ZiroTheme.Spacing.xSmall)
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

/// Renders the cursor in the same attributed string so it follows the final character.
private struct StreamingText: View {
    let content: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                renderedText(cursorVisible: true)
            } else {
                TimelineView(.periodic(from: .now, by: 0.6)) { context in
                    renderedText(
                        cursorVisible: Int(context.date.timeIntervalSinceReferenceDate / 0.6).isMultiple(of: 2)
                    )
                }
            }
        }
        .font(.body)
        .textSelection(.enabled)
    }

    private func renderedText(cursorVisible: Bool) -> Text {
        var attributed = MarkdownRenderer.render(content)
        var cursor = AttributedString("|")
        cursor.font = .body
        cursor.foregroundColor = cursorVisible ? Color.accentColor : Color.clear
        attributed.append(cursor)
        return Text(attributed)
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
