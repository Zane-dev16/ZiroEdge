import SwiftUI

struct StoreRecoveryView: View {
    let failure: PersistenceFailure
    let diagnosticsURL: URL?
    let onRetry: () -> Void
    let onExportDiagnostics: () -> Void
    let onReset: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Local History Unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(failure.localizedDescription)
        } actions: {
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
            Button("Export Diagnostics", action: onExportDiagnostics)
            if let diagnosticsURL {
                ShareLink(item: diagnosticsURL) {
                    Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                }
            }
            Button("Reset Local History", role: .destructive, action: onReset)
        }
        .padding()
    }
}
