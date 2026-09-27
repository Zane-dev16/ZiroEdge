// ImportWizardTransfer.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Import wizard pages 5–6 (Transfer, Done): live transfer status and
// the outcome summary.

import SwiftUI

// MARK: - Step 5: Transfer

/// Live transfer status for the freshly recorded model. The download itself
/// is owned by DownloadManager; this page only reflects its state, so closing
/// the wizard never cancels the transfer.
struct TransferStepView: View {
    @ObservedObject var viewModel: ImportViewModel
    @ObservedObject var downloadManager: DownloadManager
    var onClose: () -> Void
    var onReady: () -> Void

    var body: some View {
        Group {
            if let model = viewModel.importingModel {
                let status = downloadManager.status(for: model)
                transferContent(model: model, status: status)
                    .task {
                        // Reused artifacts can verify instantly; advance without
                        // waiting for a status change.
                        if downloadManager.status(for: model).isReady { onReady() }
                    }
                    .onChange(of: status) { _, new in
                        if new.isReady { onReady() }
                    }
            } else {
                ContentUnavailableView {
                    Label("No Transfer in Progress", systemImage: "arrow.down.circle")
                } description: {
                    Text("The import was not started in this session.")
                } actions: {
                    Button("Back to Library", action: onClose)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle("Transferring")
        .navigationBarTitleDisplayMode(.inline)
        .importWizardStepHeader(.transfer)
        .importWizardBottomBar {
            Button(action: onClose) {
                Text("Back to Library")
            }
            .buttonStyle(ZiroSecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private func transferContent(model: AIModel, status: ModelDownloadStatus) -> some View {
        ScrollView {
            VStack(spacing: ZiroTheme.Spacing.large) {
                // The transfer card is the wizard's one truly floating card.
                ZiroCard() {
                    VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                        HStack(spacing: ZiroTheme.Spacing.small) {
                            Image(systemName: "arrow.down.circle")
                                .font(.title2)
                                .foregroundStyle(ZiroTheme.secondaryText)
                            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
                                Text(model.displayName)
                                    .font(ZiroType.rowTitle)
                                Text(model.formattedSize)
                                    .font(ZiroType.technical(.caption))
                                    .foregroundStyle(ZiroTheme.secondaryText)
                            }
                        }
                            statusContent(model: model, status: status)
                    }
                }
                Text("You can close this wizard — the transfer continues in the background and can be paused, resumed, or repaired from the Models page.")
                    .font(ZiroType.footnote)
                    .foregroundStyle(ZiroTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, ZiroTheme.Spacing.xLarge)
            .padding(.vertical, ZiroTheme.Spacing.large)
            .frame(maxWidth: ZiroMeasure.standard)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func statusContent(model: AIModel, status: ModelDownloadStatus) -> some View {
        switch status.displayState {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
                ProgressView(value: progress) {
                    Text("Downloading")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                        .font(ZiroType.technical(.caption))
                }
                .accessibilityLabel("Downloading \(model.displayName)")
                .accessibilityValue("\(Int(progress * 100)) percent complete")
                Text("Pause or resume anytime from the Models page.")
                    .font(ZiroType.caption)
                    .foregroundStyle(ZiroTheme.secondaryText)
            }

        case .pausing(let progress):
            HStack(spacing: ZiroTheme.Spacing.small) {
                ProgressView()
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
                    Text("Saving resume data…")
                    Text("\(Int(progress * 100))% complete")
                        .font(ZiroType.technical(.caption))
                        .foregroundStyle(ZiroTheme.secondaryText)
                }
            }

        case .resuming(let progress):
            HStack(spacing: ZiroTheme.Spacing.small) {
                ProgressView()
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
                    Text("Resuming…")
                    Text("\(Int(progress * 100))% complete")
                        .font(ZiroType.technical(.caption))
                        .foregroundStyle(ZiroTheme.secondaryText)
                }
            }

        case .paused(let progress):
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                ProgressView(value: progress) {
                    Text("Paused")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                        .font(ZiroType.technical(.caption))
                }
                Button("Manage in Library") { onClose() }
                    .buttonStyle(ZiroSecondaryButtonStyle())
            }

        case .verifying:
            HStack(spacing: ZiroTheme.Spacing.small) {
                ProgressView()
                Text("Verifying download…")
                    .foregroundStyle(ZiroTheme.secondaryText)
            }

        case .downloaded:
            Label("Transfer complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(ZiroTheme.positiveText)

        case .failed(let error):
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(ZiroTheme.dangerText)
                    .announcingOnAppear("Download failed. \(error.localizedDescription)")
                Button("Manage in Library") { onClose() }
                    .buttonStyle(ZiroSecondaryButtonStyle())
            }

        case .cancelled:
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                Label("Transfer cancelled", systemImage: "xmark.circle")
                    .foregroundStyle(ZiroTheme.secondaryText)
                Button("Manage in Library") { onClose() }
                    .buttonStyle(ZiroSecondaryButtonStyle())
            }

        case .notDownloaded:
            HStack(spacing: ZiroTheme.Spacing.small) {
                ProgressView()
                Text("Waiting for the transfer to start…")
                    .foregroundStyle(ZiroTheme.secondaryText)
            }
        }
    }
}

// MARK: - Step 6: Done

/// Outcome summary. Duplicate detection (same repository revision + artifact
/// set) lands here as well, with a pointer back to the library.
struct DoneStepView: View {
    @ObservedObject var viewModel: ImportViewModel
    var onStartChatting: (AIModel) -> Void
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: ZiroTheme.Spacing.xLarge) {
                if let existing = viewModel.existingModel, viewModel.phase == .completed {
                    duplicateContent(model: existing)
                } else if let model = viewModel.importingModel {
                    successContent(model: model)
                } else {
                    ContentUnavailableView {
                        Label("Import Finished", systemImage: "checkmark.circle")
                    } actions: {
                        Button("Back to Library", action: onClose)
                    }
                }
            }
            .padding(.horizontal, ZiroTheme.Spacing.xLarge)
            .padding(.vertical, ZiroTheme.Spacing.large)
            .frame(maxWidth: ZiroMeasure.standard)
            .frame(maxWidth: .infinity)
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle("Import Complete")
        .navigationBarTitleDisplayMode(.inline)
        .importWizardStepHeader(.done)
    }

