// ImportWizardSteps.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Pages 3–6 of the Hugging Face import wizard (Configure, Review, Transfer,
// Done) plus the shared wizard chrome: the sticky step-progress header, the
// bottom action bar, and reusable pieces (PreflightCard, RAMAssessmentCard,
// LicenseRow, ConfidenceBadge) that the imported-model update flow composes.

import SwiftUI

// MARK: - Wizard Steps

/// Ordered wizard pages. `source` is the NavigationStack root; the rest are
/// pushed one at a time. Forward gates (derived from existing ImportViewModel
/// state) live in each step view; `ImportFlowView` owns the navigation path.
enum ImportWizardStep: Int, CaseIterable, Hashable {
    case source
    case artifacts
    case configure
    case review
    case transfer
    case done
}

// MARK: - Sticky Chrome

/// Sticky per-step progress strip shown on every wizard page so users always
/// know where they are in the flow.
private struct ImportWizardStepHeader: View {
    let step: ImportWizardStep

    var body: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            Text("Step \(step.rawValue + 1) of \(ImportWizardStep.allCases.count)")
                .font(ZiroType.caption)
                .foregroundStyle(ZiroTheme.secondaryText)
            ProgressView(
                value: Double(step.rawValue + 1),
                total: Double(ImportWizardStep.allCases.count)
            )
            .tint(ZiroTheme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ZiroTheme.Spacing.large)
        .padding(.vertical, ZiroTheme.Spacing.small)
        .background(ZiroTheme.raisedBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Import step \(step.rawValue + 1) of \(ImportWizardStep.allCases.count)")
    }
}

extension View {
    /// Pins the shared step-progress strip under the navigation bar.
    func importWizardStepHeader(_ step: ImportWizardStep) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            ImportWizardStepHeader(step: step)
        }
    }

    /// Pins the step's forward action above the safe area. The action column
    /// caps at the standard measure so the button doesn't stretch edge-to-edge
    /// on iPad.
    func importWizardBottomBar<Actions: View>(@ViewBuilder actions: () -> Actions) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            actions()
                .frame(maxWidth: ZiroMeasure.standard)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ZiroTheme.Spacing.large)
                .padding(.top, ZiroTheme.Spacing.small)
                .padding(.bottom, ZiroTheme.Spacing.medium)
                .background(ZiroTheme.pageBackground)
        }
    }
}

