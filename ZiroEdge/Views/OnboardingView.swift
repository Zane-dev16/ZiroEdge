// OnboardingView.swift
// ZiroEdge — Privacy-first local AI assistant

import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0
    // Decorative sizes scale with Dynamic Type via @ScaledMetric (spec rule 5)
    // — the hero follows ZiroEmptyState's uncapped mark pattern, so it grows
    // monotonically at accessibility sizes instead of clamping.
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 72
    @ScaledMetric(relativeTo: .body) private var topBarMarkSize: CGFloat = 48
    // Hit-target floor for the quiet "Skip" dismissal; scales like the
    // composer controls so the glyph/text never overflows its frame.
    @ScaledMetric(relativeTo: .body) private var skipControlSide: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Page {
        let symbol: String
        /// Hero glyph tint. Large decorative glyphs are exempt from the
        /// 4.5:1 text contrast floor, but they still resolve through the
        /// verified tone tokens (no raw system hues).
        let color: Color
        /// Eyebrow caption tint — the verified text tokens (spec §8.5.2).
        let eyebrowColor: Color
        let eyebrow: String
        let title: String
        let description: String
    }

    private let pages = [
        Page(
            symbol: "lock.shield.fill", color: ZiroTheme.infoText, eyebrowColor: ZiroTheme.infoText,
            eyebrow: "PRIVATE BY DESIGN", title: "Your AI stays yours",
            description: "Messages, images, and model responses are processed locally. Your conversations never leave this device."
        ),
        Page(
            symbol: "arrow.down.circle.fill", color: ZiroTheme.positiveText, eyebrowColor: ZiroTheme.positiveText,
            eyebrow: "YOU CHOOSE THE MODEL", title: "Download once. Use anywhere.",
            description: "Pick a model that fits your device. After downloading, chat works without an internet connection."
        ),
        Page(
            symbol: "bubble.left.and.bubble.right.fill", color: ZiroTheme.accentPurpleText, eyebrowColor: ZiroTheme.accentPurpleText,
            eyebrow: "READY WHEN YOU ARE", title: "A focused place to think",
            description: "Start conversations, attach images with vision models, and keep a private history on your device."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ZiroTheme.Spacing.small) {
                ZiroBrandMark(size: topBarMarkSize)
                Text("ZIROEDGE")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(ZiroTheme.secondaryText)
                Spacer()
                Button("Skip", action: completeOnboarding)
                    .font(ZiroType.footnote.weight(.semibold))
                    .foregroundStyle(ZiroTheme.secondaryText)
                    // The app's quiet dismissal must still meet the 44×44pt
                    // hit-target floor; the scaled frame grows with Dynamic
                    // Type so the label never overflows it.
                    .frame(minWidth: skipControlSide, minHeight: skipControlSide)
                    .contentShape(Rectangle())
                    .accessibilityHint("Closes introduction")
            }
            .padding(.horizontal, ZiroTheme.Spacing.xLarge)
            .padding(.top, ZiroTheme.Spacing.large)

            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    ScrollView {
                        VStack(spacing: ZiroTheme.Spacing.xLarge) {
                            Image(systemName: page.symbol)
                                .font(.system(size: heroIconSize, weight: .medium))
                                .foregroundStyle(page.color)
                                .symbolRenderingMode(.hierarchical)
                                .accessibilityHidden(true)

                            VStack(spacing: ZiroTheme.Spacing.medium) {
                                Text(page.eyebrow)
                                    .font(.caption.weight(.bold))
                                    .tracking(1.1)
                                    .foregroundStyle(page.eyebrowColor)
                                Text(page.title)
                                    .font(ZiroType.display)
                                    .foregroundStyle(ZiroTheme.primaryText)
                                    .multilineTextAlignment(.center)
                                Text(page.description)
                                    .font(ZiroType.body)
                                    .foregroundStyle(ZiroTheme.secondaryText)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: ZiroMeasure.standard)
                        }
                        .padding(.horizontal, ZiroTheme.Spacing.xLarge)
                        .padding(.vertical, ZiroTheme.Spacing.xxLarge)
                        .frame(maxWidth: .infinity)
                    }
                    .tag(index)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Page \(index + 1) of \(pages.count). \(page.title). \(page.description)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            HStack(spacing: ZiroTheme.Spacing.medium) {
                if currentPage > 0 {
                    Button("Back") { stepPage(-1) }
                        .buttonStyle(ZiroSecondaryButtonStyle())
                }

                Button(currentPage < pages.count - 1 ? "Continue" : "Get Started") {
                    if currentPage < pages.count - 1 {
                        stepPage(1)
                    } else {
                        completeOnboarding()
                    }
                }
                .buttonStyle(ZiroPrimaryButtonStyle())
            }
            .padding(.horizontal, ZiroTheme.Spacing.xLarge)
            .padding(.bottom, ZiroTheme.Spacing.xLarge)
        }
        .background(ZiroTheme.pageBackground)
        .interactiveDismissDisabled()
    }

    /// Page navigation shares one motion treatment: `ZiroMotion.appear` for
    /// the transition, dropped entirely under Reduce Motion (the page still
    /// changes, just without animation).
    private func stepPage(_ direction: Int) {
        if reduceMotion {
            currentPage += direction
        } else {
            withAnimation(ZiroMotion.appear) { currentPage += direction }
        }
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        isPresented = false
    }
}

@MainActor
final class OnboardingManager: ObservableObject {
    @Published var showOnboarding: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let completed = defaults.bool(forKey: "hasCompletedOnboarding")
        let isUITesting = CommandLine.arguments.contains("--uitesting")
        showOnboarding = !completed && !isUITesting
    }

    func completeOnboarding() {
        defaults.set(true, forKey: "hasCompletedOnboarding")
        showOnboarding = false
    }
}

#Preview { OnboardingView(isPresented: .constant(true)) }
