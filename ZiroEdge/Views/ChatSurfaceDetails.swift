// ChatSurfaceDetails.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Banner/retry rows and composer status hints for ChatView, split out to keep
// that file focused on layout wiring. Members access internal view state so
// nothing is duplicated.

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
// focused on layout and interaction wiring: banner/retry rows and composer
// status hints.

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

    /// Composer stack: the single compact model-picker pill, image
    /// previews, then the one rounded input well — the always-visible
    /// attachment cluster, the message field, and send riding one
    /// well-elevation fill with a hairline rest state and an accent focus
    /// ring. The well uses `Radius.control` (not `Radius.card`): it is a
    /// text field, and the radius scale assigns text fields/controls to
    /// `control` (design system §6.2, matching `ziroComposerField`). The
    /// text field and send stay disabled until the model is resident; the
    /// attachment cluster disables itself (with a spoken reason) until a
    /// vision-capable model is resident, but never leaves the row — see
    /// `attachmentButtons`. No top hairline, no stacked pills: the picker
    /// row above is the sole pill.
    var inputBar: some View {
        VStack(spacing: ZiroTheme.Spacing.xSmall) {
            statusOrTokenHintRow

            if !viewModel.pendingImages.isEmpty { imagePreviewRow }

            HStack(alignment: .bottom, spacing: ZiroTheme.Spacing.small) {
                attachmentButtons
                TextField("Message ZiroEdge", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("chatInput")
                    .accessibilityHint("Enter a message for the local model")
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .disabled(!chatReady || viewModel.isLoadingConversation)
                    .onSubmit {
                        if !viewModel.isStreaming { Task { await viewModel.sendMessage() } }
                    }
                sendButton
            }
            .padding(.horizontal, ZiroTheme.Spacing.medium)
            .padding(.vertical, ZiroTheme.Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: ZiroTheme.Radius.control, style: .continuous)
                    .fill(ZiroTheme.wellBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ZiroTheme.Radius.control, style: .continuous)
                    .stroke(isInputFocused ? Color.accentColor : ZiroTheme.hairline, lineWidth: isInputFocused ? 1.5 : 1)
            )
            .ziroAnimation(ZiroMotion.press, value: isInputFocused)
            .padding(.horizontal, ZiroTheme.Spacing.large)
            .padding(.bottom, ZiroTheme.Spacing.medium)
        }
        .padding(.top, ZiroTheme.Spacing.small)
        .background(ZiroTheme.pageBackground)
    }

    /// Composer top row: the single compact model-picker pill — the sole
    /// identity surface (same phases, menu, and VoiceOver labels the
    /// toolbar pill used to carry). The token counter and the
    /// download/unload captions are gone: the counter was permanent
    /// engineering text, and both captions duplicated states the picker
    /// title already carries ("No model yet" / "… unloaded").
    var statusOrTokenHintRow: some View {
        HStack {
            ComposerModelPicker(
                phase: viewModel.modelLoadPhase,
                modelName: viewModel.selectedModel?.displayName,
                isUserUnloaded: viewModel.lifecycleManager.isUserUnloaded,
                availableModels: viewModel.availableModels,
                onSelectModel: { model in Task { await viewModel.selectModel(model) } },
                onBrowseModels: { navigateToRoute(.models) },
                onRetryLoad: { viewModel.retryModelLoad() }
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ZiroTheme.Spacing.large)
    }
}
