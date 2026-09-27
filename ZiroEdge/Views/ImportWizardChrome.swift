// ImportWizardChrome.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Shared import-wizard chrome: the sticky step-progress header, the
// bottom action bar, and the gated Continue button.

import SwiftUI

// MARK: - Sticky Chrome

/// Quiet per-step marker, chat voice: a single caption plus a hairline
/// progress rule. No filled strip — the wizard pages already sit on the
/// page canvas, and the navigation title names the step.
private struct ImportWizardStepHeader: View {
    let step: ImportWizardStep

    var body: some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.xSmall) {
            Text("Step \(step.rawValue + 1) of \(ImportWizardStep.allCases.count)")
                .font(ZiroType.caption)
                .foregroundStyle(ZiroTheme.tertiaryText)
            ProgressView(
                value: Double(step.rawValue + 1),
                total: Double(ImportWizardStep.allCases.count)
            )
            .tint(ZiroTheme.accent)
            .scaleEffect(y: 0.5, anchor: .center)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ZiroTheme.Spacing.large)
        .padding(.vertical, ZiroTheme.Spacing.xSmall)
        .background(ZiroTheme.pageBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Import step \(step.rawValue + 1) of \(ImportWizardStep.allCases.count)")
    }
}

extension View {
    /// Pins the shared step-progress strip under the navigation bar.
    func importWizardStepHeader(_ step: ImportWizardStep) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            ImportWizardStepHeader(step: step)
        }
    }

    /// Pins the step's forward action above the safe area. The action column
    /// caps at the standard measure so the button doesn't stretch edge-to-edge
    /// on iPad.
    func importWizardBottomBar<Actions: View>(@ViewBuilder actions: () -> Actions) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            actions()
                .frame(maxWidth: ZiroMeasure.standard)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ZiroTheme.Spacing.large)
                .padding(.top, ZiroTheme.Spacing.small)
                .padding(.bottom, ZiroTheme.Spacing.medium)
                .background(ZiroTheme.pageBackground)
        }
    }
}

/// Gated forward action shared by the wizard's Continue-style steps. The hint
/// explains why the gate is closed so per-step validation is never silent.
struct ImportWizardContinueButton: View {
    let title: String
    var systemImage: String?
    let isEnabled: Bool
    var hint: String?
    let action: () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        isEnabled: Bool,
        hint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.hint = hint
        self.action = action
    }

    var body: some View {
        VStack(spacing: ZiroTheme.Spacing.small) {
            if !isEnabled, let hint, !hint.isEmpty {
                Text(hint)
                    .font(ZiroType.caption)
                    .foregroundStyle(ZiroTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: action) {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .buttonStyle(ZiroPrimaryButtonStyle())
            .disabled(!isEnabled)
            // The visual hint caption is skipped by VoiceOver's default
            // traversal; surface the gate reason as a hint on the control
            // itself while it is disabled (r4 MEDIUM).
            .accessibilityHint(!isEnabled ? (hint ?? "") : "")
        }
    }
}
