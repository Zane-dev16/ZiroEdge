import SwiftUI

/// Shared visual language for ZiroEdge's privacy-first, system-native interface.
enum ZiroTheme {
    static let pageBackground = Color(uiColor: .systemBackground)
    static let elevatedBackground = Color(uiColor: .secondarySystemBackground)
    static let inputBackground = Color(uiColor: .tertiarySystemBackground)
    static let subtleBorder = Color.primary.opacity(0.08)
    static let errorBackground = Color.red.opacity(0.10)
    static let warningBackground = Color.orange.opacity(0.11)
    static let infoBackground = Color.accentColor.opacity(0.10)
    static let accentForeground = Color("AccentForeground")

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
        static let xxLarge: CGFloat = 40
    }

    enum Radius {
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
