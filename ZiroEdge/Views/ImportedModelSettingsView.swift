// ImportedModelSettingsView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Bounded generation-parameter editor for an imported model, hosted inside
// ModelDetailView's Generation Settings page (it renders Form/List sections;
// the hosting page supplies navigation chrome). Unsafe runtime parameters
// (batch, threads, GPU layers, mmap, KV cache) are documented as locked,
// app-owned values on the Safety & Runtime page. The staged-update flow
// (check → review → stage → finish) lives in ModelDetailView's
// UpdateFlowSheet.

import SwiftUI

/// Adjustable, safe generation settings for an imported model. Context
/// length and sampling behavior are bounded; the estimated-RAM row updates
/// with the chosen context length so the cost of raising it is visible.
struct ImportedModelSettingsView: View {
    let model: AIModel
    @ObservedObject var viewModel: ModelsViewModel

    @State private var contextLength: Int
    @State private var temperature: Double
    @State private var topP: Double
    @State private var maxTokens: Int
    @State private var topK: Int
    @State private var repeatPenalty: Double

    @State private var savedMessage: String?
    @State private var saveFailed = false

    init(model: AIModel, viewModel: ModelsViewModel) {
        self.model = model
        self.viewModel = viewModel
        let config = model.config
        _contextLength = State(initialValue: config.contextLength)
        _temperature = State(initialValue: Double(config.defaultSampling.temperature))
        _topP = State(initialValue: Double(config.defaultSampling.topP))
        _maxTokens = State(initialValue: config.defaultSampling.maxTokens)
        _topK = State(initialValue: config.defaultSampling.topK)
        _repeatPenalty = State(initialValue: Double(config.defaultSampling.repeatPenalty))
    }

    var body: some View {
        Section {
            adjustableControls
            estimatedMemoryRow
        } header: {
            Text("Generation Parameters")
        } footer: {
            Text("Changes take effect the next time the model is loaded.")
        }

        Section("Apply") {
            saveButton
            if let savedMessage {
                Text(savedMessage)
                    .font(ZiroType.caption)
                    .foregroundStyle(saveFailed ? ZiroTheme.warningText : ZiroTheme.positiveText)
                    .announcingOnAppear(savedMessage)
            }
            retryNativeLoadButton
            loadStatusRow
        }
    }

    // MARK: - Adjustable Controls

    @ViewBuilder
    private var adjustableControls: some View {
        Stepper("Context: \(contextLength) tokens", value: $contextLength, in: 512...4096, step: 512)

        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            // Numeric readouts use the technical voice; the label side stays
            // in the supporting role. Content (and the spoken text) is
            // unchanged from the pre-overhaul row.
            Text("Temperature: ")
                .font(ZiroType.supporting)
                .foregroundStyle(ZiroTheme.secondaryText)
                + Text("\(temperature, specifier: "%.1f")")
                .font(ZiroType.technical(.subheadline, .semibold))
                .foregroundStyle(ZiroTheme.primaryText)
            Slider(value: $temperature, in: 0...2, step: 0.1)
                .tint(ZiroTheme.accent)
                .accessibilityLabel("Temperature")
                .accessibilityValue("\(temperature, specifier: "%.1f")")
        }

        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            Text("Top-P: ")
                .font(ZiroType.supporting)
                .foregroundStyle(ZiroTheme.secondaryText)
                + Text("\(topP, specifier: "%.2f")")
                .font(ZiroType.technical(.subheadline, .semibold))
                .foregroundStyle(ZiroTheme.primaryText)
            Slider(value: $topP, in: 0...1, step: 0.05)
                .tint(ZiroTheme.accent)
                .accessibilityLabel("Top-P")
                .accessibilityValue("\(topP, specifier: "%.2f")")
        }

        Stepper("Max Tokens: \(maxTokens)", value: $maxTokens, in: 64...4096, step: 64)

        Stepper("Top-K: \(topK)", value: $topK, in: 1...100, step: 1)

        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            Text("Repeat Penalty: ")
                .font(ZiroType.supporting)
                .foregroundStyle(ZiroTheme.secondaryText)
                + Text("\(repeatPenalty, specifier: "%.2f")")
                .font(ZiroType.technical(.subheadline, .semibold))
                .foregroundStyle(ZiroTheme.primaryText)
            Slider(value: $repeatPenalty, in: 0...2, step: 0.05)
                .tint(ZiroTheme.accent)
                .accessibilityLabel("Repeat Penalty")
                .accessibilityValue("\(repeatPenalty, specifier: "%.2f")")
        }
    }

    // MARK: - Memory Estimate

    private var estimatedMemory: UInt64 {
        ImportRAMAssessment.estimatedBytes(
            artifactBytes: model.totalFileSizeBytes,
            contextLength: contextLength
        )
    }

    private var estimatedMemoryRow: some View {
        LabeledContent("Estimated RAM") {
            // Byte figures read as engineering data — technical voice.
            Text(
                StorageByteFormatter.string(
                    fromByteCount: Int64(clamping: estimatedMemory),
                    countStyle: .memory
                )
            )
            .font(ZiroType.technical(.footnote))
        }
    }

    // MARK: - Apply

    private var saveButton: some View {
        Button("Save Safe Settings") {
            let sampling = SamplingConfig(
                temperature: Float(temperature),
                topP: Float(topP),
                topK: topK,
                maxTokens: maxTokens,
                repeatPenalty: Float(repeatPenalty)
            )
            switch viewModel.updateImportedConfiguration(
                for: model,
                contextLength: contextLength,
                sampling: sampling
            ) {
            case .success:
                saveFailed = false
                savedMessage = "Settings saved. Changes take effect on next load."
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if savedMessage == "Settings saved. Changes take effect on next load." {
                        savedMessage = nil
                    }
                }
            case .failure(let error):
                saveFailed = true
                savedMessage = error.localizedDescription
            }
        }
    }

    private var retryNativeLoadButton: some View {
        Button("Retry Native Load") {
            Task { await viewModel.retryImportedModel(model) }
        }
        .disabled(!viewModel.isDownloaded(model))
    }

    @ViewBuilder
    private var loadStatusRow: some View {
        if let loadStatus = loadStatusMessage {
            Text(loadStatus)
                .font(ZiroType.technical(.caption))
                .foregroundStyle(loadStatusColor)
        }
    }

    // MARK: - Load Status

    private var loadStatusMessage: String? {
        guard let record = ImportedModelStore.shared.record(id: model.id) else { return nil }
        switch record.loadStatus {
        case .neverLoaded:
            return nil
        case .loaded:
            return "Last load succeeded."
        case .loadFailed(let kind, let diagnostic, let at):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "[\(kind)] \(formatter.localizedString(for: at, relativeTo: Date())): \(diagnostic)"
        case .configurationChanged:
            return "Settings changed; retry load to apply."
        }
    }

    private var loadStatusColor: Color {
        guard let record = ImportedModelStore.shared.record(id: model.id) else { return ZiroTheme.secondaryText }
        switch record.loadStatus {
        case .loaded: return ZiroTheme.positiveText
        case .loadFailed: return ZiroTheme.warningText
        case .configurationChanged: return ZiroTheme.warningText
        case .neverLoaded: return ZiroTheme.secondaryText
        }
    }
}
