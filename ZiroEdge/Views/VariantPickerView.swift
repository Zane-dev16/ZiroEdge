// VariantPickerView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Reusable variant picker for multi-quantization GGUF repositories.
// Each artifact is listed with quantization, architecture, and digest info.
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
        ForEach(candidates) { artifact in
            VariantRow(
                artifact: artifact,
                isSelected: selection?.id == artifact.id,
                capability: capabilityEstimate(artifact)
            )
                .contentShape(Rectangle())
                .onTapGesture { selection = artifact }
        }
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
                    .lineLimit(1)
                HStack(spacing: ZiroTheme.Spacing.small) {
                    QuantizationBadge(label: artifact.quantization)
                    Text(artifact.architecture)
                        .font(ZiroType.technical(.caption))
                        .foregroundStyle(ZiroTheme.tertiaryText)
                    Text(StorageByteFormatter.string(fromByteCount: artifact.size))
                        .font(ZiroType.technical(.caption))
                        .foregroundStyle(ZiroTheme.tertiaryText)
                }
                if let caption = capability?.caption {
                    Text(caption)
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.tertiaryText)
                        .lineLimit(1)
                }
                Text("SHA-256 \(artifact.sha256.prefix(12))…")
                    .font(ZiroType.technical(.caption2))
                    .foregroundStyle(ZiroTheme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ZiroTheme.accent)
                    .font(.title3)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, ZiroTheme.Spacing.xSmall)
        // One reachable element per variant with button + selected traits, so
        // VoiceOver announces the current GGUF choice for this mandatory
        // step instead of scattering its texts. The visual checkmark is
        // hidden because the .isSelected trait already speaks "selected".
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
