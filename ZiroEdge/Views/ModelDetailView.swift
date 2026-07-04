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
            metadataSection
            downloadSection
            if viewModel.isDownloaded(model) {
                actionsSection
            }
        }
        .navigationTitle(model.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        Section("Model Info") {
            LabeledContent("Name", value: model.displayName)
            LabeledContent("Size", value: model.formattedSize)
            LabeledContent("Quantization", value: model.quantization)
            LabeledContent("Type", value: model.modelType == .text ? "Text" : "Vision")
            LabeledContent("License", value: model.license.name)
            if viewModel.isDownloaded(model) {
                LabeledContent("Storage Used", value: viewModel.diskUsage(for: model))
            }
        }
    }

    // MARK: - Download

    private var downloadSection: some View {
        Section("Download") {
            let status = viewModel.status(for: model)

            switch status.baseState {
            case .notDownloaded:
                downloadButton

            case .downloading(let progress):
                downloadingRow(progress: progress)

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
        .buttonStyle(.borderedProminent)
    }

    private func downloadingRow(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView(value: progress) {
                    Text("Downloading...")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                }
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
