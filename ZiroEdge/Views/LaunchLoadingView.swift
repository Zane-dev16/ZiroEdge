// LaunchLoadingView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Minimal cold-launch placeholder: brand mark + loading animation only.
// The store opens and services verify off the critical path (AppRuntime),
// so this frame carries no copy about history or verification — the logo
// and spinner are the entire moment. Quiet surfaces only
// (`ZiroTheme.pageBackground`: warm paper `#F7F3EC` / navy `#0A0F1E`,
// matching the `LaunchBackground` splash asset so the handoff is seamless).
// Static logo + standard ProgressView: Reduce Motion safe, no custom
// animation curves, no text sizes to scale (Dynamic Type neutral).

import SwiftUI

/// First-frame loading surface while `AppRuntime` publishes `.ready`.
struct LaunchLoadingView: View {
    var body: some View {
        VStack(spacing: ZiroTheme.Spacing.xLarge) {
            ZiroBrandMark(size: 72)
            ProgressView()
                .controlSize(.large)
                .accessibilityIdentifier("launch-loading-spinner")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZiroTheme.pageBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading")
        .accessibilityIdentifier("launch-loading-view")
    }
}
