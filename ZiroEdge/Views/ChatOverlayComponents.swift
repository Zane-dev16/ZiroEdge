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
            return "\(modelName ?? "Model") unloaded"
        case .failed:
            return modelName ?? "Model failed"
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
    /// hears it from the picker itself — the orange warning indicator and phase
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

/// Phase dot / spinner / warning shared by both picker labels (identical
/// busy signal in each placement; the small ProgressView is system-aware
/// under Reduce Motion so no extra gating is needed).
struct ChatModelStatusIndicator: View {
    let phase: ModelLoadPhase

    var body: some View {
        switch phase {
        case .loading:
            ProgressView().controlSize(.small)
        case .ready:
            Circle()
                .fill(ZiroTheme.positiveText)
                .frame(width: 7, height: 7)
        case .evicted, .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ZiroTheme.warningText)
        case .needsDownload, .idle:
            // Quiet-state dot: tertiary metadata token instead of an
            // opacity-dimmed system color.
            Circle()
                .fill(ZiroTheme.tertiaryText)
                .frame(width: 7, height: 7)
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
                    Label(
                        model.displayName,
                        systemImage: ChatModelPicker.isSelected(modelName: modelName, model: model)
                            ? "checkmark" : "cpu"
                    )
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

/// Compact Claude-style model picker sitting above the composer message
/// field (see `statusOrTokenHintRow`). Same phases, menu actions, and
/// VoiceOver labels the former toolbar pill carried, via the shared
/// `ChatModelPicker` source of truth — only the label is restyled: a smaller
/// capsule with a single chevron, `supporting` type, and a narrower width
/// cap suited to the composer row it shares with the token badge.
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
    /// subheadline font) so long model names truncate with an ellipsis
    /// instead of squeezing the token badge off the composer row.
    @ScaledMetric(relativeTo: .subheadline) private var pickerMaxWidth: CGFloat = 220

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
            ChatModelStatusIndicator(phase: phase)
            Text(ChatModelPicker.title(phase: phase, modelName: modelName))
                .font(ZiroType.supporting)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)
                .foregroundStyle(ChatModelPicker.titleTint(phase: phase))
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ZiroTheme.secondaryText)
        }
        // 44pt minimum hit target (repo standard): the capsule never shrinks
        // below the touch floor even for short names.
        .frame(maxWidth: pickerMaxWidth, minHeight: 44)
        .padding(.horizontal, ZiroTheme.Spacing.medium)
        .padding(.vertical, ZiroTheme.Spacing.xSmall)
        .background(ZiroTheme.wellBackground, in: Capsule())
        .contentShape(Capsule())
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
