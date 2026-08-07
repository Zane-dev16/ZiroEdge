// ModelDetailView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Detail view for a single model — shows metadata, download controls, and storage.

import SwiftUI

struct ModelDetailView: View {
    let model: AIModel
    @ObservedObject var viewModel: ModelsViewModel

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                    Image(systemName: modelIconName)
                        .font(.largeTitle)
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                    Text(model.description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, ZiroTheme.Spacing.small)
            }
            metadataSection
            runtimeSection
            if model.isImported { importedConfigurationSection }
            downloadSection
            if viewModel.isDownloaded(model) {
                actionsSection
            }
        }
        .navigationTitle(model.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Load Safety", isPresented: $viewModel.showingSafetyResetResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.safetyResetMessage)
        }
        .confirmationDialog(
            "Cancel Download",
            isPresented: $viewModel.showingCancelConfirmation
        ) {
            Button("Cancel Download", role: .destructive) {
                viewModel.confirmCancelDownload()
            }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("Cancelling stops the current transfer and removes its partial download data for \(viewModel.pendingCancelModel?.displayName ?? "this model").")
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        Section("Model Info") {
            LabeledContent("Name", value: model.displayName)
            LabeledContent("Size", value: model.formattedSize)
            LabeledContent("Quantization", value: model.quantization)
            LabeledContent("Type", value: modelTypeLabel)
            LabeledContent("License", value: model.license.name)
            if let source = model.huggingFaceProvenance {
                ImportedProvenanceRows(source: source)
            }
            if viewModel.isDownloaded(model) {
                LabeledContent("Storage Used", value: viewModel.diskUsage(for: model))
            }
        }
    }

    private var modelIconName: String {
        guard model.modelType == .vision else { return "text.bubble.fill" }
        return viewModel.status(for: model).isVisionReady
            ? "eye.circle.fill"
            : "eye.slash.circle.fill"
    }

    private var modelTypeLabel: String {
        guard model.modelType == .vision else { return "Text" }
        return viewModel.status(for: model).isVisionReady
            ? "Vision"
            : "Vision pair incomplete"
    }

    private var runtimeSection: some View {
        Section("Runtime Status") {
            LabeledContent("Mode", value: model.runtimeEligibility.label)
            Text(model.runtimeEligibilityExplanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if viewModel.isLoadSafetyDisabled(for: model) {
                Label(
                    "Loading is disabled after repeated unclean attempts.",
                    systemImage: "exclamationmark.shield.fill"
                )
                .foregroundStyle(.orange)
                Button("Reset Load-Safety History") {
                    viewModel.resetLoadSafety(for: model)
                }
            }

            if model.runtimeEligibility == .experimental {
                if viewModel.hasExperimentalConsent(for: model) {
                    Button("Disable Experimental Use", role: .destructive) {
                        viewModel.revokeExperimentalConsent(for: model)
                    }
                } else {
                    Button("Review Experimental Use") {
                        viewModel.requestExperimentalConsent(for: model)
                    }
                }
            }
        }
    }

    private var importedConfigurationSection: some View {
        ImportedModelSettingsView(model: model, viewModel: viewModel)
            .id(model.id)
    }

    // MARK: - Download

    private var downloadSection: some View {
        Section("Download") {
            let status = viewModel.status(for: model)

            switch status.displayState {
            case .notDownloaded:
                if status.isRepairNeeded || ModelManagerService.isRepairNeeded(for: model) {
                    Label("This model needs repair. Downloading again will replace damaged files.", systemImage: "wrench.and.screwdriver")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                if model.allowsTextOnlyCapability {
                    capabilityDownloadButtons
                } else {
                    downloadButton
                }

            case .downloading(let progress):
                downloadingRow(progress: progress)

            case .pausing(let progress):
                transferTransitionRow(label: "Saving resume data…", progress: progress)

            case .resuming(let progress):
                transferTransitionRow(label: "Resuming…", progress: progress)

            case .paused(let progress):
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                    ProgressView(value: progress) {
                        Text("Paused")
                    } currentValueLabel: {
                        Text("\(Int(progress * 100))%")
                    }
                    .accessibilityValue("\(Int(progress * 100)) percent complete")

                    HStack(spacing: ZiroTheme.Spacing.medium) {
                        Button {
                            viewModel.resumeDownload(for: model)
                        } label: {
                            Label("Resume Download", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button(role: .destructive) {
                            viewModel.requestCancelDownload(for: model)
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                }

            case .verifying:
                HStack {
                    ProgressView()
                    Text("Verifying...")
                        .foregroundStyle(.secondary)
                }

            case .downloaded:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(status.isVisionReady ? "Text + Image Processing" : "Text Only")
                        .foregroundStyle(.green)
                }
                if model.allowsTextOnlyCapability && !status.isVisionReady {
                    Button {
                        viewModel.initiateDownload(for: model, includeOptionalProjector: true)
                    } label: {
                        Label(
                            "Add Image Processing · \(ByteCountFormatter.string(fromByteCount: model.mmprojFileSizeBytes ?? 0, countStyle: .file))",
                            systemImage: "photo.badge.plus"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .failed(let error):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Failed: \(error.localizedDescription)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    partialOutcomeSummary(for: status)
                    HStack(spacing: 12) {
                        retryButton
                        if status.partialOutcomes.contains(where: { $0.isBase }) {
                            Button {
                                viewModel.retryInvalidArtifacts(for: model)
                            } label: {
                                Label("Retry Only Invalid", systemImage: "arrow.trianglehead.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

            case .cancelled:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cancelled")
                        .foregroundStyle(.secondary)
                    downloadButton
                }
            }

            if !viewModel.isDownloaded(model) && !status.isDownloading {
                storageWarning
            }
        }
    }

    private var capabilityDownloadButtons: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
            Button {
                viewModel.initiateDownload(for: model, includeOptionalProjector: false)
            } label: {
                Label(
                    "Text Only · \(ByteCountFormatter.string(fromByteCount: model.baseFileSizeBytes, countStyle: .file))",
                    systemImage: "text.bubble"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ZiroPrimaryButtonStyle())

            Button {
                viewModel.initiateDownload(for: model, includeOptionalProjector: true)
            } label: {
                Label("Text + Image Processing · \(model.formattedSize)", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Text("Both choices reuse any verified E2B files already on this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var downloadButton: some View {
        Button {
            viewModel.initiateDownload(for: model)
        } label: {
            Label("Download \(model.formattedSize)", systemImage: "arrow.down.circle.fill")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(ZiroPrimaryButtonStyle())
        .accessibilityHint("Downloads the model for offline use")
    }

    private func transferTransitionRow(label: String, progress: Double) -> some View {
        HStack {
            ProgressView()
            VStack(alignment: .leading) {
                Text(label)
                Text("\(Int(progress * 100))% complete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func downloadingRow(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView(value: progress) {
                    Text("Downloading…")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                }
                .accessibilityLabel("Downloading \(model.displayName)")
                .accessibilityValue("\(Int(progress * 100)) percent complete")
            }

            HStack(spacing: 16) {
                Button {
                    viewModel.pauseDownload(for: model)
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    viewModel.requestCancelDownload(for: model)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func partialOutcomeSummary(for status: ModelDownloadStatus) -> some View {
        let outcomes = status.partialOutcomes
        if !outcomes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(outcomes.indices, id: \.self) { idx in
                switch outcomes[idx] {
                case .baseDownloaded:
                    Label("Base model verified", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .baseFailed(let error):
                    Label("Base: \(error.localizedDescription)", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                case .baseDownloading(let progress):
                    Label("Base downloading (\(Int(progress * 100))%)", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .basePaused(let progress):
                    Label("Base paused (\(Int(progress * 100))%)", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .projectorDownloaded:
                    Label("Projector verified", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .projectorFailed(let error):
                    Label("Projector: \(error.localizedDescription)", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                case .projectorDownloading(let progress):
                    Label("Projector downloading (\(Int(progress * 100))%)", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .projectorPaused(let progress):
                    Label("Projector paused (\(Int(progress * 100))%)", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var retryButton: some View {
        Button {
            viewModel.initiateDownload(for: model)
        } label: {
            Label("Retry Download", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var storageWarning: some View {
        let available = viewModel.downloadManager.formattedAvailableSpace()
        let required = model.formattedSize
        if !viewModel.downloadManager.hasSufficientStorage(for: model) {
            Label("Low storage: \(available) available, \(required) required", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Label("Storage: \(available) available", systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            Button(role: .destructive) {
                viewModel.requestDelete(model)
            } label: {
                Label("Delete Model", systemImage: "trash")
            }
        }
    }
}

private struct ImportedProvenanceRows: View {
    let source: HuggingFaceProvenance

    var body: some View {
        LabeledContent("Repository", value: source.repositoryID)
        LabeledContent("Pinned Revision", value: String(source.revision.prefix(12)))
        LabeledContent("Artifact", value: source.baseFilename)
        if let projector = source.projectorFilename {
            LabeledContent("Projector", value: projector)
        }
    }
}