/// Gated forward action shared by the wizard's Continue-style steps. The hint
/// explains why the gate is closed so per-step validation is never silent.
struct ImportWizardContinueButton: View {
    let title: String
    var systemImage: String?
    let isEnabled: Bool
    var hint: String?
    let action: () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        isEnabled: Bool,
        hint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.hint = hint
        self.action = action
    }

    var body: some View {
        VStack(spacing: ZiroTheme.Spacing.small) {
            if !isEnabled, let hint, !hint.isEmpty {
                Text(hint)
                    .font(ZiroType.caption)
                    .foregroundStyle(ZiroTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: action) {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .buttonStyle(ZiroPrimaryButtonStyle())
            .disabled(!isEnabled)
            // The visual hint caption is skipped by VoiceOver's default
            // traversal; surface the gate reason as a hint on the control
            // itself while it is disabled (r4 MEDIUM).
            .accessibilityHint(!isEnabled ? (hint ?? "") : "")
        }
    }
}

// MARK: - Step 3: Configure

/// Vision pairing and license acceptance. Storage/RAM numbers are
/// deliberately deferred to the Review step with their risk acknowledgment.
struct ConfigureStepView: View {
    @ObservedObject var viewModel: ImportViewModel
    var onContinue: () -> Void

    var body: some View {
        Group {
            if let review = viewModel.review {
                configureForm(review: review)
            } else {
                ContentUnavailableView(
                    "Nothing to Configure",
                    systemImage: "square.and.pencil",
                    description: Text("Inspect a repository first.")
                )
            }
        }
        .navigationTitle("Configure")
        .navigationBarTitleDisplayMode(.inline)
        .importWizardStepHeader(.configure)
        .importWizardBottomBar {
            ImportWizardContinueButton(
                title: "Continue",
                isEnabled: canContinue,
                hint: continueHint,
                action: onContinue
            )
        }
    }

    private var canContinue: Bool {
        viewModel.licenseConfirmed
            && viewModel.visionPairingError == nil
            && !viewModel.needsVisionPairConfirmation
    }

    private var continueHint: String? {
        if !viewModel.licenseConfirmed { return "Accept the license to continue." }
        if viewModel.needsVisionPairConfirmation { return "Confirm the vision pairing to continue." }
        return nil
    }

    private func configureForm(review: HFRepositoryReview) -> some View {
        Form {
            if !review.projectorArtifacts.isEmpty, viewModel.selectedBase != nil {
                Section {
                    visionPairContent
                } header: {
                    Text("Vision Projector")
                } footer: {
                    if let note = viewModel.suggestedPair?.projectorArchitectureNote {
                        Text(note)
                    }
                }
            } else if viewModel.importAsVision, viewModel.selectedBase != nil {
                // Defensive: a stale `importAsVision` reaching a repository
                // with no usable projector (enabled on repo A, then inspecting
                // repo B) must stay clearable. inspect() now resets the flag
                // for non-viable repositories, but without a toggle here any
                // residual path would leave `visionPairingError` permanent and
                // the Continue gate closed.
                Section("Vision Unavailable") {
                    visionToggle
                    Label(
                        viewModel.noVisionPairReason ?? "Vision import is not available for this repository.",
                        systemImage: "eye.slash"
                    )
                    .foregroundStyle(ZiroTheme.secondaryText)
                }
            }

            Section("License") {
                LicenseRow(
                    licenseURL: review.licenseURL,
                    confirmed: $viewModel.licenseConfirmed
                )
            }
        }
        // Warm paper canvas with raised card rows (design spec §3.1).
        .scrollContentBackground(.hidden)
        .background(ZiroTheme.pageBackground.ignoresSafeArea())
        .listRowBackground(ZiroTheme.raisedBackground)
    }

    @ViewBuilder
    private var visionToggle: some View {
        Toggle("Import as vision model", isOn: Binding<Bool>(
            get: { viewModel.importAsVision },
            set: { newValue in
                viewModel.importAsVision = newValue
                viewModel.toggleVisionImport()
            }
        ))
    }

    @ViewBuilder
    private var visionPairContent: some View {
        visionToggle

        if viewModel.importAsVision {
            if let pair = viewModel.suggestedPair {
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                    HStack {
                        ConfidenceBadge(confidence: pair.confidence)
                        Spacer()
                        Text(pair.formattedCombinedSize)
                            .font(ZiroType.technical(.caption))
                            .foregroundStyle(ZiroTheme.secondaryText)
                    }

                    Divider()

                    ImportArtifactSummaryRow(role: "Base Model", icon: "cpu", artifact: pair.base)

                    Divider()

                    ImportArtifactSummaryRow(role: "Vision Projector", icon: "eye", artifact: pair.projector)

                    Text(pair.confidenceExplanation)
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if pair.confidence != .high {
                        HStack(spacing: ZiroTheme.Spacing.small) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(ZiroTheme.warningText)
                            Text("This pairing requires explicit confirmation before import.")
                                .font(ZiroType.caption)
                                .foregroundStyle(ZiroTheme.warningText)
                        }
                    }

                    if !viewModel.visionPairConfirmed {
                        Button {
                            viewModel.confirmVisionPair()
                        } label: {
                            Label(
                                pair.confidence == .high
                                    ? "Confirm Recommended Pair"
                                    : "Accept This Pairing",
                                systemImage: "checkmark.shield"
                            )
                        }
                        .buttonStyle(ZiroPrimaryButtonStyle())
                    } else {
                        Label("Vision pair confirmed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(ZiroTheme.positiveText)
                    }
                }
            } else if let error = viewModel.visionPairingError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(ZiroTheme.warningText)
                    .announcingOnAppear("Vision pairing failed. \(error)")
            } else {
                Label("Resolving compatible vision pair…", systemImage: "hourglass")
                    .foregroundStyle(ZiroTheme.secondaryText)
            }
        }
    }
}

// MARK: - Step 4: Review

