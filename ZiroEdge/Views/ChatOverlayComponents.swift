// ChatOverlayComponents.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Modal and transient chat components: the model picker, the thinking
// indicator, and the scroll-offset preference key.

import SwiftUI

// MARK: - Model Picker (composer control + toolbar pill)

/// Single source of truth for the chat model picker, placed as the
/// Claude-style composer control (`ComposerModelPicker`) above the message
/// field. It carries the same titles, menu actions, and VoiceOver labels the
/// former toolbar pill projected: same phases, same callbacks, no duplicated
/// state — a stateless projection of `ChatViewModel.modelLoadPhase` /
/// `selectedModel` / `availableModels`, so nothing can drift.
/// Eviction copy inside (`title`/`accessibilityText` for `.evicted`) mirrors
/// `ModelEvictionPresentation.message` — the picker tail names the model
/// ("X unloaded") while the banner/alert carry the full sentence; keep the
/// shared "unloaded … reload available" wording aligned on any edit.
enum ChatModelPicker {
    /// Visible title for every phase: loading spinner text, needsDownload
    /// "No model yet", evicted/failed retry text, ready name.
    static func title(phase: ModelLoadPhase, modelName: String?) -> String {
        switch phase {
        case .loading:
            return "\(modelName ?? "Model")…"
        case .needsDownload:
            return "No model yet"
        case .ready, .idle:
            return modelName ?? "Private on-device chat"
        case .evicted:
            // State word LEADS. The label is tail-truncated at `pickerMaxWidth`,
            // and for imported models the name is long ("repo · quantization"),
            // so a trailing state word was the first thing lost — leaving a
            // bare amber model name with nothing to explain why it was amber.
            // Now the NAME truncates instead: its head still identifies the
            // model, and `accessibilityText` still speaks it in full.
            return "unloaded · \(modelName ?? "Model")"
        case .failed:
            // Previously `modelName ?? "Model failed"` — a named model carried
            // no state word at all, so a failed picker was indistinguishable
            // from a ready one apart from the tint.
            return "failed · \(modelName ?? "Model")"
        }
    }

    static func titleTint(phase: ModelLoadPhase) -> Color {
        switch phase {
        case .ready: return ZiroTheme.primaryText
        // Semantic status tokens: raw .orange fails 4.5:1 on light backgrounds.
        case .failed, .evicted: return ZiroTheme.warningText
        case .needsDownload, .idle: return ZiroTheme.secondaryText
        case .loading: return ZiroTheme.primaryText
        }
    }

    static func isSelected(modelName: String?, model: AIModel) -> Bool {
        modelName == model.displayName
    }

    static func needsDownload(phase: ModelLoadPhase, availableModels: [AIModel]) -> Bool {
        if phase == .needsDownload { return true }
        return availableModels.isEmpty && phase != .loading
    }

    static func showsRetry(phase: ModelLoadPhase) -> Bool {
        switch phase {
        case .failed, .evicted: return true
        default: return false
        }
    }

    static func isEvicted(phase: ModelLoadPhase) -> Bool {
        if case .evicted = phase { return true }
        return false
    }

    /// Matches the historical picker-label family used by UI test helpers
    /// (`readModelPickerLabel`, `selectChatModel`). State folds into the label
    /// ("Chat model, X, loading" / "…, failed to load" / "…, unloaded, reload
    /// available" / "…, unloaded, choose a model to reload") so VoiceOver
    /// hears it from the picker itself — the warning indicator and phase
    /// are otherwise invisible after the one-shot transition announcement, and
    /// revisiting the picker would read like a normal ready state.
    static func accessibilityText(
        phase: ModelLoadPhase,
        modelName: String?,
        isUserUnloaded: Bool
    ) -> String {
        let name = modelName ?? "Model"
        switch phase {
        case .loading:
            return "Chat model, \(name), loading"
        case .failed:
            return "Chat model, \(name), failed to load"
        case .evicted:
            return "Chat model, \(name), unloaded, reload available"
        case .idle:
            // User-initiated unload: the label must distinguish the parked
            // state from `.ready`, which projects the same "Chat model, X"
            // tail otherwise.
            if isUserUnloaded {
                return "Chat model, \(name), unloaded, choose a model to reload"
            }
            return "Chat model, \(title(phase: phase, modelName: modelName))"
        case .ready, .needsDownload:
            return "Chat model, \(title(phase: phase, modelName: modelName))"
        }
    }
}

