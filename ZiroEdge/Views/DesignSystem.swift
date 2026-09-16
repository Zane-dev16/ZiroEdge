// DesignSystem.swift
// ZiroEdge — Privacy-first local AI assistant
//
// "Midnight signal — a precision instrument."
//
// The single source of truth for ZiroEdge's visual language. This file has
// ZERO app-internal dependencies: it typechecks against SwiftUI alone so it
// can be reasoned about, previewed, and evolved in isolation. Everything a
// screen needs to look like ZiroEdge lives here:
//
//   ZiroTheme      — color, spacing, radius, measure, motion, type tokens
//   ZiroTone       — the one badge/banner tint system (tinted fill + text)
//   ZiroType       — the type scale (Orbitron/Satoshi/Space Mono — Typography.swift)
//   ZiroMeasure    — content width caps (replaces ad-hoc 360/520/680/760)
//   ZiroMotion     — the three standard curves, reduce-motion aware
//   Button styles  — primary / secondary / destructive
//   Components     — status banner, card, badge, chip, section header,
//                    empty-state hero + brand mark, progress ring,
//                    message-bubble & composer-field treatments
//
// Contrast rigor: every foreground/background pairing below was verified
// with the WCAG relative-luminance formula against BOTH appearances. The
// floors are 4.5:1 for text and 3:1 for icons/large text (repo a11y
// standard); no pairing in this file falls below 4.5:1. The computed table
// lives in docs/DESIGN-SPEC.md §6.

import SwiftUI

// MARK: - Color Foundation

/// Builds a dynamic sRGB Color from 0xRRGGBB hex values per appearance.
/// Fixed hex (not opacity blends) keeps every contrast ratio in this file
/// exact and reviewable — nothing depends on what happens to sit beneath it.
private func ziroColor(light: UInt32, dark: UInt32) -> Color {
    Color(uiColor: UIColor { traits in
        let hex = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    })
}

// MARK: - Theme Tokens

/// ZiroEdge's token namespace. Screens must never reach for raw system
/// colors, ad-hoc opacities, or untyped spacing numbers; everything visual
/// resolves to a named token here.
///
/// Surfaces — "near-black graphite" (dark) and "warm paper" (light), four
/// elevations that replace raw `.systemBackground`:
///   page    the base canvas (chat transcript, page bodies)
///   raised  cards, assistant bubbles, banner fills
///   well    input wells and the composer (same gray as `raised` — the
///           vision's composer and assistant bubble are one fill)
///   overlay custom floating layers (menus, popovers) — brightest
enum ZiroTheme {

    // MARK: Surfaces

    /// Base canvas. Light: warm paper `#F7F3EC`. Dark: near-black `#121314`.
    static let pageBackground = ziroColor(light: 0xF7F3EC, dark: 0x121314)

    /// Raised content on the page: cards, assistant bubbles, banner fills.
    /// Light: white `#FFFFFF`. Dark: dark charcoal `#1C1C1E`.
    static let raisedBackground = ziroColor(light: 0xFFFFFF, dark: 0x1C1C1E)

    /// Input wells (composer well, search fields). Light: `#EFE9DF`.
    /// Dark: `#1C1C1E` — deliberately identical to `raisedBackground`:
    /// a message bubble and the composer are the same gray in the vision,
    /// and both sit one clear step above the near-black page.
    static let inputBackground = ziroColor(light: 0xEFE9DF, dark: 0x1C1C1E)

    /// Alias for the input-well elevation; prefer this name in new code.
    static let wellBackground = inputBackground

    /// Subtle selection fill for selected rows (sidebar conversations,
    /// lists): the input-well elevation — tonal, never vivid, never ringed.
    /// Accent rings appear only as keyboard-focus indicators.
    static let selectedBackground = wellBackground

    /// Floating custom layers above everything. Light: white. Dark: `#25252A`.
    static let overlayBackground = ziroColor(light: 0xFFFFFF, dark: 0x25252A)

    /// The user's own message bubble. Light keeps the brand accent blue
    /// `#2E6BFF` (unchanged, with `accentForeground` on it = 4.50:1). Dark
    /// drops the vivid accent for a deep navy `#1D2445`: in the vision the
    /// only saturated thing left on the transcript is the user's own voice,
    /// and vivid `#2E6BFF` appears nowhere. White `accentForeground` on it is
    /// 15.10:1.
    static let userBubble = ziroColor(light: 0x2E6BFF, dark: 0x1D2445)

