// ImportView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Multi-step Hugging Face import wizard, presented as a sheet from the Models
// page. One concern per page:
//   1 Source     — repository input + inspection          (this file)
//   2 Artifacts  — pinned source + GGUF variant choice    (this file)
//   3 Configure  — vision pairing + license               (ImportWizardSteps.swift)
//   4 Review     — storage/RAM preflight + risk sign-off  (ImportWizardSteps.swift)
//   5 Transfer   — live download status                   (ImportWizardSteps.swift)
//   6 Done       — outcome summary                        (ImportWizardSteps.swift)
// ImportViewModel remains the untouched brain; each step's forward gate is a
// partition of `canConfirm` (see ImportViewModel.canConfirm doc comment).

import SwiftUI

/// Wizard router. Owns the push path; step views own their forward gates.
struct ImportFlowView: View {
    @StateObject private var viewModel: ImportViewModel
    private let downloadManager: DownloadManager
    private let onStartChatting: (AIModel) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [ImportWizardStep] = []

    init(
        downloadManager: DownloadManager,
        repositoryInput: String = "",
        onStartChatting: @escaping (AIModel) -> Void = { _ in }
    ) {
        _viewModel = StateObject(wrappedValue: ImportViewModel(
            downloadManager: downloadManager,
            repositoryInput: repositoryInput
        ))
        self.downloadManager = downloadManager
        self.onStartChatting = onStartChatting
    }

    var body: some View {
        NavigationStack(path: $path) {
            SourceStepView(viewModel: viewModel)
                .navigationDestination(for: ImportWizardStep.self) { step in
                    stepDestination(step)
                }
        }
        .onChange(of: viewModel.phase) { _, phase in
            route(phase)
        }
    }

    /// Central navigation rules: inspection success advances to artifacts; a
    /// confirmed import advances to transfer or (duplicate branch) done.
    private func route(_ phase: ImportViewModel.Phase) {
        switch phase {
        case .review:
            // Inspection completed; the source step is the only origin.
            if path.isEmpty { advanceTo(.artifacts) }
        case .importing:
            advanceTo(.transfer)
        case .completed:
            advanceTo(.done)
        case .idle, .inspecting, .failed:
            break
        }
    }

    private func advanceTo(_ step: ImportWizardStep) {
        guard path.last != step else { return }
        path.append(step)
    }

    @ViewBuilder
    private func stepDestination(_ step: ImportWizardStep) -> some View {
        switch step {
        case .source:
            SourceStepView(viewModel: viewModel)
        case .artifacts:
            ArtifactStepView(viewModel: viewModel) { advanceTo(.configure) }
        case .configure:
            ConfigureStepView(viewModel: viewModel) { advanceTo(.review) }
        case .review:
            ReviewStepView(viewModel: viewModel)
        case .transfer:
            TransferStepView(
                viewModel: viewModel,
                downloadManager: downloadManager,
                onClose: { dismiss() },
                onReady: { advanceTo(.done) }
            )
        case .done:
            DoneStepView(
                viewModel: viewModel,
                onStartChatting: { model in
                    dismiss()
                    onStartChatting(model)
                },
                onClose: { dismiss() }
            )
        }
    }
}

// MARK: - Step 1: Source

/// Repository input and inspection. Only the Hugging Face source is live;
/// local-file import is an explicit placeholder (no pipeline exists yet).
struct SourceStepView: View {
    @ObservedObject var viewModel: ImportViewModel
    @Environment(\.dismiss) private var dismiss
    /// Tracks the repository field's focus so the input well can raise its
    /// accent ring (the keyboard focus indicator).
    @FocusState private var repositoryFieldFocused: Bool