/// Device preflight numbers and the risk acknowledgments that belong with
/// them: storage requirement and RAM assessment.
struct ReviewStepView: View {
    @ObservedObject var viewModel: ImportViewModel

    var body: some View {
        Group {
            if let base = viewModel.selectedBase {
                reviewForm(base: base)
            } else {
                ContentUnavailableView(
                    "Nothing to Review",
                    systemImage: "shippingbox",
                    description: Text("Choose a GGUF artifact first.")
                )
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .importWizardStepHeader(.review)
        .importWizardBottomBar {
            ImportWizardContinueButton(
                title: "Import Selected Model",
                systemImage: "arrow.down.circle",
                isEnabled: canImport,
                hint: importHint,
                action: { viewModel.confirmImport() }
            )
        }
    }

    /// The remaining halves of `ImportViewModel.canConfirm` — the artifact,
    /// license, and vision halves were validated by the earlier steps. The
    /// `phase` guard mirrors the pre-wizard button's `.importing` disable so
    /// a double-tap cannot re-enter `confirmImport()` after the transfer
    /// started.
    private var canImport: Bool {
        viewModel.phase != .importing
            && viewModel.storagePreflight.canProceed
            && (viewModel.ramAssessment.classification == .likelyFits || viewModel.ramRiskAccepted)
    }

    private var importHint: String? {
        if !viewModel.storagePreflight.canProceed { return "Free up storage — the download cannot start." }
        if viewModel.ramAssessment.classification == .risky, !viewModel.ramRiskAccepted {
            return "Acknowledge the memory risk to continue."
        }
        return nil
    }

    private func reviewForm(base: HFArtifact) -> some View {
        Form {
            // Artifact names and byte sizes are engineering data — technical voice.
            Section("Chosen Artifacts") {
                LabeledContent("Base model") {
                    Text("\(base.filename) · \(StorageByteFormatter.string(fromByteCount: base.size))")
                        .font(ZiroType.technical(.footnote))
                }
                if let projector = viewModel.selectedProjector {
                    LabeledContent("Vision projector") {
                        Text("\(projector.filename) · \(StorageByteFormatter.string(fromByteCount: projector.size))")
                            .font(ZiroType.technical(.footnote))
                    }
                }
                LabeledContent("Total download") {
                    Text(StorageByteFormatter.string(fromByteCount: viewModel.selectedBytes))
                        .font(ZiroType.technical(.footnote))
                }
            }

            Section("Storage") {
                PreflightCard(storage: viewModel.storagePreflight)
            }

            Section("Memory") {
                RAMAssessmentCard(assessment: viewModel.ramAssessment, riskAccepted: $viewModel.ramRiskAccepted)
            }

            if case .failed(let message) = viewModel.phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ZiroTheme.dangerText)
                        .announcingOnAppear("Import failed. \(message)")
                }
            }
        }
        // Warm paper canvas with raised card rows (design spec §3.1).
        .scrollContentBackground(.hidden)
        .background(ZiroTheme.pageBackground.ignoresSafeArea())
        .listRowBackground(ZiroTheme.raisedBackground)
    }
}

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
                ZiroCard(showsShadow: true) {
                    VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                        HStack(spacing: ZiroTheme.Spacing.small) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2)
                                .foregroundStyle(ZiroTheme.accent)
                            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
                                Text(model.displayName)
                                    .font(ZiroType.rowTitle)
                                Text(model.formattedSize)
                                    .font(ZiroType.technical(.caption))
                                    .foregroundStyle(ZiroTheme.secondaryText)
                            }
                        }
                        Divider()
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
            ZiroCard {
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                    LabeledContent("Model", value: model.displayName)
                    // Numeric outcome values read as engineering data — technical voice.
                    LabeledContent("Size") {
                        Text(model.formattedSize)
                            .font(ZiroType.technical(.footnote))
                    }
                    LabeledContent("Capabilities", value: model.modelType == .vision ? "Text + images" : "Text only")
                }
            }
            VStack(spacing: ZiroTheme.Spacing.small) {
                Button { onStartChatting(model) } label: {
                    Label("Start Chatting", systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(ZiroPrimaryButtonStyle())

                Button("Add to Library", action: onClose)
                    .buttonStyle(ZiroSecondaryButtonStyle())
            }
        }
    }
}

