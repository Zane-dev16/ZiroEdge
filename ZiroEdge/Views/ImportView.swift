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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.large) {
                intro
                inputSection
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
        // No bottom bar: this step's action sits directly under the field,
        // next to the input it acts on (the chat-send pattern) — not
        // stranded in a far bar.
    }

    private var trimmedInput: String {
        viewModel.repositoryInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same gate as the pre-wizard Inspect button: non-empty input, not
    /// already inspecting.
    private var canInspect: Bool {
        !trimmedInput.isEmpty && viewModel.phase != .inspecting
    }

    /// Chat-empty-state voice: one line of what this step does, nothing
    /// else. There is no source to choose (Hugging Face is the only live
    /// source; local-file import stays hidden until its pipeline exists),
    /// so the old selection card was chrome around a single option.
    private var intro: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            Text("Import from Hugging Face")
                .font(ZiroType.title)
                .foregroundStyle(ZiroTheme.primaryText)
            Text("Paste a public GGUF repository. It is pinned to an immutable revision before anything downloads.")
                .font(ZiroType.supporting)
                .foregroundStyle(ZiroTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Search-field row (icon + field in one bordered well, so it reads as
    /// an input at rest) with the Inspect action directly beneath it — the
    /// button acts on this field, so it lives next to it.
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
            HStack(spacing: ZiroTheme.Spacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ZiroTheme.tertiaryText)
                    .accessibilityHidden(true)
                TextField("owner/repository or URL", text: $viewModel.repositoryInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($repositoryFieldFocused)
                    .onSubmit {
                        if canInspect { Task { await viewModel.inspect() } }
                    }
            }
            // Design-system input well: bordered at rest, stronger edge on
            // focus (the keyboard focus indicator) — never the accent ring.
            .ziroComposerField(isActive: repositoryFieldFocused)
            if viewModel.phase == .inspecting {
                HStack(spacing: ZiroTheme.Spacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Pinning revision…")
                        .font(ZiroType.footnote)
                        .foregroundStyle(ZiroTheme.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Pinning revision")
            }
            ImportWizardContinueButton(
                title: "Inspect Repository",
                systemImage: "magnifyingglass",
                isEnabled: canInspect,
                // While inspecting, the spinner above is the gate
                // explanation — a static "enter a repository" caption
                // (also spoken as the disabled button's hint) would state
                // the wrong reason.
                hint: viewModel.phase == .inspecting ? nil : "Enter a repository to inspect.",
                action: { Task { await viewModel.inspect() } }
            )
        }
    }

    private func failureCard(_ message: String) -> some View {
        ZiroStatusBanner(
            icon: "exclamationmark.triangle.fill",
            title: "Import rejected",
            message: message,
            tone: .danger
        ) {
            Button {
                Task { await viewModel.retryInspection() }
            } label: {
                Label("Retry Inspection", systemImage: "arrow.clockwise")
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// One quiet footnote, not a section: only inspection and the chosen
    /// download ever leave the device.
    private var privacyNotice: some View {
        Label(
            "Only inspection and the chosen download contact Hugging Face. Chats stay on this device.",
            systemImage: "lock.shield"
        )
        .font(ZiroType.footnote)
        .foregroundStyle(ZiroTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
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
        ScrollView {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.large) {
                // Pinned provenance in one quiet line; the revision digest
                // is verification detail, not a choice input.
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
                    Text("Pinned Source")
                        .font(ZiroType.caption)
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(ZiroTheme.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text(review.repositoryID)
                        .font(ZiroType.technical(.footnote))
                        .foregroundStyle(ZiroTheme.primaryText)
                    Link(review.licenseName, destination: review.licenseURL)
                        .font(ZiroType.footnote)
                }
                if viewModel.baseCandidates.isEmpty {
                    EmptyVariantView(repositoryID: review.repositoryID)
                } else {
                    Text("Choose one file. Smaller downloads faster; larger can be more capable.")
                        .font(ZiroType.supporting)
                        .foregroundStyle(ZiroTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    VariantPickerView(
                        candidates: viewModel.baseCandidates,
                        selection: Binding(
                            get: { viewModel.selectedBase },
                            set: { artifact in
                                viewModel.selectedBase = artifact
                                viewModel.visionPairConfirmed = false
                                viewModel.ramRiskAccepted = false
                            }
                        ),
                        capabilityEstimate: { viewModel.capabilityEstimate(for: $0) }
                    )
                }
            }
            .padding(.horizontal, ZiroTheme.Spacing.xLarge)
            .padding(.vertical, ZiroTheme.Spacing.large)
            .frame(maxWidth: ZiroMeasure.standard)
            .frame(maxWidth: .infinity)
        }
        .background(ZiroTheme.pageBackground.ignoresSafeArea())
    }
}
