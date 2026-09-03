// ModelsView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Models catalog: one page split by a segmented scope picker into
// "Available" (browse/download) and "Installed" (on this device). Every row
// is a single card-style entry with a clear download status and one primary
// action (open the model's detail page, where capability choice and storage
// checks live). Import wizard and detail concerns are kept off this page.

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

    // Hit targets and icon gutters scale with Dynamic Type (like ChatView's
    // composerControlSide) so glyphs never overflow their frames at
    // accessibility sizes, while meeting the 44×44 hit-target minimum at the
    // default size.
    @ScaledMetric(relativeTo: .title3) private var cancelControlSide: CGFloat = 44
    /// The import row's accent icon square (44×44 min per the spec's import
    /// entry), scaling with Dynamic Type.
    @ScaledMetric(relativeTo: .title3) private var importIconSide: CGFloat = 44

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
                if !viewModel.hasInstalledModels { introductionSection }
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
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.large)
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
        .confirmationDialog(
            viewModel.pendingDeleteModel.map(viewModel.canForgetImport) == true ? "Forget Import" : "Delete Model",
            isPresented: $viewModel.showingDeleteConfirmation
        ) {
            Button(
                viewModel.pendingDeleteModel.map(viewModel.canForgetImport) == true ? "Forget Import" : "Delete",
                role: .destructive
            ) { Task { await viewModel.confirmDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let model = viewModel.pendingDeleteModel, viewModel.canForgetImport(model) {
                Text("Forget \(model.displayName)? Its import record and unreferenced partial transfer data will be removed.")
            } else {
                Text("Delete \(viewModel.pendingDeleteModel?.displayName ?? "this model")? You can download it again later.")
            }
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

    // MARK: - Scope

    private var scopeSection: some View {
        Section {
            Picker("Catalog scope", selection: $scope) {
                Text("Available").tag(Scope.available)
                Text("Installed").tag(Scope.installed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // labelsHidden also drops the title from the a11y tree, leaving
            // the segments unnamed for VoiceOver (r4 MEDIUM).
            .accessibilityLabel("Catalog scope")
        }
    }

    private var introductionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                Label("Runs entirely on your device", systemImage: "lock.shield")
                    .font(ZiroType.rowTitle)
                    .foregroundStyle(ZiroTheme.accent)
                Text("Download one model to begin. Larger models can be more capable, while smaller models load faster and use less memory.")
                    .font(ZiroType.supporting)
                    .foregroundStyle(ZiroTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, ZiroTheme.Spacing.small)
        }
    }

    private var importSection: some View {
        Section {
            Button { viewModel.showingImporter = true } label: {
                HStack(spacing: ZiroTheme.Spacing.medium) {
                    // Import-entry icon in the spec's accent-tinted rounded
                    // square (44×44 min, Radius.small), scaling with
                    // Dynamic Type so the glyph never overflows.
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.title3)
                        .foregroundStyle(ZiroTheme.accent)
                        .frame(width: importIconSide, height: importIconSide)
                        .background(
                            ZiroTheme.accentContainer,
                            in: RoundedRectangle(cornerRadius: ZiroTheme.Radius.small, style: .continuous)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
                        Text("Import from Hugging Face")
                            .font(ZiroType.rowTitle)
                            .foregroundStyle(ZiroTheme.accent)
                        Text("Bring a compatible GGUF model onto this device.")
                            .font(ZiroType.caption)
                            .foregroundStyle(ZiroTheme.secondaryText)
                    }
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
                catalogRow(model, subtitle: installedSubtitle(for: model))
            }
        } header: {
            Text("On This Device")
        } footer: {
            Text("Managed model storage: \(viewModel.managedStorageUsage), including installed, in-progress, resumable, and quarantined files.")
        }
    }

    private var importedSection: some View {
        Section("Imported from Hugging Face") {
            ForEach(viewModel.importedModels) { model in
                catalogRow(model, subtitle: model.description)
            }
        }
    }

    private var availableSection: some View {
        let available = viewModel.curatedModels.filter { !viewModel.isDownloaded($0) }
        return Section(viewModel.hasInstalledModels ? "Available to Download" : "Choose a Model") {
            ForEach(available) { model in
                catalogRow(model, subtitle: model.description)
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
        }
    }

    private var emptyAvailableSection: some View {
        VStack(spacing: ZiroTheme.Spacing.small) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(ZiroTheme.positiveText)
                .accessibilityHidden(true)
            Text("All curated models are installed")
                .font(ZiroType.rowTitle)
            Text("Import a model from Hugging Face to add more.")
                .font(ZiroType.supporting)
                .foregroundStyle(ZiroTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ZiroTheme.Spacing.large)
    }

    // MARK: - Rows

    /// One card per model: identity, short subtitle, meta, and a trailing
    /// status indicator. The row itself is the single primary action — it
    /// opens the detail page where download decisions are made.
    private func catalogRow(_ model: AIModel, subtitle: String) -> some View {
        let status = viewModel.status(for: model)
        return HStack(spacing: ZiroTheme.Spacing.small) {
            NavigationLink {
                ModelDetailView(model: model, viewModel: viewModel, onStartChatting: onStartChatting)
            } label: {
                ModelRow(model: model, subtitle: subtitle, status: status)
            }
            if status.isDownloading {
                Button { viewModel.requestCancelDownload(for: model) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .frame(width: cancelControlSide, height: cancelControlSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ZiroTheme.secondaryText)
                .accessibilityLabel("Cancel \(model.displayName) download")
            }
        }
    }

    private func installedSubtitle(for model: AIModel) -> String {
        var details = [capabilityLabel(model)]
        if viewModel.isVerifiedForOfflineUse(model) {
            details.append("Verified for offline use")
        } else {
            details.append("Offline verification pending")
        }
        return details.joined(separator: " · ")
    }

    private func capabilityLabel(_ model: AIModel) -> String {
        let status = viewModel.status(for: model)
        if model.allowsTextOnlyCapability && !status.isVisionReady { return "Text only" }
        return model.modelType == .vision ? "Text + images" : "Text"
    }
}

// MARK: - Model Row

/// Unified catalog card for curated and imported models, in both scopes.
private struct ModelRow: View {
    let model: AIModel
    let subtitle: String
    let status: ModelDownloadStatus

    // Icon gutter scales with Dynamic Type so the title3 glyph never
    // overflows the column at accessibility sizes.
    @ScaledMetric(relativeTo: .title3) private var iconColumnWidth: CGFloat = 30

    var body: some View {
        HStack(spacing: ZiroTheme.Spacing.medium) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(ZiroTheme.accent)
                .symbolRenderingMode(.hierarchical)
                .frame(width: iconColumnWidth)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
                HStack(spacing: ZiroTheme.Spacing.small) {
                    Text(model.displayName)
                        .font(ZiroType.rowTitle)
                    capabilityBadge
                }
                Text(subtitle)
                    .font(ZiroType.supporting)
                    .foregroundStyle(ZiroTheme.secondaryText)
                    .lineLimit(2)
                // Single wrapping Text with styled runs: sibling Texts in an
                // HStack truncate to fragments at accessibility sizes, and the
                // safety-tinted runtime state must stay legible and spoken.
                // The size/quantization tail is engineering data — technical
                // (monospaced) voice per the type scale.
                (Text(model.runtimeEligibility.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(eligibilityTint) +
                 Text(" · \(model.formattedSize) · \(model.quantization)")
                    .font(ZiroType.technical(.caption))
                    .foregroundStyle(ZiroTheme.tertiaryText))
            }

            Spacer(minLength: ZiroTheme.Spacing.small)
            statusIndicator
        }
        .padding(.vertical, ZiroTheme.Spacing.xSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    /// Combined row label. Repair-needed rows must not announce the generic
    /// "available to download" — the visible orange Repair state is the row's
    /// most important information, so it is spoken plus a pointer to the fix.
    private var rowAccessibilityLabel: String {
        var label = "\(model.displayName), \(subtitle), \(model.runtimeEligibility.label), \(model.formattedSize), \(status.statusAccessibilityLabel(for: model))"
        if status.presentsAsRepairNeeded(for: model) {
            label += ". Open the model to repair its download."
        }
        return label
    }

    private var iconName: String {
        guard model.modelType == .vision else { return "text.bubble.fill" }
        return status.isVisionReady ? "eye.circle.fill" : "eye.slash.circle.fill"
    }

    @ViewBuilder
    private var capabilityBadge: some View {
        // The one badge system: VISION is a purple data hue, PAIR INCOMPLETE
        // a warning — both verified token pairs via ZiroBadge.
        if status.isVisionReady {
            ZiroBadge(text: "VISION", tone: .purple)
        } else if model.modelType == .vision {
            ZiroBadge(text: "PAIR INCOMPLETE", tone: .warning)
        }
    }

    private var eligibilityTint: Color {
        // Semantic status tokens: raw .green/.orange fail 4.5:1 on light
        // backgrounds for caption-size text.
        switch model.runtimeEligibility {
        case .validated: ZiroTheme.positiveText
        case .experimental: ZiroTheme.warningText
        case .unavailable: ZiroTheme.secondaryText
        }
    }

    /// Ring plus a Dynamic Type-scaling percentage label. The percentage is
    /// the only visible transfer indicator, so it can't live at a fixed 9pt
    /// inside the 26pt ring (r4 MEDIUM) — it sits beside the ring at caption2
    /// and scales with the user's text size. Hidden from a11y: the row's
    /// combined label already announces the percentage.
    private func downloadProgressIndicator(_ progress: Double, tint: Color) -> some View {
        HStack(spacing: ZiroTheme.Spacing.micro) {
            ZiroProgressRing(progress: progress, tint: tint)
            Text("\(Int((progress * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(ZiroTheme.secondaryText)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status.displayState {
        case .downloading(let progress), .resuming(let progress), .pausing(let progress):
            downloadProgressIndicator(progress, tint: ZiroTheme.accent)
        case .paused(let progress):
            downloadProgressIndicator(progress, tint: ZiroTheme.secondaryText)
        case .verifying:
            VStack(spacing: ZiroTheme.Spacing.xSmall) {
                ProgressView()
                Text("Verifying")
                    .font(ZiroType.micro)
                    .foregroundStyle(ZiroTheme.secondaryText)
            }
            .accessibilityHidden(true)
        case .failed:
            // Hard failure → the danger token (raw .red fails AA for this size).
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(ZiroTheme.dangerText)
                .accessibilityLabel("Download failed")
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(ZiroTheme.secondaryText)
                .accessibilityLabel("Download cancelled")
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ZiroTheme.positiveText)
                .accessibilityHidden(true)
        case .notDownloaded:
            if status.isRepairNeeded || ModelManagerService.isRepairNeeded(for: model) {
                Text("Repair")
                    .font(ZiroType.caption.weight(.semibold))
                    .foregroundStyle(ZiroTheme.warningText)
                    .accessibilityLabel("Repair \(model.displayName)")
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(ZiroTheme.accent)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension ModelDownloadStatus {
    /// Whether this status should be presented as repair-needed (files on
    /// disk failed validation, or a partial pair needs re-download). Shared
    /// by the row indicator and its accessibility label so the two never
    /// disagree.
    func presentsAsRepairNeeded(for model: AIModel) -> Bool {
        guard case .notDownloaded = displayState else { return false }
        return isRepairNeeded || ModelManagerService.isRepairNeeded(for: model)
    }

    /// Spoken status for a catalog row; preserved from the pre-redesign
    /// catalog so VoiceOver and tests keep hearing the same phrases. The
    /// `.notDownloaded` case branches on repair state: repair-needed rows
    /// announce "needs repair" instead of "available to download".
    func statusAccessibilityLabel(for model: AIModel) -> String {
        switch displayState {
        case .downloading(let progress): return "downloading, \(Int(progress * 100)) percent complete"
        case .pausing(let progress): return "pausing, \(Int(progress * 100)) percent complete"
        case .paused(let progress): return "paused, \(Int(progress * 100)) percent complete"
        case .resuming(let progress): return "resuming, \(Int(progress * 100)) percent complete"
        case .verifying: return "verifying download"
        case .failed: return "download failed"
        case .cancelled: return "download cancelled"
        case .downloaded: return "installed"
        case .notDownloaded:
            return presentsAsRepairNeeded(for: model) ? "needs repair" : "available to download"
        }
    }
}
