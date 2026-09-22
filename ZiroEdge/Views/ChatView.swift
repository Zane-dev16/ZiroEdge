// ChatView.swift
// ZiroEdge — Privacy-first local AI assistant

import PhotosUI
import SwiftUI
import UIKit

/// The chat surface. Identity/loading feedback lives in the composer model
/// picker (`ComposerModelPicker`); the composer enables only while the model is resident;
/// load failures surface as inline retry rows, not alerts (master plan §B).
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    /// Compact shells render the sidebar toggle inside the chat toolbar.
    var showsSidebarToggle: Bool = false
    /// Opens a shell route (e.g. the models catalog) from header CTA states.
    var onNavigateToRoute: ((ShellRoute) -> Void)? = nil
    /// Presents the sidebar drawer; nil hides the toggle even when requested.
    var onOpenSidebar: (() -> Void)? = nil
    /// Deletes the active conversation (shell-owned: cancels any in-flight
    /// stream first). Nil hides the ... menu's Delete row.
    var onDeleteConversation: (() -> Void)? = nil

    @FocusState var isInputFocused: Bool
    @State private var hasScrolledUp = false
    // Composer discs draw at vision size (~32pt) and scale with Dynamic
    // Type so glyphs never overflow at accessibility sizes. The 44x44
    // hit target lives on contentShape (expanded rect), not the frame,
    // so the drawn row stays ~33pt. Composer cluster shares one size
    // (.title3) — send included, state via tint only.
    @ScaledMetric(relativeTo: .title3) private var composerControlSide: CGFloat = 32
    @ScaledMetric(relativeTo: .title3) private var sendControlSide: CGFloat = 32
    @ScaledMetric(relativeTo: .title3) private var imageRemoveControlSide: CGFloat = 44
    // Pending-attachment thumbnail: decorative image size that grows with
    // Dynamic Type (design-system §6.2 — Radius.small corners, no shadow).
    @ScaledMetric(relativeTo: .body) private var pendingImageSide: CGFloat = 68
    // Empty-state brand mark (spec §8.1: 80pt): decorative size that grows
    // with Dynamic Type instead of clamping at accessibility sizes.
    @ScaledMetric(relativeTo: .largeTitle) private var emptyStateMarkSize: CGFloat = 80
    /// Pull-back distance that keeps the remove glyph anchored on the
    /// thumbnail corner as its hit-target frame scales with Dynamic Type:
    /// half the frame minus the 8pt glyph margin (14pt at the 44pt default).
    private var imageRemoveCornerInset: CGFloat { imageRemoveControlSide / 2 - 8 }
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showDeleteChatConfirmation = false
    @State private var pendingBranchMessageID: UUID?
    @State private var pendingRetryMessageID: UUID?
    @State private var toastMessage: String?
    // BATCH-04: throttle scrollToBottom to avoid stacked withAnimation per token
    @State private var lastScrollTime: Date = .distantPast
    @State private var pendingScrollTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            messageList
            banners
            modelRetryRow
            inputBar
        }
        .overlay(alignment: .center) {
            if pendingBranchMessageID != nil {
                ZiroConfirmationModal(
                    title: "Branch conversation?",
                    message: "A new conversation starts from this message. The current transcript is unchanged.",
                    confirmTitle: "Branch",
                    isDestructive: false,
                    onConfirm: {
                        if let id = pendingBranchMessageID {
                            pendingBranchMessageID = nil
                            Task {
                                await viewModel.branchFromMessage(id)
                                showToast("Branched into a new conversation")
                            }
                        }
                    },
                    onCancel: { pendingBranchMessageID = nil }
                )
            }
            if pendingRetryMessageID != nil {
                ZiroConfirmationModal(
                    title: "Retry response?",
                    message: "Regenerate this response? replacing previous reply",
                    confirmTitle: "Retry",
                    isDestructive: false,
                    onConfirm: {
                        pendingRetryMessageID = nil
                        Task { await viewModel.retryLastResponse() }
                    },
                    onCancel: { pendingRetryMessageID = nil }
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                HStack(spacing: ZiroTheme.Spacing.small) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(toastMessage)
                        .font(ZiroType.footnote)
                }
                .foregroundStyle(ZiroTheme.primaryText)
                .padding(.horizontal, ZiroTheme.Spacing.large)
                .padding(.vertical, ZiroTheme.Spacing.medium)
                .background(ZiroTheme.raisedBackground)
                .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: ZiroTheme.Radius.control)
                        .stroke(ZiroTheme.hairline, lineWidth: 1)
                )
                .padding(.bottom, ZiroTheme.Spacing.large)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat-toast")
            }
        }
        .background(ZiroTheme.pageBackground)
        // No navigation title: the bar carries only the two shell controls,
        // and the model identity lives in the composer's picker pill. An
        // inline conversation title duplicated the sidebar row and ate the
        // transcript's first 44pt for chrome.
        .toolbar { chatToolbar }
        .onAppear {
            // Deferred autoload lives here rather than at startup: reaching
            // the chat never waits on model work (master plan §B).
            viewModel.startDeferredModelLoadIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            // The chat stays mounted across backgrounding (compact shell base
            // layer / split detail), so onAppear never re-fires on return.
            // Re-kick the same idempotent loader so a system-evicted model
            // auto-reloads; user-unload intent stays parked via the existing
            // gate inside startDeferredModelLoadIfNeeded.
            if phase == .active {
                viewModel.handleForegroundTransition()
            } else if phase == .background {
                // P2-6/8: the system dismisses the keyboard out from under us
                // on background — drop the focus affordance with it (otherwise
                // the accent ring sticks with no keyboard) and park + persist
                // per-conversation drafts for kill-recovery.
                resignComposerFocus()
                viewModel.noteBackgroundTransition()
            }
        }
        .onDisappear {
            // P2-6: leaving the surface resigns focus and drops any coalesced
            // scroll so a stale task cannot scroll a recycled view.
            resignComposerFocus()
            pendingScrollTask?.cancel()
            pendingScrollTask = nil
        }
        .onChange(of: viewModel.composerResignGeneration) { _, _ in
            // P2-6: shell navigation (sidebar open, conversation switch, new
            // draft, route push) resigns the composer even though the chat
            // stays mounted beneath the pushed surface.
            resignComposerFocus()
        }
        .onChange(of: viewModel.inputText) { _, _ in
            // P2-8: mirror every keystroke into the per-conversation memory
            // store (the UserDefaults flush stays background-only).
            viewModel.parkCurrentDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            // P2-8: the system can dismiss the keyboard without touching our
            // focus state (backgrounding, hardware-keyboard detach). Reset
            // the affordance — but only off the active phase, so a keyboard
            // type-switch (hide+show while active) never steals focus.
            if scenePhase != .active {
                resignComposerFocus()
            }
        }
        // Single queued alert (P1-4): the experimental-consent and delete
        // confirmations share one alert driven by the `ZiroAlert` queue, so
        // only one modal can win (stacked `.alert` modifiers compete and
        // silently drop all but one). Buttons/messages mirror the pre-queue
        // alerts verbatim. There is no modern `.alert(item:)` in this SDK
        // (deprecated since iOS 15 — use presenting-data instead), so the
        // queue drives `isPresented` + `presenting:` with a dynamic title.
        .alert(
            Text(chatAlertQueue?.title ?? ""),
            isPresented: chatAlertPresented,
            presenting: chatAlertQueue
        ) { (alert: ZiroAlert) in
            switch alert {
            case .experimentalConsent:
                Button("Enable Experimental Use") {
                    Task { await viewModel.confirmExperimentalConsent() }
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cancelExperimentalConsent()
                }
            case .deleteConversation:
                Button("Delete", role: .destructive) {
                    showDeleteChatConfirmation = false
                    onDeleteConversation?()
                }
                Button("Cancel", role: .cancel) {
                    showDeleteChatConfirmation = false
                }
            case .visionDownscale:
                Button("Send smaller version") {
                    Task { await viewModel.confirmVisionDownscale() }
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cancelVisionDownscale()
                }
            default:
                Button("OK", role: .cancel) {}
            }
        } message: { (alert: ZiroAlert) in
            Text(alert.message)
        }
    }

    /// Attachment cluster (photo picker + paste): always in the composer
    /// row so the affordance never jumps layout as models load or vision
    /// capability changes. Gating stays logic-only — the controls disable
    /// (dimmed to the `tertiaryText` disabled voice, with a spoken reason)
    /// when the selected model is not vision-capable, instead of leaving
    /// the hierarchy. Typing stays enabled while the model loads; only send
    /// waits for residency (`chatReady`); this cluster adds the
    /// vision-capable requirement on top.
    var attachmentButtons: some View {
        HStack(spacing: ZiroTheme.Spacing.medium) {
            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 10, matching: .images) {
                Image(systemName: "plus")
                    .font(.title3)
                    .frame(width: composerControlSide, height: composerControlSide)
                    // Drawn disc ~32pt; 44pt hit target via expanded shape.
                    .contentShape(Rectangle().inset(by: -6))
                    // The composer's controls sit on their own discs (fill,
                    // not stroke — the glyph is the ink): the `+` on the
                    // neutral `controlDisc`, one step above the well, so the
                    // row reads as controls rather than floating icons.
                    .background(Circle().fill(ZiroTheme.controlDisc))
            }
            .disabled(!attachmentsEnabled)
            .accessibilityLabel("Add photos")
            .accessibilityHint(
                attachmentsEnabled
                    ? "Attach up to 10 images to this message"
                    : "Attach images, unavailable until a vision-capable model is loaded"
            )
            .onChange(of: selectedPhotos) { _, items in
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) { await viewModel.addImage(data) }
                    }
                    selectedPhotos.removeAll()
                }
            }
        }
        // White glyph on the disc when live; the disabled voice (tertiary
        // ink) keeps the blocked control legible without spending the accent
        // on a secondary affordance.
        .foregroundStyle(attachmentsEnabled ? ZiroTheme.accentForeground : ZiroTheme.tertiaryText)
    }

    /// Attachment gating: vision-capable selection (enabled while the model
    /// loads so drafts/attachments are never blocked). The cluster renders
    /// always-visible-but-disabled otherwise (see `inputBar`) so the row
    /// never reflows and VoiceOver keeps a stable landmark.
    private var attachmentsEnabled: Bool { viewModel.isVisionModel }

    private func showToast(_ message: String) {
        toastMessage = message
        UIAccessibility.post(notification: .announcement, argument: message)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toastMessage == message { toastMessage = nil }
        }
    }

    var sendButton: some View {
        Button {
            Task {
                if viewModel.isStreaming { await viewModel.cancelStream() }
                else { await viewModel.sendMessage() }
            }
        } label: {
            Group {
                if viewModel.isStreaming {
                    Image(systemName: "stop.circle.fill")
                        .transition(.opacity)
                } else if isModelLoading {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                        .accessibilityLabel("Loading model")
                } else {
                    Image(systemName: "arrow.up")
                        .font(.title3)
                        .transition(.opacity)
                }
            }
            .font(.title3)
            .foregroundStyle(sendTint)
            .frame(width: sendControlSide, height: sendControlSide)
            // The disc is the send affordance: white arrow on
            // `controlDiscActive` once a send can fire, a bare muted glyph
            // when it cannot. Fill-not-stroke keeps it a button, not a badge.
            .background(Circle().fill(sendDisc ?? .clear))
            // Drawn disc ~32pt; 44pt hit target via expanded shape.
            .contentShape(Rectangle().inset(by: -6))
            .ziroAnimation(ZiroMotion.press, value: viewModel.isStreaming)
        }
        .buttonStyle(ZiroSubtlePressButtonStyle())
        .disabled(sendDisabled)
        .accessibilityLabel(sendAccessibilityLabel)
        .accessibilityHint(sendAccessibilityHint)
    }

    /// Inline loading marker: the composer picker already carries the phase
    /// text, this only swaps the send glyph for a spinner while loading so
    /// the blocked send reads as busy, not broken. Draft text is preserved
    /// (the button stays disabled, never clears `inputText`).
    private var isModelLoading: Bool { viewModel.modelLoadPhase == .loading }

    private var sendAccessibilityLabel: String {
        if viewModel.isStreaming { return "Stop generating" }
        if isModelLoading { return "Loading model" }
        return "Send message"
    }

    private var sendAccessibilityHint: String {
        if viewModel.isStreaming { return "Stops the current response" }
        if isModelLoading { return "Waiting for the model to load" }
        return "Sends your message to the local model"
    }

    /// Streaming stays interruptible; sending requires residency (`chatReady`).
    private var sendDisabled: Bool {
        (!chatReady || !canSend || viewModel.isLoadingConversation) && !viewModel.isStreaming
    }

    /// Send-glyph ink: white on the live disc, accent while streaming (the
    /// stop control is the live action and keeps the signal), the disabled
    /// voice otherwise.
    private var sendTint: Color {
        if viewModel.isStreaming { return Color.accentColor }
        return sendDisc != nil ? ZiroTheme.accentForeground : ZiroTheme.tertiaryText
    }

    /// The send disc, present only while the send button is actually
    /// enabled (`sendDisabled` is the single gate the button uses): the
    /// accent stays the app's single live signal, so a blocked send is a bare
    /// glyph rather than a second filled control.
    private var sendDisc: Color? {
        guard !viewModel.isStreaming, !sendDisabled else { return nil }
        return ZiroTheme.controlDiscActive
    }

    var imagePreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZiroTheme.Spacing.small) {
                // PERF: indices directly — avoids the per-body Array(enumerated())
                // copy (positional identity is correct for this tiny append/remove strip).
                ForEach(viewModel.pendingImages.indices, id: \.self) { index in
                    let data = viewModel.pendingImages[index]
                    if let image = UIImage(data: data) {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: image)
                                .resizable().scaledToFill()
                                .frame(width: pendingImageSide, height: pendingImageSide)
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
                                .accessibilityLabel("Attached image \(index + 1)")
                            Button { viewModel.removeImage(at: index) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3).foregroundStyle(.white)
                                    // Depth without a shadow (shadows only ever
                                    // accompany a hairline): the pure black/white
                                    // edge keeps the white disc legible over
                                    // bright photo content in both appearances.
                                    .overlay(
                                        Circle().stroke(
                                            Color(uiColor: UIColor { traits in
                                                traits.userInterfaceStyle == .dark
                                                    ? UIColor.white.withAlphaComponent(0.35)
                                                    : UIColor.black.withAlphaComponent(0.2)
                                            }),
                                            lineWidth: 1
                                        )
                                    )
                                    .frame(width: imageRemoveControlSide, height: imageRemoveControlSide)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(ZiroSubtlePressButtonStyle())
                            .accessibilityLabel("Remove attached image \(index + 1)")
                            // The scaled 44×44 hit target centers the glyph in
                            // a frame whose top-trailing corner is pinned to
                            // the thumbnail's; the inset keeps the glyph itself
                            // anchored on the corner instead of pulled half a
                            // frame inside by the enlarged hit area.
                            .offset(x: imageRemoveCornerInset, y: -imageRemoveCornerInset)
                        }
                    }
                }
            }
            .padding(.horizontal, ZiroTheme.Spacing.large)
            .padding(.vertical, ZiroTheme.Spacing.small)
        }
    }
}