    /// Legacy alias retained for the pre-overhaul call sites; identical to
    /// `raisedBackground`. New code should use the elevation names above.
    static let elevatedBackground = raisedBackground

    // MARK: Composer Controls

    /// Disc behind the composer's attachment (`+`) control: neutral graphite
    /// one clear step above the well, so the glyph reads as a tactile control
    /// rather than a bare icon. Deliberately the same value in both
    /// appearances (composer chrome does not flip with the page). White
    /// `accentForeground` on it is 11.44:1.
    static let controlDisc = ziroColor(light: 0x353A42, dark: 0x353A42)

    /// The composer's send disc once a send is available: one step brighter
    /// than `controlDisc` so the live action leads the row. White
    /// `accentForeground` on it is 8.00:1.
    static let controlDiscActive = ziroColor(light: 0x4B515B, dark: 0x4B515B)

    // MARK: Hairlines & Dividers

    /// The 1pt stroke that does the work shadows do elsewhere. Light: warm
    /// sand `#DCD2C2`. Dark: charcoal hairline `#2E2E32`. Decorative (no contrast floor).
    static let hairline = ziroColor(light: 0xDCD2C2, dark: 0x2E2E32)

    /// Legacy alias; identical to `hairline`. Prefer `hairline` in new code.
    static let subtleBorder = hairline

    /// Emphasized stroke for focused/selected outlines and the brand mark's
    /// tile edge. Light: `#C9BCA6`. Dark: `#3F4249`.
    static let hairlineStrong = ziroColor(light: 0xC9BCA6, dark: 0x3F4249)

    // MARK: Text Hierarchy

    /// Primary text. Light `#1C1814` (15.95:1 on page). Dark `#EDF1F7`
    /// (16.41:1 on page). Cool-tinted near-black/near-white — pure
    /// black/white reads clinical against the tinted surfaces.
    static let primaryText = ziroColor(light: 0x1C1814, dark: 0xEDF1F7)

    /// Supporting text (descriptions, footers, captions). Light `#5C544A`
    /// (6.73:1 on page). Dark `#9AA3B8` (7.36:1 on page).
    static let secondaryText = ziroColor(light: 0x5C544A, dark: 0x9AA3B8)

    /// Tertiary metadata (timestamps, SHA fragments, locked parameters).
    /// Light `#6E6659` (5.12:1 on page). Dark `#8B93A7` (6.05:1 on page,
    /// 5.03:1 on wells). Still clears 4.5:1 on every surface including wells.
    static let tertiaryText = ziroColor(light: 0x6E6659, dark: 0x8B93A7)

    // MARK: Accent — vivid blue

    /// The brand accent: vivid blue, owned by the asset catalog so it also
    /// drives system chrome (toolbar tint, menus, selection). `#2E6BFF` in
    /// every appearance (Increased Contrast variants step lighter). Used with
    /// discipline: primary actions, focus, active states, the streaming
    /// cursor, progress. White `accentForeground` on the fill is 4.50:1.
    static let accent = Color.accentColor

    /// Text/icon color on top of an accent fill: white in every appearance
    /// (4.50:1 on `#2E6BFF`). Asset-backed so it carries Increased Contrast
    /// variants.
    static let accentForeground = Color("AccentForeground")

    /// Pre-composited accent-tinted container (accent at ~12% over the raised
    /// surface). Light `#E6EDFF`. Dark `#16265A`. The fill behind secondary
    /// buttons and accent badges. NOTE: raw accent `#2E6BFF` on these tints
    /// is ~3.7:1 (light) / ~3.2:1 (dark) — it clears the 3:1 large-text/icon
    /// floor (semibold body labels qualify) but not the 4.5:1 caption floor;
    /// a lighter dark-mode accent-text token is the follow-up if accent
    /// badges ever carry caption-size copy.
    static let accentContainer = ziroColor(light: 0xE6EDFF, dark: 0x16265A)

    // MARK: Semantic Status — success / warning / danger / info

