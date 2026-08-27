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
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ProgressView(
                value: Double(step.rawValue + 1),
                total: Double(ImportWizardStep.allCases.count)
            )
            .tint(.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ZiroTheme.Spacing.large)
        .padding(.vertical, ZiroTheme.Spacing.small)
        .background(ZiroTheme.elevatedBackground)
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

    /// Pins the step's forward action above the safe area.
    func importWizardBottomBar<Actions: View>(@ViewBuilder actions: () -> Actions) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            actions()
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Section("Vision Unavailable") {
                    Label(
                        viewModel.noVisionPairReason ?? "Vision import is not available for this repository.",
                        systemImage: "eye.slash"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            Section("License") {
                LicenseRow(
                    licenseURL: review.licenseURL,
                    confirmed: $viewModel.licenseConfirmed
                )
            }
        }
    }

    @ViewBuilder
    private var visionPairContent: some View {
        Toggle("Import as vision model", isOn: Binding<Bool>(
            get: { viewModel.importAsVision },
            set: { newValue in
                viewModel.importAsVision = newValue
                viewModel.toggleVisionImport()
            }
        ))

        if viewModel.importAsVision {
            if let pair = viewModel.suggestedPair {
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                    HStack {
                        ConfidenceBadge(confidence: pair.confidence)
                        Spacer()
                        Text(pair.formattedCombinedSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    ImportArtifactSummaryRow(role: "Base Model", icon: "cpu", artifact: pair.base)

                    Divider()

                    ImportArtifactSummaryRow(role: "Vision Projector", icon: "eye", artifact: pair.projector)

                    Text(pair.confidenceExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if pair.confidence != .high {
                        HStack(spacing: ZiroTheme.Spacing.small) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("This pairing requires explicit confirmation before import.")
                                .font(.caption)
                                .foregroundStyle(.orange)
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
                        .buttonStyle(.borderedProminent)
                    } else {
                        Label("Vision pair confirmed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            } else if let error = viewModel.visionPairingError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Label("Resolving compatible vision pair…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
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
            Section("Chosen Artifacts") {
                LabeledContent(
                    "Base model",
                    value: "\(base.filename) · \(StorageByteFormatter.string(fromByteCount: base.size))"
                )
                if let projector = viewModel.selectedProjector {
                    LabeledContent(
                        "Vision projector",
                        value: "\(projector.filename) · \(StorageByteFormatter.string(fromByteCount: projector.size))"
                    )
                }
                LabeledContent("Total download", value: StorageByteFormatter.string(fromByteCount: viewModel.selectedBytes))
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
                        .foregroundStyle(.red)
                }
            }
        }
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
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func transferContent(model: AIModel, status: ModelDownloadStatus) -> some View {
        ScrollView {
            VStack(spacing: ZiroTheme.Spacing.large) {
                ZiroCard {
                    VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                        HStack(spacing: ZiroTheme.Spacing.small) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
                                Text(model.displayName)
                                    .font(.headline)
                                Text(model.formattedSize)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        statusContent(model: model, status: status)
                    }
                }
                Text("You can close this wizard — the transfer continues in the background and can be paused, resumed, or repaired from the Models page.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(ZiroTheme.Spacing.large)
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
                }
                .accessibilityLabel("Downloading \(model.displayName)")
                .accessibilityValue("\(Int(progress * 100)) percent complete")
                Text("Pause or resume anytime from the Models page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .pausing(let progress):
            HStack(spacing: ZiroTheme.Spacing.small) {
                ProgressView()
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
                    Text("Saving resume data…")
                    Text("\(Int(progress * 100))% complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .resuming(let progress):
            HStack(spacing: ZiroTheme.Spacing.small) {
                ProgressView()
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
                    Text("Resuming…")
                    Text("\(Int(progress * 100))% complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .paused(let progress):
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                ProgressView(value: progress) {
                    Text("Paused")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                }
                Button("Manage in Library") { onClose() }
                    .buttonStyle(.bordered)
            }

        case .verifying:
            HStack(spacing: ZiroTheme.Spacing.small) {
                ProgressView()
                Text("Verifying download…")
                    .foregroundStyle(.secondary)
            }

        case .downloaded:
            Label("Transfer complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

        case .failed(let error):
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("Manage in Library") { onClose() }
                    .buttonStyle(.bordered)
            }

        case .cancelled:
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                Label("Transfer cancelled", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
                Button("Manage in Library") { onClose() }
                    .buttonStyle(.bordered)
            }

        case .notDownloaded:
            HStack(spacing: ZiroTheme.Spacing.small) {
                ProgressView()
                Text("Waiting for the transfer to start…")
                    .foregroundStyle(.secondary)
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
            .padding(ZiroTheme.Spacing.large)
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
                tint: .green
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
                tint: .green
            )
            ZiroCard {
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                    LabeledContent("Model", value: model.displayName)
                    LabeledContent("Size", value: model.formattedSize)
                    LabeledContent("Capabilities", value: model.modelType == .vision ? "Text + images" : "Text only")
                }
            }
            VStack(spacing: ZiroTheme.Spacing.small) {
                Button { onStartChatting(model) } label: {
                    Label("Start Chatting", systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(ZiroPrimaryButtonStyle())

                Button("Add to Library", action: onClose)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
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
            LabeledContent("Download storage", value: StorageByteFormatter.string(fromByteCount: storage.requiredBytes))
            LabeledContent("Safety margin", value: StorageByteFormatter.string(fromByteCount: storage.safetyMarginBytes))
            LabeledContent("Available storage", value: StorageByteFormatter.string(fromByteCount: storage.availableBytes))
            if !storage.canProceed {
                Label("Not enough storage. No download can start.", systemImage: "internaldrive.fill.badge.xmark")
                    .foregroundStyle(.red)
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
            LabeledContent(
                "Estimated RAM",
                value: StorageByteFormatter.string(fromByteCount: Int64(clamping: assessment.estimatedBytes), countStyle: .memory)
            )
            LabeledContent(
                "Device RAM",
                value: StorageByteFormatter.string(fromByteCount: Int64(clamping: assessment.physicalBytes), countStyle: .memory)
            )
            switch assessment.classification {
            case .likelyFits:
                Label("Should run within this device's memory.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .risky:
                if let warning = assessment.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
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

/// Confidence badge for a suggested vision pair (import wizard + update flow).
struct ConfidenceBadge: View {
    let confidence: VisionPairConfidence

    var body: some View {
        HStack(spacing: ZiroTheme.Spacing.xSmall) {
            Image(systemName: iconName)
            Text(confidence.label)
        }
        .font(.caption)
        .padding(.horizontal, ZiroTheme.Spacing.small)
        .padding(.vertical, ZiroTheme.Spacing.xSmall)
        .background(
            RoundedRectangle(cornerRadius: ZiroTheme.Radius.badge)
                .fill(tint.opacity(fillOpacity))
        )
        .foregroundStyle(tint)
    }

    private var iconName: String {
        switch confidence {
        case .high: "checkmark.shield.fill"
        case .medium: "shield"
        case .low: "exclamationmark.shield"
        }
    }

    private var tint: Color {
        switch confidence {
        case .high: .green
        case .medium: .orange
        case .low: .red
        }
    }

    private var fillOpacity: Double {
        switch confidence {
        case .high, .medium: 0.15
        case .low: 0.10
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
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(artifact.filename)
                .font(.subheadline)
            Text("\(artifact.quantization) · \(StorageByteFormatter.string(fromByteCount: artifact.size))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("SHA-256 \(artifact.sha256.prefix(12))…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}
