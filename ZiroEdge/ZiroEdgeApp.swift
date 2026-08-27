// ZiroEdgeApp.swift
// ZiroEdge — Privacy-first local AI assistant

import SwiftUI

@main
struct ZiroEdgeApp: App {
    @UIApplicationDelegateAdaptor(ZiroEdgeAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var runtime = AppRuntime()

    static let diagnosticLogURL: URL =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("download-diagnostic.log")

    static func diagnosticLog(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(sanitizedDiagnosticMessage(message))\n"
        let url = diagnosticLogURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func sanitizedDiagnosticMessage(_ message: String) -> String {
        var sanitized = message
        let patterns = [
            #"https?://[^\s]+"#,
            #"file://[^\s]+"#,
            #"/(?:private/)?var/(?:mobile|folders)/[^\s]+"#,
            #"(?i)(?:authorization|bearer|token|signature|credential|conversation)=?[^\s]*"#
        ]
        for pattern in patterns {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: .regularExpression
            )
        }
        return sanitized
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .task {
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    if MemoryDiagnosticRecorder.shared.isEnabled {
                        if CommandLine.arguments.contains("--memory-diagnostic-reset") {
                            MemoryDiagnosticRecorder.shared.resetLog()
                        }
                        MemoryDiagnosticRecorder.shared.capture(.cold)
                    }
                    await runtime.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        MemoryDiagnosticRecorder.shared.capture(.background)
                    } else if phase == .active {
                        MemoryDiagnosticRecorder.shared.capture(.foreground)
                    }
                    guard phase == .background,
                          case .ready(let services) = runtime.state else { return }
                    services.downloadManager.handleBackgroundTransition()
                    Task {
                        await services.lifecycleManager.handleBackgroundTransition()
                        let failures = await services.persistence.flushPendingWrites()
                        if let failure = failures.values.first {
                            await MainActor.run {
                                services.chatViewModel.presentBackgroundPersistenceFailure(failure)
                            }
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        switch runtime.state {
        case .loading(let attempt):
            StoreOperationProgressView(
                symbol: "lock.open.display",
                title: "Opening local history",
                message: attempt > 1
                    ? "Retry attempt \(attempt). Large histories can take a moment to verify."
                    : "Preparing your private conversations on this device."
            )
        case .ready(let services):
            AppShellView(services: services, onboardingManager: OnboardingManager())
                .overlay(alignment: .top) {
                    if let message = runtime.postResetMessage {
                        ZiroStatusBanner(
                            icon: "checkmark.circle.fill",
                            message: message,
                            tint: ZiroTheme.positiveText
                        )
                        .announcingOnAppear(message)
                        .clipShape(RoundedRectangle(cornerRadius: ZiroTheme.Radius.control))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                        .padding()
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .snappy, value: runtime.postResetMessage)
        case .failed(let failure):
            StoreRecoveryView(
                failure: failure,
                diagnosticsURL: runtime.diagnosticsURL,
                diagnosticsExportError: runtime.diagnosticsExportError,
                onRetry: runtime.retry,
                onExportDiagnostics: runtime.exportDiagnostics,
                onReset: runtime.prepareReset
            )
        case .loadSafetyFailed(let message):
            VStack(spacing: ZiroTheme.Spacing.large) {
                ZiroHero(
                    symbol: "lock.trianglebadge.exclamationmark",
                    title: "Model loading is blocked",
                    message: message,
                    tint: .orange
                )
                Button("Retry Safety Storage") { runtime.retry() }
                    .buttonStyle(ZiroPrimaryButtonStyle())
            }
            .padding()
        case .quarantining:
            StoreOperationProgressView(
                symbol: "doc.on.doc.fill",
                title: "Creating a recovery copy",
                message: "Copying and verifying local history before any changes are made."
            )
        case .awaitingResetConfirmation(let artifact):
            StoreResetConfirmationView(
                artifact: artifact,
                onCancel: runtime.cancelReset,
                onConfirm: { runtime.confirmReset(artifact) }
            )
        case .resetting:
            StoreOperationProgressView(
                symbol: "arrow.clockwise.circle.fill",
                title: "Starting fresh",
                message: "Preserving the recovery copy and creating a clean local history."
            )
        }
    }
}