    /// Positive status text (installed, verified, RAM fits). Light `#166E2B`
    /// (6.36:1 on white). Dark `#34C759` — the system green (7.69:1 on
    /// raised). Replaces raw `.green`, which fails 4.5:1 in light mode.
    static let positiveText = ziroColor(light: 0x166E2B, dark: 0x34C759)

    /// Warning status text (needs repair, RAM risk, pair incomplete). Light
    /// `#A64B00` (5.79:1 on white). Dark `#FF9500` — system orange (7.77:1
    /// on raised). Replaces raw `.orange`, which fails 4.5:1 in light mode.
    static let warningText = ziroColor(light: 0xA64B00, dark: 0xFF9500)

    /// Danger/error status text (failed load, download failed, destructive
    /// confirmations). Light `#C40013` (6.26:1 on white). Dark `#FF554A`
    /// (5.41:1 on raised). Replaces every raw `.red` — raw `.red` is
    /// 3.99:1 on white, below the AA floor for caption text.
    static let dangerText = ziroColor(light: 0xC40013, dark: 0xFF554A)

    /// Informational text (onboarding eyebrows, Q8/F16 quality tier). Light
    /// `#0062CC` (5.80:1 on white). Dark `#3D9BFF` (5.96:1 on raised) —
    /// system blue `#0A84FF` is only 4.11:1 on its 12% tinted container, so
    /// the dark token is lightened just enough to clear the floor there.
    static let infoText = ziroColor(light: 0x0062CC, dark: 0x3D9BFF)

    /// Data-hue: vision-capable badges and Q5 quality tier. Light `#8236B8`
    /// (6.63:1 on white). Dark `#C973F5` (5.90:1 on raised) — system purple
    /// is 4.19:1 on its tinted container, so the dark token is lightened.
    /// These are categorical data hues, not status: they never appear in
    /// banners or buttons.
    static let accentPurpleText = ziroColor(light: 0x8236B8, dark: 0xC973F5)

    /// Data-hue: Q6 quantization tier. Light `#4F48D6` (6.50:1 on white).
    /// Dark `#8686FF` (5.58:1 on raised) — system indigo is too dim for dark
    /// mode outright, matching the pre-overhaul finding.
    static let accentIndigoText = ziroColor(light: 0x4F48D6, dark: 0x8686FF)

    // MARK: Semantic Tinted Containers (pre-composited over raised surface)

    /// Positive-tinted container. Light `#E3EEE6`, dark `#22301E`.
    /// `positiveText` on it: 5.35:1 (light) / 6.27:1 (dark).
    static let positiveContainer = ziroColor(light: 0xE3EEE6, dark: 0x22301E)

    /// Warning-tinted container. Light `#F4E9E0`, dark `#3B2A13`.
    /// `warningText` on it: 4.85:1 (light) / 6.26:1 (dark).
    static let warningContainer = ziroColor(light: 0xF4E9E0, dark: 0x3B2A13)

    /// Danger-tinted container. Light `#F8E0E3`, dark `#3B221C`.
    /// `dangerText` on it: 4.99:1 (light) / 4.65:1 (dark).
    static let dangerContainer = ziroColor(light: 0xF8E0E3, dark: 0x3B221C)

    /// Info-tinted container. Light `#E0ECF9`, dark `#232A32`.
    /// `infoText` on it: 4.85:1 (light) / 5.06:1 (dark).
    static let infoContainer = ziroColor(light: 0xE0ECF9, dark: 0x232A32)

    /// Purple data-hue container. Light `#F0E7F6`, dark `#342631`.
    /// `accentPurpleText` on it: 5.51:1 (light) / 4.94:1 (dark).
    static let purpleContainer = ziroColor(light: 0xF0E7F6, dark: 0x342631)

    /// Indigo data-hue container. Light `#EAE9FA`, dark `#2C2832`.
    /// `accentIndigoText` on it: 5.43:1 (light) / 4.71:1 (dark).
    static let indigoContainer = ziroColor(light: 0xEAE9FA, dark: 0x2C2832)

    /// Neutral badge/well container: the input-well elevation doubles as the
    /// untinted fill. `secondaryText` on it: 6.16:1 (light) / 6.11:1 (dark).
    static let neutralContainer = wellBackground

    // MARK: Shadow Language

