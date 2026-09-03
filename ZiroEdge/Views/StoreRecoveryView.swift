import SwiftUI

struct StoreRecoveryView: View {
    let failure: PersistenceFailure
    let diagnosticsURL: URL?
    let diagnosticsExportError: String?
    let onRetry: () -> Void
    let onExportDiagnostics: () -> Void
    let onReset: () -> Void

    @State private var showsDetails = false

    var body: some View {
        ScrollView {
            VStack(spacing: ZiroTheme.Spacing.xLarge) {
                ZiroHero(
                    symbol: "externaldrive.badge.exclamationmark",
                    title: "Local history is unavailable",
                    message: failure.localizedDescription,
                    tint: ZiroTheme.warningText
                )

                VStack(spacing: ZiroTheme.Spacing.medium) {
                    Button("Try Again", action: onRetry)
                        .buttonStyle(ZiroPrimaryButtonStyle())
                        .accessibilityHint("Attempts to open local history again")

                    if let diagnosticsURL {
                        ShareLink(item: diagnosticsURL) {
                            Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(ZiroSecondaryButtonStyle())
                    } else {
                        Button(action: onExportDiagnostics) {
                            Label("Export Diagnostics", systemImage: "doc.badge.gearshape")
                        }
                        .buttonStyle(ZiroSecondaryButtonStyle())
                    }

                    Button(action: onReset) {
                        Label("Recover Local Store", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(ZiroSecondaryButtonStyle())
                    .accessibilityHint("Creates a verified recovery copy before offering a reset")
                }
                .frame(maxWidth: ZiroMeasure.narrow)

                if let diagnosticsExportError {
                    ZiroStatusBanner(
                        icon: "exclamationmark.triangle.fill",
                        message: diagnosticsExportError,
                        tone: .danger
                    )
                    // The only transient banner in the app that mounted
                    // without an announcement — VoiceOver users otherwise
                    // get zero feedback that their export failed.
                    .announcingOnAppear(diagnosticsExportError)
                    .frame(maxWidth: ZiroMeasure.standard)
                }

                DisclosureGroup("Technical Details", isExpanded: $showsDetails) {
                    Text(failure.sanitizedDiagnostic)
                        .font(ZiroType.technical(.caption))
                        .foregroundStyle(ZiroTheme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, ZiroTheme.Spacing.small)
                }
                .frame(maxWidth: ZiroMeasure.standard)
                .accessibilityHint("Shows a sanitized error code with no conversation content")
            }
            .padding(.horizontal, ZiroTheme.Spacing.xLarge)
            .padding(.vertical, ZiroTheme.Spacing.xxLarge)
            .frame(maxWidth: .infinity)
        }
        .background(ZiroTheme.pageBackground)
    }
}

struct StoreResetConfirmationView: View {
    let artifact: StoreRecoveryArtifact
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var copiedSize: String {
        let bytes = artifact.manifest.reduce(Int64(0)) { $0 + $1.byteCount }
        return StorageByteFormatter.string(fromByteCount: bytes)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ZiroTheme.Spacing.xLarge) {
                ZiroHero(
                    symbol: "externaldrive.badge.checkmark",
                    title: "Recovery copy created",
                    message: "A verified \(copiedSize) copy is safe. Resetting will remove the unreadable original and create a fresh local history.",
                    tint: ZiroTheme.positiveText
                )

                ZiroStatusBanner(
                    icon: "checkmark.shield.fill",
                    title: "Your recovery copy is protected",
                    message: "\(artifact.manifest.count) local history file\(artifact.manifest.count == 1 ? "" : "s") copied and verified byte-for-byte.",
                    tone: .positive
                )
                .frame(maxWidth: ZiroMeasure.standard)

                VStack(spacing: ZiroTheme.Spacing.medium) {
                    // In-page destructive confirmations use the destructive
                    // token style (spec §8.8) — system red stays reserved for
                    // dialogs.
                    Button("Reset and Start Fresh", role: .destructive, action: onConfirm)
                        .buttonStyle(ZiroDestructiveButtonStyle())
                        .accessibilityHint("Deletes the unreadable original after preserving the recovery copy")
                    Button("Cancel", action: onCancel)
                        .buttonStyle(ZiroSecondaryButtonStyle())
                }
                .frame(maxWidth: ZiroMeasure.standard)
            }
            .padding(.horizontal, ZiroTheme.Spacing.xLarge)
            .padding(.vertical, ZiroTheme.Spacing.xxLarge)
            .frame(maxWidth: .infinity)
        }
        .background(ZiroTheme.pageBackground)
    }
}

struct StoreOperationProgressView: View {
    let symbol: String
    let title: String
    let message: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                progressContent(elapsed: nil)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    progressContent(elapsed: Int(context.date.timeIntervalSinceReferenceDate) % 60)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZiroTheme.pageBackground)
    }

    private func progressContent(elapsed: Int?) -> some View {
        VStack(spacing: ZiroTheme.Spacing.xLarge) {
            Group {
                if reduceMotion {
                    Image(systemName: symbol)
                } else {
                    Image(systemName: symbol).symbolEffect(.pulse)
                }
            }
            .font(.largeTitle.weight(.medium))
            .foregroundStyle(ZiroTheme.accent)
            .accessibilityHidden(true)
            ProgressView().controlSize(.large)
            VStack(spacing: ZiroTheme.Spacing.small) {
                Text(title)
                    .font(ZiroType.title)
                    .foregroundStyle(ZiroTheme.primaryText)
                Text(message)
                    .font(ZiroType.body)
                    .foregroundStyle(ZiroTheme.secondaryText)
                    .multilineTextAlignment(.center)
                if let elapsed {
                    Text("Working securely · \(elapsed)s")
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.tertiaryText)
                        .monospacedDigit()
                } else {
                    Text("Working securely")
                        .font(ZiroType.caption)
                        .foregroundStyle(ZiroTheme.tertiaryText)
                }
            }
        }
        .padding(.horizontal, ZiroTheme.Spacing.xLarge)
        .padding(.vertical, ZiroTheme.Spacing.xxLarge)
        .frame(maxWidth: ZiroMeasure.standard)
        .accessibilityElement(children: .combine)
    }
}
