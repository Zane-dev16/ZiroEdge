// GenerationGate.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Single-slot mutex guarding exclusive use of the llama.cpp context. Two
// concurrent decode loops on one LlamaEngine (e.g. title generation racing a
// chat reply) are undefined behavior, so every engine-stream acquisition must
// pass through this gate: chat preempts the holder via cancelAndAwaitRelease,
// best-effort callers (title) fail fast on acquire() == false.

import Foundation

actor GenerationGate {

    /// Current owner's ID, or nil when idle.
    private var holder: UUID?

    /// Takes ownership if idle. Returns true and stores a fresh holder UUID on
    /// success; false when another generation already holds the gate.
    func acquire() -> Bool {
        guard holder == nil else { return false }
        holder = UUID()
        return true
    }

    /// Clears the holder only when `id` matches the current owner.
    /// Idempotent; foreign releases are ignored.
    func release(_ id: UUID) {
        guard holder == id else { return }
        holder = nil
    }

    /// The current holder, or nil when idle.
    func heldBy() -> UUID? {
        holder
    }

    /// If idle, returns true immediately. Otherwise invokes `canceller` once
    /// (e.g. to cancel the running stream) and polls `heldBy()` every 50 ms
    /// until the holder releases or `timeoutNs` elapses. Returns whether the
    /// gate is idle when this call returns. Cooperative cancellation of the
    /// awaiting task ends the wait immediately (with the current idle state)
    /// instead of hot-spinning through swallowed CancellationErrors.
    func cancelAndAwaitRelease(
        timeoutNs: UInt64 = 2_000_000_000,
        using canceller: @Sendable () async -> Void
    ) async -> Bool {
        guard holder != nil else { return true }
        await canceller()
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(clamping: timeoutNs)))
        while holder != nil && ContinuousClock.now < deadline {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                // A cancelled waiter must not degrade into a zero-sleep spin
                // for the remainder of the timeout window.
                return holder == nil
            }
        }
        return holder == nil
    }
}