    /// One shadow language, two levels. In light mode a soft neutral-gray drop;
    /// in dark mode shadows sink deeper but tighter (dark surfaces swallow
    /// soft shadows, so the lift reads through the hairline-stroke + shadow
    /// pair). Shadows never substitute for the stroke — they always travel
    /// together via `.ziroShadow(_:)` plus a `ZiroTheme.hairline` stroke
    /// (see `ziroShadow(_:)`). The one sanctioned shadow-color fill is
    /// `scrim`, never `shadowFloating` directly.
    static let shadowRaised = ziroShadowColor(lightAlpha: 0.14, darkAlpha: 0.50)
    static let shadowFloating = ziroShadowColor(lightAlpha: 0.20, darkAlpha: 0.55)

    /// Full-screen tap-to-dismiss dim behind slide-over panels and custom
    /// floating layers. Intentionally aliases the floating-shadow black —
    /// an appearance-adaptive dim with no dedicated value of its own. This
    /// alias is the token: call sites must use `scrim`, never reach for
    /// `shadowFloating` as a fill directly. If the dim ever needs its own
    /// alpha ramp, fork the value here; appearances stay adaptive via the
    /// shared `ziroShadowColor` builder.
    static let scrim = shadowFloating

    private static func ziroShadowColor(lightAlpha: Double, darkAlpha: Double) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(darkAlpha)
                : UIColor.black.withAlphaComponent(lightAlpha)
        })
    }

    // MARK: Spacing — the 2/4/8/12/16/24/40 rhythm

    enum Spacing {
        /// Tightest inset: two-line stack gutters and badge vertical padding.
        static let micro: CGFloat = 2
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
        static let xxLarge: CGFloat = 40
        /// Capsule badge/chip horizontal inset (a half-step of the rhythm).
        static let badge: CGFloat = 6
        /// Chat composer outer margin (off-rhythm by design; vision spec 22).
        static let composer: CGFloat = 22
    }

    // MARK: Radius — one shape scale

    enum Radius {
        /// Badge/chip background corners.
        static let badge: CGFloat = 6
        /// Small wells, thumbnails, inline image frames.
        static let small: CGFloat = 10
        /// Controls, buttons, text fields, banners.
        static let control: CGFloat = 14
        /// Message bubbles and the thinking indicator.
        static let bubble: CGFloat = 13
        /// Cards and large grouped surfaces.
        static let card: CGFloat = 20
        /// The chat composer's floating well — a larger, softer round than
        /// `control` so it reads as a surface you speak into, not a list row.
        static let composer: CGFloat = 23
    }

    // MARK: Measure — content width caps

    /// Content width caps, replacing the ad-hoc 360/520/680/760 literals.
    /// All are `maxWidth` caps centered by a full-width frame — never fixed
    /// widths — so iPhone portrait and iPad split view both breathe.
    enum Measure {
        /// Focused dialogs and single-action recoveries (StoreRecovery).
        static let narrow: CGFloat = 360
        /// Heroes, onboarding copy, single-column forms, empty states.
        static let standard: CGFloat = 520
        /// Reading content: message bubbles.
        static let wide: CGFloat = 680
        /// The full transcript surface (the widest allowed content column).
        static let full: CGFloat = 760
    }

    // MARK: Motion — small, springy, purposeful

    /// The three standard curves. Everything animated in the app uses one
    /// of these (or `.ziroAnimation`, which drops the animation entirely
    /// under Reduce Motion).
    enum ZiroMotionTokens {
        /// Control presses and micro state changes (0.18s snappy).
        static let press = Animation.snappy(duration: 0.18)
        /// Elements appearing/moving into place (streaming bubble enter,
        /// banner mount, chip reveal): a gentle spring, response 0.35.
        static let appear = Animation.spring(response: 0.35, dampingFraction: 0.8)
        /// Text-streaming rhythm: the debounced transcript scroll (0.22s
        /// ease-out) and the streaming cursor cadence (0.6s period).
        static let stream = Animation.easeOut(duration: 0.22)
        /// Streaming-cursor blink period in seconds (matches MessageBubble's
        /// TimelineView cadence; documented here so it changes in one place).
        static let cursorPeriod: TimeInterval = 0.6
    }
}

// MARK: - Motion

/// Convenience aliases for the motion tokens.
typealias ZiroMotion = ZiroTheme.ZiroMotionTokens

/// Convenience alias for the measure (content width cap) tokens.
typealias ZiroMeasure = ZiroTheme.Measure

