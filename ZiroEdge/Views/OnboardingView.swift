// OnboardingView.swift
// ZiroEdge — Privacy-first local AI assistant

import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 72
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Page {
        let symbol: String
        let color: Color
        let eyebrow: String
        let title: String
        let description: String
    }

    private let pages = [
        Page(
            symbol: "lock.shield.fill", color: .blue, eyebrow: "PRIVATE BY DESIGN", title: "Your AI stays yours",
            description: "Messages, images, and model responses are processed locally. Your conversations never leave this device."
        ),
        Page(
            symbol: "arrow.down.circle.fill", color: .green, eyebrow: "YOU CHOOSE THE MODEL", title: "Download once. Use anywhere.",
            description: "Pick a model that fits your device. After downloading, chat works without an internet connection."
        ),
        Page(
            symbol: "bubble.left.and.bubble.right.fill", color: .purple, eyebrow: "READY WHEN YOU ARE", title: "A focused place to think",
            description: "Start conversations, attach images with vision models, and keep a private history on your device."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ZIROEDGE")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Skip", action: completeOnboarding)
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Closes introduction")
            }
            .padding(.horizontal, ZiroTheme.Spacing.xLarge)
            .padding(.top, ZiroTheme.Spacing.large)

            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    ScrollView {
                        VStack(spacing: ZiroTheme.Spacing.xLarge) {
                            Image(systemName: page.symbol)
                                .font(.system(size: min(heroIconSize, 120), weight: .medium))
                                .foregroundStyle(page.color)
                                .symbolRenderingMode(.hierarchical)
                                .accessibilityHidden(true)

                            VStack(spacing: ZiroTheme.Spacing.medium) {
                                Text(page.eyebrow)
                                    .font(.caption.weight(.bold))
                                    .tracking(1.1)
                                    .foregroundStyle(page.color)
                                Text(page.title)
                                    .font(.largeTitle.bold())
                                    .multilineTextAlignment(.center)
                                Text(page.description)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: 520)
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
                    Button("Back") {
                        if reduceMotion { currentPage -= 1 }
                        else { withAnimation(.snappy) { currentPage -= 1 } }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Button(currentPage < pages.count - 1 ? "Continue" : "Get Started") {
                    if currentPage < pages.count - 1 {
                        if reduceMotion { currentPage += 1 }
                        else { withAnimation(.snappy) { currentPage += 1 } }
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
