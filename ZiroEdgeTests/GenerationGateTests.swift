// GenerationGateTests.swift
// Pure unit tests for the single-slot generation gate that serializes access
// to the llama.cpp context. No model, no engine — actor semantics only.

import XCTest
@testable import ZiroEdge

// MARK: - Helpers

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

final class GenerationGateTests: XCTestCase {

    /// Acquires the gate and returns its holder ID (test fails on refusal).
    private func hold(_ gate: GenerationGate) async throws -> UUID {
        guard await gate.acquire(), let id = await gate.heldBy() else {
            XCTFail("expected fresh gate to be acquirable")
            throw NSError(domain: "GenerationGateTests", code: 1)
        }
        return id
    }

    // MARK: - Mutual exclusion

    func testSecondAcquireRefusedWhileHeld() async throws {
        let gate = GenerationGate()
        _ = try await hold(gate)

        let refused = await gate.acquire()
        XCTAssertFalse(refused, "second acquire while held must be refused")
        let holderCount = await gate.heldBy().map { _ in 1 }
        XCTAssertEqual(holderCount, 1, "exactly one holder")
    }

    // MARK: - Release semantics

    func testReleaseByWrongIDIsIgnored() async throws {
        let gate = GenerationGate()
        let holderID = try await hold(gate)

        await gate.release(UUID()) // foreign release

        let afterForeign = await gate.heldBy()
        XCTAssertEqual(
            afterForeign,
            holderID,
            "a foreign ID must not clear someone else's slot"
        )
    }

    func testCorrectReleaseReopensGateWithFreshHolder() async throws {
        let gate = GenerationGate()
        let first = try await hold(gate)

        await gate.release(first)
        let idleAfterRelease = await gate.heldBy()
        XCTAssertNil(idleAfterRelease)

        let reacquired = await gate.acquire()
        XCTAssertTrue(reacquired)
        let second = await gate.heldBy()
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first, "re-acquisition must mint a new holder ID")
    }

    // MARK: - cancelAndAwaitRelease

    func testCancelAndAwaitReleaseInvokesCancellerAndReturnsTrueOnceReleased() async throws {
        let gate = GenerationGate()
        let holderID = try await hold(gate)
        let cancellerRuns = LockedCounter()

        let released = await gate.cancelAndAwaitRelease(timeoutNs: 2_000_000_000) {
            cancellerRuns.increment()
            // Holder notices cancellation and releases at its next token boundary.
            try? await Task.sleep(nanoseconds: 100_000_000)
            await gate.release(holderID)
        }
        let idleAfterwards = await gate.heldBy()

        XCTAssertTrue(released)
        XCTAssertEqual(cancellerRuns.count, 1, "canceller must run exactly once")
        XCTAssertNil(idleAfterwards)
    }

    func testCancelAndAwaitReleaseReturnsFalseOnTimeout() async throws {
        let gate = GenerationGate()
        let holderID = try await hold(gate)
        let cancellerRuns = LockedCounter()

        let start = Date()
        let released = await gate.cancelAndAwaitRelease(timeoutNs: 200_000_000) {
            cancellerRuns.increment() // holder never releases
        }
        let elapsed = Date().timeIntervalSince(start)
        let stillHeld = await gate.heldBy()

        XCTAssertFalse(released, "must report failure when the holder never releases")
        XCTAssertEqual(cancellerRuns.count, 1)
        XCTAssertGreaterThanOrEqual(elapsed, 0.18, "must wait roughly the full timeout")
        XCTAssertEqual(stillHeld, holderID, "original holder keeps ownership")
    }

    func testIdleGateSkipsCancellerAndReturnsTrueImmediately() async {
        let gate = GenerationGate()
        let cancellerRuns = LockedCounter()

        let released = await gate.cancelAndAwaitRelease(timeoutNs: 2_000_000_000) {
            cancellerRuns.increment()
        }

        XCTAssertTrue(released)
        XCTAssertEqual(cancellerRuns.count, 0, "idle gate must not invoke the canceller")
    }

    // MARK: - Concurrency

    func testConcurrentAcquirersExactlyOneWinnerOutOfN() async {
        let gate = GenerationGate()
        let contenders = 32

        let winners = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<contenders {
                group.addTask { await gate.acquire() }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        let leftoverHolder = await gate.heldBy()

        XCTAssertEqual(winners, 1, "exactly one of \(contenders) racing acquirers wins")

        // Cleanup so the gate is left idle for other tests.
        if let winnerID = leftoverHolder {
            await gate.release(winnerID)
        }
        let finalHolder = await gate.heldBy()
        XCTAssertNil(finalHolder)
    }
}