// MARK: - Reusable Pieces

/// Storage requirement summary with the red insufficiency state. Embeddable
/// in Form sections or cards; also reused by the imported-model update flow.
struct PreflightCard: View {
    let storage: ImportStoragePreflight

    var body: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
            // Byte sizes are engineering data — technical voice.
            LabeledContent("Download storage") {
                Text(StorageByteFormatter.string(fromByteCount: storage.requiredBytes))
                    .font(ZiroType.technical(.footnote))
            }
            LabeledContent("Safety margin") {
                Text(StorageByteFormatter.string(fromByteCount: storage.safetyMarginBytes))
                    .font(ZiroType.technical(.footnote))
            }
            LabeledContent("Available storage") {
                Text(StorageByteFormatter.string(fromByteCount: storage.availableBytes))
                    .font(ZiroType.technical(.footnote))
            }
            if !storage.canProceed {
                Label("Not enough storage. No download can start.", systemImage: "internaldrive.fill.badge.xmark")
                    .foregroundStyle(ZiroTheme.warningText)
                    .announcingOnAppear("Not enough storage. No download can start.")
            }
        }
    }
}

/// Estimated RAM vs physical RAM with the risky-download acknowledgment.
struct RAMAssessmentCard: View {
    let assessment: ImportRAMAssessment
    @Binding var riskAccepted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
            LabeledContent("Estimated RAM") {
                Text(StorageByteFormatter.string(fromByteCount: Int64(clamping: assessment.estimatedBytes), countStyle: .memory))
                    .font(ZiroType.technical(.footnote))
            }
            LabeledContent("Device RAM") {
                Text(StorageByteFormatter.string(fromByteCount: Int64(clamping: assessment.physicalBytes), countStyle: .memory))
                    .font(ZiroType.technical(.footnote))
            }
            switch assessment.classification {
            case .likelyFits:
                Label("Should run within this device's memory.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(ZiroTheme.positiveText)
            case .risky:
                if let warning = assessment.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ZiroTheme.warningText)
                }
                Toggle("Download despite RAM risk", isOn: $riskAccepted)
            }
        }
    }
}

/// License review + acceptance control reused by the import wizard and the
/// imported-model update flow.
struct LicenseRow: View {
    let licenseURL: URL
    @Binding var confirmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
            Link(destination: licenseURL) {
                Label("View license terms", systemImage: "doc.text")
            }
            Toggle("I reviewed and accept the license", isOn: $confirmed)
        }
    }
}

/// Confidence badge for a suggested vision pair (import wizard + update
/// flow). A thin wrapper over `ZiroBadge` — the one badge system — mapping
/// each confidence level to its verified tone and shield imagery.
struct ConfidenceBadge: View {
    let confidence: VisionPairConfidence

    var body: some View {
        ZiroBadge(text: confidence.label, tone: tone, icon: iconName)
    }

    private var tone: ZiroTone {
        switch confidence {
        case .high: .positive
        case .medium: .warning
        case .low: .danger
        }
    }

    private var iconName: String {
        switch confidence {
        case .high: "checkmark.shield.fill"
        case .medium: "shield"
        case .low: "exclamationmark.shield"
        }
    }
}

/// One artifact (base or projector) summary line inside a pair card.
struct ImportArtifactSummaryRow: View {
    let role: String
    let icon: String
    let artifact: HFArtifact

    var body: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            Label(role, systemImage: icon)
                .font(ZiroType.caption)
                .foregroundStyle(ZiroTheme.secondaryText)
            // Artifact identity and digest are engineering data — technical voice.
            Text(artifact.filename)
                .font(ZiroType.technical(.subheadline))
            Text("\(artifact.quantization) · \(StorageByteFormatter.string(fromByteCount: artifact.size))")
                .font(ZiroType.technical(.caption))
                .foregroundStyle(ZiroTheme.secondaryText)
            Text("SHA-256 \(artifact.sha256.prefix(12))…")
                .font(ZiroType.technical(.caption2))
                .foregroundStyle(ZiroTheme.tertiaryText)
        }
        .accessibilityElement(children: .combine)
    }
}