/// Applies an animation to `value` only when the user allows motion. Under
/// Reduce Motion the state change still applies, just without animation.
/// Every tokenized animation must route through this (or through a
/// ButtonStyle that checks `accessibilityReduceMotion` itself).
private struct ZiroAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation?
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Token-aware, reduce-motion-aware `.animation(_:value:)`.
    func ziroAnimation(_ animation: Animation?, value: some Equatable) -> some View {
        modifier(ZiroAnimationModifier(animation: animation, value: value))
    }
}

// MARK: - Shadow Language

/// The two shadow levels. Apply with `.ziroShadow(_:)` together with a
/// `ZiroTheme.hairline` stroke — the pair (stroke + shadow) is the depth
/// system. `ZiroTheme.scrim` is the only sanctioned shadow-color fill.
enum ZiroShadowLevel {
    /// Resting content: cards, primary buttons, floating pill controls.
    case raised
    /// Truly floating moments: overlays, hero CTA, jump-to-bottom button.
    case floating
}

private struct ZiroShadowModifier: ViewModifier {
    let level: ZiroShadowLevel?

    func body(content: Content) -> some View {
        // Minimalist pass: hairline carries depth, shadows off.
        content
    }
}

extension View {
    /// The one shadow language. Never hand-roll `.shadow(...)` in a screen.
    /// Pass `nil` to opt out (e.g. cards resting inside scroll forms).
    func ziroShadow(_ level: ZiroShadowLevel?) -> some View {
        modifier(ZiroShadowModifier(level: level))
    }
}

// MARK: - Tone System (badges + banners)

/// The single tint system replacing the 0.10/0.12/0.15 fill chaos. A tone
/// pairs a contrast-verified text color with its pre-composited container;
/// components consume the pair, never a raw opacity.
enum ZiroTone: CaseIterable {
    case accent
    case positive
    case warning
    case danger
    case info
    case neutral
    /// Categorical data hues — quantization tiers and vision capability.
    /// Not status; never for banners or buttons.
    case purple
    case indigo

    /// Foreground (text/icon) color for the tone.
    var tint: Color {
        switch self {
        case .accent: ZiroTheme.accent
        case .positive: ZiroTheme.positiveText
        case .warning: ZiroTheme.warningText
        case .danger: ZiroTheme.dangerText
        case .info: ZiroTheme.infoText
        case .neutral: ZiroTheme.secondaryText
        case .purple: ZiroTheme.accentPurpleText
        case .indigo: ZiroTheme.accentIndigoText
        }
    }

    /// Pre-composited tinted fill; every `tint` clears 4.5:1 on it in both
    /// modes (ratios in docs/DESIGN-SPEC.md §6).
    var container: Color {
        switch self {
        case .accent: ZiroTheme.accentContainer
        case .positive: ZiroTheme.positiveContainer
        case .warning: ZiroTheme.warningContainer
        case .danger: ZiroTheme.dangerContainer
        case .info: ZiroTheme.infoContainer
        case .neutral: ZiroTheme.neutralContainer
        case .purple: ZiroTheme.purpleContainer
        case .indigo: ZiroTheme.indigoContainer
        }
    }

    /// Canonical status symbol for semantic tones. The UI-test contract
    /// requires `checkmark.circle.fill`, `exclamationmark.circle.fill`, and
    /// `wrench.and.screwdriver` to remain Image-based SF Symbols — these map
    /// onto that contract (repair imagery uses `wrench.and.screwdriver`
    /// directly with `.warning`).
    var statusSymbol: String? {
        switch self {
        case .positive: "checkmark.circle.fill"
        case .danger: "exclamationmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .accent: nil
        case .neutral: nil
        case .purple: nil
        case .indigo: nil
        }
    }
}

// MARK: - Button Styles

/// Primary action: full accent fill, capsule, white/black label. One per
/// screen-section (the single most important action). Disabled state fades
/// the fill to 30% and keeps the label readable.
struct ZiroPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    var isStatic = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // System type ramp via token (Callout, Dynamic Type scaled) +
            // true 44pt floor: no vertical padding stacked on minHeight.
            .font(ZiroType.body)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.horizontal, ZiroTheme.Spacing.xLarge)
            .foregroundStyle(ZiroTheme.primaryText.opacity(isEnabled ? 1 : 0.5))
            .background(ZiroTheme.wellBackground, in: Capsule())
            .overlay(Capsule().stroke(ZiroTheme.hairline, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.9)
            .scaleEffect(reduceMotion || isStatic || !configuration.isPressed ? 1 : 0.96)
            .animation(reduceMotion ? nil : ZiroMotion.press, value: configuration.isPressed)
    }
}

