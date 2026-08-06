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
    @StateObject private var updateCoordinator: ImportedModelUpdateCoordinator

    @State private var contextLength: Int
    @State private var temperature: Double
    @State private var topP: Double
    @State private var maxTokens: Int
    @State private var topK: Int
    @State private var repeatPenalty: Double

    @State private var savedMessage: String?
    @State private var updateCheckMessage: String?
    @State private var availableUpdate: HFRepositoryReview?
    @State private var selectedUpdateBase: HFArtifact?
    @State private var updateLicenseConfirmed = false
    @State private var updatePairConfirmed = false

    init(model: AIModel, viewModel: ModelsViewModel) {
        self.model = model
        self.viewModel = viewModel
        _updateCoordinator = StateObject(wrappedValue: ImportedModelUpdateCoordinator(
            downloadManager: viewModel.downloadManager
        ))
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
        ImportRAMAssessment.estimatedBytes(
            artifactBytes: model.totalFileSizeBytes,
            contextLength: contextLength
        )
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
            availableUpdate = nil
            selectedUpdateBase = nil
            updateLicenseConfirmed = false
            updatePairConfirmed = false
            Task {
                do {
                    switch try await updateCoordinator.checkForUpdate(model: model) {
                    case .upToDate:
                        updateCheckMessage = "This pinned revision is up to date."
                    case .review(let review):
                        availableUpdate = review
                        updateCheckMessage = "A newer revision is available and ready to stage."
                    }
                } catch {
                    updateCheckMessage = error.localizedDescription
                }
            }
        }
        .disabled(updateCoordinator.hasStagedUpdate(modelID: model.id))

        if let availableUpdate,
           !updateCoordinator.hasStagedUpdate(modelID: model.id) {
            Text("Revision \(availableUpdate.revision.prefix(12)) · \(availableUpdate.licenseName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            VariantPickerView(
                candidates: availableUpdate.baseArtifacts,
                selection: Binding(
                    get: { selectedUpdateBase },
                    set: {
                        selectedUpdateBase = $0
                        updatePairConfirmed = false
                    }
                )
            )
            if model.modelType == .vision, let selectedUpdateBase {
                if let pair = VisionPairResolver().bestPair(for: selectedUpdateBase, in: availableUpdate) {
                    Text("Projector: \(pair.projector.filename) · \(pair.confidence.label)")
                        .font(.caption)
                    Toggle("I confirm this updated vision pair", isOn: $updatePairConfirmed)
                } else {
                    Label("No unambiguous high-confidence projector pair is available.", systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Toggle("I reviewed and accept the updated license", isOn: $updateLicenseConfirmed)
            Button("Download and Stage Update") {
                do {
                    try stageUpdate(availableUpdate)
                    updateCheckMessage = "The update is downloading beside the installed revision."
                } catch {
                    updateCheckMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            .disabled(
                selectedUpdateBase == nil
                    || !updateLicenseConfirmed
                    || (model.modelType == .vision && !updatePairConfirmed)
            )
        }

        if updateCoordinator.hasStagedUpdate(modelID: model.id) {
            Button("Finish Verified Update") {
                do {
                    if try updateCoordinator.promoteIfVerified(modelID: model.id) != nil {
                        availableUpdate = nil
                        updateCheckMessage = "Update installed. Return to Models to open the new revision."
                    } else {
                        updateCheckMessage = "The staged artifacts are still downloading or have not passed verification."
                    }
                } catch {
                    updateCheckMessage = error.localizedDescription
                }
            }

            Button("Cancel Staged Update", role: .destructive) {
                updateCoordinator.discardStagedUpdate(modelID: model.id)
                availableUpdate = nil
                updateCheckMessage = "The staged update was discarded. The installed revision is unchanged."
            }
        }

        if let updateCheckMessage {
            Text(updateCheckMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stageUpdate(_ review: HFRepositoryReview) throws {
        guard updateLicenseConfirmed, let base = selectedUpdateBase else {
            throw HFInspectionError.noCompatibleArtifact
        }

        if model.modelType == .vision {
            guard let candidate = VisionPairResolver().bestPair(for: base, in: review) else {
                throw review.projectorArtifacts.isEmpty
                    ? HFInspectionError.projectorMissing
                    : HFInspectionError.projectorAmbiguous
            }
            switch try updateCoordinator.stagePairedUpdate(
                existing: model,
                review: review,
                candidate: candidate
            ) {
            case .staging, .promoted:
                return
            case .rejected(let message):
                throw ImportedModelUpdateError.rejected(message)
            }
        } else {
            _ = try updateCoordinator.stageUpdate(
                existing: model,
                review: review,
                base: base,
                projector: nil
            )
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

private enum ImportedModelUpdateError: LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let message): message
        }
    }
}
