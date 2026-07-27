// ModelsView.swift
// ZiroEdge — Privacy-first local AI assistant

import SwiftUI

struct ModelsView: View {
    @ObservedObject var viewModel: ModelsViewModel

    var body: some View {
        List {
            if !viewModel.hasInstalledModels { introductionSection }
            if viewModel.hasInstalledModels { installedSection }
            availableSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.large)
        .alert("Review Download", isPresented: $viewModel.showingDownloadWarning) {
            if viewModel.canConfirmPendingDownload {
                Button("Download") { viewModel.confirmPendingDownload() }
            }
            Button("Cancel", role: .cancel) { viewModel.cancelPendingDownload() }
        } message: {
            Text(viewModel.pendingDownloadWarningMessage)
        }
        .alert("Enable Experimental Runtime?", isPresented: $viewModel.showingExperimentalConsent) {
            Button("Enable Experimental Use") { viewModel.confirmExperimentalConsent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This profile has measured load evidence but has not passed the full physical workload. ZiroEdge will still enforce its measured admission floor and reserve.")
        }
        .confirmationDialog("Delete Model", isPresented: $viewModel.showingDeleteConfirmation) {
            Button("Delete", role: .destructive) { Task { await viewModel.confirmDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \(viewModel.pendingDeleteModel?.displayName ?? "this model")? You can download it again later.")
        }
    }

    private var introductionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                Label("Runs entirely on your device", systemImage: "lock.shield")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                Text("Download one model to begin. Larger models can be more capable, while smaller models load faster and use less memory.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, ZiroTheme.Spacing.small)
        }
    }

    private var installedSection: some View {
        Section("On This Device") {
            ForEach(viewModel.allModels.filter { viewModel.isDownloaded($0) }) { model in
                NavigationLink { ModelDetailView(model: model, viewModel: viewModel) } label: {
                    ModelRow(
                        model: model,
                        subtitle: "\(model.runtimeEligibility.label) · \(model.quantization) · \(viewModel.diskUsage(for: model)) used",
                        status: .installed
                    )
                }
            }
        }
    }

    private var availableSection: some View {
        Section(viewModel.hasInstalledModels ? "Available to Download" : "Choose a Model") {
            ForEach(viewModel.allModels.filter { !viewModel.isDownloaded($0) }) { model in
                HStack(spacing: ZiroTheme.Spacing.small) {
                    NavigationLink { ModelDetailView(model: model, viewModel: viewModel) } label: {
                        modelRow(model)
                    }
                    if viewModel.status(for: model).isDownloading {
                        Button { viewModel.cancelDownload(for: model) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Cancel \(model.displayName) download")
                    }
                }
            }
        }
    }

    private func modelRow(_ model: AIModel) -> some View {
        let status = viewModel.status(for: model)
        return HStack(spacing: ZiroTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
                HStack(spacing: ZiroTheme.Spacing.small) {
                    Text(model.displayName).font(.headline)
                    if model.modelType == .vision {
                        Text("VISION")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(.purple)
                            .background(Color.purple.opacity(0.1), in: Capsule())
                    }
                }
                Text(model.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: ZiroTheme.Spacing.small) {
                    Text(model.runtimeEligibility.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(runtimeTint(model.runtimeEligibility))
                    Text("\(model.formattedSize) · \(model.quantization)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: ZiroTheme.Spacing.small)
            downloadIndicator(model, status: status)
        }
        .padding(.vertical, ZiroTheme.Spacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.displayName), \(model.description), \(model.formattedSize), \(statusAccessibilityLabel(status))")
    }

    @ViewBuilder
    private func downloadIndicator(_ model: AIModel, status: ModelDownloadStatus) -> some View {
        switch status.displayState {
        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: ZiroTheme.Spacing.xSmall) {
                ProgressView(value: progress).frame(width: 64)
                Text("\(Int(progress * 100))%")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityHidden(true)
        case .paused(let progress):
            Label("\(Int(progress * 100))%", systemImage: "pause.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .verifying:
            VStack(spacing: ZiroTheme.Spacing.xSmall) {
                ProgressView()
                Text("Verifying").font(.caption2).foregroundStyle(.secondary)
            }
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                .accessibilityLabel("Download failed")
        default:
            if status.isRepairNeeded || ModelManagerService.isRepairNeeded(for: model) {
                Text("Repair")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Repair \(model.displayName)")
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Download \(model.displayName)")
            }
        }
    }

    private func runtimeTint(_ eligibility: RuntimeEligibility) -> Color {
        switch eligibility {
        case .validated: .green
        case .experimental: .orange
        case .unavailable: .secondary
        }
    }

    private func statusAccessibilityLabel(_ status: ModelDownloadStatus) -> String {
        switch status.displayState {
        case .downloading(let progress): return "downloading, \(Int(progress * 100)) percent complete"
        case .paused(let progress): return "paused, \(Int(progress * 100)) percent complete"
        case .verifying: return "verifying download"
        case .failed: return "download failed"
        case .cancelled: return "download cancelled"
        case .downloaded: return "installed"
        case .notDownloaded: return "available to download"
        }
    }
}

private struct ModelRow: View {
    enum Status { case installed }
    let model: AIModel
    let subtitle: String
    let status: Status

    var body: some View {
        HStack(spacing: ZiroTheme.Spacing.medium) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3).foregroundStyle(.green).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
                Text(model.displayName).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, ZiroTheme.Spacing.xSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.displayName), installed, \(subtitle)")
    }
}