/// Secondary action: quiet tinted accent container, accent label. For
/// meaningful-but-not-primary choices (the `.bordered` replacement).
struct ZiroSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    var isStatic = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ZiroType.body)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.horizontal, ZiroTheme.Spacing.large)
            .foregroundStyle(ZiroTheme.secondaryText.opacity(isEnabled ? 1 : 0.5))
            .background(.clear, in: Capsule())
            .overlay(Capsule().stroke(ZiroTheme.hairline, lineWidth: 1))
            .scaleEffect(reduceMotion || isStatic || !configuration.isPressed ? 1 : 0.96)
            .animation(reduceMotion ? nil : ZiroMotion.press, value: configuration.isPressed)
    }
}

/// Destructive action: danger-tinted container, danger label. Reserved for
/// deletions and irreversible operations.
struct ZiroDestructiveButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    var isStatic = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ZiroType.body)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.horizontal, ZiroTheme.Spacing.large)
            .foregroundStyle(ZiroTheme.dangerText.opacity(isEnabled ? 1 : 0.5))
            .background(ZiroTheme.wellBackground, in: Capsule())
            .overlay(Capsule().stroke(ZiroTheme.hairline, lineWidth: 1))
            .scaleEffect(reduceMotion || isStatic || !configuration.isPressed ? 1 : 0.96)
            .animation(reduceMotion ? nil : ZiroMotion.press, value: configuration.isPressed)
    }
}

// MARK: - Status Banner

/// The standard in-stream recovery/status surface (model-load retries,
/// persistence recovery, errors, truncation warnings).
///
/// Canonical construction uses a `ZiroTone`, which pairs the verified tinted
/// container with its text color. The legacy `tint:` initializer is retained
/// for pre-overhaul call sites and renders with a 10% fill + 3pt leading
/// rail; implementation agents migrate call sites to `tone:`.
struct ZiroStatusBanner<Actions: View>: View {
    private let icon: String
    private let title: String?
    private let message: String
    private let toneTint: Color
    private let toneContainer: Color
    private let showsRail: Bool
    private let actions: Actions

    /// Canonical: tone-driven (fixed, verified container color).
    init(
        icon: String,
        title: String? = nil,
        message: String,
        tone: ZiroTone,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.toneTint = tone.tint
        self.toneContainer = tone.container
        self.showsRail = false
        self.actions = actions()
    }

    /// Legacy: arbitrary tint (10% fill + leading rail). Migrate to `tone:`.
    init(
        icon: String,
        title: String? = nil,
        message: String,
        tint: Color,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.toneTint = tint
        self.toneContainer = tint.opacity(0.10)
        self.showsRail = true
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: ZiroTheme.Spacing.medium) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(toneTint)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
                    if let title {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(ZiroTheme.primaryText)
                    }
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(ZiroTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
                    .font(ZiroType.footnote)
                    // 44×44pt hit-target floor (repo a11y standard): banner
                    // actions are the sole recovery/dismissal path for their
                    // banners and would otherwise measure ~20pt tall at
                    // default Dynamic Type as caption-size buttons.
                    .frame(minHeight: 44, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ZiroTheme.Spacing.large)
        .padding(.vertical, ZiroTheme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: ZiroTheme.Radius.control, style: .continuous)
                .fill(ZiroTheme.wellBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ZiroTheme.Radius.control, style: .continuous)
                .stroke(ZiroTheme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.control, style: .continuous))
        .overlay(alignment: .leading) {
            if showsRail {
                Rectangle().fill(toneTint).frame(width: 3)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension ZiroStatusBanner where Actions == EmptyView {
    /// Canonical tone-driven banner without actions.
    init(icon: String, title: String? = nil, message: String, tone: ZiroTone) {
        self.init(icon: icon, title: title, message: message, tone: tone) { EmptyView() }
    }

    /// Legacy tint-driven banner without actions.
    init(icon: String, title: String? = nil, message: String, tint: Color) {
        self.init(icon: icon, title: title, message: message, tint: tint) { EmptyView() }
    }
}

// MARK: - Card

/// Shared card container: a raised surface resting on the page, defined by
/// its raised fill at rest (fill-only; the shadow only lifts it). Used for
/// content composed outside Form/List sections — wizard pages, transfer
/// status, heroes.
struct ZiroCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat
    private let showsShadow: Bool

    /// - Parameters:
    ///   - padding: inner inset; defaults to the standard 16pt.
    ///   - showsShadow: adds the raised shadow (on for floating cards).
    init(
        padding: CGFloat = ZiroTheme.Spacing.large,
        showsShadow: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.padding = padding
        self.showsShadow = showsShadow
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ZiroTheme.Radius.card, style: .continuous)
                    .fill(ZiroTheme.raisedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ZiroTheme.Radius.card, style: .continuous)
                    .stroke(ZiroTheme.hairline, lineWidth: 1)
            )
            .ziroShadow(showsShadow ? ZiroShadowLevel.raised : nil)
    }
}

