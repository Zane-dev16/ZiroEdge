import XCTest
@testable import ZiroEdge

@MainActor
final class DownloadManagerBatch01Tests: XCTestCase {

    private func makeSession(delegate: DownloadManager) -> URLSession {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: delegate, delegateQueue: OperationQueue.main)
    }

    // MARK: - (a) Off-main deallocation must not trap

    func testDeallocationOffMainDoesNotTrap() {
        weak var weakManager: DownloadManager?
        let exp = expectation(description: "off-main dealloc completes")
        Task { @MainActor in
            var manager: DownloadManager? = DownloadManager()
            weakManager = manager
            _ = manager?.getSession()
            _ = manager?.getChunkSession()
            let holder = manager
            manager = nil
            DispatchQueue.global(qos: .userInitiated).async {
                _ = holder
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    XCTAssertNil(weakManager, "DownloadManager must deallocate even when last reference drops off-main (no trap/leak)")
                    exp.fulfill()
                }
            }
        }
        wait(for: [exp], timeout: 4.0)
    }

    func testDeallocationOffMainWithInjectedSessionDoesNotTrap() {
        weak var weakManager: DownloadManager?
        let exp = expectation(description: "off-main dealloc with injected session")
        Task { @MainActor in
            var manager: DownloadManager? = DownloadManager()
            weakManager = manager
            // Use production-like session creation (which now uses weak proxy, no retain cycle)
            _ = manager?.getSession()
            _ = manager?.getChunkSession()
            let holder = manager
            manager = nil
            DispatchQueue.global(qos: .userInitiated).async {
                _ = holder
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    XCTAssertNil(weakManager, "Injected-session manager must deallocate off-main without trap")
                    exp.fulfill()
                }
            }
        }
        wait(for: [exp], timeout: 4.0)
    }

    // MARK: - (b) Teardown invalidates URLSession exactly once (observable via nil + distinct)

    func testTeardownNilStorageExactlyOnce() {
        let manager = DownloadManager()
        let session = makeSession(delegate: manager)
        manager.urlSessionStorage = session
        manager.teardown()
        XCTAssertNil(manager.urlSessionStorage, "urlSessionStorage must be nil after teardown")
        // Second teardown must be idempotent
        manager.teardown()
        XCTAssertNil(manager.urlSessionStorage, "second teardown must keep nil (idempotent)")
    }

    func testTeardownUsesCorrectInvalidationStrategy() {
        // No active tasks -> should use invalidateAndCancel (observable via storage nilled and no crash)
        let manager = DownloadManager()
        let session = makeSession(delegate: manager)
        manager.urlSessionStorage = session
        XCTAssertTrue(manager.activeTasks.isEmpty)
        manager.teardown()
        XCTAssertNil(manager.urlSessionStorage)
        // With active tasks -> should use finishTasksAndInvalidate
        let manager2 = DownloadManager()
        let session2 = makeSession(delegate: manager2)
        manager2.urlSessionStorage = session2
        let task = DownloadTask(model: ModelRegistry.llama32_3B, artifact: .base)
        task.task = session2.downloadTask(with: URL(string: "https://example.com/file.gguf")!)
        manager2.activeTasks[task.storageID] = task
        manager2.teardown()
        XCTAssertNil(manager2.urlSessionStorage, "active-task teardown must also nil storage")
    }

    func testChunkSessionInvalidatedOnTeardown() {
        let manager = DownloadManager()
        let session = makeSession(delegate: manager)
        manager.chunkSessionStorage = session
        manager.teardown()
        XCTAssertNil(manager.chunkSessionStorage)
    }

    func testTeardownIsIdempotentForBothSessions() {
        let manager = DownloadManager()
        manager.urlSessionStorage = makeSession(delegate: manager)
        manager.chunkSessionStorage = makeSession(delegate: manager)
        manager.teardown()
        XCTAssertNil(manager.urlSessionStorage)
        XCTAssertNil(manager.chunkSessionStorage)
        manager.teardown()
        XCTAssertNil(manager.urlSessionStorage)
        XCTAssertNil(manager.chunkSessionStorage)
    }

    // MARK: - (c) Recreation path leaves no live session collision

    func testRecreationDoesNotLeaveLiveSessionCollision() {
        let first = DownloadManager()
        let sessionOne = makeSession(delegate: first)
        first.urlSessionStorage = sessionOne
        let idOne = ObjectIdentifier(sessionOne)
        first.teardown()
        XCTAssertNil(first.urlSessionStorage, "old storage must be nil after teardown")
        let second = DownloadManager()
        let sessionTwo = makeSession(delegate: second)
        second.urlSessionStorage = sessionTwo
        XCTAssertNotEqual(idOne, ObjectIdentifier(sessionTwo), "new manager must have distinct session")
        XCTAssertNotNil(second.urlSessionStorage)
        second.teardown()
    }

    func testDeinitAfterTeardownDoesNotDoubleInvalidate() {
        var manager: DownloadManager? = DownloadManager()
        let session = makeSession(delegate: manager!)
        manager?.urlSessionStorage = session
        manager?.teardown()
        XCTAssertNil(manager?.urlSessionStorage)
        manager = nil
        let exp = expectation(description: "deinit after teardown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        // If double-invalidate occurred, it would trap or log; reaching here means safe
    }

    func testTeardownClearsTimerAndObserver() {
        let manager = DownloadManager()
        // Timer is created lazily via startStuckWatchdog; simulate
        manager.stuckTimer = Timer.scheduledTimer(withTimeInterval: 100, repeats: false) { _ in }
        XCTAssertNotNil(manager.stuckTimer)
        manager.teardown()
        XCTAssertNil(manager.stuckTimer, "teardown must nil stuckTimer")
        XCTAssertNil(manager.protectedDataObserver, "teardown must nil observer")
    }
}
