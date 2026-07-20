// OnboardingView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// 3-screen onboarding tour shown on first launch only.

import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0

    private let pages: [(symbol: String, color: Color, title: String, description: String)] = [
        (
            symbol: "lock.shield.fill",
            color: .blue,
            title: "Welcome to ZiroEdge",
            description: "A privacy-first AI assistant. Everything runs on your device — no data ever leaves your phone."
        ),
        (
            symbol: "arrow.down.circle.fill",
            color: .green,
            title: "Download a Model",
            description: "Get started by downloading an AI model. Choose from a variety of models optimized for on-device use."
        ),
        (
            symbol: "bubble.left.and.bubble.right.fill",
            color: .purple,
            title: "Start Chatting",
            description: "Ask questions, get help, or just have a conversation. Your data stays private, always."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Skip button
            HStack {
                Spacer()
                Button("Skip") {
                    completeOnboarding()
                }
                .foregroundStyle(.secondary)
                .padding()
            }

            // Pages
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    VStack(spacing: 24) {
                        Spacer()

                        Image(systemName: page.symbol)
                            .font(.system(size: 80))
                            .foregroundStyle(page.color)
                            .padding(.bottom, 16)

                        Text(page.title)
                            .font(.title.bold())
                            .multilineTextAlignment(.center)

                        Text(page.description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)

                        Spacer()
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            // Continue / Get Started button
            Button(action: {
                if currentPage < pages.count - 1 {
                    withAnimation {
                        currentPage += 1
                    }
                } else {
                    completeOnboarding()
                }
            }) {
                Text(currentPage < pages.count - 1 ? "Continue" : "Get Started")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .interactiveDismissDisabled()
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        isPresented = false
    }
}

// MARK: - Onboarding Manager

/// Manages onboarding state. Extracted for testability.
@MainActor
final class OnboardingManager: ObservableObject {
    @Published var showOnboarding: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let completed = defaults.bool(forKey: "hasCompletedOnboarding")
        let isUITesting = CommandLine.arguments.contains("--uitesting")
        self.showOnboarding = !completed && !isUITesting
    }

    func completeOnboarding() {
        defaults.set(true, forKey: "hasCompletedOnboarding")
        showOnboarding = false
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
}