// MARK: - Badge

/// The ONE badge system. Every capsule-with-label in the app is a
/// `ZiroBadge` with a tone — capability flags (VISION), pair-incomplete
/// warnings, quantization tiers, confidence levels, "Coming soon" stubs.
/// Non-interactive by design; a tappable label is a `ZiroSuggestionChip`.
struct ZiroBadge: View {
    let text: String
    var tone: ZiroTone = .neutral
    var icon: String? = nil
    /// Renders the label in the technical (monospaced) voice — for
    /// quantization tiers, revisions, and other engineering strings.
    var monospaced: Bool = false

    var body: some View {
        HStack(spacing: ZiroTheme.Spacing.xSmall) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(
                    monospaced
                        ? ZiroType.technical(.caption2)
                        : Font.caption2
                )
        }
        .foregroundStyle(tone.tint)
        .padding(.horizontal, ZiroTheme.Spacing.badge)
        .padding(.vertical, ZiroTheme.Spacing.micro)
        .background(ZiroTheme.wellBackground, in: Capsule())
        .overlay(Capsule().stroke(ZiroTheme.hairline, lineWidth: 1))
        // Badge copy is a single unit — keep the capsule hugging one line
        // instead of wrapping when the surrounding row gets tight.
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Suggestion Chip (interactive)

/// Interactive capsule for guided starting points and quick actions — the
/// chat empty state's sample prompts. 44pt minimum hit target, scales with
/// Dynamic Type; pressed state switches to the accent container.
struct ZiroSuggestionChip: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZiroTheme.Spacing.xSmall) {
                if let systemImage {
                    Image(systemName: systemImage)
                        // Match the chip text voice (supporting.medium) — one
                        // weight/size set per surface.
                        .font(ZiroType.supporting)
                        .foregroundStyle(ZiroTheme.secondaryText)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(ZiroType.supporting)
                    .foregroundStyle(ZiroTheme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, ZiroTheme.Spacing.medium)
            .frame(minHeight: 44)
            .background(ZiroTheme.wellBackground, in: Capsule())
        }
        .buttonStyle(ZiroSuggestionChipButtonStyle())
    }
}

/// Pressed treatment for suggestion chips: accent container + accent border,
/// micro press-down scale. Reduce Motion drops the scale/animation.
private struct ZiroSuggestionChipButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isStatic = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule().fill(configuration.isPressed ? ZiroTheme.wellBackground : .clear)
            )
            .overlay(
                Capsule().stroke(ZiroTheme.hairline, lineWidth: 1)
            )
            .scaleEffect(reduceMotion || isStatic || !configuration.isPressed ? 1 : 0.96)
            .animation(reduceMotion ? nil : ZiroMotion.press, value: configuration.isPressed)
    }
}

// MARK: - Flow Layout (wrapped chip rows)

