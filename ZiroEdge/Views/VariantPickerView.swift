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
                Text(artifact.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: ZiroTheme.Spacing.small) {
                    QuantizationBadge(label: artifact.quantization)
                    Text(artifact.architecture)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(StorageByteFormatter.string(fromByteCount: artifact.size))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let caption = capability?.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text("SHA-256 \(artifact.sha256.prefix(12))…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
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

/// Compact quantization label. Highlights the variant's quality tier.
struct QuantizationBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, ZiroTheme.Spacing.badge)
            .padding(.vertical, ZiroTheme.Spacing.micro)
            .foregroundStyle(qualityTint)
            .background(qualityTint.opacity(0.12), in: Capsule())
    }

    private var qualityTint: Color {
        let upper = label.uppercased()
        // Semantic status tokens: raw .green/.orange fail 4.5:1 on light
        // backgrounds for badge text.
        if upper.contains("Q8") || upper.contains("F16") { return .blue }
        if upper.contains("Q6") { return .indigo }
        if upper.contains("Q5") { return .purple }
        if upper.contains("Q4") { return ZiroTheme.positiveText }
        if upper.contains("Q3") || upper.contains("Q2") { return ZiroTheme.warningText }
        return .secondary
    }
}

/// When there are no variants, show a useful empty state instead of blank space.
struct EmptyVariantView: View {
    let repositoryID: String

    var body: some View {
        VStack(spacing: ZiroTheme.Spacing.medium) {
            Image(systemName: "questionmark.folder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No compatible GGUF artifacts found in \(repositoryID).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ZiroTheme.Spacing.large)
    }
}
