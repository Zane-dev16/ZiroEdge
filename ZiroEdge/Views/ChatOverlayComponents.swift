// ChatOverlayComponents.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Modal and transient chat components: the conversation-instructions sheet,
// the thinking indicator, and the scroll-offset preference key. Verbatim
// relocations from ChatView.swift for file-size hygiene.

import SwiftUI

// MARK: - Header Pill

/// Toolbar identity control showing the chat's selected model name plus an
/// animated busy indicator while loading (respects Reduce Motion). Absorbs
/// the former input-bar model-picker menu; tap-to-change leads to the picker
/// and catalog routes per master plan §B.3. Loading state is carried by the
/// pill's own spinner/title and the composer status badge — the pill is a
/// single VoiceOver element whose label names the state.
struct ChatHeaderPill: View {
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

    /// Width cap scales with Dynamic Type (relative to the pill's headline
    /// font) so the anti-overflow clamp doesn't shrink the title slot below
    /// legibility at accessibility sizes. Identical 240pt at default size.
    @ScaledMetric(relativeTo: .headline) private var pillMaxWidth: CGFloat = 240

    var body: some View {
        menu
    }

    private var menu: some View {
        Menu {
            if needsDownload {
                Button {
                    onBrowseModels()
                } label: {
                    Label("Download a Model…", systemImage: "arrow.down.circle")
                }
            } else {
                if showsRetry {
                    Button {
                        onRetryLoad()
                    } label: {
                        Label(isEvicted ? "Reload Model" : "Retry Loading", systemImage: "arrow.clockwise")
                    }
                    Divider()
                }
                ForEach(availableModels) { model in
                    Button {
                        onSelectModel(model)
                    } label: {
                        Label(model.displayName, systemImage: isSelected(model) ? "checkmark" : "cpu")
                    }
                }
            }
        } label: {
            pillLabel
        }
        .disabled(phase == .loading)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(phase == .loading ? "" : "Choose the local model for this conversation")
    }

    private var pillLabel: some View {
        HStack(spacing: ZiroTheme.Spacing.xSmall) {
            statusIndicator
            Text(pillTitle)
                .font(ZiroType.rowTitle)
                .lineLimit(1)
                .allowsTightening(true)
                .foregroundStyle(titleTint)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(ZiroTheme.secondaryText)
        }
        // Hard width cap: without one, Menu labels size to their ideal width,
        // so long model names stretch the capsule under the leading/trailing
        // toolbar buttons and the toolbar clips it mid-glyph at both ends.
        // The cap keeps the capsule inside the principal slot and lets the
        // title truncate with an ellipsis instead.
        .frame(maxWidth: pillMaxWidth)
        .padding(.horizontal, ZiroTheme.Spacing.medium)
        .padding(.vertical, ZiroTheme.Spacing.xSmall)
        .background(ZiroTheme.wellBackground, in: Capsule())
    }

    @ViewBuilder
    private var statusIndicator: some View {
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

    /// Gentle busy signal beyond the spinner is skipped under Reduce Motion;
    /// the small ProgressView already animates and is system-aware.

    private var pillTitle: String {
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

    private var titleTint: Color {
        switch phase {
        case .ready: return ZiroTheme.primaryText
        // Semantic status tokens: raw .orange fails 4.5:1 on light backgrounds.
        case .failed, .evicted: return ZiroTheme.warningText
        case .needsDownload, .idle: return ZiroTheme.secondaryText
        case .loading: return ZiroTheme.primaryText
        }
    }

    private func isSelected(_ model: AIModel) -> Bool {
        modelName == model.displayName
    }

    private var needsDownload: Bool {
        if phase == .needsDownload { return true }
        return availableModels.isEmpty && phase != .loading
    }

    private var showsRetry: Bool {
        switch phase {
        case .failed, .evicted: return true
        default: return false
        }
    }

    private var isEvicted: Bool {
        if case .evicted = phase { return true }
        return false
    }

    /// Matches the historical picker-label family used by UI test helpers
    /// (`readModelPickerLabel`, `selectChatModel`). State folds into the label
    /// ("Chat model, X, loading" / "…, failed to load" / "…, unloaded, reload
    /// available" / "…, unloaded, choose a model to reload") so VoiceOver
    /// hears it from the pill itself — the orange warning indicator and phase
    /// are otherwise invisible after the one-shot transition announcement, and
    /// revisiting the pill would read like a normal ready state.
    private var accessibilityText: String {
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
            return "Chat model, \(pillTitle)"
        case .ready, .needsDownload:
            return "Chat model, \(pillTitle)"
        }
    }
}


struct ConversationSystemPromptEditor: View {
    @Binding var prompt: String
    let defaultPrompt: String
    let onSave: () async -> Void
    let onUseDefault: () async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $prompt)
                        .font(ZiroType.body)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Conversation instructions")
                } header: {
                    Text("Instructions for this conversation")
                } footer: {
                    Text("These instructions are sent only to the on-device model.")
                }

                if !defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Default Instructions") {
                        Text(defaultPrompt)
                            .font(ZiroType.body)
                            .foregroundStyle(ZiroTheme.secondaryText)
                            .textSelection(.enabled)
                        Button("Use Default") { Task { await onUseDefault() } }
                    }
                }
            }
            // Warm paper canvas with raised card rows (design spec §3.1).
            .scrollContentBackground(.hidden)
            .background(ZiroTheme.pageBackground.ignoresSafeArea())
            .listRowBackground(ZiroTheme.raisedBackground)
            .navigationTitle("Conversation Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await onSave() } }
                }
            }
        }
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
            // minWidth (not fixed width): a fixed 96pt frame turns the bubble
            // into a tall sliver with wrapped/truncated text at accessibility
            // Dynamic Type sizes — hug the content instead and let the
            // min-width only steady the dots animation at the default size.
            Text(text)
                .font(ZiroType.supporting)
                .foregroundStyle(ZiroTheme.secondaryText)
                .frame(minWidth: 96, alignment: .leading)
                .padding(.horizontal, ZiroTheme.Spacing.large)
                .padding(.vertical, ZiroTheme.Spacing.medium)
                // Assistant bubble treatment: raised surface + hairline,
                // continuous corners at the bubble radius.
                .ziroMessageBubble(.assistant)
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
