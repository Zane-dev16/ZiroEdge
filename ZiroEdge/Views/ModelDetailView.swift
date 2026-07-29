// ModelDetailView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Detail view for a single model — shows metadata, download controls, and storage.

import SwiftUI

struct ModelDetailView: View {
    let model: AIModel
    @ObservedObject var viewModel: ModelsViewModel
    @State private var showingUpdateImport = false
    @State private var updateStatusMessage: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                    Image(systemName: model.modelType == .vision ? "eye.circle.fill" : "text.bubble.fill")
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
        .sheet(isPresented: $showingUpdateImport) {
            ImportView(
                downloadManager: viewModel.downloadManager,
                repositoryInput: model.huggingFaceProvenance?.repositoryID ?? ""
            )
        }
        .alert("Load Safety", isPresented: $viewModel.showingSafetyResetResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.safetyResetMessage)
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        Section("Model Info") {
            LabeledContent("Name", value: model.displayName)
            LabeledContent("Size", value: model.formattedSize)
            LabeledContent("Quantization", value: model.quantization)
            LabeledContent("Type", value: model.modelType == .text ? "Text" : "Vision")
            LabeledContent("License", value: model.license.name)
            if let source = model.huggingFaceProvenance {
                LabeledContent("Repository", value: source.repositoryID)
                LabeledContent("Pinned Revision", value: String(source.revision.prefix(12)))
                LabeledContent("Artifact", value: source.baseFilename)
                if let projector = source.projectorFilename {
                    LabeledContent("Projector", value: projector)
                }
            }
            if viewModel.isDownloaded(model) {
                LabeledContent("Storage Used", value: viewModel.diskUsage(for: model))
            }
        }
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
                downloadButton

            case .downloading(let progress):
                downloadingRow(progress: progress)

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
                            viewModel.cancelDownload(for: model)
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
                    Text("Downloaded")
                        .foregroundStyle(.green)
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
                    retryButton
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
                    viewModel.cancelDownload(for: model)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