extension ChatView {

    // MARK: Transcript

    /// One transcript row. Extracted so the LazyVStack body stays within
    /// the compiler's type-check budget with five action closures.
    private func messageRow(_ message: ChatMessagePayload) -> some View {
        let messageID = message.id
        let isLastAssistant = message.role == .assistant
            && message.id == viewModel.messages.last(where: { $0.role == .assistant })?.id
        return MessageBubble(
            message: message,
            // Action chrome is gated to the live turn: copy/branch/retry under
            // every past reply turned the transcript into a wall of repeated
            // icons. Older replies stay fully selectable and readable.
            showsActions: isLastAssistant,
            // Clock chrome is gated the same way: only time-block
            // boundaries carry a timestamp (one O(n) pass below).
            showsTimestamp: timestampVisibleIDs.contains(messageID),
            onBranch: { pendingBranchMessageID = messageID },
            onCopy: { [content = message.content] in viewModel.copyMessageText(content) },
            onRetry: isLastAssistant && viewModel.canRetryLastResponse
                ? { pendingRetryMessageID = messageID }
                : nil
        )
        .id(messageID)
        // PERF: opacity-only insert (GPU-composited, no layout pass). The
        // previous move(edge:)+opacity forced layout/offscreen work for every
        // inserted row on this high-churn path; the fade keeps the appear cue
        // in both motion modes.
        .transition(.opacity)
    }

