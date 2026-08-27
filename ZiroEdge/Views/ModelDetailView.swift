// ModelDetailView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Detail view for a single model. The landing page is the Overview:
// identity, the primary action (download / start chatting) with live
// transfer status, and a runtime strip. Everything else is a dedicated
// child page kept one push deep — Generation Settings (imported models),
// Safety & Runtime, and Storage & Provenance. The staged-update flow lives
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
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
                        Text(model.displayName)
                            .font(.title3.weight(.semibold))
                        Text("\(model.formattedSize) · \(model.quantization)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(model.description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, ZiroTheme.Spacing.small)
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
            downloadingRow(progress: progress)

        case .pausing(let progress):
            transferTransitionRow(label: "Saving resume data…", progress: progress)

        case .resuming(let progress):
            transferTransitionRow(label: "Resuming…", progress: progress)

        case .paused(let progress):
            pausedRow(progress: progress)

        case .verifying:
            HStack {
                ProgressView()
                Text("Verifying...")
                    .foregroundStyle(.secondary)
            }

        case .downloaded:
            readyContent(status)

        case .failed(let error):
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ZiroTheme.warningText)
                    Text("Failed: \(error.localizedDescription)")
                        .font(.caption)
                        .foregroundStyle(ZiroTheme.warningText)
                }
                partialOutcomeSummary(for: status)
                HStack(spacing: ZiroTheme.Spacing.medium) {
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
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                Text("Cancelled")
                    .foregroundStyle(.secondary)
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
                .font(.caption)
                .foregroundStyle(.secondary)

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
                .buttonStyle(.bordered)
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
                .padding(.vertical, ZiroTheme.Spacing.xSmall)
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

    private func pausedRow(progress: Double) -> some View {
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
    }

    private func downloadingRow(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
            ProgressView(value: progress) {
                Text("Downloading…")
            } currentValueLabel: {
                Text("\(Int(progress * 100))%")
            }
            .accessibilityLabel("Downloading \(model.displayName)")
            .accessibilityValue("\(Int(progress * 100)) percent complete")

            HStack(spacing: ZiroTheme.Spacing.large) {
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
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
                ForEach(outcomes.indices, id: \.self) { idx in
                switch outcomes[idx] {
                case .baseDownloaded:
                    Label("Base model verified", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(ZiroTheme.positiveText)
                case .baseFailed(let error):
                    Label("Base: \(error.localizedDescription)", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(ZiroTheme.warningText)
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
                        .foregroundStyle(ZiroTheme.positiveText)
                case .projectorFailed(let error):
                    Label("Projector: \(error.localizedDescription)", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(ZiroTheme.warningText)
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
                .foregroundStyle(ZiroTheme.warningText)
        } else {
            Label("Storage: \(available) available", systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Runtime Strip

    private var runtimeSection: some View {
        Section("Runtime Status") {
            LabeledContent("Mode", value: model.runtimeEligibility.label)
            Text(model.runtimeEligibilityExplanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
        .navigationTitle("Safety & Runtime")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var lockedParameters: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            Text("Non-adjustable runtime parameters:")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

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
}

// MARK: - Storage & Provenance Page

/// Where the model came from, what it uses on disk, and the destructive
/// management zone (delete / forget import).
private struct StorageProvenancePage: View {
    let model: AIModel
    @ObservedObject var viewModel: ModelsViewModel

    var body: some View {
        List {
            Section("Model Info") {
                LabeledContent("Size", value: model.formattedSize)
                LabeledContent("Quantization", value: model.quantization)
                LabeledContent("Type", value: modelTypeLabel)
                LabeledContent("License", value: model.license.name)
                if let source = model.huggingFaceProvenance {
                    ImportedProvenanceRows(source: source)
                }
            }

            if viewModel.isDownloaded(model) {
                Section("On This Device") {
                    LabeledContent("Storage Used", value: viewModel.diskUsage(for: model))
                }
            }

            destructiveSection
        }
        .navigationTitle("Storage & Provenance")
        .navigationBarTitleDisplayMode(.inline)
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

// MARK: - Update Flow Sheet

/// Staged-update flow for imported models, extracted from the old settings
/// panel. Check → review (variant, vision pair, storage, RAM, license) →
/// stage → finish/verify, driven entirely by the unchanged
/// ImportedModelUpdateCoordinator API.
private struct UpdateFlowSheet: View {
    let model: AIModel
    @ObservedObject var coordinator: ImportedModelUpdateCoordinator

    @Environment(\.dismiss) private var dismiss

    @State private var isChecking = false
    @State private var checkFailed = false
    @State private var upToDate = false
    @State private var availableUpdate: HFRepositoryReview?
    @State private var statusMessage: String?

    @State private var selectedBase: HFArtifact?
    @State private var updateLicenseConfirmed = false
    @State private var updatePairConfirmed = false
    @State private var updateRAMRiskAccepted = false
    @State private var showsCancelStagedConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if coordinator.hasStagedUpdate(modelID: model.id) {
                    stagedSection
                } else if isChecking {
                    Section {
                        HStack(spacing: ZiroTheme.Spacing.medium) {
                            ProgressView()
                            Text("Checking for updates…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let review = availableUpdate {
                    reviewSections(review)
                } else {
                    outcomeSection
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Check for Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await runCheckIfIdle() }
        }
    }

    // MARK: Check

    @MainActor
    private func runCheckIfIdle() async {
        guard !coordinator.hasStagedUpdate(modelID: model.id) else { return }
        isChecking = true
        checkFailed = false
        upToDate = false
        availableUpdate = nil
        // Every check can resolve a different revision/artifact set (this is
        // the only place availableUpdate is assigned, so resetting here also
        // covers any revision change). The prior revision's license
        // acceptance, vision-pair confirmation, and RAM-risk acknowledgment
        // were given for that earlier artifact set; carrying them over would
        // let canStageUpdate pass without the user reviewing the new license
        // or risk (same leak class the wizard's inspect() reset fixed).
        selectedBase = nil
        updateLicenseConfirmed = false
        updatePairConfirmed = false
        updateRAMRiskAccepted = false
        statusMessage = nil
        do {
            switch try await coordinator.checkForUpdate(model: model) {
            case .upToDate:
                upToDate = true
            case .review(let review):
                availableUpdate = review
            }
        } catch {
            checkFailed = true
            statusMessage = error.localizedDescription
        }
        isChecking = false
    }

    /// Up-to-date or failed initial check; offers a manual re-check.
    private var outcomeSection: some View {
        Section {
            if upToDate {
                Label("This pinned revision is up to date.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(ZiroTheme.positiveText)
            } else if checkFailed {
                Label("Could not check for updates.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(ZiroTheme.warningText)
            }
            Button("Check Again") {
                Task { await runCheckIfIdle() }
            }
        }
    }

    // MARK: Review

    @ViewBuilder
    private func reviewSections(_ review: HFRepositoryReview) -> some View {
        Section("Available Update") {
            LabeledContent(
                "Revision",
                value: String(review.revision.prefix(12))
            )
            LabeledContent("License", value: review.licenseName)
        }

        Section("Choose Artifact") {
            VariantPickerView(
                candidates: review.baseArtifacts,
                selection: Binding(
                    get: { selectedBase },
                    set: {
                        selectedBase = $0
                        updatePairConfirmed = false
                    }
                ),
                capabilityEstimate: {
                    coordinator.capabilityEstimate(
                        for: $0,
                        candidates: review.baseArtifacts
                    )
                }
            )
        }

        if model.modelType == .vision, let selectedBase {
            visionPairSection(base: selectedBase, review: review)
        }

        if let selectedBase {
            Section("Storage") {
                PreflightCard(
                    storage: coordinator.storagePreflight(
                        base: selectedBase,
                        projector: updateProjector(for: selectedBase, review: review)
                    )
                )
            }

            Section("Memory") {
                RAMAssessmentCard(
                    assessment: coordinator.ramAssessment(
                        base: selectedBase,
                        projector: updateProjector(for: selectedBase, review: review)
                    ),
                    riskAccepted: $updateRAMRiskAccepted
                )
            }
        }

        Section("License") {
            LicenseRow(licenseURL: review.licenseURL, confirmed: $updateLicenseConfirmed)
        }

        Section {
            Button("Download and Stage Update") {
                do {
                    try stageUpdate(review)
                    statusMessage = "The update is downloading beside the installed revision."
                } catch {
                    statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            .disabled(!canStageUpdate(review: review))
            // Gate explanation, mirroring the import wizard's
            // ImportWizardContinueButton hint: five silent gates (variant,
            // license, vision-pair confirmation, storage, RAM risk) would
            // otherwise leave the disabled button unexplained.
            if !canStageUpdate(review: review), let hint = stageGateHint(review: review) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The first unmet staging gate, in the order canStageUpdate evaluates
    /// them; nil when staging is allowed.
    private func stageGateHint(review: HFRepositoryReview) -> String? {
        guard let base = selectedBase else { return "Choose a base artifact to continue." }
        if !updateLicenseConfirmed { return "Accept the license to continue." }
        let projector = updateProjector(for: base, review: review)
        if model.modelType == .vision {
            if projector == nil { return "No unambiguous vision pair is available for this artifact — choose another." }
            if !updatePairConfirmed { return "Confirm the vision pairing to continue." }
        }
        if !coordinator.storagePreflight(base: base, projector: projector).canProceed {
            return "Free up storage — the download cannot start."
        }
        let ram = coordinator.ramAssessment(base: base, projector: projector)
        if ram.classification == .risky, !updateRAMRiskAccepted {
            return "Acknowledge the memory risk to continue."
        }
        return nil
    }

    @ViewBuilder
    private func visionPairSection(base: HFArtifact, review: HFRepositoryReview) -> some View {
        Section("Vision Pair") {
            if let pair = VisionPairResolver().bestPair(for: base, in: review) {
                Text("Projector: \(pair.projector.filename) · \(pair.confidence.label)")
                    .font(.caption)
                Toggle("I confirm this updated vision pair", isOn: $updatePairConfirmed)
            } else {
                Label("No unambiguous high-confidence projector pair is available.", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(ZiroTheme.warningText)
            }
        }
    }

    // MARK: Staged

    private var stagedSection: some View {
        Section("Staged Update") {
            Button("Finish Verified Update") {
                Task {
                    do {
                        if try await coordinator.promoteIfVerified(modelID: model.id) != nil {
                            statusMessage = "Update installed. Return to Models to open the new revision."
                        } else {
                            statusMessage = "The staged artifacts are still downloading or have not passed verification."
                        }
                    } catch {
                        statusMessage = error.localizedDescription
                    }
                }
            }

            // r4 MEDIUM: discarding deletes staged download data (a later
            // update re-downloads it), so the destructive action confirms
            // first — mirroring ModelsView's cancel-download dialog.
            Button("Cancel Staged Update", role: .destructive) {
                showsCancelStagedConfirmation = true
            }
            .confirmationDialog(
                "Discard Staged Update",
                isPresented: $showsCancelStagedConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard Staged Update", role: .destructive) {
                    coordinator.discardStagedUpdate(modelID: model.id)
                    statusMessage = "The staged update was discarded. The installed revision is unchanged."
                }
                Button("Keep Staged Update", role: .cancel) {}
            } message: {
                Text("Discarding removes the staged download data. The installed revision stays unchanged; checking for the update again would re-download it.")
            }
        }
    }

    // MARK: Staging math (preserved from the pre-redesign settings panel)

    private func updateProjector(for base: HFArtifact, review: HFRepositoryReview) -> HFArtifact? {
        guard model.modelType == .vision else { return nil }
        return VisionPairResolver().bestPair(for: base, in: review)?.projector
    }

    private func canStageUpdate(review: HFRepositoryReview) -> Bool {
        guard updateLicenseConfirmed, let base = selectedBase else { return false }
        let projector = updateProjector(for: base, review: review)
        guard model.modelType != .vision || (updatePairConfirmed && projector != nil) else { return false }
        let storage = coordinator.storagePreflight(base: base, projector: projector)
        let ram = coordinator.ramAssessment(base: base, projector: projector)
        return storage.canProceed && (ram.classification == .likelyFits || updateRAMRiskAccepted)
    }

    private func stageUpdate(_ review: HFRepositoryReview) throws {
        guard canStageUpdate(review: review), let base = selectedBase else {
            throw HFInspectionError.noCompatibleArtifact
        }

        if model.modelType == .vision {
            guard let candidate = VisionPairResolver().bestPair(for: base, in: review) else {
                throw review.projectorArtifacts.isEmpty
                    ? HFInspectionError.projectorMissing
                    : HFInspectionError.projectorAmbiguous
            }
            switch try coordinator.stagePairedUpdate(
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
            _ = try coordinator.stageUpdate(
                existing: model,
                review: review,
                base: base,
                projector: nil
            )
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

// MARK: - Provenance Rows

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
