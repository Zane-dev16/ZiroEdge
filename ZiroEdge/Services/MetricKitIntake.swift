// MetricKitIntake.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Receive-only MetricKit intake. Apple delivers crash, hang, and metric
// payloads on-device on next launch when the user opted in to share
// diagnostics with developers. This subscriber appends short summaries to
// the existing local diagnostic log — the Export button stays the only way
// data leaves the device. No third-party SDK, no uploads.

import Foundation
import MetricKit

/// Subscribes to MetricKit and mirrors payload summaries into the local log.
final class MetricKitIntake: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitIntake()

    private override init() {
        super.init()
    }

    /// Register for on-device delivery. Safe to call once at launch.
    func start() {
        MXMetricManager.shared.add(self)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard let latest = payloads.last else { return }
        ZiroEdgeApp.diagnosticLog(
            "metrickit metrics received count=\(payloads.count) from=\(latest.timeStampBegin) to=\(latest.timeStampEnd)"
        )
    }

    @available(iOS 14.0, *)
    func didReceive(_ payloads: [MXCrashDiagnostic]) {
        for crash in payloads {
            let reason = crash.terminationReason ?? "unknown"
            let type = crash.exceptionReason?.composedMessage
                ?? crash.exceptionType?.stringValue
                ?? "unknown"
            ZiroEdgeApp.diagnosticLog(
                "metrickit crash reason=\(reason) type=\(type)"
            )
        }
    }

    @available(iOS 15.0, *)
    func didReceive(_ payloads: [MXHangDiagnostic]) {
        for hang in payloads {
            ZiroEdgeApp.diagnosticLog(
                "metrickit hang duration=\(hang.hangDuration)"
            )
        }
    }
}
