import Foundation
import UIKit

// MARK: - Background Download Lifecycle
//
// Background model downloads use a shared URLSession background configuration
// identified by `DownloadManager.backgroundSessionIdentifier`. The delegate
// (DownloadManager itself) receives callbacks on a main-queue operation queue.
//
// ## Scenario behavior (honest accounting)
//
// | Scenario               | Active downloads        | Inactive (paused/failed) | Completion delivered |
// |------------------------|-------------------------|--------------------------|----------------------|
// | Foreground             | Live delegate callbacks | Restored from durable    | N/A                  |
// | Background             | URLSession continues    | Durable state persists   | Via didFinishEvents   |
// | Suspended by OS        | URLSession continues    | Durable state persists   | Via didFinishEvents   |
// | OS termination         | URLSession MAY continue | Restored from durable    | Via handleEvents +    |
// |                        | (not guaranteed)        | on relaunch              | didFinishEvents       |
// | User force-quit        | URLSession cancelled by | Restored from durable    | N/A — system kills   |
// |                        | system; staged bytes    | on relaunch; must        | the session; durable  |
// |                        | discarded               | restart from scratch     | state re-wraps as    |
// |                        |                         |                          | paused               |
// | Device reboot          | All URLSession tasks    | Restored from durable    | N/A — no session     |
// |                        | evicted; staged bytes   | on relaunch; best-effort | survives reboot      |
// |                        | survive on disk         | resume from staging      |                      |
//
// ### Force-quit limitations
//
// When the user force-quits (swipes the app away), iOS cancels every
// background URLSession task. `urlSession(_:task:didCompleteWithError:)`
// delivers `NSURLErrorCancelled` with a resume-data blob when the server
// supports it, but the delegate may not receive this callback before the
// process exits. Staged bytes survive on disk but the URLSession resume
// handle is lost.
//
// After a force-quit relaunch, `restoreDurableTransfers()` rewraps the
// durable state as `.paused`. The user must tap Resume to restart the
// transfer from the persisted progress (chunked downloads) or resume data
// (small downloads). This is a deliberate design choice: never silently
// restart a download whose URLSession token was invalidated.
//
// ### Stable identities
//
// - Session identity: `DownloadManager.backgroundSessionIdentifier` is a
//   compile-time constant so URLSession can reattach across relaunches.
// - Transfer identity: `DownloadTask.storageID` is deterministic (derived
//   from model identity and artifact type). It is set as the URLSession
//   `taskDescription` so delegate callbacks can unambiguously map system
//   tasks back to application-level transfer records.

@MainActor
enum BackgroundDownloadCompletionStore {
    private static var handlers: [String: () -> Void] = [:]

    static func retain(identifier: String, completion: @escaping () -> Void) {
        handlers[identifier] = completion
    }

    static func drain(identifier: String) {
        let completion = handlers.removeValue(forKey: identifier)
        completion?()
    }

    /// For testing: whether a handler is pending for the given session identifier.
    static func hasPendingHandler(for identifier: String) -> Bool {
        handlers[identifier] != nil
    }
}

final class ZiroEdgeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            BackgroundDownloadCompletionStore.retain(
                identifier: identifier,
                completion: completionHandler
            )
        }
    }
}
