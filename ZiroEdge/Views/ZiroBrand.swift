// ZiroBrand.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Brand surfaces: the logo mark, the full-viewport empty state, and the
// symbol-led hero for outcome pages. Split out of DesignSystem.swift so the
// token file stays under the project's file-length limit.

import SwiftUI

// MARK: - Brand Mark

/// ZiroEdge's brand mark: the ZE logo asset (white monogram with
/// transparency), rendered as a template glyph in the adaptive primary text
/// color so it floats on the surrounding surface — adaptive ink on paper in
/// light mode, near-white on navy in dark mode — with no baked tile.
/// One asset (`AppLogo` imageset, transparent) backs every in-app surface
/// (empty state, onboarding bar, galleries), so a logo swap is a single
/// asset replacement. The app icon (`AppIcon`, opaque) is a separate asset
/// and is untouched. Static by construction (no animation) so it is Reduce
/// Motion safe everywhere.
struct ZiroBrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        Image("AppLogo")
            // Template rendering uses the asset's alpha as a mask and tints
            // with the adaptive foreground: the transparent PNG has no baked
            // background, so the glyph blends into whatever surface sits
            // behind it instead of drawing the app-icon-style black box.
            // `.fit` (not `.fill`) so the full monogram stays visible — the
            // artwork occupies a centered subset of the square asset.
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(ZiroTheme.primaryText)
            .accessibilityHidden(true)
    }
}

// MARK: - Empty State Hero (the brand moment)

/// One guided starting point for the chat empty state: the prompt text
/// inserted into the composer plus the card's tinted dot. Dots use
/// `ZiroTheme` text tokens only (no raw hues): purple → `accentPurpleText`,
/// teal → `infoText` (closest cool data hue), third → `accentIndigoText`
/// (data hue, never a warning amber). Dots are decorative — the `primaryText`
/// label carries the meaning — so the pairing needs no contrast floor beyond the label's.
struct ZiroSuggestion {
    let text: String
    let dot: Color
}

/// Reference-style capability card: full-width row with a tinted dot,
/// two-line title, and a disclosure chevron on a raised-background card with
/// a `ZiroTheme.hairline` stroke (depth pair: stroke + `.ziroShadow(.raised)`
/// at the call site when floating).
/// 44pt minimum height meets the repo touch floor exactly; pressed state mirrors
/// `ZiroSuggestionChip` (accent container + accent edge). Reduce Motion
/// drops the press scale like the chip style does.
struct ZiroCapabilityCard: View {
    let item: ZiroSuggestion
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZiroTheme.Spacing.medium) {
                Circle()
                    .fill(item.dot)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(item.text)
                    .font(ZiroType.supporting.weight(.medium))
                    .foregroundStyle(ZiroTheme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ZiroTheme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, ZiroTheme.Spacing.large)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ZiroTheme.Radius.control, style: .continuous)
                    .fill(ZiroTheme.raisedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ZiroTheme.Radius.control, style: .continuous)
                    .stroke(ZiroTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(ZiroCapabilityCardStyle())
    }
}

private struct ZiroCapabilityCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: ZiroTheme.Radius.control, style: .continuous)
                    .fill(configuration.isPressed ? ZiroTheme.accentContainer : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ZiroTheme.Radius.control, style: .continuous)
                    .stroke(configuration.isPressed ? Color.accentColor : .clear, lineWidth: 1)
            )
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .animation(reduceMotion ? nil : ZiroMotion.press, value: configuration.isPressed)
    }
}

/// The chat empty state and other full-viewport resting moments.
/// Composition (top to bottom): the centered greeting title, one subtle
/// privacy caption, optional guided starting-point cards
/// (reference-style `ZiroCapabilityCard` rows when `suggestionItems` is
/// set, legacy `ZiroSuggestionChip` flow for plain `suggestions`), and
/// optional actions. No brand mark, glow, or wordmark — the greeting is
/// the moment. Everything is centered, capped at `ZiroMeasure.standard`,
/// and fully static (Reduce Motion safe).
struct ZiroEmptyState<Actions: View>: View {
    let title: String
    let message: String
    var suggestions: [String] = []
    /// Capability pills with per-card tint + chevron (preferred for chat).
    /// When non-empty this replaces the legacy chip flow below.
    var suggestionItems: [ZiroSuggestion] = []
    var onSuggestion: ((String) -> Void)? = nil
    @ViewBuilder var actions: () -> Actions

    init(
        title: String,
        message: String,
        suggestions: [String] = [],
        suggestionItems: [ZiroSuggestion] = [],
        onSuggestion: ((String) -> Void)? = nil,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.message = message
        self.suggestions = suggestions
        self.suggestionItems = suggestionItems
        self.onSuggestion = onSuggestion
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: ZiroTheme.Spacing.xLarge) {
            VStack(spacing: ZiroTheme.Spacing.small) {
                Text(title)
                    .font(ZiroType.title)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ZiroTheme.primaryText)
                // Subtitle renders only when non-empty: the chat empty state
                // passes empty to drop the caption before the Hello title,
                // while other callers (gallery preview) keep their message.
                if !message.isEmpty {
                    Text(message)
                        .font(ZiroType.supporting)
                        .foregroundStyle(ZiroTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, ZiroTheme.Spacing.large)
                }
            }
            .accessibilityElement(children: .combine)

            if !suggestionItems.isEmpty, let onSuggestion {
                VStack(spacing: ZiroTheme.Spacing.small) {
                    ForEach(Array(suggestionItems.enumerated()), id: \.offset) { index, item in
                        ZiroCapabilityCard(item: item) { onSuggestion(item.text) }
                            .accessibilityLabel(item.text)
                            .accessibilityHint("Inserts this starter prompt into the message field")
                            .accessibilityIdentifier("suggestion-card-\(index)")
                    }
                }
                .padding(.horizontal, ZiroTheme.Spacing.large)
            } else if !suggestions.isEmpty, let onSuggestion {
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