/// The Menu buttons both pickers present: download CTA when nothing is
/// installed, otherwise retry (failed/evicted) plus the model list.
struct ChatModelPickerMenuContent: View {
    let phase: ModelLoadPhase
    let modelName: String?
    let availableModels: [AIModel]
    let onSelectModel: (AIModel) -> Void
    let onBrowseModels: () -> Void
    let onRetryLoad: () -> Void

    var body: some View {
        if ChatModelPicker.needsDownload(phase: phase, availableModels: availableModels) {
            Button {
                onBrowseModels()
            } label: {
                Label("Download a Model…", systemImage: "arrow.down.circle")
            }
        } else {
            if ChatModelPicker.showsRetry(phase: phase) {
                Button {
                    onRetryLoad()
                } label: {
                    Label(
                        ChatModelPicker.isEvicted(phase: phase) ? "Reload Model" : "Retry Loading",
                        systemImage: "arrow.clockwise"
                    )
                }
                Divider()
            }
            ForEach(availableModels) { model in
                Button {
                    onSelectModel(model)
                } label: {
                    // One symbol per slot (cpu), recolored per state — never
                    // swap to a checkmark glyph. Selection reads via tint;
                    // the Menu system supplies its own checkmark affordance.
                    let selected = ChatModelPicker.isSelected(modelName: modelName, model: model)
                    Label(model.displayName, systemImage: "cpu")
                        .foregroundStyle(selected ? ZiroTheme.accent : ZiroTheme.primaryText)
                        .opacity(selected ? 1 : 0.85)
                }
            }
        }
    }
}

/// Wraps any picker label in the shared Menu content, loading hit-testing,
/// and VoiceOver semantics. The Menu is hit-test-disabled while loading in
/// every placement — the spinner state never accepts taps.
struct ChatModelPickerMenu<PickerLabel: View>: View {
    let phase: ModelLoadPhase
    let modelName: String?
    var isUserUnloaded: Bool = false
    let availableModels: [AIModel]
    let onSelectModel: (AIModel) -> Void
    let onBrowseModels: () -> Void
    let onRetryLoad: () -> Void
    @ViewBuilder let label: () -> PickerLabel

    var body: some View {
        Menu {
            ChatModelPickerMenuContent(
                phase: phase,
                modelName: modelName,
                availableModels: availableModels,
                onSelectModel: onSelectModel,
                onBrowseModels: onBrowseModels,
                onRetryLoad: onRetryLoad
            )
        } label: {
            label()
        }
        .allowsHitTesting(phase != .loading)
        .accessibilityLabel(
            ChatModelPicker.accessibilityText(
                phase: phase,
                modelName: modelName,
                isUserUnloaded: isUserUnloaded
            )
        )
        .accessibilityHint(phase == .loading ? "" : "Choose the local model for this conversation")
    }
}

/// Model picker living inside the composer's control row (see
/// `ChatView.inputBar`). Same phases, menu actions, and VoiceOver labels the
/// former toolbar pill carried, via the shared `ChatModelPicker` source of
/// truth — and, like the vision's pill, drawn as a capsule: hairline border on
/// the composer's own fill, so it reads as an outlined chip embedded in the
/// well rather than a second surface beside it.
struct ComposerModelPicker: View {
    let phase: ModelLoadPhase
    let modelName: String?
    /// True while a user-initiated unload (Settings → Unload Model) has
    /// parked the chat on `.idle` with a named model. Without it that state
    /// reads identically to `.ready` over VoiceOver while the composer sits
    /// dimmed and disabled.
    var isUserUnloaded: Bool = false
    let availableModels: [AIModel]
    let onSelectModel: (AIModel) -> Void
    let onBrowseModels: () -> Void
    let onRetryLoad: () -> Void

    /// Width cap scales with Dynamic Type (relative to the picker's
    /// footnote font) so long model names truncate with an ellipsis
    /// instead of pushing past the vision pill (~116pt outer: ~90pt text +
    /// slim insets + text/chevron gap + chevron).
    @ScaledMetric(relativeTo: .footnote) private var pickerMaxWidth: CGFloat = 90

