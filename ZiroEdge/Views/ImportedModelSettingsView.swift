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
                    .font(.caption)
                    .foregroundStyle(saveFailed ? .red : .green)
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
            Text("Temperature: \(temperature, specifier: "%.1f")")
                .font(.subheadline)
            Slider(value: $temperature, in: 0...2, step: 0.1)
        }

        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            Text("Top-P: \(topP, specifier: "%.2f")")
                .font(.subheadline)
            Slider(value: $topP, in: 0...1, step: 0.05)
        }

        Stepper("Max Tokens: \(maxTokens)", value: $maxTokens, in: 64...4096, step: 64)

        Stepper("Top-K: \(topK)", value: $topK, in: 1...100, step: 1)

        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            Text("Repeat Penalty: \(repeatPenalty, specifier: "%.2f")")
                .font(.subheadline)
            Slider(value: $repeatPenalty, in: 0...2, step: 0.05)
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
        LabeledContent(
            "Estimated RAM",
            value: StorageByteFormatter.string(
                fromByteCount: Int64(clamping: estimatedMemory),
                countStyle: .memory
            )
        )
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
                .font(.caption)
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
        guard let record = ImportedModelStore.shared.record(id: model.id) else { return .secondary }
        switch record.loadStatus {
        case .loaded: return .green
        case .loadFailed: return .red
        case .configurationChanged: return .orange
        case .neverLoaded: return .secondary
        }
    }
}
