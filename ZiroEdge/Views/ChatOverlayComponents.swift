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
    let availableModels: [AIModel]
    let onSelectModel: (AIModel) -> Void
    let onBrowseModels: () -> Void
    let onRetryLoad: () -> Void

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
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(titleTint)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, ZiroTheme.Spacing.medium)
        .padding(.vertical, ZiroTheme.Spacing.xSmall)
        .background(ZiroTheme.inputBackground, in: Capsule())
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch phase {
        case .loading:
            ProgressView().controlSize(.small)
        case .ready:
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
        case .evicted, .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.orange)
        case .needsDownload, .idle:
            Circle()
                .fill(Color.secondary.opacity(0.5))
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
        case .ready: return Color.primary
        case .failed, .evicted: return Color.orange
        case .needsDownload, .idle: return Color.secondary
        case .loading: return Color.primary
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
    /// available") so VoiceOver hears it from the pill itself — the orange
    /// warning indicator and phase are otherwise invisible after the one-shot
    /// transition announcement, and revisiting the pill would read like a
    /// normal ready state.
    private var accessibilityText: String {
        let name = modelName ?? "Model"
        switch phase {
        case .loading:
            return "Chat model, \(name), loading"
        case .failed:
            return "Chat model, \(name), failed to load"
        case .evicted:
            return "Chat model, \(name), unloaded, reload available"
        case .ready, .idle, .needsDownload:
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
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Use Default") { Task { await onUseDefault() } }
                    }
                }
            }
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
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
                .padding(.horizontal, ZiroTheme.Spacing.large)
                .padding(.vertical, ZiroTheme.Spacing.medium)
                .background(ZiroTheme.elevatedBackground)
                .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.bubble))
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