    private func duplicateContent(model: AIModel) -> some View {
        VStack(spacing: ZiroTheme.Spacing.large) {
            ZiroHero(
                symbol: "checkmark.seal.fill",
                title: "Already Imported",
                message: "\(model.displayName) — this exact revision and artifact is already imported.",
                tint: ZiroTheme.positiveText
            )
            Button(action: onClose) {
                Label("Open in Library", systemImage: "books.vertical")
            }
            .buttonStyle(ZiroPrimaryButtonStyle())
        }
    }

    private func successContent(model: AIModel) -> some View {
        VStack(spacing: ZiroTheme.Spacing.large) {
            ZiroHero(
                symbol: "checkmark.circle.fill",
                title: "Import Complete",
                message: "\(model.displayName) is downloaded and ready on this device.",
                tint: ZiroTheme.positiveText
            )
            // One quiet spec line under the hero; the card ledger added a
            // second surface for data the hero already confirmed.
            Text("\(model.formattedSize) · \(model.modelType == .vision ? "Text + images" : "Text only")")
                .font(ZiroType.technical(.caption))
                .foregroundStyle(ZiroTheme.secondaryText)
            VStack(spacing: ZiroTheme.Spacing.small) {
                Button { onStartChatting(model) } label: {
                    Label("Start Chatting", systemImage: "bubble.left.and.text.bubble.right")
                        .flipsForRightToLeft(true)
                }
                .buttonStyle(ZiroPrimaryButtonStyle())

                Button("Add to Library", action: onClose)
                    .buttonStyle(ZiroSecondaryButtonStyle())
            }
        }
    }
}
