// ImportSharedCards.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Shared import cards composed by the wizard and the imported-model
// update flow: PreflightCard, RAMAssessmentCard, LicenseRow,
// ConfidenceBadge, ImportArtifactSummaryRow.

import SwiftUI

// MARK: - Reusable Pieces

/// Storage verdict in two lines: does it fit, and the numbers behind it.
/// The old three-row ledger (required / margin / available) asked the user
/// to do the subtraction; the preflight already did.
struct PreflightCard: View {
    let storage: ImportStoragePreflight

    var body: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            if storage.canProceed {
                Label("Enough storage", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(ZiroTheme.positiveText)
            } else {
                Label("Not enough storage. No download can start.", systemImage: "internaldrive.fill.badge.xmark")
                    .foregroundStyle(ZiroTheme.warningText)
                    .announcingOnAppear("Not enough storage. No download can start.")
            }
            // Byte sizes are engineering data — technical voice.
            Text(storageLine)
                .font(ZiroType.technical(.caption))
                .foregroundStyle(ZiroTheme.secondaryText)
        }
    }

    private var storageLine: String {
        let need = StorageByteFormatter.string(fromByteCount: storage.requiredBytes)
        let free = StorageByteFormatter.string(fromByteCount: storage.availableBytes)
        return "\(need) needed · \(free) free"
    }
}

/// Memory verdict in two lines: the estimate behind one caption, the
/// acknowledgment only when the download is risky.
struct RAMAssessmentCard: View {
    let assessment: ImportRAMAssessment
    @Binding var riskAccepted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            switch assessment.classification {
            case .likelyFits:
                Label("Should run within this device's memory.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(ZiroTheme.positiveText)
            case .risky:
                if let warning = assessment.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ZiroTheme.warningText)
                }
            }
            Text(needsLine)
                .font(ZiroType.technical(.caption))
                .foregroundStyle(ZiroTheme.secondaryText)
            if assessment.classification == .risky {
                Toggle("Download despite RAM risk", isOn: $riskAccepted)
            }
        }
    }

    private var needsLine: String {
        let need = StorageByteFormatter.string(
            fromByteCount: Int64(clamping: assessment.estimatedBytes),
            countStyle: .memory
        )
        let have = StorageByteFormatter.string(
            fromByteCount: Int64(clamping: assessment.physicalBytes),
            countStyle: .memory
        )
        return "Needs ~\(need) · this device has \(have)"
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

/// One artifact (base or projector) in two lines: role, then filename.
/// Size and digest live with the pair header and the pinned revision —
/// this row only answers "which file plays which part".
struct ImportArtifactSummaryRow: View {
    let role: String
    let icon: String
    let artifact: HFArtifact

    var body: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
            Label(role, systemImage: icon)
                .font(ZiroType.caption)
                .foregroundStyle(ZiroTheme.secondaryText)
            // Artifact identity is engineering data — technical voice.
            Text(artifact.filename)
                .font(ZiroType.technical(.footnote))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}
