// ModelsView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Models catalog: one page split by a scope filter into
// "Available" (browse/download) and "Installed" (on this device). Every row
// is one quiet line of identity — name, a single meta line, trailing
// status — and opens the model's detail page, where the description,
// capability choice, runtime state, and storage checks live. Import wizard
// and detail concerns are kept off this page.

import SwiftUI

struct ModelsView: View {
    enum Scope: Hashable {
        case available
        case installed
    }

    @ObservedObject var viewModel: ModelsViewModel
    /// Called from the import wizard's Done page ("Start Chatting"): the
    /// shell pops back to the chat root and selects the freshly imported
    /// model. Default no-op keeps previews and callers without a shell
    /// compiling.
    var onStartChatting: (AIModel) -> Void = { _ in }

    @State private var scope: Scope
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Hit targets and icon gutters scale with Dynamic Type (like ChatView's
    // composerControlSide) so glyphs never overflow their frames at
    // accessibility sizes, while meeting the 44×44 hit-target minimum at the
    // default size.
    @ScaledMetric(relativeTo: .title3) private var cancelControlSide: CGFloat = 44

    init(viewModel: ModelsViewModel, onStartChatting: @escaping (AIModel) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.onStartChatting = onStartChatting
        // Land on the scope the user most likely came for: managing what is
        // installed, or browsing downloads on a fresh device.
        _scope = State(initialValue: viewModel.hasInstalledModels ? .installed : .available)
    }

    var body: some View {
        List {
            scopeSection
            switch scope {
            case .available:
                importSection
                availableSection
            case .installed:
                importSection
                if viewModel.hasInstalledModels { installedSection }
                if !viewModel.importedModels.isEmpty { importedSection }
                if !viewModel.hasInstalledModels && viewModel.importedModels.isEmpty {
                    emptyInstalledSection
                }
            }
        }
        .listStyle(.insetGrouped)
        // Warm paper canvas with raised card rows (design spec §3.1).
        .scrollContentBackground(.hidden)
        .background(ZiroTheme.pageBackground.ignoresSafeArea())
        .listRowBackground(ZiroTheme.raisedBackground)
        // Catalog parity: scope drives the filter, counts drive
        // installs/imports — rows carry the matching transition below.
        .ziroAnimation(ZiroMotion.appear, value: scope)
        .ziroAnimation(ZiroMotion.appear, value: viewModel.curatedModels.count)
        .ziroAnimation(ZiroMotion.appear, value: viewModel.importedModels.count)
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Models")
                    .font(ZiroType.face(.orbitronBold, .title3))
                    .foregroundStyle(ZiroTheme.primaryText)
            }
        }
        .sheet(isPresented: $viewModel.showingImporter) {
            ImportFlowView(
                downloadManager: viewModel.downloadManager,
                onStartChatting: onStartChatting
            )
        }
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
        .overlay(alignment: .center) {
            if viewModel.showingDeleteConfirmation {
                ZiroConfirmationModal(
                    title: viewModel.pendingDeleteModel.map(viewModel.canForgetImport) == true ? "Forget Import" : "Delete Model",
                    message: forgetOrDeleteMessage,
                    confirmTitle: viewModel.pendingDeleteModel.map(viewModel.canForgetImport) == true ? "Forget Import" : "Delete",
                    onConfirm: { Task { await viewModel.confirmDelete() } },
                    onCancel: { viewModel.showingDeleteConfirmation = false }
                )
            }
        }
        .overlay(alignment: .center) {
            if viewModel.showingCancelConfirmation {
                ZiroConfirmationModal(
                    title: "Cancel Download",
                    message: "Cancelling stops the current transfer and removes its partial download data for \(viewModel.pendingCancelModel?.displayName ?? "this model").",
                    confirmTitle: "Cancel Download",
                    cancelTitle: "Keep Downloading",
                    onConfirm: { viewModel.confirmCancelDownload() },
                    onCancel: { viewModel.showingCancelConfirmation = false }
                )
            }
        }
        // Dead-button fix (MEDIUM): `confirmDelete` failures set
        // `updateMessage` — without this binding they never surface.
        // Mirrors the SettingsPage deletion-failure alert verbatim.
        .alert(
            ModelEvictionPresentation.deleteFailureTitle,
            isPresented: Binding(
                get: { viewModel.updateMessage != nil },
                set: { if !$0 { viewModel.updateMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { viewModel.updateMessage = nil }
        } message: {
            Text(viewModel.updateMessage ?? "The model could not be removed.")
                .accessibilityIdentifier(ModelEvictionPresentation.deleteFailureID)
        }
    }

    private var forgetOrDeleteMessage: String {
        if let model = viewModel.pendingDeleteModel, viewModel.canForgetImport(model) {
            return "Forget \(model.displayName)? Its import record and unreferenced partial transfer data will be removed."
        }
        return "Delete \(viewModel.pendingDeleteModel?.displayName ?? "this model")? You can download it again later."
    }

    // MARK: - Scope

    /// Catalog scope filter: one split pill (single capsule track, two
    /// segments share it — no nested pills). The selected segment reads
    /// in the recessed-well fill with primary text. Each segment keeps a
    /// 44pt-minimum-height touch floor via expanded contentShape and
    /// grows with Dynamic Type; the selected segment carries `.isSelected`
    /// for VoiceOver. The row groups as one "Catalog scope" container
    /// (children `.contain`) so rotor users land on the group once, then
    /// swipe through the segments. Plain labels keep the UI-test contract
    /// (`app.buttons["Available"]`).
    private var scopeSection: some View {
        Section {
            HStack(spacing: 0) {
                scopeSegment(.available, label: "Available")
                scopeSegment(.installed, label: "Installed")
            }
            .padding(3)
            .background(Capsule().fill(.clear))
            .overlay(Capsule().stroke(ZiroTheme.hairline, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Catalog scope")
        }
    }

    private func scopeSegment(_ item: Scope, label: String) -> some View {
        Button {
            scope = item
        } label: {
            Text(label)
                .font(ZiroType.face(.orbitronSemiBold, .footnote))
                .tracking(0.8)
                .foregroundStyle(item == scope ? ZiroTheme.primaryText : ZiroTheme.secondaryText)
                .padding(.horizontal, ZiroTheme.Spacing.medium)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(
                    Capsule().fill(item == scope ? ZiroTheme.wellBackground : .clear)
                )
                .contentShape(Rectangle().inset(by: -6))
                // Selected fill cross-fades on the press curve.
                .ziroAnimation(ZiroMotion.press, value: scope)
        }
        .buttonStyle(ZiroSubtlePressButtonStyle())
        .accessibilityHint("Filters the model catalog")
        .accessibilityAddTraits(item == scope ? .isSelected : [])
    }

    /// Import entry: one glyph plus the title, no subtitle. What import
    /// means is explained once, on the wizard's own source screen —
    /// repeating it under every catalog visit is filler.

    private var importSection: some View {
        Section {
            Button { viewModel.showingImporter = true } label: {
                HStack(spacing: ZiroTheme.Spacing.medium) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                        .foregroundStyle(ZiroTheme.secondaryText)
                        .accessibilityHidden(true)
                    Text("Import from Hugging Face")
                        .font(ZiroType.rowTitle)
                        .foregroundStyle(ZiroTheme.primaryText)
                }
                .padding(.vertical, ZiroTheme.Spacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Sections

    private var installedSection: some View {
        Section {
            ForEach(viewModel.curatedModels.filter { viewModel.isDownloaded($0) }) { model in
                catalogRow(model)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
            }
        } header: {
            Text("On This Device")
        } footer: {
            Text("\(viewModel.managedStorageUsage) used on this device.")
        }
    }

    private var importedSection: some View {
        Section("Imported from Hugging Face") {
            ForEach(viewModel.importedModels) { model in
                catalogRow(model)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
            }
        }
    }

    private var availableSection: some View {
        let available = viewModel.curatedModels.filter { !viewModel.isDownloaded($0) }
        return Section(viewModel.hasInstalledModels ? "Available to Download" : "Choose a Model") {
            ForEach(available) { model in
                catalogRow(model)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
            }
            if available.isEmpty {
                emptyAvailableSection
            }
        }
    }

    private var emptyInstalledSection: some View {
        Section {
            ContentUnavailableView(
                "Nothing Installed Yet",
                systemImage: "tray",
                description: Text("Download a curated model or import one from Hugging Face.")
            )
            .transition(.opacity)
        }
    }

    /// Quiet terminal state: one centered line. The import entry sits
    /// directly above, so restating it here would be filler.
    private var emptyAvailableSection: some View {
        Text("All curated models are installed")
            .font(ZiroType.supporting)
            .foregroundStyle(ZiroTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, ZiroTheme.Spacing.large)
            .transition(.opacity)
    }
    // MARK: - Rows

    /// One quiet row per model: name, a single meta line, trailing status.
    /// The row itself is the single primary action — it opens the detail
    /// page where the description, capability choice, runtime state, and
    /// storage checks live.
    private func catalogRow(_ model: AIModel) -> some View {
        let status = viewModel.status(for: model)
        let meta = rowMeta(for: model)
        return HStack(spacing: ZiroTheme.Spacing.small) {
            NavigationLink(value: ShellRoute.modelDetail(id: model.id)) {
                ModelRow(model: model, meta: meta.text, metaWarning: meta.isWarning, status: status)
            }
            if status.isDownloading {
                Button { viewModel.requestCancelDownload(for: model) } label: {
                    // Same xmark.circle outline at .title3 as statusIndicator's
                    // cancelled state — tinted, not a separate .fill asset.
                    Image(systemName: "xmark.circle")
                        .font(.title3)
                        .frame(width: cancelControlSide, height: cancelControlSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ZiroSubtlePressButtonStyle())
                .foregroundStyle(ZiroTheme.secondaryText)
                .accessibilityLabel("Cancel \(model.displayName) download")
            }
        }
    }

    /// The row's single meta line: capability + size. The two transient
    /// states that need words swap in; repair is carried by the trailing
    /// indicator, and eligibility/quantization live on the detail page.
    private func rowMeta(for model: AIModel) -> (text: String, isWarning: Bool) {
        let status = viewModel.status(for: model)
        if model.modelType == .vision && !status.isVisionReady && viewModel.isDownloaded(model) {
            return ("Pair incomplete · \(model.formattedSize)", true)
        }
        if viewModel.isDownloaded(model) && viewModel.isOfflineVerificationPending {
            // Empty-report window: the deferred sweep has not landed yet.
            // Loading state only — never an error or false not-downloaded.
            return ("Verifying offline availability…", false)
        }
        return ("\(capabilityLabel(model)) · \(model.formattedSize)", false)
    }
    private func capabilityLabel(_ model: AIModel) -> String {
        let status = viewModel.status(for: model)
        if model.allowsTextOnlyCapability && !status.isVisionReady { return "Text only" }
        return model.modelType == .vision ? "Text + images" : "Text"
    }
}
