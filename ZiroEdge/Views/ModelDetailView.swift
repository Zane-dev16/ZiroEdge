// ModelDetailView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Detail view for a single model. The landing page is the Overview:
// identity, the primary action (download / start chatting) with a compact
// transfer-status link, and a runtime strip. Everything else is a dedicated
// child page kept one push deep — Generation Settings (imported models),
// Safety & Runtime, and Storage & Provenance (live download management:
// progress, pause/resume, verify, cancel). The staged-update flow lives
// in UpdateFlowSheet, presented from Generation Settings, and reuses the
// import wizard's shared pieces (VariantPickerView, PreflightCard,
// RAMAssessmentCard, LicenseRow).

import SwiftUI

struct ModelDetailView: View {
    let model: AIModel
    @ObservedObject var viewModel: ModelsViewModel
    /// Pops back to the chat root and selects this model (offered for
    /// downloaded models). Default no-op keeps previews compiling.
    var onStartChatting: (AIModel) -> Void = { _ in }

    var body: some View {
        List {
            identitySection
            primaryActionSection
            runtimeSection
            manageSection
        }
        // Warm paper canvas with raised card rows (design spec §3.1).
        .scrollContentBackground(.hidden)
        .background(ZiroTheme.pageBackground.ignoresSafeArea())
        .listRowBackground(ZiroTheme.raisedBackground)
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

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                HStack(spacing: ZiroTheme.Spacing.medium) {
                    Image(systemName: modelIconName)
                        .font(.largeTitle)
                        .foregroundStyle(ZiroTheme.accent)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
                        Text(model.displayName)
                            .font(ZiroType.heading)
                        // Engineering data in the technical voice.
                        Text("\(model.formattedSize) · \(model.quantization)")
                            .font(ZiroType.technical(.subheadline))
                            .foregroundStyle(ZiroTheme.secondaryText)
                    }
                }
                Text(model.description)
                    .font(ZiroType.body)
                    .foregroundStyle(ZiroTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, ZiroTheme.Spacing.small)
        }
    }

    /// Token tint for the runtime-eligibility voice, shared by the Overview
    /// runtime strip. Semantic tokens keep caption-size text AA in both modes.
    private func eligibilityTint(_ eligibility: RuntimeEligibility) -> Color {
        switch eligibility {
        case .validated: ZiroTheme.positiveText
        case .experimental: ZiroTheme.warningText
        case .unavailable: ZiroTheme.secondaryText
        }
    }

    private var modelIconName: String {
        guard model.modelType == .vision else { return "text.bubble.fill" }
        return viewModel.status(for: model).isVisionReady
            ? "eye.circle.fill"
            : "eye.slash.circle.fill"
    }

    // MARK: - Primary Action (download / ready)

    private var primaryActionSection: some View {
        Section {
            primaryActionContent
        }
    }

    @ViewBuilder
    private var primaryActionContent: some View {
        let status = viewModel.status(for: model)

        switch status.displayState {
        case .notDownloaded:
            if status.isRepairNeeded || ModelManagerService.isRepairNeeded(for: model) {
                Label("This model needs repair. Downloading again will replace damaged files.", systemImage: "wrench.and.screwdriver")
                    .font(.subheadline)
                    .foregroundStyle(ZiroTheme.warningText)
            }
            if model.allowsTextOnlyCapability {
                capabilityDownloadButtons
            } else {
                downloadButton
            }

        case .downloading(let progress):
            transferManagementLink(label: "Downloading… \(Int(progress * 100))%", symbol: "arrow.down.circle")

        case .pausing:
            transferManagementLink(label: "Saving resume data…", symbol: "arrow.down.circle")

        case .resuming:
            transferManagementLink(label: "Resuming…", symbol: "arrow.down.circle")

        case .paused(let progress):
            transferManagementLink(label: "Paused · \(Int(progress * 100))%", symbol: "pause.circle")

        case .verifying:
            transferManagementLink(label: "Verifying...", symbol: "checkmark.seal")

        case .downloaded:
            readyContent(status)

        case .failed(let error):
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ZiroTheme.dangerText)
                    Text("Failed: \(error.localizedDescription)")
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.dangerText)
                }
                .announcingOnAppear("Download failed. \(error.localizedDescription)")
                partialOutcomeSummary(for: status)
                HStack(spacing: ZiroTheme.Spacing.medium) {
                    retryButton
                    if status.partialOutcomes.contains(where: { $0.isBase }) {
                        Button {
                            viewModel.retryInvalidArtifacts(for: model)
                        } label: {
                            Label("Retry Only Invalid", systemImage: "arrow.trianglehead.clockwise")
                        }
                        .buttonStyle(ZiroSecondaryButtonStyle())
                    }
                }
            }

        case .cancelled:
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                Text("Cancelled")
                    .font(ZiroType.body)
                    .foregroundStyle(ZiroTheme.secondaryText)
                downloadButton
            }
        }

        if !viewModel.isDownloaded(model) && !status.isDownloading {
            storageWarning
        }
    }

    private func readyContent(_ status: ModelDownloadStatus) -> some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(ZiroTheme.positiveText)
            Text(status.isVisionReady ? "Text + Image Processing" : "Text Only")
                .font(ZiroType.caption)
                .foregroundStyle(ZiroTheme.secondaryText)

            Button { onStartChatting(model) } label: {
                Label("Start Chatting", systemImage: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(ZiroPrimaryButtonStyle())

            if model.allowsTextOnlyCapability && !status.isVisionReady {
                Button {
                    viewModel.initiateDownload(for: model, includeOptionalProjector: true)
                } label: {
                    Label(
                        "Add Image Processing · \(StorageByteFormatter.string(fromByteCount: model.mmprojFileSizeBytes ?? 0))",
                        systemImage: "photo.badge.plus"
                    )
                }
                .buttonStyle(ZiroSecondaryButtonStyle())
            }
        }
    }

    private var capabilityDownloadButtons: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
            Button {
                viewModel.initiateDownload(for: model, includeOptionalProjector: false)
            } label: {
                Label(
                    "Text Only · \(StorageByteFormatter.string(fromByteCount: model.baseFileSizeBytes))",
                    systemImage: "text.bubble"
                )
            }
            .buttonStyle(ZiroPrimaryButtonStyle())

            Button {
                viewModel.initiateDownload(for: model, includeOptionalProjector: true)
            } label: {
                Label("Text + Image Processing · \(model.formattedSize)", systemImage: "photo")
            }
            .buttonStyle(ZiroSecondaryButtonStyle())
            Text("Both choices reuse any verified E2B files already on this device.")
                .font(ZiroType.caption)
                .foregroundStyle(ZiroTheme.secondaryText)
        }
    }

    private var downloadButton: some View {
        Button {
            viewModel.initiateDownload(for: model)
        } label: {
            Label("Download \(model.formattedSize)", systemImage: "arrow.down.circle.fill")
        }
        .buttonStyle(ZiroPrimaryButtonStyle())
        .accessibilityHint("Downloads the model for offline use")
    }

    /// Compact transfer-status affordance for the Overview. Live transfer
    /// management (progress, pause/resume, verify, cancel) lives on the
    /// Storage & Provenance page (plan §D: one concern per page).
    private func transferManagementLink(label: String, symbol: String) -> some View {
        NavigationLink {
            StorageProvenancePage(model: model, viewModel: viewModel)
        } label: {
            Label(label, systemImage: symbol)
        }
    }

    @ViewBuilder
    private func partialOutcomeSummary(for status: ModelDownloadStatus) -> some View {
        let outcomes = status.partialOutcomes
        if !outcomes.isEmpty {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
                ForEach(outcomes.indices, id: \.self) { idx in
                switch outcomes[idx] {
                case .baseDownloaded:
                    Label("Base model verified", systemImage: "checkmark.circle.fill")
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.positiveText)
                case .baseFailed(let error):
                    Label("Base: \(error.localizedDescription)", systemImage: "xmark.circle.fill")
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.dangerText)
                case .baseDownloading(let progress):
                    Label("Base downloading (\(Int(progress * 100))%)", systemImage: "arrow.down.circle")
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.secondaryText)
                case .basePaused(let progress):
                    Label("Base paused (\(Int(progress * 100))%)", systemImage: "pause.circle")
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.secondaryText)
                case .projectorDownloaded:
                    Label("Projector verified", systemImage: "checkmark.circle.fill")
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.positiveText)
                case .projectorFailed(let error):
                    Label("Projector: \(error.localizedDescription)", systemImage: "xmark.circle.fill")
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.dangerText)
                case .projectorDownloading(let progress):
                    Label("Projector downloading (\(Int(progress * 100))%)", systemImage: "arrow.down.circle")
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.secondaryText)
                case .projectorPaused(let progress):
                    Label("Projector paused (\(Int(progress * 100))%)", systemImage: "pause.circle")
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.secondaryText)
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
        .buttonStyle(ZiroSecondaryButtonStyle())
    }

    @ViewBuilder
    private var storageWarning: some View {
        let available = viewModel.downloadManager.formattedAvailableSpace()
        let required = model.formattedSize
        if !viewModel.downloadManager.hasSufficientStorage(for: model) {
            Label("Low storage: \(available) available, \(required) required", systemImage: "exclamationmark.triangle")
                .font(ZiroType.caption)
                .foregroundStyle(ZiroTheme.warningText)
        } else {
            Label("Storage: \(available) available", systemImage: "internaldrive")
                .font(ZiroType.caption)
                .foregroundStyle(ZiroTheme.secondaryText)
        }
    }

    // MARK: - Runtime Strip

    private var runtimeSection: some View {
        Section("Runtime Status") {
            LabeledContent("Mode") {
                Text(model.runtimeEligibility.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(eligibilityTint(model.runtimeEligibility))
            }
            Text(model.runtimeEligibilityExplanation)
                .font(ZiroType.supporting)
                .foregroundStyle(ZiroTheme.secondaryText)
        }
    }

    // MARK: - Child Pages

    private var manageSection: some View {
        Section("Manage") {
            if model.isImported {
                NavigationLink {
                    GenerationSettingsPage(model: model, viewModel: viewModel)
                } label: {
                    Label("Generation Settings", systemImage: "slider.horizontal.3")
                }
            }
            NavigationLink {
                SafetyRuntimePage(model: model, viewModel: viewModel)
            } label: {
                Label("Safety & Runtime", systemImage: "shield.lefthalf.filled")
            }
            NavigationLink {
                StorageProvenancePage(model: model, viewModel: viewModel)
            } label: {
                Label("Storage & Provenance", systemImage: "internaldrive")
            }
        }
    }
}

