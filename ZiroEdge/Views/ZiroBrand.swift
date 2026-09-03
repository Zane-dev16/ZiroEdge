// ZiroBrand.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Brand surfaces: the logo mark, the full-viewport empty state, and the
// symbol-led hero for outcome pages. Split out of DesignSystem.swift so the
// token file stays under the project's file-length limit.

import SwiftUI

// MARK: - Brand Mark

/// ZiroEdge's brand mark: the ZE logo asset (white monogram on black),
/// presented as a continuous rounded tile with a hairline edge. One asset
/// (`AppLogo` imageset) backs the app icon motif and every in-app surface
/// (empty state, onboarding bar, galleries), so a logo swap is a single
/// asset replacement. Static by construction (no animation) so it is
/// Reduce Motion safe everywhere.
struct ZiroBrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        Image("AppLogo")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .stroke(ZiroTheme.hairlineStrong, lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Empty State Hero (the brand moment)

/// The chat empty state and other full-viewport resting moments. Composition
/// (top to bottom): the brand mark over a soft ember glow, the ZIROEDGE
/// wordmark, the title, the privacy message, optional guided starting-point
/// chips, and optional actions. Everything is centered, capped at
/// `ZiroMeasure.standard`, and fully static (Reduce Motion safe).
struct ZiroEmptyState<Actions: View>: View {
    let title: String
    let message: String
    var suggestions: [String] = []
    var onSuggestion: ((String) -> Void)? = nil
    @ViewBuilder var actions: () -> Actions

    @ScaledMetric(relativeTo: .largeTitle) private var markSize: CGFloat = 68

    init(
        title: String,
        message: String,
        suggestions: [String] = [],
        onSuggestion: ((String) -> Void)? = nil,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.message = message
        self.suggestions = suggestions
        self.onSuggestion = onSuggestion
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: ZiroTheme.Spacing.xLarge) {
            ZiroBrandMark(size: markSize)
                .background(
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0)],
                                center: .center,
                                startRadius: markSize * 0.2,
                                endRadius: markSize * 1.15
                            )
                        )
                        .frame(width: markSize * 2.2, height: markSize * 2.2)
                )

            VStack(spacing: ZiroTheme.Spacing.small) {
                Text("ZIROEDGE")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(ZiroTheme.secondaryText)
                Text(title)
                    .font(ZiroType.title)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ZiroTheme.primaryText)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(ZiroTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ZiroTheme.Spacing.large)
            }
            .accessibilityElement(children: .combine)

            if !suggestions.isEmpty, let onSuggestion {
                ZiroFlowLayout(spacing: ZiroTheme.Spacing.small) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        ZiroSuggestionChip(
                            title: suggestion,
                            systemImage: "sparkle",
                            action: { onSuggestion(suggestion) }
                        )
                    }
                }
                .padding(.horizontal, ZiroTheme.Spacing.large)
            }

            actions()
        }
        .frame(maxWidth: ZiroMeasure.standard)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Hero (kept, refined)

/// Symbol-led hero for outcome pages (import complete, duplicate import,
/// store recovery). The chat empty state uses `ZiroEmptyState` instead —
/// that one carries the brand mark.
struct ZiroHero: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: ZiroTheme.Spacing.large) {
            Image(systemName: symbol)
                .font(.largeTitle.weight(.medium))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(title)
                .font(ZiroType.title)
                .foregroundStyle(ZiroTheme.primaryText)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(ZiroTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: ZiroMeasure.standard)
    }
}
