// ZiroConfirmationModal.swift
// ZiroEdge — Privacy-first local AI assistant
//
// One reusable full-screen confirmation modal (dim + centered card).
// Replaces inline confirmation bubbles and confirmationDialog sheets for
// destructive confirms (delete model, branch chat, delete chat).

import SwiftUI

/// Full-screen confirm: dim + centered card with title, message,
/// Confirm/Cancel. Reduce-motion safe (no entrance animation — the card
/// mounts without a transition, so Reduce Motion needs no exit).
struct ZiroConfirmationModal: View {
    let title: String
    let message: String
    let confirmTitle: String
    var cancelTitle: String = "Cancel"
    var isDestructive: Bool = true
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            ZiroTheme.scrim
                .opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)
                .accessibilityIdentifier("confirmation-dim")
            VStack(alignment: .leading, spacing: ZiroTheme.Spacing.medium) {
                Text(title)
                    .font(ZiroType.heading)
                    .foregroundStyle(ZiroTheme.primaryText)
                    .accessibilityIdentifier("confirmation-title")
                Text(message)
                    .font(ZiroType.supporting)
                    .foregroundStyle(ZiroTheme.secondaryText)
                    .accessibilityIdentifier("confirmation-message")
                HStack(spacing: ZiroTheme.Spacing.medium) {
                    Button(cancelTitle, action: onCancel)
                        .buttonStyle(ZiroSecondaryButtonStyle())
                        .accessibilityIdentifier("confirmation-cancel")
                    if isDestructive {
                        Button(confirmTitle, action: onConfirm)
                            .buttonStyle(ZiroDestructiveButtonStyle())
                            .accessibilityIdentifier("confirmation-confirm")
                    } else {
                        Button(confirmTitle, action: onConfirm)
                            .buttonStyle(ZiroPrimaryButtonStyle())
                            .accessibilityIdentifier("confirmation-confirm")
                    }
                }
                .padding(.top, ZiroTheme.Spacing.small)
            }
            .padding(ZiroTheme.Spacing.large)
            .frame(maxWidth: 340)
            .background(ZiroTheme.raisedBackground)
            .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.card))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .accessibilityIdentifier("confirmation-modal")
    }
}
