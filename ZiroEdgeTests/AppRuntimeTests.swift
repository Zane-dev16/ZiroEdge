import XCTest
@testable import ZiroEdge

@MainActor
final class AppRuntimeTests: XCTestCase {
    func testLoadFailureGatesRuntimeAndUserRetryRecovers() async throws {
        let injected = NSError(domain: "NSSQLiteErrorDomain", code: 14)
        let faults = ScriptedPersistenceFaultInjector([.fail(.loadStore, error: injected)])
        let runtime = AppRuntime(configuration: .inMemory, faultInjector: faults)

        await runtime.start()
        guard case .failed(let failure) = runtime.state else {
            return XCTFail("Persistence failure must gate runtime construction")
        }
        XCTAssertEqual(failure.category, .storeUnavailable)

        runtime.retry()
        for _ in 0..<1_000 {
            if case .ready = runtime.state { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("User retry did not transition to ready")
    }

    func testCustomStoreResetPreparationQuarantinesOnlyConfiguredStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("custom.sqlite")
        let recoveryRoot = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("custom-store".utf8).write(to: store)
        defer { try? FileManager.default.removeItem(at: root) }

        let loadError = NSError(domain: "fixture", code: 14)
        let runtime = AppRuntime(
            configuration: .store(store),
            faultInjector: ScriptedPersistenceFaultInjector([.fail(.loadStore, error: loadError)]),
            recoveryCoordinator: StoreRecoveryCoordinator(recoveryRoot: recoveryRoot)
        )
        await runtime.start()
        runtime.prepareReset()
        for _ in 0..<1_000 {
            if case .awaitingResetConfirmation(let artifact) = runtime.state {
                XCTAssertEqual(artifact.sourceStoreURL, store.standardizedFileURL)
                XCTAssertEqual(try Data(contentsOf: store), Data("custom-store".utf8))
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Custom store quarantine did not complete")
    }

    func testDiagnosticsAreSanitized() async {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError,
            userInfo: [NSFilePathErrorKey: "/private/user/secret.sqlite"]
        )
        let runtime = AppRuntime(
            configuration: .inMemory,
            faultInjector: ScriptedPersistenceFaultInjector([.fail(.loadStore, error: error)])
        )
        await runtime.start()
        runtime.exportDiagnostics()
        guard let url = runtime.diagnosticsURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return XCTFail("Expected diagnostics export")
        }
        XCTAssertTrue(text.contains("domain=NSCocoaErrorDomain"))
        XCTAssertFalse(text.contains("secret.sqlite"))
        XCTAssertFalse(text.contains("/private/"))
    }
}