// MARK: - Generation Settings Page

/// Bounded chat parameters for imported models plus the staged-update entry
/// point. The parameter controls themselves live in ImportedModelSettingsView;
/// update staging lives in UpdateFlowSheet.
private struct GenerationSettingsPage: View {
    let model: AIModel
    @ObservedObject var viewModel: ModelsViewModel
    @StateObject private var updateCoordinator: ImportedModelUpdateCoordinator
    @State private var showingUpdateFlow = false

    init(model: AIModel, viewModel: ModelsViewModel) {
        self.model = model
        self.viewModel = viewModel
        _updateCoordinator = StateObject(wrappedValue: ImportedModelUpdateCoordinator(
            downloadManager: viewModel.downloadManager,
            lifecycleManager: viewModel.lifecycleManager
        ))
    }

    var body: some View {
        List {
            ImportedModelSettingsView(model: model, viewModel: viewModel)
            Section("Update") {
                Button {
                    showingUpdateFlow = true
                } label: {
                    Label(
                        updateCoordinator.hasStagedUpdate(modelID: model.id)
                            ? "Review Staged Update"
                            : "Check for Update",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ZiroTheme.pageBackground.ignoresSafeArea())
        .listRowBackground(ZiroTheme.raisedBackground)
        .navigationTitle("Generation Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingUpdateFlow) {
            UpdateFlowSheet(model: model, coordinator: updateCoordinator)
        }
    }
}

// MARK: - Safety & Runtime Page

/// Load-safety state, experimental-runtime consent, and the locked
/// app-managed runtime parameters (moved out of the old settings panel so
/// the sandbox is documented in one place).
private struct SafetyRuntimePage: View {
    let model: AIModel
    @ObservedObject var viewModel: ModelsViewModel

    var body: some View {
        List {
            Section("Load Safety") {
                if viewModel.isLoadSafetyDisabled(for: model) {
                    Label(
                        "Loading is disabled after repeated unclean attempts.",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .foregroundStyle(ZiroTheme.warningText)
                    Button("Reset Load-Safety History") {
                        viewModel.resetLoadSafety(for: model)
                    }
                } else {
                    Label(
                        "Load-safety monitoring is active for this model.",
                        systemImage: "checkmark.shield"
                    )
                    .foregroundStyle(ZiroTheme.secondaryText)
                }
            }

            if model.runtimeEligibility == .experimental {
                Section("Experimental Runtime") {
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

            Section {
                lockedParameters
            } header: {
                Text("App-Managed Parameters")
            } footer: {
                Text("These parameters are controlled by ZiroEdge for safety and cannot be overridden.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(ZiroTheme.pageBackground.ignoresSafeArea())
        .listRowBackground(ZiroTheme.raisedBackground)
        .navigationTitle("Safety & Runtime")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var lockedParameters: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            Text("Non-adjustable runtime parameters:")
                .font(ZiroType.caption.weight(.medium))
                .foregroundStyle(ZiroTheme.secondaryText)

            // Locked values are engineering data — technical voice.
            lockedRow("Batch size", value: "\(model.config.batchSize)")
            lockedRow("Micro-batch", value: "\(model.config.microBatchSize)")
            lockedRow("Threads", value: "\(model.config.threadCount)")
            lockedRow("GPU layers", value: "\(model.config.gpuLayers)")
            lockedRow("mmap", value: model.config.useMmap ? "On" : "Off")
            lockedRow("KV-cache (f16)", value: model.config.f16KV ? "On" : "Off")
        }
    }

    private func lockedRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(ZiroType.caption)
                .foregroundStyle(ZiroTheme.tertiaryText)
            Spacer()
            Text(value)
                .font(ZiroType.technical(.caption))
                .foregroundStyle(ZiroTheme.tertiaryText)
            Image(systemName: "lock.fill")
                .font(ZiroType.micro)
                .foregroundStyle(ZiroTheme.tertiaryText)
        }
    }
}

// MARK: - Storage & Provenance Page

/// Live download management (progress / pause / resume / verify / cancel),
/// where the model came from, what it uses on disk, and the destructive
/// management zone (delete / forget import).
private struct StorageProvenancePage: View {
    let model: AIModel
    @ObservedObject var viewModel: ModelsViewModel

    var body: some View {
        List {
            transferSection

            Section("Model Info") {
                // Sizes and quantization are engineering data — technical voice.
                LabeledContent("Size") {
                    Text(model.formattedSize)
                        .font(ZiroType.technical(.footnote))
                }
                LabeledContent("Quantization") {
                    Text(model.quantization)
                        .font(ZiroType.technical(.footnote))
                }
                LabeledContent("Type", value: modelTypeLabel)
                LabeledContent("License", value: model.license.name)
                if let source = model.huggingFaceProvenance {
                    ImportedProvenanceRows(source: source)
                }
            }

            if viewModel.isDownloaded(model) {
                Section("On This Device") {
                    LabeledContent("Storage Used") {
                        Text(viewModel.diskUsage(for: model))
                            .font(ZiroType.technical(.footnote))
                    }
                }
            }

            destructiveSection
        }
        .scrollContentBackground(.hidden)
        .background(ZiroTheme.pageBackground.ignoresSafeArea())
        .listRowBackground(ZiroTheme.raisedBackground)
        .navigationTitle("Storage & Provenance")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Live Transfer

    /// Active-transfer management rows (plan §D): progress with pause/cancel,
    /// resume, and the verify transition. Hidden when nothing is in flight.
    @ViewBuilder
    private var transferSection: some View {
        switch viewModel.status(for: model).displayState {
        case .downloading(let progress):
            Section("Download") {
                downloadingRow(progress: progress)
            }
        case .pausing(let progress):
            Section("Download") {
                transferTransitionRow(label: "Saving resume data…", progress: progress)
            }
        case .resuming(let progress):
            Section("Download") {
                transferTransitionRow(label: "Resuming…", progress: progress)
            }
        case .paused(let progress):
            Section("Download") {
                pausedRow(progress: progress)
            }
        case .verifying:
            Section("Download") {
                HStack {
                    ProgressView()
                    Text("Verifying...")
                        .foregroundStyle(ZiroTheme.secondaryText)
                }
            }
        case .failed(let error):
            Section("Download") {
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                    Label("Failed: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ZiroTheme.dangerText)
                        .announcingOnAppear("Download failed. \(error.localizedDescription)")
                    Button {
                        viewModel.initiateDownload(for: model)
                    } label: {
                        Label("Retry Download", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ZiroSecondaryButtonStyle())
                }
            }
        default:
            EmptyView()
        }
    }

    private func transferTransitionRow(label: String, progress: Double) -> some View {
        HStack {
            ProgressView()
            VStack(alignment: .leading) {
                Text(label)
                Text("\(Int(progress * 100))% complete")
                    .font(ZiroType.technical(.caption))
                    .foregroundStyle(ZiroTheme.secondaryText)
            }
        }
    }

    private func pausedRow(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
            ProgressView(value: progress) {
                Text("Paused")
            } currentValueLabel: {
                Text("\(Int(progress * 100))%")
                    .font(ZiroType.technical(.caption))
            }
            .accessibilityValue("\(Int(progress * 100)) percent complete")

            HStack(spacing: ZiroTheme.Spacing.medium) {
                Button {
                    viewModel.resumeDownload(for: model)
                } label: {
                    Label("Resume Download", systemImage: "play.fill")
                }
                .buttonStyle(ZiroPrimaryButtonStyle())

                Button(role: .destructive) {
                    viewModel.requestCancelDownload(for: model)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(ZiroDestructiveButtonStyle())
            }
        }
    }

    private func downloadingRow(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
            ProgressView(value: progress) {
                Text("Downloading…")
            } currentValueLabel: {
                Text("\(Int(progress * 100))%")
                    .font(ZiroType.technical(.caption))
            }
            .accessibilityLabel("Downloading \(model.displayName)")
            .accessibilityValue("\(Int(progress * 100)) percent complete")

            HStack(spacing: ZiroTheme.Spacing.large) {
                Button {
                    viewModel.pauseDownload(for: model)
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(ZiroSecondaryButtonStyle())

                Button(role: .destructive) {
                    viewModel.requestCancelDownload(for: model)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(ZiroDestructiveButtonStyle())
            }
        }
    }

    private var modelTypeLabel: String {
        guard model.modelType == .vision else { return "Text" }
        return viewModel.status(for: model).isVisionReady
            ? "Vision"
            : "Vision pair incomplete"
    }

    @ViewBuilder
    private var destructiveSection: some View {
        if viewModel.isDownloaded(model) {
            Section {
                Button(role: .destructive) {
                    viewModel.requestDelete(model)
                } label: {
                    Label("Delete Model", systemImage: "trash")
                }
            } footer: {
                Text("Deleting removes the model files from this device. You can download it again later.")
            }
        } else if viewModel.canForgetImport(model) {
            Section {
                Button(role: .destructive) {
                    viewModel.requestDelete(model)
                } label: {
                    Label("Forget Import", systemImage: "trash")
                }
            } footer: {
                Text("Forgetting removes this import record and its unreferenced partial transfer data.")
            }
        }
    }
}

// MARK: - Provenance Rows

private struct ImportedProvenanceRows: View {
    let source: HuggingFaceProvenance

    var body: some View {
        // Provenance values are pinned engineering identifiers — technical voice.
        LabeledContent("Repository") {
            Text(source.repositoryID)
                .font(ZiroType.technical(.footnote))
        }
        LabeledContent("Pinned Revision") {
            Text(String(source.revision.prefix(12)))
                .font(ZiroType.technical(.footnote))
        }
        LabeledContent("Artifact") {
            Text(source.baseFilename)
                .font(ZiroType.technical(.footnote))
        }
        if let projector = source.projectorFilename {
            LabeledContent("Projector") {
                Text(projector)
                    .font(ZiroType.technical(.footnote))
            }
        }
    }
}
