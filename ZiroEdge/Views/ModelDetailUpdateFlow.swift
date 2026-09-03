// ModelDetailUpdateFlow.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Staged-update flow sheet for imported models, extracted from
// ModelDetailView.swift to keep the detail view file focused on the
// Overview/child-page shell. Presented from Generation Settings; reuses the
// import wizard's shared pieces (VariantPickerView, PreflightCard,
// RAMAssessmentCard, LicenseRow) against the unchanged
// ImportedModelUpdateCoordinator API.

import SwiftUI

// MARK: - Update Flow Sheet

/// Staged-update flow for imported models, extracted from the old settings
/// panel. Check → review (variant, vision pair, storage, RAM, license) →
/// stage → finish/verify, driven entirely by the unchanged
/// ImportedModelUpdateCoordinator API.
struct UpdateFlowSheet: View {
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
                                .foregroundStyle(ZiroTheme.secondaryText)
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
                            .font(ZiroType.caption)
                            .foregroundStyle(ZiroTheme.secondaryText)
                            .announcingOnAppear(statusMessage)
                    }
                }
            }
            // Warm paper canvas with raised card rows (design spec §3.1).
            .scrollContentBackground(.hidden)
            .background(ZiroTheme.pageBackground.ignoresSafeArea())
            .listRowBackground(ZiroTheme.raisedBackground)
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
                    .announcingOnAppear("Could not check for updates.")
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
            // Pinned revisions are engineering identifiers — technical voice.
            LabeledContent("Revision") {
                Text(String(review.revision.prefix(12)))
                    .font(ZiroType.technical(.footnote))
            }
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
            .buttonStyle(ZiroPrimaryButtonStyle())
            .disabled(!canStageUpdate(review: review))
            // VoiceOver parity with ImportWizardContinueButton (r4): the
            // visible gate caption is skipped by default traversal, so when
            // disabled, surface the first unmet gate as a hint on the control
            // itself — a silent disabled button gives no spoken reason.
            .accessibilityHint(
                !canStageUpdate(review: review)
                    ? (stageGateHint(review: review) ?? "")
                    : ""
            )
            // Gate explanation, mirroring the import wizard's
            // ImportWizardContinueButton hint: five silent gates (variant,
            // license, vision-pair confirmation, storage, RAM risk) would
            // otherwise leave the disabled button unexplained.
            if !canStageUpdate(review: review), let hint = stageGateHint(review: review) {
                Text(hint)
                    .font(ZiroType.caption)
                    .foregroundStyle(ZiroTheme.secondaryText)
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
                    .font(ZiroType.technical(.caption))
                Toggle("I confirm this updated vision pair", isOn: $updatePairConfirmed)
            } else {
                Label("No unambiguous high-confidence projector pair is available.", systemImage: "eye.slash")
                    .font(ZiroType.caption)
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
            .buttonStyle(ZiroPrimaryButtonStyle())

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

enum ImportedModelUpdateError: LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let message): message
        }
    }
}