    var body: some View {
        ChatModelPickerMenu(
            phase: phase,
            modelName: modelName,
            isUserUnloaded: isUserUnloaded,
            availableModels: availableModels,
            onSelectModel: onSelectModel,
            onBrowseModels: onBrowseModels,
            onRetryLoad: onRetryLoad
        ) {
            pickerLabel
        }
    }

    private var pickerLabel: some View {
        HStack(spacing: ZiroTheme.Spacing.xSmall) {
            // The slot only exists in phases that draw an indicator
            // (loading/failed/evicted) — ready/idle/needsDownload hug the
            // text + chevron with zero leading dead space, as the vision does.
            if showsStatusIndicator {
                statusSlot
            }
            Text(ChatModelPicker.title(phase: phase, modelName: modelName))
                .font(ZiroType.footnote)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)
                .foregroundStyle(ChatModelPicker.titleTint(phase: phase))
                // The cap lives on the text, not the row, so the capsule hugs
                // the (possibly truncated) label instead of filling the cap.
                .frame(maxWidth: pickerMaxWidth, alignment: .leading)
            Image(systemName: "chevron.down")
                // Match the picker text voice (ZiroType.footnote, regular) —
                // one weight/size set per surface. chevron.down is vertical,
                // so no RTL flip.
                .font(ZiroType.footnote)
                .foregroundStyle(ZiroTheme.tertiaryText)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, ZiroTheme.Spacing.medium)
        // Drawn height ~33pt (vision pill); 44pt hit target lives on the
        // expanded contentShape, not the frame, so the row stays short.
        .frame(minHeight: 33)
        // Quiet text directly on the composer well — no pill fill or ring.
        // The well already draws fill+stroke; a nested capsule only
        // doubles the ring with zero fill contrast.
        .contentShape(Rectangle().inset(by: -6))
    }

    /// Whether the phase draws a leading indicator (spinner / warning glyph).
    private var showsStatusIndicator: Bool {
        switch phase {
        case .loading, .failed, .evicted: true
        case .ready, .idle, .needsDownload: false
        }
    }

    /// Leading indicator, hugging its content and present only in phases
    /// that need it. Hosts the loading spinner while loading, and a warning
    /// glyph for the two attention phases — so the amber tint is explained
    /// by a symbol instead of reading as a randomly coloured model name.
    /// The glyph matches the picker's own type voice (`ZiroType.footnote`,
    /// same as the chevron): one size/weight set per surface, and Dynamic
    /// Type aware rather than a fixed icon size. Decorative: the phase
    /// already reads in the title text and the shared accessibility label,
    /// so VoiceOver skips the slot itself.
    private var statusSlot: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed, .evicted:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(ZiroType.footnote)
                    .foregroundStyle(ZiroTheme.warningText)
            case .ready, .idle, .needsDownload:
                // Unreachable: hidden behind `showsStatusIndicator`.
                Color.clear
            }
        }
        .transition(.opacity)
        .ziroAnimation(ZiroMotion.press, value: phase)
        .accessibilityHidden(true)
    }
}


struct ThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                thinkingRow(text: "Thinking…")
            } else {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let dots = (Int(context.date.timeIntervalSinceReferenceDate * 2) % 3) + 1
                    thinkingRow(text: "Thinking" + String(repeating: ".", count: dots))
                }
            }
        }
        .accessibilityLabel("Model is thinking")
    }

    private func thinkingRow(text: String) -> some View {
        HStack {
            // Quiet status line on the page — no bubble, no card. The
            // min-width only steadies the dots animation at the default
            // size; the text itself is plain secondary copy.
            Text(text)
                .font(ZiroType.supporting)
                .foregroundStyle(ZiroTheme.secondaryText)
                .frame(minWidth: 96, alignment: .leading)
                .padding(.vertical, ZiroTheme.Spacing.small)
            Spacer()
        }
        .padding(.horizontal, ZiroTheme.Spacing.large)
        .padding(.vertical, ZiroTheme.Spacing.xSmall)
    }
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
