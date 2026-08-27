import SwiftUI

/// Shared visual language for ZiroEdge's privacy-first, system-native interface.
enum ZiroTheme {
    static let pageBackground = Color(uiColor: .systemBackground)
    static let elevatedBackground = Color(uiColor: .secondarySystemBackground)
    static let inputBackground = Color(uiColor: .tertiarySystemBackground)
    static let subtleBorder = Color.primary.opacity(0.08)
    static let accentForeground = Color("AccentForeground")

    /// Status text for warning states (download needs repair, RAM risk,
    /// vision pair incomplete, failed model pill). Raw `.orange` passes in
    /// dark mode but sits far below the 4.5:1 WCAG AA contrast floor on
    /// light backgrounds, so light mode uses this darkened variant
    /// (#B25000, 5.2:1 on white); dark mode keeps the system orange.
    /// Icon-only usages satisfy the 3:1 non-text floor too.
    static let warningText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemOrange
            : UIColor(red: 0.698, green: 0.314, blue: 0, alpha: 1)
    })

    /// Status text for positive states (installed, vision pair confirmed,
    /// RAM fits). Raw `.green` fails 4.5:1 in light mode; this darkened
    /// variant (#1E7B34, 5.3:1 on white) keeps dark mode on system green.
    static let positiveText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemGreen
            : UIColor(red: 0.118, green: 0.482, blue: 0.204, alpha: 1)
    })

    /// Status text for informational/blue accents (onboarding eyebrows).
    /// Raw `.blue` reads ≈4.0:1 on white — below the 4.5:1 AA floor for
    /// caption text; this darkened variant (#0062CC, 5.8:1 on white) keeps
    /// dark mode on system blue.
    static let infoText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemBlue
            : UIColor(red: 0, green: 0.384, blue: 0.8, alpha: 1)
    })

    /// Status text for purple accents (onboarding eyebrows). Raw `.purple`
    /// reads ≈4.1:1 on white — below the 4.5:1 AA floor; this darkened
    /// variant (#8236B8, 6.6:1 on white) keeps dark mode on system purple.
    static let accentPurpleText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemPurple
            : UIColor(red: 0.510, green: 0.212, blue: 0.722, alpha: 1)
    })

    enum Spacing {
        /// Tightest inset: two-line stack gutters and badge vertical padding.
        static let micro: CGFloat = 2
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
        static let xxLarge: CGFloat = 40
        /// Capsule badge/chip horizontal inset.
        static let badge: CGFloat = 6
        /// Empty-state hero top inset.
        static let heroTop: CGFloat = 96
    }

    enum Radius {
        /// Badge/chip background corners.
        static let badge: CGFloat = 6
        static let control: CGFloat = 14
        static let card: CGFloat = 20
        static let bubble: CGFloat = 18
    }
}

struct ZiroPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ZiroTheme.Spacing.xLarge)
            .padding(.vertical, ZiroTheme.Spacing.medium)
            .foregroundStyle(ZiroTheme.accentForeground)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(Capsule())
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: configuration.isPressed)
    }
}

struct ZiroStatusBanner<Actions: View>: View {
    let icon: String
    let title: String?
    let message: String
    let tint: Color
    let actions: Actions

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
        self.tint = tint
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: ZiroTheme.Spacing.medium) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.small) {
                VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
                    if let title {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
                    .font(.caption.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ZiroTheme.Spacing.large)
        .padding(.vertical, ZiroTheme.Spacing.medium)
        .background(tint.opacity(0.10))
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 3)
        }
        .accessibilityElement(children: .contain)
    }
}

extension ZiroStatusBanner where Actions == EmptyView {
    init(icon: String, title: String? = nil, message: String, tint: Color) {
        self.init(icon: icon, title: title, message: message, tint: tint) { EmptyView() }
    }
}

/// Shared card container: elevated rounded surface with a subtle border for
/// content composed outside Form/List sections (wizard pages, heroes).
struct ZiroCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(ZiroTheme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ZiroTheme.Radius.card)
                    .fill(ZiroTheme.elevatedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ZiroTheme.Radius.card)
                    .stroke(ZiroTheme.subtleBorder)
            )
    }
}

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
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520)
    }
}
