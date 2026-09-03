// MessageBubble.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Individual message bubble. User messages right-aligned on the accent fill,
// assistant messages left-aligned on the raised surface with markdown
// rendering — both via the design system's `ziroMessageBubble` treatment.

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessagePayload
    let isStreaming: Bool
    let onBranch: (() -> Void)?
    let onCopy: (() -> Void)?

    // Copy/branch hit targets: scale with Dynamic Type (like ChatView's
    // composerControlSide) so the caption glyphs never overflow their frames
    // at accessibility sizes, while meeting the 44×44 minimum at the default
    // size.
    @ScaledMetric(relativeTo: .body) private var actionControlSide: CGFloat = 44

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
        HStack(alignment: .top, spacing: ZiroTheme.Spacing.medium) {
            if message.role == .user {
                Spacer(minLength: ZiroTheme.Spacing.xLarge)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: ZiroTheme.Spacing.xSmall) {
                // Ordered image attachments (including decoded legacy single images).
                if !message.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ZiroTheme.Spacing.small) {
                            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, imageData in
                                if let uiImage = UIImage(data: imageData) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: 240, maxHeight: 240)
                                        .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.small, style: .continuous))
                                        .accessibilityLabel("Message attachment")
                                }
                            }
                        }
                    }
                    .padding(.bottom, ZiroTheme.Spacing.xSmall)
                }

                // Message content.
                if message.role == .user {
                    Text(message.content)
                        .font(ZiroType.body)
                        .foregroundStyle(ZiroTheme.accentForeground)
                        .padding(.horizontal, ZiroTheme.Spacing.large)
                        .padding(.vertical, ZiroTheme.Spacing.medium)
                        .ziroMessageBubble(.user)
                        .accessibilityLabel("You said: \(message.content)")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        if isStreaming {
                            // The growing transcript must never re-bind this
                            // element's label: VoiceOver would re-announce the
                            // full text on every token chunk (r4 HIGH). The
                            // streaming element keeps one stable label; the
                            // finished reply becomes readable when this branch
                            // swaps to the final Text below. Completion is
                            // announced by ChatView when isStreaming flips —
                            // this element is torn down at completion, so it
                            // cannot announce its own finish.
                            StreamingText(content: displayContent)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Assistant is responding")
                        } else {
                            Text(markdown: displayContent)
                                .font(ZiroType.body)
                                .foregroundStyle(ZiroTheme.primaryText)
                                .textSelection(.enabled)
                                .accessibilityLabel("Assistant said: \(displayContent)")
                        }
                    }
                    .padding(.horizontal, ZiroTheme.Spacing.large)
                    .padding(.vertical, ZiroTheme.Spacing.medium)
                    .ziroMessageBubble(.assistant)
                }

                // Action buttons (assistant messages only). The glyphs stay
                // caption-size, but each button reserves a scaled 44pt-square
                // frame with a full-area contentShape — they are the only path
                // to copy or branch a message, so the hit target must meet the
                // 44pt minimum and grow with Dynamic Type.
                if message.role == .assistant && !isStreaming {
                    HStack(spacing: 0) {
                        Button(action: { onCopy?() }) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(ZiroTheme.secondaryText)
                                .frame(width: actionControlSide, height: actionControlSide)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Copy message")

                        Button(action: { onBranch?() }) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.caption)
                                .foregroundStyle(ZiroTheme.secondaryText)
                                .frame(width: actionControlSide, height: actionControlSide)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Branch from this message")
                    }
                    .padding(.leading, ZiroTheme.Spacing.xSmall)
                }
            }

            if message.role == .assistant {
                Spacer(minLength: ZiroTheme.Spacing.xLarge)
            }
        }
        // Bubble rows cap at the reading measure; the transcript column above
        // caps wider (ZiroMeasure.full) — the nested 760/680 rhythm from the
        // design system's measure scale.
        .frame(maxWidth: ZiroMeasure.wide)
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
/// BATCH-04: debounced off-main markdown rendering to avoid O(n²) per-token re-parse on main thread.
private struct StreamingText: View {
    let content: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rendered: AttributedString = AttributedString()

    var body: some View {
        Group {
            if reduceMotion {
                Text(renderedWithCursor(visible: true))
            } else {
                // Blink cadence is the design system's cursor period (0.6s);
                // the TimelineView pattern itself is the Reduce-Motion exit.
                TimelineView(.periodic(from: .now, by: ZiroMotion.cursorPeriod)) { context in
                    let tick = Int(context.date.timeIntervalSinceReferenceDate / ZiroMotion.cursorPeriod)
                    Text(renderedWithCursor(visible: tick.isMultiple(of: 2)))
                }
            }
        }
        .font(ZiroType.body)
        .textSelection(.enabled)
        .task(id: content) {
            // Debounce 80ms then render off-main
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            let snapshot = content
            let result = await Task.detached(priority: .userInitiated) {
                MarkdownRenderer.render(snapshot)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if snapshot == content {
                    rendered = result
                }
            }
        }
        .onAppear {
            if content.isEmpty == false {
                // Kick initial render without debounce for first paint
                rendered = MarkdownRenderer.render(content)
            }
        }
        .onChange(of: content) { _, newValue in
            // Immediate fast-path for tiny first chunk to avoid empty flash
            if rendered == AttributedString() && newValue.isEmpty == false {
                rendered = MarkdownRenderer.render(newValue)
            }
        }
    }

    private func renderedWithCursor(visible: Bool) -> AttributedString {
        var attributed = rendered
        var cursor = AttributedString("|")
        cursor.font = ZiroType.body
        // The amber caret: the ember accent marks what is alive on screen.
        cursor.foregroundColor = visible ? ZiroTheme.accent : Color.clear
        attributed.append(cursor)
        return attributed
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
            content: "SwiftUI is Apple's **declarative** framework "
                + "for building user interfaces across all Apple platforms."
        ),
        onBranch: {},
        onCopy: {}
    )
    .padding()
}
