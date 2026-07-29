// ImportedModelSettingsView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// User-adjustable safe settings for an imported model.
// Context length and generation behavior are bounded; unsafe runtime
// parameters (batch, threads, GPU layers, KV cache) remain app-owned.

import SwiftUI

/// Settings panel for an imported model. Only exposes bounded, safe controls.
/// Unsafe runtime knobs (batch, threads, GPU layers, mmap, KV-cache) are
/// rendered as locked read-only values so users understand the sandbox.
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
    @State private var updateCheckMessage: String?
    @State private var retryMessage: String?

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
        Section("Safe Imported Settings") {
            adjustableControls
            estimatedMemoryRow
            actionButtons
            lockedPolicyNotice
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
        UInt64(clamping: model.totalFileSizeBytes / 3)
            + UInt64(contextLength) * 256_000
            + MemoryProfile.productionReserveBytes
    }

    private var estimatedMemoryRow: some View {
        LabeledContent(
            "Estimated RAM",
            value: ByteCountFormatter.string(
                fromByteCount: Int64(clamping: estimatedMemory),
                countStyle: .memory
            )
        )
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        Button("Save Safe Settings") {
            let sampling = SamplingConfig(
                temperature: Float(temperature),
                topP: Float(topP),
                topK: topK,
                maxTokens: maxTokens,
                repeatPenalty: Float(repeatPenalty)
            )
            viewModel.updateImportedConfiguration(
                for: model,
                contextLength: contextLength,
                sampling: sampling
            )
            savedMessage = "Settings saved. Changes take effect on next load."
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if savedMessage == "Settings saved. Changes take effect on next load." {
                    savedMessage = nil
                }
            }
        }

        if let savedMessage {
            Text(savedMessage)
                .font(.caption)
                .foregroundStyle(.green)
        }

        Button("Retry Native Load") {
            retryMessage = nil
            Task { await viewModel.retryImportedModel(model) }
        }
        .disabled(!viewModel.isDownloaded(model))

        if let loadStatus = loadStatusMessage {
            Text(loadStatus)
                .font(.caption)
                .foregroundStyle(loadStatusColor)
        }

        Button("Check for Update") {
            updateCheckMessage = nil
            Task {
                do {
                    let coordinator = ImportedModelUpdateCoordinator(
                        downloadManager: viewModel.downloadManager
                    )
                    switch try await coordinator.checkForUpdate(model: model) {
                    case .upToDate:
                        updateCheckMessage = "This pinned revision is up to date."
                    case .review:
                        updateCheckMessage = "A newer revision is available. Re-import to update."
                    }
                } catch {
                    updateCheckMessage = error.localizedDescription
                }
            }
        }

        if let updateCheckMessage {
            Text(updateCheckMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Locked Policy Notice

    private var lockedPolicyNotice: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            Text("App-managed parameters (non-adjustable):")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            lockedRow("Batch size", value: "\(model.config.batchSize)")
            lockedRow("Micro-batch", value: "\(model.config.microBatchSize)")
            lockedRow("Threads", value: "\(model.config.threadCount)")
            lockedRow("GPU layers", value: "\(model.config.gpuLayers)")
            lockedRow("mmap", value: model.config.useMmap ? "On" : "Off")
            lockedRow("KV-cache (f16)", value: model.config.f16KV ? "On" : "Off")

            Text("These parameters are controlled by ZiroEdge for safety and cannot be overridden.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    private func lockedRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
