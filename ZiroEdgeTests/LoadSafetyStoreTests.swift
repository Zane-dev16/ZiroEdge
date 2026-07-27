import XCTest
@testable import ZiroEdge

final class LoadSafetyStoreTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func recordClean(_ store: LoadSafetyStore, profileID: String) throws {
        try store.beginLoad(profileID: profileID)
        try store.clearAfterNativeConstruction(profileID: profileID)
    }

    private func recordUnclean(directory: URL, profileID: String) throws -> LoadSafetyStore {
        let store = try LoadSafetyStore(directory: directory)
        try store.beginLoad(profileID: profileID)
        return try LoadSafetyStore(directory: directory)
    }

    func testZeroOfFiveDoesNotDisableProfile() throws {
        let url = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try LoadSafetyStore(directory: url)
        for _ in 0..<5 { try recordClean(store, profileID: "p1") }
        XCTAssertEqual(store.recentUncleanAttemptCount(profileID: "p1"), 0)
        XCTAssertFalse(store.isDisabled(profileID: "p1"))
    }

    func testOneOfFiveDoesNotDisableProfile() throws {
        let url = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = try recordUnclean(directory: url, profileID: "p1")
        for _ in 0..<4 { try recordClean(store, profileID: "p1") }
        store = try LoadSafetyStore(directory: url)
        XCTAssertEqual(store.recentUncleanAttemptCount(profileID: "p1"), 1)
        XCTAssertFalse(store.isDisabled(profileID: "p1"))
    }

    func testTwoOfFiveDisableOnlyThatProfile() throws {
        let url = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = try recordUnclean(directory: url, profileID: "p1")
        try recordClean(store, profileID: "p1")
        store = try recordUnclean(directory: url, profileID: "p1")

        XCTAssertEqual(store.lastLaunchClassification, .suspectedJetsam)
        XCTAssertEqual(store.lastInterruptedProfileID, "p1")
        XCTAssertTrue(store.isDisabled(profileID: "p1"))
        XCTAssertFalse(store.isDisabled(profileID: "p2"))
        XCTAssertThrowsError(try store.beginLoad(profileID: "p1")) {
            XCTAssertEqual($0 as? LoadSafetyError, .profileDisabled)
        }
    }

    func testUncleanOutcomeAgesOutOfExactFiveAttemptWindow() throws {
        let url = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = try recordUnclean(directory: url, profileID: "p1")
        for _ in 0..<5 { try recordClean(store, profileID: "p1") }
        store = try LoadSafetyStore(directory: url)
        XCTAssertEqual(store.recentUncleanAttemptCount(profileID: "p1"), 0)
        XCTAssertFalse(store.isDisabled(profileID: "p1"))
    }

    func testRelaunchClassifiesPendingConstructionExactlyOnce() throws {
        let url = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try LoadSafetyStore(directory: url)
        try first.beginLoad(profileID: "p1")

        let recovered = try LoadSafetyStore(directory: url)
        XCTAssertEqual(recovered.lastLaunchClassification, .suspectedJetsam)
        XCTAssertEqual(recovered.recentUncleanAttemptCount(profileID: "p1"), 1)

        let nextLaunch = try LoadSafetyStore(directory: url)
        XCTAssertNil(nextLaunch.lastLaunchClassification)
        XCTAssertEqual(nextLaunch.recentUncleanAttemptCount(profileID: "p1"), 1)
    }

    func testCorruptStateFailsClosedWithoutJetsamMisclassification() throws {
        let url = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url.appendingPathComponent("load-safety-state.json"))

        XCTAssertThrowsError(try LoadSafetyStore(directory: url)) {
            XCTAssertEqual($0 as? LoadSafetyError, .corruptState)
        }
    }

    func testAtomicWriteFailureDoesNotMutateInMemoryHistory() throws {
        let url = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let fileSystem = FaultingLoadSafetyFileSystem()
        let store = try LoadSafetyStore(directory: url, fileSystem: fileSystem)
        fileSystem.failNextWrite = true

        XCTAssertThrowsError(try store.beginLoad(profileID: "p1")) {
            XCTAssertEqual($0 as? LoadSafetyError, .persistenceFailed)
        }
        XCTAssertEqual(store.recentUncleanAttemptCount(profileID: "p1"), 0)
        XCTAssertFalse(store.isDisabled(profileID: "p1"))
    }

    func testExplicitResetIsProfileScopedAndPersistsAcrossRelaunch() throws {
        let url = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        var store = try recordUnclean(directory: url, profileID: "p1")
        store = try recordUnclean(directory: url, profileID: "p1")
        _ = try recordUnclean(directory: url, profileID: "p2")
        store = try LoadSafetyStore(directory: url)

        try store.reset(profileID: "p1")
        store = try LoadSafetyStore(directory: url)
        XCTAssertFalse(store.isDisabled(profileID: "p1"))
        XCTAssertEqual(store.recentUncleanAttemptCount(profileID: "p1"), 0)
        XCTAssertEqual(store.recentUncleanAttemptCount(profileID: "p2"), 1)
    }
}

private final class FaultingLoadSafetyFileSystem: LoadSafetyFileSystem, @unchecked Sendable {
    var failNextWrite = false
    private let production = ProductionLoadSafetyFileSystem()

    func createDirectory(at url: URL) throws { try production.createDirectory(at: url) }
    func fileExists(at url: URL) -> Bool { production.fileExists(at: url) }
    func read(at url: URL) throws -> Data { try production.read(at: url) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        if failNextWrite {
            failNextWrite = false
            throw CocoaError(.fileWriteUnknown)
        }
        try production.writeAtomically(data, to: url)
    }
}
