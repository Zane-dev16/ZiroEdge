// VariantPickerView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Reusable variant picker for multi-quantization GGUF repositories.
// Minimal rows (chat voice): filename, size + quality tier, one fit note.
// The caller must explicitly pick one variant before import can proceed.

import SwiftUI

/// A picker that lists every compatible base GGUF in the pinned revision.
/// Selection is mandatory — the caller must explicitly pick a variant before import.
struct VariantPickerView: View {
    let candidates: [HFArtifact]
    @Binding var selection: HFArtifact?
    let capabilityEstimate: (HFArtifact) -> VariantCapabilityEstimate?

    init(
        candidates: [HFArtifact],
        selection: Binding<HFArtifact?>,
        capabilityEstimate: @escaping (HFArtifact) -> VariantCapabilityEstimate? = { _ in nil }
    ) {
        self.candidates = candidates
        _selection = selection
        self.capabilityEstimate = capabilityEstimate
    }

    var body: some View {
        VStack(spacing: ZiroTheme.Spacing.small) {            ForEach(candidates) { artifact in
                let isSelected = selection?.id == artifact.id
                Button { selection = artifact } label: {
                    VariantRow(
                        artifact: artifact,
                        isSelected: isSelected,
                        capability: capabilityEstimate(artifact)
                    )
                }
                .buttonStyle(ZiroSubtlePressButtonStyle())
                // One reachable element per variant: VoiceOver announces the
                // GGUF choice instead of scattering its texts. The visual
                // checkmark is hidden because .isSelected already speaks it.
                .accessibilityLabel(variantSpokenLabel(artifact))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private func variantSpokenLabel(_ artifact: HFArtifact) -> String {
        let size = StorageByteFormatter.string(fromByteCount: artifact.size)
        return "\(artifact.filename), \(size)"
    }
}

struct VariantRow: View {
    let artifact: HFArtifact
    let isSelected: Bool
    let capability: VariantCapabilityEstimate?

    var body: some View {
        HStack(spacing: ZiroTheme.Spacing.small) {
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
                // Artifact identity is engineering data — technical voice.
                Text(artifact.filename)
                    .font(ZiroType.technical(.subheadline))
                    .foregroundStyle(ZiroTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.85)
                HStack(spacing: ZiroTheme.Spacing.small) {
                    QuantizationBadge(label: artifact.quantization)
                    Text(StorageByteFormatter.string(fromByteCount: artifact.size))
                        .font(ZiroType.technical(.caption))
                        .foregroundStyle(ZiroTheme.secondaryText)
                }
                if let caption = capability?.caption {
                    Text(caption)
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.secondaryText)
                        // Safety signal — must never truncate the memory-fit
                        // text on the mandatory-choice step: no lineLimit +
                        // vertical fixedSize so it wraps (incl. AX sizes).
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: ZiroTheme.Spacing.small)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                // The live choice is the row's single accent, mirroring the
                // chat send disc (accent only while actionable); unchosen
                // rows keep a quiet hairline ring.
                .foregroundStyle(isSelected ? ZiroTheme.accent : ZiroTheme.tertiaryText)
                .font(.title3)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, ZiroTheme.Spacing.large)
        .padding(.vertical, ZiroTheme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ZiroTheme.Radius.control, style: .continuous)
                .fill(isSelected ? ZiroTheme.selectedBackground : ZiroTheme.raisedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ZiroTheme.Radius.control, style: .continuous)
                .stroke(isSelected ? Color.accentColor : ZiroTheme.hairline, lineWidth: isSelected ? 1.5 : 1)
        )
    }
}

/// Compact quantization label. Highlights the variant's quality tier. A thin
/// wrapper over `ZiroBadge` — the one badge system — with the spec's
/// quant-tier tone mapping (Q8/F16 → info, Q6 → indigo, Q5 → purple,
/// Q4 → positive, Q3/Q2 → warning, unknown → neutral) in the technical voice.
struct QuantizationBadge: View {
    let label: String

    var body: some View {
        ZiroBadge(text: label, tone: qualityTone, monospaced: true)
    }

    private var qualityTone: ZiroTone {
        let upper = label.uppercased()
        if upper.contains("Q8") || upper.contains("F16") { return .info }
        if upper.contains("Q6") { return .indigo }
        if upper.contains("Q5") { return .purple }
        if upper.contains("Q4") { return .positive }
        if upper.contains("Q3") || upper.contains("Q2") { return .warning }
        return .neutral
    }
}

/// When there are no variants, show a useful empty state instead of blank space.
struct EmptyVariantView: View {
    let repositoryID: String

    var body: some View {
        VStack(spacing: ZiroTheme.Spacing.medium) {
            Image(systemName: "questionmark.folder")
                .font(.largeTitle)
                .foregroundStyle(ZiroTheme.secondaryText)
            Text("No compatible GGUF artifacts found in \(repositoryID).")
                .font(ZiroType.supporting)
                .foregroundStyle(ZiroTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ZiroTheme.Spacing.large)
    }
}