    /// Source-choice icon squares: 44×44 min, scaling with Dynamic Type.
    @ScaledMetric(relativeTo: .title3) private var sourceIconSide: CGFloat = 44

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.large) {
                sourceChoice
                inputCard
                if case .failed(let message) = viewModel.phase {
                    // r4 MEDIUM: inspection failure was visual-only; announce
                    // it when the card mounts (Retry button already carries a
                    // visible, labeled title).
                    failureCard(message)
                        .announcingOnAppear("Import rejected. \(message) Retry inspection.")
                }
                privacyNotice
            }
            // Single-column wizard form: xLarge screen padding, standard
            // measure cap centered on wide devices.
            .padding(.horizontal, ZiroTheme.Spacing.xLarge)
            .padding(.vertical, ZiroTheme.Spacing.large)
            .frame(maxWidth: ZiroMeasure.standard)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Import Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .importWizardStepHeader(.source)
        .importWizardBottomBar {
            ImportWizardContinueButton(
                title: "Inspect Repository",
                systemImage: "magnifyingglass",
                isEnabled: canInspect,
                // While inspecting, the input card's "Resolving…" spinner is
                // the gate explanation — a static "enter a repository"
                // caption (also spoken as the disabled button's hint) would
                // state the wrong reason.
                hint: viewModel.phase == .inspecting ? nil : "Enter a repository to inspect.",
                action: { Task { await viewModel.inspect() } }
            )
        }
    }

    private var trimmedInput: String {
        viewModel.repositoryInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same gate as the pre-wizard Inspect button: non-empty input, not
    /// already inspecting.
    private var canInspect: Bool {
        !trimmedInput.isEmpty && viewModel.phase != .inspecting
    }

    private var sourceChoice: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
            ZiroCard {
                HStack(spacing: ZiroTheme.Spacing.medium) {
                    // Source icon in the spec's accent-tinted rounded square.
                    Image(systemName: "globe")
                        .font(.title2)
                        .foregroundStyle(ZiroTheme.accent)
                        .frame(width: sourceIconSide, height: sourceIconSide)
                        .background(
                            ZiroTheme.accentContainer,
                            in: RoundedRectangle(cornerRadius: ZiroTheme.Radius.small, style: .continuous)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
                        Text("Hugging Face Repository")
                            .font(ZiroType.rowTitle)
                        Text("Public GGUF repositories, pinned to an immutable revision.")
                            .font(ZiroType.caption)
                            .foregroundStyle(ZiroTheme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ZiroTheme.accent)
                        .accessibilityLabel("Selected")
                }
                .accessibilityElement(children: .combine)
            }

            ZiroCard {
                HStack(spacing: ZiroTheme.Spacing.medium) {
                    Image(systemName: "doc")
                        .font(.title2)
                        .foregroundStyle(ZiroTheme.secondaryText)
                        .frame(width: sourceIconSide, height: sourceIconSide)
                        .background(
                            ZiroTheme.accentContainer,
                            in: RoundedRectangle(cornerRadius: ZiroTheme.Radius.small, style: .continuous)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
                        HStack(spacing: ZiroTheme.Spacing.xSmall) {
                            Text("Local GGUF File")
                                .font(ZiroType.rowTitle)
                            // The one badge system — neutral stub tone.
                            ZiroBadge(text: "Coming soon", tone: .neutral)
                        }
                        Text("Import a model file stored on this device.")
                            .font(ZiroType.caption)
                            .foregroundStyle(ZiroTheme.secondaryText)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)
            }
            .opacity(0.55)
            .accessibilityHint("Not available yet")
        }
    }

    private var inputCard: some View {
        ZiroCard {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                Text("Repository")
                    .font(ZiroType.supporting.weight(.semibold))
                TextField("owner/repository or URL", text: $viewModel.repositoryInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($repositoryFieldFocused)
                    // Design-system input well: recessed fill + hairline at
                    // rest, accent focus ring while typing (the keyboard
                    // focus indicator).
                    .ziroComposerField(isActive: repositoryFieldFocused)
                    .onSubmit {
                        if canInspect { Task { await viewModel.inspect() } }
                    }
                if viewModel.phase == .inspecting {
                    HStack(spacing: ZiroTheme.Spacing.small) {
                        ProgressView()
                        Text("Resolving an immutable revision…")
                            .font(ZiroType.footnote)
                            .foregroundStyle(ZiroTheme.secondaryText)
                    }
                }
            }
        }
    }

    private func failureCard(_ message: String) -> some View {
        ZiroCard {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                Label("Import Rejected", systemImage: "exclamationmark.triangle.fill")
                    .font(ZiroType.supporting.weight(.semibold))
                    // Hard rejection → the danger token (warning reads as
                    // recoverable; per spec this card is danger).
                    .foregroundStyle(ZiroTheme.dangerText)
                Text(message)
                    .font(ZiroType.footnote)
                    .foregroundStyle(ZiroTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await viewModel.retryInspection() }
                } label: {
                    Label("Retry Inspection", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ZiroSecondaryButtonStyle())
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            ZiroSectionHeader(title: "Privacy", systemImage: "lock.shield")
            Text("Only repository inspection and selected artifact downloads contact Hugging Face. Prompts, images, conversations, and inference stay on this device.")
                .font(ZiroType.footnote)
                .foregroundStyle(ZiroTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 2: Artifacts

/// Pinned source summary and the mandatory GGUF variant choice.
struct ArtifactStepView: View {
    @ObservedObject var viewModel: ImportViewModel
    var onContinue: () -> Void

    var body: some View {
        Group {
            if let review = viewModel.review {
                artifactForm(review: review)
            } else {
                ContentUnavailableView(
                    "Nothing to Choose",
                    systemImage: "shippingbox",
                    description: Text("Inspect a repository first.")
                )
            }
        }
        .navigationTitle("Choose Artifact")
        .navigationBarTitleDisplayMode(.inline)
        .importWizardStepHeader(.artifacts)
        .importWizardBottomBar {
            ImportWizardContinueButton(
                title: "Continue",
                isEnabled: viewModel.selectedBase != nil,
                hint: viewModel.baseCandidates.isEmpty ? nil : "Choose a GGUF variant to continue.",
                action: onContinue
            )
        }
    }

    private func artifactForm(review: HFRepositoryReview) -> some View {
        Form {
            // Pinned provenance values are engineering identifiers — technical voice.
            Section("Pinned Source") {
                LabeledContent("Repository") {
                    Text(review.repositoryID)
                        .font(ZiroType.technical(.footnote))
                }
                LabeledContent("Revision") {
                    Text(String(review.revision.prefix(12)))
                        .font(ZiroType.technical(.footnote))
                }
                LabeledContent("License") {
                    Link(review.licenseName, destination: review.licenseURL)
                }
            }

            Section("Choose GGUF Artifact") {
                if viewModel.baseCandidates.isEmpty {
                    EmptyVariantView(repositoryID: review.repositoryID)
                } else {
                    VariantPickerView(
                        candidates: viewModel.baseCandidates,
                        selection: Binding(
                            get: { viewModel.selectedBase },
                            set: { artifact in
                                viewModel.selectedBase = artifact
                                viewModel.visionPairConfirmed = false
                            }
                        ),
                        capabilityEstimate: { viewModel.capabilityEstimate(for: $0) }
                    )
                }
            }
        }
        // Warm paper canvas with raised card rows (design spec §3.1).
        .scrollContentBackground(.hidden)
        .background(ZiroTheme.pageBackground.ignoresSafeArea())
        .listRowBackground(ZiroTheme.raisedBackground)
    }
}
