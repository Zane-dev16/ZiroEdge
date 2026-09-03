// DesignSystemGallery.swift
// ZiroEdge — Privacy-first local AI assistant
//
// System gallery preview for the design-system tokens and brand surfaces.
// Split out of DesignSystem.swift so the token file stays under the
// project's file-length limit.

import SwiftUI

// MARK: - Previews (system gallery)

#if DEBUG
#Preview("Tokens — surfaces & tones") {
    ScrollView {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.large) {
            ZiroSectionHeader(title: "Surfaces", systemImage: "square.stack.3d.up")
            HStack(spacing: ZiroTheme.Spacing.small) {
                surfaceSwatch("page", ZiroTheme.pageBackground)
                surfaceSwatch("raised", ZiroTheme.raisedBackground)
                surfaceSwatch("well", ZiroTheme.wellBackground)
                surfaceSwatch("overlay", ZiroTheme.overlayBackground)
            }

            ZiroSectionHeader(title: "Badges", systemImage: "tag")
            ZiroFlowLayout {
                ZiroBadge(text: "Q4_K_M", tone: .positive, monospaced: true)
                ZiroBadge(text: "Q6_K", tone: .indigo, monospaced: true)
                ZiroBadge(text: "Q3", tone: .warning, monospaced: true)
                ZiroBadge(text: "VISION", tone: .purple)
                ZiroBadge(text: "PAIR INCOMPLETE", tone: .warning)
                ZiroBadge(text: "INSTALLED", tone: .positive, icon: "checkmark.circle.fill")
                ZiroBadge(text: "FAILED", tone: .danger, icon: "exclamationmark.circle.fill")
                ZiroBadge(text: "Coming soon", tone: .neutral)
            }

            ZiroSectionHeader(title: "Banners", systemImage: "exclamationmark.bubble")
            ZiroStatusBanner(
                icon: "wrench.and.screwdriver",
                title: "Couldn't load model",
                message: "The download failed verification. Retry to replace damaged files.",
                tone: .warning
            ) {
                Button("Retry") {}
            }
            ZiroStatusBanner(
                icon: "exclamationmark.octagon.fill",
                title: "Response not saved",
                message: "The response is safely retained while you choose what to do.",
                tone: .danger
            )

            ZiroSectionHeader(title: "Buttons", systemImage: "rectangle.and.pencil.and.ellipsis")
            VStack(spacing: ZiroTheme.Spacing.medium) {
                Button("Start Chatting") {}.buttonStyle(ZiroPrimaryButtonStyle())
                Button("Add Image Processing") {}.buttonStyle(ZiroSecondaryButtonStyle())
                Button("Delete Model") {}.buttonStyle(ZiroDestructiveButtonStyle())
            }

            ZiroSectionHeader(title: "Empty state", systemImage: "sparkles")
            ZiroEmptyState(
                title: "Start a conversation",
                message: "Ask anything below. Your messages and the model's response stay on this device.",
                suggestions: ["Explain a concept simply", "Help me draft a reply", "Summarize my notes"],
                onSuggestion: { _ in }
            ) {
                EmptyView()
            }

            ZiroSectionHeader(title: "Brand mark", systemImage: "shield")
            HStack(spacing: ZiroTheme.Spacing.large) {
                ZiroBrandMark(size: 28)
                ZiroBrandMark(size: 48)
                ZiroBrandMark(size: 68)
                ZiroProgressRing(progress: 0.65)
            }
        }
        .padding()
    }
    .background(ZiroTheme.pageBackground)
}

private func surfaceSwatch(_ name: String, _ color: Color) -> some View {
    VStack(spacing: ZiroTheme.Spacing.micro) {
        RoundedRectangle(cornerRadius: ZiroTheme.Radius.small)
            .fill(color)
            .overlay(RoundedRectangle(cornerRadius: ZiroTheme.Radius.small).stroke(ZiroTheme.hairline))
            .frame(width: 64, height: 44)
        Text(name).font(.caption2).foregroundStyle(ZiroTheme.secondaryText)
    }
}
#endif
