// Typography.swift
// ZiroEdge — Privacy-first local AI assistant
//
// The type stack, split out of DesignSystem.swift when the bundled faces
// pushed that file past the 1000-line ceiling. Depends on SwiftUI alone.

import SwiftUI

// MARK: - Type Scale

/// ZiroEdge's type scale. Every role is a bundled face anchored to a system
/// text style via `Font.custom(_:size:relativeTo:)`, so Dynamic Type scaling
/// is inherited for free — never use fixed point sizes for text.
///
/// The stack (`ZiroEdge/Resources/Fonts`, registered in `Config/Info.plist`
/// `UIAppFonts`):
///
///   Orbitron 600/700   display only — the brand voice. NEVER body copy.
///   Satoshi 400/500/700  every text role: chat, chrome, hero copy.
///   Space Mono 400/700   the technical voice: model IDs, quant tiers, token
///                        counts, byte sizes, SHA fragments, timestamps.
///
/// Adding a role means adding a face here, not a `.font(.system(...))` at a
/// call site. `TypographyContractTests` asserts every face below resolves in
/// the shipped bundle.
enum ZiroType {

    // MARK: Faces

    /// Bundled faces by PostScript name — the identifier `Font.custom` wants.
    /// A wrong name here does not crash or hide text; it silently renders the
    /// system face at the same size, so the names are test-asserted.
    enum Face: String, CaseIterable {
        case orbitronSemiBold = "Orbitron-SemiBold"
        case orbitronBold = "Orbitron-Bold"
        case satoshiRegular = "Satoshi-Regular"
        case satoshiMedium = "Satoshi-Medium"
        case satoshiBold = "Satoshi-Bold"
        case spaceMonoRegular = "SpaceMono-Regular"
        case spaceMonoBold = "SpaceMono-Bold"
    }

    /// Default point size of a system text style at the (Large) content size
    /// category. These are the anchors that keep each bundled role optically
    /// where its system counterpart sat — `relativeTo:` then scales the role
    /// up and down the Dynamic Type ramp exactly like that style does.
    /// Kept in sync by `TypographyContractTests.testBaseSizesMatchTheSystemRamp`.
    static func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .subheadline: 15
        case .body: 17
        case .callout: 16
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }

    /// A bundled face at a text style's size, still Dynamic-Type scaled.
    static func face(_ face: Face, _ style: Font.TextStyle) -> Font {
        .custom(face.rawValue, size: baseSize(for: style), relativeTo: style)
    }

    // MARK: Roles

    /// Onboarding page titles — the largest brand moment. Orbitron only.
    /// Empty-state greetings and outcome heroes are `title` (Satoshi).
    static let display = face(.orbitronBold, .title)
    /// The ZIROEDGE wordmark in the onboarding header — the one place the
    /// brand voice is a single word.
    static let wordmark = face(.orbitronSemiBold, .caption)
    /// Page-level statements that are not brand heroes. Satoshi.
    static let title = face(.satoshiBold, .title3)
    /// Card headers, model detail identity, sheet titles.
    static let heading = face(.satoshiMedium, .headline)
    /// List row titles, banner titles, header-pill labels.
    static let rowTitle = face(.satoshiMedium, .subheadline)
    /// Message text and primary copy.
    static let body = face(.satoshiRegular, .callout)
    /// Secondary copy: descriptions, banner messages, subtitles.
    static let supporting = face(.satoshiRegular, .footnote)
    /// Inline support text and button labels in dense contexts.
    static let footnote = face(.satoshiRegular, .caption)
    /// Metadata, banner actions.
    static let caption = face(.satoshiRegular, .caption)
    /// Badges, micro-meta, download percentages.
    static let micro = face(.satoshiRegular, .caption2)

    // MARK: Weight-pinned roles

    /// Body copy one step heavier — the user's own message bubble, one step of
    /// optical hierarchy above the model's reply.
    ///
    /// These two exist because `.weight(_:)` on a custom face is not a weight
    /// dial: the Satoshi family has no semibold, so `.weight(.semibold)`
    /// resolves DOWN to Medium 500 (asserted by
    /// `TypographyContractTests.testSemiboldOnACustomFaceIsNotBold`). Pick a
    /// face instead of asking for a weight.
    static let bodyMedium = face(.satoshiMedium, .callout)
    /// Callout-size Satoshi **700** — button labels, where the contrast rules
    /// rather than taste decides: accent on `accentContainer` is 3.84:1 light /
    /// 3.20:1 dark, which clears AA only as bold ≥14pt (§4). Medium would put
    /// `ZiroPrimaryButtonStyle`/`Secondary`/`Destructive` below the floor.
    static let bodyStrong = face(.satoshiBold, .callout)

    /// The technical voice — timestamps, model IDs, quant tiers, byte sizes,
    /// SHA fragments. Default suits quant badges, token counts, file sizes;
    /// pass `.caption2` for SHA fragments, `.body` for model IDs in detail
    /// headers. Only two faces exist, so weights below medium snap to
    /// Regular and medium-or-heavier snap to Bold.
    static func technical(_ style: Font.TextStyle = .footnote, _ weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .ultraLight, .thin, .light, .regular:
            face(.spaceMonoRegular, style)
        default:
            face(.spaceMonoBold, style)
        }
    }

    /// Timestamps and other meta rows that sit beside a bubble.
    static let meta = technical(.caption2)
}
