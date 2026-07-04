// ModelsView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Models page — browse, download, and manage on-device AI models.

import SwiftUI

struct ModelsView: View {
    @ObservedObject var viewModel: ModelsViewModel

    var body: some View {
        List {
            if viewModel.hasInstalledModels {
                installedSection
            }

            availableSection
        }
        .overlay {
            if !viewModel.hasInstalledModels && viewModel.allModels.allSatisfy({ !viewModel.status(for: $0).isDownloading }) {
                emptyState
            }
        }
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.large)
        .alert("Cellular Data", isPresented: $viewModel.showingCellularWarning) {
            Button("Download Anyway") {
                viewModel.confirmCellularDownload()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelPendingDownload()
            }
        } message: {
            Text("You're on cellular data. Model downloads can be large (\(viewModel.pendingDownloadModel?.formattedSize ?? "")). Continue?")
        }
        .alert("Low Storage", isPresented: $viewModel.showingStorageWarning) {
            Button("Download Anyway") {
                viewModel.confirmStorageDownload()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelPendingDownload()
            }
        } message: {
            let model = viewModel.pendingDownloadModel
            Text("This model requires \(model?.formattedSize ?? "") but only \(viewModel.downloadManager.formattedAvailableSpace()) is available. The download may fail.")
        }
        .confirmationDialog("Delete Model", isPresented: $viewModel.showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                viewModel.confirmDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete \(viewModel.pendingDeleteModel?.displayName ?? "this model")? You'll need to download it again.")
        }
    }

    // MARK: - Installed Models Section

    private var installedSection: some View {
        Section("Installed") {
            ForEach(viewModel.allModels.filter { viewModel.isDownloaded($0) }) { model in
                NavigationLink {
                    ModelDetailView(model: model, viewModel: viewModel)
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.headline)
                            Text("\(model.quantization) · \(viewModel.diskUsage(for: model)) used")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Available Models Section

    private var availableSection: some View {
        Section(viewModel.hasInstalledModels ? "Available" : "All Models") {
            ForEach(viewModel.allModels.filter { !viewModel.isDownloaded($0) }) { model in
                NavigationLink {
                    ModelDetailView(model: model, viewModel: viewModel)
                } label: {
                    modelRow(model)
                }
            }
        }
    }

    private func modelRow(_ model: AIModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.headline)
                Text("\(model.formattedSize) · \(model.quantization)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            downloadIndicator(model)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func downloadIndicator(_ model: AIModel) -> some View {
        let status = viewModel.status(for: model)

        switch status.baseState {
        case .downloading(let progress):
            VStack(spacing: 4) {
                ProgressView(value: progress)
                    .frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .verifying:
            ProgressView()
                .frame(width: 80)
        default:
            Button {
                viewModel.initiateDownload(for: model)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)

            Text("No Models Installed")
                .font(.title2.bold())

            Text("Download a model to start chatting with your private AI assistant.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if let firstModel = viewModel.allModels.first {
                Button {
                    viewModel.initiateDownload(for: firstModel)
                } label: {
                    Label("Download \(firstModel.displayName)", systemImage: "arrow.down.circle.fill")
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
