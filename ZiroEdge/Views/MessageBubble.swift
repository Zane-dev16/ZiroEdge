// MessageBubble.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Individual message row. Both roles are bubbles: the user's right-aligned
// in deep navy, the assistant's left-aligned in dark charcoal, each with a
// hairline edge and a small monospaced timestamp just outside the bubble.

import SwiftUI
import UIKit

struct MessageBubble: View {
    let message: ChatMessagePayload
    let isStreaming: Bool
    /// Action-row gate. The transcript shows copy/branch/retry on the live
    /// (latest assistant) turn only — repeating the row under every past
    /// reply buried the conversation in chrome.
    let showsActions: Bool
    let onBranch: (() -> Void)?
    let onCopy: (() -> Void)?
    let onRetry: (() -> Void)?

    // Copy/branch hit targets: scale with Dynamic Type (like ChatView's
    // composerControlSide) so the caption glyphs never overflow their frames
    // at accessibility sizes, while meeting the 44×44 minimum at the default
    // size.
    @ScaledMetric(relativeTo: .body) private var actionControlSide: CGFloat = 44
    @State private var showCopiedAck = false

    init(
        message: ChatMessagePayload,
        isStreaming: Bool = false,
        showsActions: Bool = true,
        onBranch: (() -> Void)? = nil,
        onCopy: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil
    ) {
        self.message = message
        self.isStreaming = isStreaming
        self.showsActions = showsActions
        self.onBranch = onBranch
        self.onCopy = onCopy
        self.onRetry = onRetry
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
                            // PERF: indices directly — no per-body Array(enumerated()) copy.
                            ForEach(message.attachments.indices, id: \.self) { attachmentIndex in
                                let imageData = message.attachments[attachmentIndex]
                                if let uiImage = UIImage(data: imageData) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: 240, maxHeight: 240)
                                        .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.small, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: ZiroTheme.Radius.small, style: .continuous)
                                                .stroke(
                                                    Color(uiColor: UIColor { traits in
                                                        traits.userInterfaceStyle == .dark
                                                            ? UIColor.white.withAlphaComponent(0.1)
                                                            : UIColor.black.withAlphaComponent(0.1)
                                                    }),
                                                    lineWidth: 1
                                                )
                                        )
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
                        // Satoshi Medium: the user's own words, one step of
                        // optical weight above the model's reply.
                        .font(ZiroType.bodyMedium)
                        .foregroundStyle(ZiroTheme.accentForeground)
                        .padding(.horizontal, ZiroTheme.Spacing.large)
                        .padding(.vertical, ZiroTheme.Spacing.medium)
                        .ziroMessageBubble(.user)
                        .accessibilityLabel("You said: \(message.content)")
                } else {
                    // The assistant is a bubble too — dark charcoal with the
                    // same hairline as the user's, so the transcript reads as
                    // a two-voice exchange rather than text on a page.
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

                // Timestamp: outside the bubble, under it, aligned to the
                // bubble's own edge (trailing for the user, leading for the
                // assistant) and set in the technical voice — small, quiet,
                // monospaced. Absent for rows with no stored date. Inset 12pt
                // off the bubble edge so it reads as a caption *under* the
                // bubble rather than a band aligned with its corner.
                if let sentAt = message.createdAt {
                    Text(Self.timestampFormatter.string(from: sentAt))
                        .font(ZiroType.technical(.caption2))
                        .foregroundStyle(ZiroTheme.tertiaryText)
                        .padding(message.role == .user ? .trailing : .leading, ZiroTheme.Spacing.medium)
                        .accessibilityLabel(
                            message.role == .user
                                ? "Sent at \(Self.timestampFormatter.string(from: sentAt))"
                                : "Replied at \(Self.timestampFormatter.string(from: sentAt))"
                        )
                }

                // Action buttons. Only assistant rows offer actions
                // (copy/branch/retry), and only the gated live row renders
                // them; user rows offer none. Each button keeps the scaled
                // 44pt-square hit target.
                if message.role == .assistant && !isStreaming && showsActions {
                    HStack(spacing: 0) {
                        Button(action: {
                            onCopy?()
                            showCopiedAck = true
                            UIAccessibility.post(notification: .announcement, argument: "Copied")
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                showCopiedAck = false
                            }
                        }) {
                            Image(systemName: showCopiedAck ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(ZiroTheme.secondaryText)
                                .frame(width: actionControlSide, height: actionControlSide)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(showCopiedAck ? "Copied" : "Copy message")
                        .accessibilityIdentifier("copy-message-button")

                        Button(action: { onBranch?() }) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.caption)
                                .foregroundStyle(ZiroTheme.secondaryText)
                                // Directional — mirror in RTL.
                                .flipsForRightToLeft(true)
                                .frame(width: actionControlSide, height: actionControlSide)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Branch from this message")
                        .accessibilityIdentifier("branch-message-button")

                        if onRetry != nil {
                            Button(action: { onRetry?() }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                    .foregroundStyle(ZiroTheme.secondaryText)
                                    .frame(width: actionControlSide, height: actionControlSide)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Retry response")
                            .accessibilityIdentifier("retry-message-button")
                        }

                        if showCopiedAck {
                            Text("Copied")
                                .font(ZiroType.footnote)
                                .foregroundStyle(ZiroTheme.secondaryText)
                                .accessibilityLabel("Copied")
                                .accessibilityIdentifier("copied-ack")
                        }
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

    /// Per-message clock time (`18:28`). One shared formatter — the row is
    /// rendered for every message in the transcript, so a per-body
    /// `DateFormatter` would be a needless allocation on the streaming path.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
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
        // The accent caret: the accent marks what is alive on screen.
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