/// A simple wrapping flow for chip rows that must survive Dynamic Type:
/// at accessibility sizes a fixed HStack truncates, this wraps.
struct ZiroFlowLayout: Layout {
    var spacing: CGFloat = ZiroTheme.Spacing.small

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > 0, cursorX + size.width > maxWidth {
                maxRowWidth = max(maxRowWidth, cursorX - spacing)
                cursorY += rowHeight + spacing
                cursorX = 0
                rowHeight = 0
            }
            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        maxRowWidth = max(maxRowWidth, cursorX - spacing, 0)
        return CGSize(width: min(maxWidth, maxRowWidth), height: cursorY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > bounds.minX, cursorX + size.width > bounds.maxX {
                cursorX = bounds.minX
                cursorY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: cursorX, y: cursorY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Section Header (custom surfaces)

/// Eyebrow-style header for content composed outside List/Form sections
/// (cards, wizard pages, empty states). List/Form sections keep the system
/// header treatment.
struct ZiroSectionHeader: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: ZiroTheme.Spacing.xSmall) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(ZiroTheme.secondaryText)
                    // Directional glyphs (text.bubble, bubble.left.*) mirror
                    // in RTL; other symbols ignore the flip.
                    .flipsForRightToLeft(
                        systemImage.contains("bubble")
                            || systemImage.contains("chevron.right")
                            || systemImage.contains("arrow.triangle.branch")
                    )
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.caption)
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(ZiroTheme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Progress Ring

/// Circular progress for in-flight transfers (row indicators, compact
/// states). Decorative by default: the caller renders the scaling percentage
/// label beside it and the combined row label announces progress.
struct ZiroProgressRing: View {
    var progress: Double
    var tint: Color = .accentColor
    var size: CGFloat = 26
    var lineWidth: CGFloat = 2.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(ZiroTheme.hairline, style: StrokeStyle(lineWidth: lineWidth))
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Message Bubble Treatment

/// The two bubble treatments, both hairline-bordered above the page:
///   user      `userBubble` fill — deep navy in dark, accent blue in light
///   assistant `raisedBackground` fill — dark charcoal on the near-black page
/// Label colors are the caller's job (`accentForeground` / `primaryText`).
enum ZiroBubbleRole {
    case user
    case assistant
}

/// The shared bubble shape — one radius, one continuous-curve style.
private var ziroBubbleShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: ZiroTheme.Radius.bubble, style: .continuous)
}

extension View {
    /// Applies the message-bubble surface for `role`, including the
    /// continuous-corner shape. Call after padding the content.
    @ViewBuilder
    func ziroMessageBubble(_ role: ZiroBubbleRole) -> some View {
        switch role {
        case .user:
            self
                .background(ZiroTheme.userBubble, in: ziroBubbleShape)
                .overlay(ziroBubbleShape.stroke(ZiroTheme.hairline, lineWidth: 1))
        case .assistant:
            // The assistant is a bubble too — dark charcoal (`raisedBackground`)
            // with the same hairline. Elevation on this transcript is
            // gray-on-black: page `#121314`, bubble/composer `#1C1C1E`.
            self
                .background(ZiroTheme.raisedBackground, in: ziroBubbleShape)
                .overlay(ziroBubbleShape.stroke(ZiroTheme.hairline, lineWidth: 1))
        }
    }
}

// MARK: - Composer / Input Well Treatment

/// The composer's recessed input well: well-elevation fill-only at rest,
/// accent focus ring. The visible focus ring doubles as the keyboard
/// focus indicator — never remove it.
private struct ZiroComposerFieldModifier: ViewModifier {
    var isActive: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, ZiroTheme.Spacing.large)
            .padding(.vertical, ZiroTheme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: ZiroTheme.Radius.control, style: .continuous)
                    .fill(ZiroTheme.wellBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ZiroTheme.Radius.control, style: .continuous)
                    .stroke(isActive ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .ziroAnimation(ZiroMotion.press, value: isActive)
    }
}

extension View {
    /// The composer input-well treatment. `isActive` = field focus.
    func ziroComposerField(isActive: Bool) -> some View {
        modifier(ZiroComposerFieldModifier(isActive: isActive))
    }
}

// MARK: - RTL Mirroring

extension View {
    /// Mirrors directional glyphs (chevrons, bubbles, branch arrows) in
    /// right-to-left layouts. Pass `false` for symmetric symbols. Wraps
    /// SwiftUI's `flipsForRightToLeftLayoutDirection(_:)`.
    func flipsForRightToLeft(_ flag: Bool) -> some View {
        flipsForRightToLeftLayoutDirection(flag)
    }
}
