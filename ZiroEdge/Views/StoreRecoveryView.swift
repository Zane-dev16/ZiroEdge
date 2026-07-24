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
                    tint: .orange
                )

                VStack(spacing: ZiroTheme.Spacing.medium) {
                    Button("Try Again", action: onRetry)
                        .buttonStyle(ZiroPrimaryButtonStyle())
                        .accessibilityHint("Attempts to open local history again")

                    if let diagnosticsURL {
                        ShareLink(item: diagnosticsURL) {
                            Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    } else {
                        Button(action: onExportDiagnostics) {
                            Label("Export Diagnostics", systemImage: "doc.badge.gearshape")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    Button(action: onReset) {
                        Label("Recover Local Store", systemImage: "wrench.and.screwdriver")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityHint("Creates a verified recovery copy before offering a reset")
                }
                .frame(maxWidth: 360)

                if let diagnosticsExportError {
                    ZiroStatusBanner(
                        icon: "exclamationmark.triangle.fill",
                        message: diagnosticsExportError,
                        tint: .red
                    )
                    .frame(maxWidth: 520)
                }

                DisclosureGroup("Technical Details", isExpanded: $showsDetails) {
                    Text(failure.sanitizedDiagnostic)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, ZiroTheme.Spacing.small)
                }
                .frame(maxWidth: 520)
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
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ZiroTheme.Spacing.xLarge) {
                ZiroHero(
                    symbol: "externaldrive.badge.checkmark",
                    title: "Recovery copy created",
                    message: "A verified \(copiedSize) copy is safe. Resetting will remove the unreadable original and create a fresh local history.",
                    tint: .green
                )

                ZiroStatusBanner(
                    icon: "checkmark.shield.fill",
                    title: "Your recovery copy is protected",
                    message: "\(artifact.manifest.count) local history file\(artifact.manifest.count == 1 ? "" : "s") copied and verified byte-for-byte.",
                    tint: .green
                )
                .frame(maxWidth: 520)

                VStack(spacing: ZiroTheme.Spacing.medium) {
                    Button("Reset and Start Fresh", role: .destructive, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityHint("Deletes the unreadable original after preserving the recovery copy")
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
            .padding(ZiroTheme.Spacing.xxLarge)
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
            .font(.largeTitle)
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
            ProgressView().controlSize(.large)
            VStack(spacing: ZiroTheme.Spacing.small) {
                Text(title).font(.title2.bold())
                Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let elapsed {
                    Text("Working securely · \(elapsed)s")
                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                } else {
                    Text("Working securely")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(ZiroTheme.Spacing.xxLarge)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
    }
}