    var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.isLoadingConversation {
                        loadingTranscript
                    } else if viewModel.messages.isEmpty && !viewModel.isStreaming {
                        emptyState
                            .transition(.opacity)
                    }

                    // PERF: stable-id ForEach over the live array — no per-body
                    // Array(enumerated()) copy on every streaming token, and row
                    // identity survives inserts/deletes. Day dividers come from
                    // one O(n) labels pass (lazy enumerated, no copy).
                    // Row inserts ride the appear spring (opacity-only rows,
                    // so no layout pass per insert); keyed on count so the
                    // empty-state swap animates through the same transaction.
                    ForEach(viewModel.messages, id: \.id) { message in
                        if let divider = dayDividerLabels[message.id] {
                            DayDivider(label: divider)
                        }
                        messageRow(message)
                    }

                    if viewModel.canRetryLastResponse && !viewModel.messages.isEmpty
                        && viewModel.messages.last?.role != .assistant {
                        // Fallback when no assistant bubble hosts the retry
                        // icon (the failed turn left a trailing user message).
                        Button {
                            pendingRetryMessageID = viewModel.messages.last(where: { $0.role == .user })?.id
                        } label: {
                            Label("Retry response", systemImage: "arrow.clockwise")
                                .font(ZiroType.footnote)
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                        .padding(.horizontal, ZiroTheme.Spacing.large)
                        .padding(.vertical, ZiroTheme.Spacing.small)
                        .accessibilityHint("Generates a new response to your last message")
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
                // Transcript column: the widest allowed content cap (760),
                // centered by the full-width frame — ZiroMeasure.full.
                .frame(maxWidth: ZiroMeasure.full)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ZiroTheme.Spacing.medium)
                .ziroAnimation(ZiroMotion.appear, value: viewModel.messages.count)
                // P2-7: background-only tap-to-dismiss. Sitting behind the
                // rows, this never sees taps consumed by bubble buttons, the
                // inline Retry/Reload row, or the jump button — unlike the
                // previous ScrollView-level gesture, which fired alongside
                // those controls and stole their taps' keyboard state.
                .background(
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { resignComposerFocus() }
                )
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
            .onPreferenceChange(ScrollOffsetKey.self) { maxY in
                // BATCH-04: avoid withAnimation per scroll-offset frame
                hasScrolledUp = maxY < 0
            }
            .overlay(alignment: .bottom) {
                if hasScrolledUp {
                    jumpToBottomButton { scrollToBottom(proxy) }
                        .padding(.bottom, ZiroTheme.Spacing.small)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .ziroAnimation(ZiroMotion.appear, value: hasScrolledUp)
            .onChange(of: viewModel.messages.count) { _, _ in throttledScrollToBottom(proxy) }
            .onChange(of: viewModel.streamingText) { _, _ in
                guard !hasScrolledUp else { return }
                throttledScrollToBottom(proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                if streaming {
                    throttledScrollToBottom(proxy)
                } else {
                    // Completion cue (r5): the streaming bubble is created
                    // with isStreaming constantly true and torn down the
                    // moment this flips false, so it can never announce its
                    // own finish — post the announcement from this choke
                    // point instead. The recorded end reason branches the
                    // wording: only a natural completion may say "complete";
                    // a stop says "stopped"; an error stays silent because
                    // its banner announces the failure itself.
                    switch viewModel.lastStreamEndReason {
                    case .completed:
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Assistant response complete"
                        )
                    case .truncated:
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Assistant response complete, older messages removed to fit context"
                        )
                    case .stopped:
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Response stopped"
                        )
                    case .failed, nil:
                        break
                    }
                }
            }
        }
    }

    var loadingTranscript: some View {
        VStack(spacing: ZiroTheme.Spacing.large) {
            ProgressView()
            Text("Loading conversation…")
                .font(ZiroType.supporting)
                .foregroundStyle(ZiroTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .accessibilityElement(children: .combine)
    }

    /// The brand moment: the ZE mark centered over "Ask me anything.", the
    /// whole block centered in the space above the composer
    /// (`containerRelativeFrame` gives it the transcript viewport's height, so
    /// it stays centered instead of sitting under the navigation bar). No
    /// suggestion cards — the vision's empty state is the mark and the line —
    /// but the no-models CTA stays: with nothing installed the composer can do
    /// nothing, and the catalog is the only way forward. That CTA is a quiet
    /// well-and-hairline control, not a second full-bleed accent slab: the
    /// screen's single accent budget is never spent on the resting state.
    var emptyState: some View {
        VStack(spacing: ZiroTheme.Spacing.medium) {
            ZiroBrandMark(size: emptyStateMarkSize)

            Text("Ask me anything.")
                .font(ZiroType.title)
                .foregroundStyle(ZiroTheme.primaryText)
                .multilineTextAlignment(.center)

            if viewModel.availableModels.isEmpty {
                Button {
                    navigateToRoute(.models)
                } label: {
                    Label("Browse Models", systemImage: "arrow.down.circle")
                        .font(ZiroType.body)
                        .foregroundStyle(ZiroTheme.primaryText)
                        .padding(.horizontal, ZiroTheme.Spacing.large)
                        .frame(minHeight: 44)
                        .background(ZiroTheme.wellBackground, in: Capsule())
                        .overlay(Capsule().stroke(ZiroTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(ZiroSubtlePressButtonStyle())
                .accessibilityIdentifier("browse-models-button")
            }
        }
        .frame(maxWidth: ZiroMeasure.standard)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ZiroTheme.Spacing.xLarge)
        .containerRelativeFrame(.vertical, alignment: .center)
    }

    // MARK: Scrolling

    func jumpToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body)
                .padding(ZiroTheme.Spacing.medium)
                .foregroundStyle(ZiroTheme.primaryText)
                .background(ZiroTheme.wellBackground, in: Circle())
                .overlay(Circle().stroke(ZiroTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(ZiroSubtlePressButtonStyle())
        .accessibilityLabel("Jump to latest message")
    }

    var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.pendingImages.isEmpty
    }

    // MARK: Day Dividers

    /// Day-separator labels keyed by message id, computed in one O(n) pass
    /// per body evaluation (PERF: replaces per-row index math driven by a
    /// per-token Array(enumerated()) copy).
    private var dayDividerLabels: [UUID: String] {
        Self.dayDividerLabels(for: viewModel.messages)
    }

    /// Timestamp visibility keyed by message id, computed in one O(n) pass
    /// per body evaluation (same pattern as the day dividers above).
    private var timestampVisibleIDs: Set<UUID> {
        Self.timestampVisibleIDs(for: viewModel.messages)
    }

    /// Pure time-block rule (internal so it stays unit-testable like
    /// dayDividerLabels). A message carries its clock time only when it
    /// opens a new block — the first dated message, anything 5+ minutes
    /// after the previous dated message, or the latest message (so the live
    /// edge always carries a time). Undated messages never do — they join
    /// the running block, same as with day dividers.
    static func timestampVisibleIDs(
        for messages: [ChatMessagePayload],
        threshold: TimeInterval = 300
    ) -> Set<UUID> {
        var visible: Set<UUID> = []
        var lastDate: Date?
        for (index, message) in messages.enumerated() {
            guard let date = message.createdAt else { continue }
            let opensBlock = lastDate.map { date.timeIntervalSince($0) >= threshold } ?? true
            if opensBlock || index == messages.count - 1 {
                visible.insert(message.id)
            }
            lastDate = date
        }
        return visible
    }

    /// Pure label mapping (internal so the transcript rules are unit-testable).
    /// A message opens a divider unless its immediate predecessor carries a
    /// same-day timestamp; undated messages never open one — they join the
    /// running day.
    ///
    /// A transcript that never changes day gets no divider at all: the dashed
    /// day rule above the first bubble is an artifact when every message
    /// shares one date, and suppressing it also removes the height jump the
    /// divider caused when the streaming bubble became the first dated row.
    static func dayDividerLabels(
        for messages: [ChatMessagePayload],
        calendar: Calendar = .current
    ) -> [UUID: String] {
        var labels: [UUID: String] = [:]
        var day: Date?
        for (index, message) in messages.enumerated() {
            guard let date = message.createdAt else { continue }
            if index > 0,
               let previous = messages[index - 1].createdAt,
               calendar.isDate(previous, inSameDayAs: date) {
                continue
            }
            // First dated message of each day — remember the day, but only
            // emit the label once a second day proves the divider is needed.
            guard let seenDay = day else {
                day = date
                continue
            }
            if !calendar.isDate(seenDay, inSameDayAs: date) {
                labels[message.id] = Self.dayDividerFormatter.string(from: date)
                day = date
            }
        }
        return labels
    }

    private static let dayDividerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    func scrollToBottom(_ proxy: ScrollViewProxy) {
        let scroll = {
            if viewModel.isStreaming {
                proxy.scrollTo(viewModel.streamingText.isEmpty ? "thinking" : "streaming", anchor: .bottom)
            } else {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
        }
        if reduceMotion { scroll() } else { withAnimation(ZiroMotion.stream, scroll) }
        hasScrolledUp = false
    }

    // BATCH-04: debounced scroll — at most one animated scroll per 250ms, coalesces bursts
    func throttledScrollToBottom(_ proxy: ScrollViewProxy) {
        let now = Date()
        if now.timeIntervalSince(lastScrollTime) > 0.25 {
            scrollToBottom(proxy)
            lastScrollTime = now
        } else {
            pendingScrollTask?.cancel()
            pendingScrollTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                scrollToBottom(proxy)
                lastScrollTime = Date()
            }
        }
    }

    // MARK: Focus (P2-6)

    /// Single funnel for resigning the composer: keyboard down, focus ring
    /// off. Shell navigation additionally bumps the view model's resign
    /// generation (observed above), so shell-driven and view-local resigns
    /// converge here.
    private func resignComposerFocus() {
        isInputFocused = false
    }

    // MARK: Routes

    /// Shell route hook when provided (AppShellView); falls back to the legacy
    /// redirect flag so previews and tests keep working bare.
    func navigateToRoute(_ route: ShellRoute) {
        // P2-6: pushed routes cover the composer — resign before navigating.
        resignComposerFocus()
        if let onNavigateToRoute {
            onNavigateToRoute(route)
        } else if route == .models {
            viewModel.needsModelRedirect = true
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    var chatToolbar: some ToolbarContent {
        if showsSidebarToggle, let onOpenSidebar {
            // iOS 26 gives every toolbar item a shared glass circle by
            // default; the conversations toggle must read as a bare mark, so
            // the shared background is hidden where the API exists.
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarLeading) {
                    sidebarToggleButton(action: onOpenSidebar)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    sidebarToggleButton(action: onOpenSidebar)
                }
            }
        }
        // The toolbar carries no model control: the Claude-style composer
        // picker above the message field is the single identity surface
        // (same phases, menu, and VoiceOver labels — no redundant pill).
        // Explicit "More" menu instead of `.secondaryAction` overflow: on
        // iPhone the system collapses secondary actions behind a "..."
        // button that was not presenting anything when tapped. An explicit
        // Menu in `.topBarTrailing` always opens. System prompt lives
        // globally in Settings (Default Instructions) — this menu carries
        // only Share and Delete for the active chat.
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    viewModel.exportTranscript()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.messages.isEmpty)
                if let transcriptURL = viewModel.transcriptExportURL {
                    ShareLink(item: transcriptURL) {
                        Label("Share transcript file", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                Divider()
                if onDeleteConversation != nil {
                    Button(role: .destructive) {
                        showDeleteChatConfirmation = true
                    } label: {
                        Label("Delete chat", systemImage: "trash")
                    }
                    .disabled(viewModel.activeConversationID == nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More actions")
            .accessibilityIdentifier("more-actions-menu")
        }
    }

    /// The conversations toggle: a drawn two-bar mark (two 19×1.6pt bars)
    /// rather than the system's three-bar symbol. The shell owns the drawer;
    /// this only resigns the composer first (P2-6: the drawer covers it).
    private func sidebarToggleButton(action: @escaping () -> Void) -> some View {
        Button {
            resignComposerFocus()
            action()
        } label: {
            ZiroMenuGlyph()
                // The mark is 19×7pt; the 44pt frame keeps the repo's
                // minimum hit target without drawing anything behind it.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(ZiroSubtlePressButtonStyle())
        .accessibilityLabel("Conversations")
        .accessibilityIdentifier("sidebar-button")
    }

    // MARK: Queued Alert

    /// Queue backing the single chat alert: experimental consent wins over
    /// the delete confirmation; dismissal clears the presented flags.
    private var chatAlertQueue: ZiroAlert? {
        ZiroAlert.chatQueue(
            experimentalConsent: viewModel.showingExperimentalConsent,
            deleteConversation: showDeleteChatConfirmation,
            visionChoiceModelName: viewModel.visionDownscaleOffer.map { _ in
                viewModel.selectedModel?.displayName ?? "this model"
            }
        )
    }

    private var chatAlertPresented: Binding<Bool> {
        Binding(
            get: { chatAlertQueue != nil },
            set: { newValue in
                if !newValue {
                    if viewModel.showingExperimentalConsent { viewModel.cancelExperimentalConsent() }
                    showDeleteChatConfirmation = false
                }
            }
        )
    }

    // MARK: Recovery Actions

    var recoveryActions: some View {
        HStack(spacing: ZiroTheme.Spacing.medium) {
            Button("Retry Save") { Task { await viewModel.retryPersistenceRecovery() } }
            Button("Export") { Task { await viewModel.exportPersistenceRecovery() } }
            if let url = viewModel.recoveryExportURL { ShareLink("Share", item: url) }
            Button("Discard", role: .destructive) { Task { await viewModel.discardPersistenceRecovery() } }
        }
    }

    var recoveryActionsVertical: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
            Button("Retry Save") { Task { await viewModel.retryPersistenceRecovery() } }
            Button("Export") { Task { await viewModel.exportPersistenceRecovery() } }
            if let url = viewModel.recoveryExportURL { ShareLink("Share", item: url) }
            Button("Discard", role: .destructive) { Task { await viewModel.discardPersistenceRecovery() } }
        }
    }
}

// MARK: - Menu Glyph

/// The nav bar's conversations mark: two 19×1.6pt bars, drawn rather than
/// taken from the symbol set so the toggle is a specific mark at a specific
/// weight instead of a system glyph that changes shape with the SF Symbols
/// release. Decorative; the button carries the label.
private struct ZiroMenuGlyph: View {
    private static let barWidth: CGFloat = 19
    private static let barHeight: CGFloat = 1.6

    var body: some View {
        VStack(spacing: ZiroTheme.Spacing.xSmall) {
            bar
            bar
        }
        .foregroundStyle(ZiroTheme.primaryText)
        .accessibilityHidden(true)
    }

    private var bar: some View {
        Capsule()
            .frame(width: Self.barWidth, height: Self.barHeight)
    }
}

// MARK: - Day Divider

/// Lightweight centered day separator for the transcript: a single
/// `tertiaryText`/`micro` label flanked by dashed hairline rules. Static by
/// construction (Reduce Motion safe); never carded.
private struct DayDivider: View {
    let label: String

    var body: some View {
        HStack(spacing: ZiroTheme.Spacing.small) {
            DashedRule()
            Text(label)
                // Timestamps read as machine time, not prose: Space Mono.
                .font(ZiroType.meta)
                .foregroundStyle(ZiroTheme.tertiaryText)
                .fixedSize()
            DashedRule()
        }
        .padding(.horizontal, ZiroTheme.Spacing.large)
        .padding(.vertical, ZiroTheme.Spacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// 1pt dashed hairline that stretches to fill its container.
private struct DashedRule: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: proxy.size.width, y: 0.5))
            }
            .stroke(ZiroTheme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    ChatView(viewModel: ChatViewModel(
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
    ))
}
#endif
