// ChatSurfaceDetails.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Banner/retry rows and composer status hints for ChatView, split out to keep
// that file focused on layout wiring. Verbatim relocation; members access
// internal view state so nothing is duplicated.

import SwiftUI
import UIKit

extension View {
    /// VoiceOver support for transient banners: new banners are otherwise
    /// silent — only model-load transitions announce (ChatModelLoading). Posts
    /// a one-shot announcement when the banner first mounts so screen-reader
    /// users hear it without hunting for it. Announcements are auditory, not
    /// animated, so Reduce Motion does not apply.
    func announcingOnAppear(_ message: String) -> some View {
        modifier(BannerAnnouncementModifier(message: message))
    }
}

private struct BannerAnnouncementModifier: ViewModifier {
    let message: String

    func body(content: Content) -> some View {
        content.onAppear {
            guard UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }
}

// ChatSurfaceDetails.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Supporting pieces of the chat surface split out to keep ChatView.swift
// focused on layout and interaction wiring. Contents are verbatim relocations:
// the header identity pill, banner/retry rows, composer status hints, the
// conversation-instructions editor sheet, the thinking indicator, and the
// scroll-offset preference key.

import SwiftUI

// MARK: - ChatView Chrome (banners + composer status)

extension ChatView {

    // MARK: Banners

    @ViewBuilder
    var banners: some View {
        if viewModel.hasPersistenceRecovery {
            ZiroStatusBanner(
                icon: "externaldrive.badge.exclamationmark",
                title: "Response not saved yet",
                message: "The response is safely retained while you choose what to do.",
                tone: .warning
            ) {
                ViewThatFits(in: .horizontal) {
                    recoveryActions
                    recoveryActionsVertical
                }
            }
            .accessibilityIdentifier("persistenceRecoveryBanner")
            .announcingOnAppear(
                "Response not saved yet. The response is safely retained while you choose what to do."
            )
        }

        if let missingID = viewModel.unavailableConversationModelID {
            ZiroStatusBanner(
                icon: "questionmark.folder.fill",
                title: "Model unavailable",
                message: "This conversation used \(missingID), which was removed. Explicitly choose another installed model to continue.",
                tone: .warning
            ) {
                Button("Choose Model") { navigateToRoute(.models) }
            }
            .accessibilityIdentifier("unavailableConversationModelBanner")
            .announcingOnAppear(
                "Model unavailable. This conversation used \(missingID), which was removed. Choose another installed model to continue."
            )
        }

        if viewModel.showError, let error = viewModel.errorMessage {
            if viewModel.isStartupError {
                startupErrorBanner(message: error)
            } else {
                dismissibleBanner(
                    icon: "exclamationmark.triangle.fill",
                    message: error,
                    tone: .danger,
                    identifier: "errorBanner"
                ) { viewModel.showError = false }
            }
        }
        if let warning = viewModel.truncationWarning {
            dismissibleBanner(icon: "text.badge.minus", message: warning, tone: .warning) {
                viewModel.dismissTruncationWarning()
            }
        }

        if let warning = viewModel.visionWarning {
            dismissibleBanner(icon: "photo.badge.exclamationmark", message: warning, tone: .warning) {
                viewModel.visionWarning = nil
            }
        }
    }

    /// Inline retry surface for model-load failures and evictions — no alert
    /// dump (master plan §B.3); automatic loads recover here without modals.
    @ViewBuilder
    var modelRetryRow: some View {
        switch viewModel.modelLoadPhase {
        case .failed(let message):
            ZiroStatusBanner(
                icon: "exclamationmark.octagon.fill",
                title: "Couldn't load \(viewModel.selectedModel?.displayName ?? "model")",
                message: message,
                tone: .warning
            ) {
                Button("Retry") { viewModel.retryModelLoad() }
                    .accessibilityIdentifier("modelRetryButton")
            }
            .accessibilityIdentifier("modelRetryBanner")
        case .evicted:
            ZiroStatusBanner(
                icon: "memorychip",
                title: "Model unloaded",
                message: "\(viewModel.selectedModel?.displayName ?? "The model") was released to protect memory.",
                tone: .warning
            ) {
                Button("Reload") { viewModel.retryModelLoad() }
                    .accessibilityIdentifier("modelRetryButton")
            }
            .accessibilityIdentifier("modelRetryBanner")
            .announcingOnAppear(
                "Model unloaded. \(viewModel.selectedModel?.displayName ?? "The model") was released to protect memory. Reload available."
            )
        default:
            EmptyView()
        }
    }

