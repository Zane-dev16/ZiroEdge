// ModelCatalogRow.swift
// ZiroEdge — Privacy-first local AI assistant
//
// One quiet catalog row for the Models page (curated and imported models,
// both scopes): name, a single meta line, trailing status. Description,
// eligibility, and quantization live on the detail page one tap away.

import SwiftUI

/// Row type is internal: ModelsView builds it per catalog entry.
struct ModelRow: View {
    let model: AIModel
    let meta: String
    let metaWarning: Bool
    let status: ModelDownloadStatus

    var body: some View {
        HStack(spacing: ZiroTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
                Text(model.displayName)
                    .font(ZiroType.rowTitle)
                Text(meta)
                    .font(ZiroType.supporting)
                    .foregroundStyle(metaWarning ? ZiroTheme.warningText : ZiroTheme.secondaryText)
                    .lineLimit(1)
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
        var label = "\(model.displayName), \(meta), \(status.statusAccessibilityLabel(for: model))"
        if status.presentsAsRepairNeeded(for: model) {
            label += ". Open the model to repair its download."
        }
        return label
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
            // Outline-default: sibling trailing states share one size
            // (.title3) with .fill reserved for the installed state below.
            Image(systemName: "exclamationmark.circle")
                .font(.title3)
                .foregroundStyle(ZiroTheme.dangerText)
                .accessibilityLabel("Download failed")
        case .cancelled:
            Image(systemName: "xmark.circle")
                .font(.title3)
                .foregroundStyle(ZiroTheme.secondaryText)
                .accessibilityLabel("Download cancelled")
        case .downloaded:
            // The one .fill on this surface: installed/active state.
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(ZiroTheme.positiveText)
                .accessibilityHidden(true)
        case .notDownloaded:
            if status.isRepairNeeded || ModelManagerService.isRepairNeeded(for: model) {
                Text("Repair")
                    .font(ZiroType.caption)
                    .foregroundStyle(ZiroTheme.warningText)
                    .accessibilityLabel("Repair \(model.displayName)")
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
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
            if presentsAsRepairNeeded(for: model) {
                return ArtifactIntegrityPresentation.needsRepairSpoken
            }
            return "available to download"
        }
    }
}
