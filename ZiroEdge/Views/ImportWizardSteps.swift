// ImportWizardSteps.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Import wizard pages 3–4 (Configure, Review) plus the ImportWizardStep
// enum. Chrome lives in ImportWizardChrome.swift, Transfer/Done in
// ImportWizardTransfer.swift, shared cards in ImportSharedCards.swift.

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
        ScrollView {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.large) {
                if !review.projectorArtifacts.isEmpty, viewModel.selectedBase != nil {
                    ZiroCard {
                        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                            Text("Vision")
                                .font(ZiroType.caption)
                                .textCase(.uppercase)
                                .tracking(0.8)
                                .foregroundStyle(ZiroTheme.secondaryText)
                                .accessibilityAddTraits(.isHeader)
                            visionPairContent
                        }
                    }
                } else if viewModel.importAsVision, viewModel.selectedBase != nil {
                    // Defensive: a stale `importAsVision` reaching a repository
                    // with no usable projector must stay clearable. inspect()
                    // resets the flag for non-viable repositories; this quiet
                    // caption keeps any residual path escapable without a
                    // whole section.
                    ZiroCard {
                        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                            visionToggle
                            Text(viewModel.noVisionPairReason ?? "Vision import is not available for this repository.")
                                .font(ZiroType.footnote)
                                .foregroundStyle(ZiroTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                ZiroCard {
                    VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                        Text("License")
                            .font(ZiroType.caption)
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .foregroundStyle(ZiroTheme.secondaryText)
                            .accessibilityAddTraits(.isHeader)
                        LicenseRow(
                            licenseURL: review.licenseURL,
                            confirmed: $viewModel.licenseConfirmed
                        )
                    }
                }
            }
            .padding(.horizontal, ZiroTheme.Spacing.xLarge)
            .padding(.vertical, ZiroTheme.Spacing.large)
            .frame(maxWidth: ZiroMeasure.standard)
            .frame(maxWidth: .infinity)
        }
        .background(ZiroTheme.pageBackground.ignoresSafeArea())
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
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                    HStack {
                        ConfidenceBadge(confidence: pair.confidence)
                        Spacer()
                        Text(pair.formattedCombinedSize)
                            .font(ZiroType.technical(.caption))
                            .foregroundStyle(ZiroTheme.secondaryText)
                    }

                    ImportArtifactSummaryRow(role: "Base Model", icon: "cpu", artifact: pair.base)

                    ImportArtifactSummaryRow(role: "Vision Projector", icon: "eye", artifact: pair.projector)

                    if pair.confidence != .high {
                        Text("This pairing needs your confirmation before import.")
                            .font(ZiroType.caption)
                            .foregroundStyle(ZiroTheme.warningText)
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
                        // Quiet inner confirmation: the bottom Continue bar
                        // owns the screen's single primary action.
                        .buttonStyle(ZiroSecondaryButtonStyle())
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
        ScrollView {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.large) {
                // One line of what downloads; the artifact choice already
                // happened two steps ago.
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
                    Text(base.filename)
                        .font(ZiroType.technical(.subheadline))
                        .foregroundStyle(ZiroTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(totalLine)
                        .font(ZiroType.technical(.caption))
                        .foregroundStyle(ZiroTheme.secondaryText)
                }

                ZiroCard {
                    PreflightCard(storage: viewModel.storagePreflight)
                }

                ZiroCard {
                    RAMAssessmentCard(assessment: viewModel.ramAssessment, riskAccepted: $viewModel.ramRiskAccepted)
                }

                if case .failed(let message) = viewModel.phase {
                    ZiroStatusBanner(
                        icon: "exclamationmark.triangle.fill",
                        message: message,
                        tone: .danger
                    ) {}
                    .announcingOnAppear("Import failed. \(message)")
                }
            }
            .padding(.horizontal, ZiroTheme.Spacing.xLarge)
            .padding(.vertical, ZiroTheme.Spacing.large)
            .frame(maxWidth: ZiroMeasure.standard)
            .frame(maxWidth: .infinity)
        }
        .background(ZiroTheme.pageBackground.ignoresSafeArea())
    }

    /// Total download in one engineering line (projector included when set).
    private var totalLine: String {
        let total = StorageByteFormatter.string(fromByteCount: viewModel.selectedBytes)
        if viewModel.selectedProjector != nil {
            return "\(total) total · includes vision projector"
        }
        return "\(total) total"
    }
}