    func startupErrorBanner(message: String) -> some View {
        ZiroStatusBanner(
            icon: "exclamationmark.triangle.fill",
            message: message,
            tone: .danger
        ) {
            HStack(spacing: ZiroTheme.Spacing.medium) {
                Button("Retry") { Task { await viewModel.retryStartup() } }
                    .accessibilityIdentifier("retryStartupButton")
                Button("Dismiss") { viewModel.showError = false }
            }
        }
        .accessibilityIdentifier("errorBanner")
        .announcingOnAppear(message)
    }

    func dismissibleBanner(
        icon: String,
        message: String,
        tone: ZiroTone,
        identifier: String? = nil,
        onDismiss: @escaping () -> Void
    ) -> some View {
        ZiroStatusBanner(icon: icon, message: message, tone: tone) {
            Button("Dismiss", action: onDismiss)
        }
        .accessibilityIdentifier(identifier ?? "statusBanner")
        .announcingOnAppear(message)
    }


    // MARK: Composer

    /// True once the selected model is loaded and accepting work.
    var chatReady: Bool { viewModel.modelLoadPhase == .ready }

    /// Composer stack: status/hint row, image previews, text field, actions.
    /// The text field and send stay disabled until the model is resident.
    var inputBar: some View {
        VStack(spacing: ZiroTheme.Spacing.xSmall) {
            statusOrTokenHintRow

            if !viewModel.pendingImages.isEmpty { imagePreviewRow }

            HStack(alignment: .bottom, spacing: ZiroTheme.Spacing.medium) {
                TextField("Message ZiroEdge", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("chatInput")
                    .accessibilityHint("Enter a message for the local model")
                    // Design-system input well: recessed fill + hairline at
                    // rest, accent focus ring while typing (the keyboard
                    // focus indicator). Replaces the hand-rolled
                    // background/overlay that reused Radius.card here.
                    .ziroComposerField(isActive: isInputFocused)
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .disabled(!chatReady || viewModel.isLoadingConversation)
                    .onSubmit {
                        if !viewModel.isStreaming { Task { await viewModel.sendMessage() } }
                    }

                if chatReady && viewModel.isVisionModel { attachmentButtons }
                sendButton
            }
            .padding(.horizontal, ZiroTheme.Spacing.large)
            .padding(.bottom, ZiroTheme.Spacing.medium)
        }
        .padding(.top, ZiroTheme.Spacing.small)
        .background(.bar)
    }

    /// Replaces the former input-bar model capsule: token usage while ready,
    /// otherwise a subtle explanation of why composing is unavailable.
    var statusOrTokenHintRow: some View {
        HStack {
            Spacer(minLength: 0)
            composerStatusBadge
        }
        .padding(.horizontal, ZiroTheme.Spacing.large)
    }

    /// Composer status row. The header pill is the single authoritative
    /// loading indicator (spinner + "Name…" title), and `.failed`/`.evicted`
    /// already render the modelRetryRow banner directly above this row —
    /// repeating those states here showed the same message on screen twice.
    /// This row only speaks when nothing else carries the state: token usage
    /// while ready, the download nudge, and the user-unload caption (a
    /// user-initiated unload parks the chat on `.idle` with a dimmed,
    /// disabled composer and no banner — same visible-hint pattern as the
    /// disabled-continue hints).
    @ViewBuilder
    var composerStatusBadge: some View {
        if chatReady {
            tokenCountBadge
        } else if viewModel.modelLoadPhase == .needsDownload {
            // Allow up to two lines: at accessibility text sizes a hard single
            // line would ellipsize the instruction down to a stub that no
            // longer states the action the user must take.
            Text("Download a model to start chatting")
                .font(ZiroType.micro)
                .foregroundStyle(ZiroTheme.secondaryText)
                .lineLimit(1...2)
        } else if viewModel.modelLoadPhase == .idle,
                  viewModel.lifecycleManager.isUserUnloaded {
            Text("\(viewModel.selectedModel?.displayName ?? "The model") is unloaded. Reload from the model menu above.")
                .font(ZiroType.micro)
                .foregroundStyle(ZiroTheme.secondaryText)
                .lineLimit(1...2)
        }
    }

    var tokenCountBadge: some View {
        Text("~\(viewModel.tokenCount) / \(viewModel.contextWindowSize) tokens")
            // Technical voice: the token counter is engineering data, not UI copy.
            .font(ZiroType.technical(.caption2))
            .foregroundStyle(ZiroTheme.secondaryText)
            .accessibilityLabel(
                "Approximately \(viewModel.tokenCount) of \(viewModel.contextWindowSize) context tokens used"
            )
    }
}
