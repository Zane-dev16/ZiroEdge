import XCTest
@testable import ZiroEdge

final class MemoryBudgeterTests: XCTestCase {
    func testDecisionUsesExactlyOneProcessHeadroomSample() async {
        let metrics = CountingMemoryMetricsProvider(processAvailable: 4_000_000_000, total: 8_054_095_872)
        let decision = await MemoryBudgeter(metrics: metrics).decision(
            for: ModelRegistry.gemma4_e2b,
            allowUnvalidatedCalibration: true
        )

        XCTAssertEqual(decision.recommendation, .proceed)
        XCTAssertEqual(decision.requiredBytes, 1_750_000_000)
        XCTAssertEqual(decision.processAvailableBytes, 4_000_000_000)
        XCTAssertEqual(metrics.processAvailableCallCount, 1)
        XCTAssertNil(decision.artifactBytesUsedForAdmission)
    }

    func testAcceptedPhysicalWorkloadPromotesExactE2BProfile() async {
        let decision = await MemoryBudgeter(
            metrics: FixedMemoryMetricsProvider(
                processAvailable: 3_488_300_112,
                total: 8_054_095_872
            )
        ).decision(for: ModelRegistry.gemma4_e2b)

        XCTAssertEqual(decision.recommendation, .proceed)
        XCTAssertNil(decision.reason)
        XCTAssertEqual(decision.requiredBytes, 1_750_000_000)
        XCTAssertNil(decision.artifactBytesUsedForAdmission)
    }

    func testZeroProcessHeadroomFailsClosed() async {
        let decision = await MemoryBudgeter(
            metrics: FixedMemoryMetricsProvider(processAvailable: 0, total: 128_000_000_000)
        ).decision(for: ModelRegistry.gemma4E4BTextCalibration, allowUnvalidatedCalibration: true)

        XCTAssertEqual(decision.recommendation, .insufficientRAM)
        XCTAssertEqual(decision.reason, .metricsUnavailable)
    }

    func testPhysicalRAMMinimumIsEnforcedForCalibration() async {
        let decision = await MemoryBudgeter(
            metrics: FixedMemoryMetricsProvider(processAvailable: 4_000_000_000, total: 6_000_000_000)
        ).decision(for: ModelRegistry.gemma4E4BTextCalibration, allowUnvalidatedCalibration: true)

        XCTAssertEqual(decision.reason, .physicalRAMBelowMinimum)
    }

    func testDecisionOwnsFormattingAndUnvalidatedWording() async {
        let decision = await MemoryBudgeter(
            metrics: FixedMemoryMetricsProvider(processAvailable: 1_000_000_000, total: 8_054_095_872)
        ).decision(for: ModelRegistry.gemma4E4BTextCalibration)

        XCTAssertTrue(decision.alertMessage(modelName: "Fixture").contains("explicit consent"))
        XCTAssertTrue(decision.logSummary.contains("processHeadroomBytes=1000000000"))
    }

    func testSettingsFormattingReusesLatestDecisionSample() async {
        let metrics = CountingMemoryMetricsProvider(processAvailable: 2_500_000_000, total: 8_054_095_872)
        let budgeter = MemoryBudgeter(metrics: metrics)
        let decision = await budgeter.decision(for: ModelRegistry.gemma4E4BTextCalibration)
        let displayedHeadroom = await budgeter.formattedAppMemoryHeadroom()

        XCTAssertEqual(displayedHeadroom, decision.formattedAppMemoryHeadroom)
        XCTAssertEqual(metrics.processAvailableCallCount, 1)
    }

    func testMemoryFormattingClampsValuesAboveInt64Max() {
        XCTAssertFalse(MemoryLoadDecision.format(bytes: .max).isEmpty)
    }

    func testSystemMetricsSmoke() async {
        let budgeter = MemoryBudgeter()
        let available = await budgeter.appMemoryHeadroom()
        let total = await budgeter.totalDeviceRAM()
        let formattedHeadroom = await budgeter.formattedAppMemoryHeadroom()
        let formattedTotal = await budgeter.formattedTotalRAM()
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThanOrEqual(available, total)
        XCTAssertFalse(formattedHeadroom.isEmpty)
        XCTAssertFalse(formattedTotal.isEmpty)
    }

    // MARK: - P1-1 stale sample retry-once

    /// A transient zero sample retries once and recovers when headroom
    /// returns (jetsam settling after unload). Hermetic flaky provider.
    func testP1TransientZeroMetricsRetryOnceAndRecover() async {
        let metrics = FlakyMemoryMetricsProvider(values: [0, 4_000_000_000], total: 8_054_095_872)
        let decision = await MemoryBudgeter(metrics: metrics).decision(
            for: ModelRegistry.gemma4_e2b,
            allowUnvalidatedCalibration: true
        )
        XCTAssertEqual(decision.recommendation, .proceed)
        XCTAssertEqual(metrics.processAvailableCallCount, 2)
        XCTAssertNil(decision.artifactBytesUsedForAdmission)
    }

    /// A persistent zero still fails closed after exactly one retry.
    func testP1PersistentZeroMetricsFailClosedAfterOneRetry() async {
        let metrics = CountingMemoryMetricsProvider(processAvailable: 0, total: 128_000_000_000)
        let decision = await MemoryBudgeter(metrics: metrics).decision(
            for: ModelRegistry.gemma4E4BTextCalibration,
            allowUnvalidatedCalibration: true
        )
        XCTAssertEqual(decision.recommendation, .insufficientRAM)
        XCTAssertEqual(decision.reason, .metricsUnavailable)
        XCTAssertEqual(metrics.processAvailableCallCount, 2)
    }

    // MARK: - P1-4 malformed sizes fail closed

    /// Negative base bytes can never admit, even with ample headroom.
    /// Sentinel stays nil (quantity never used).
    func testP1NegativeBaseSizeFailsClosed() async {
        let bad = AIModel(
            id: ModelRegistry.gemma4_e2b.id,
            displayName: ModelRegistry.gemma4_e2b.displayName,
            description: "bad",
            modelType: .vision,
            baseURL: ModelRegistry.gemma4_e2b.baseURL,
            mmprojURL: ModelRegistry.gemma4_e2b.mmprojURL,
            baseFileSizeBytes: -1,
            mmprojFileSizeBytes: ModelRegistry.gemma4_e2b.mmprojFileSizeBytes,
            baseSHA256: ModelRegistry.gemma4_e2b.baseSHA256,
            mmprojSHA256: ModelRegistry.gemma4_e2b.mmprojSHA256,
            quantization: "Q4_K_M",
            config: ModelRegistry.gemma4_e2b.config,
            license: ModelRegistry.gemma4_e2b.license
        )
        let decision = await MemoryBudgeter(
            metrics: FixedMemoryMetricsProvider(processAvailable: 16_000_000_000, total: 32_000_000_000)
        ).decision(for: bad, allowUnvalidatedCalibration: true)
        XCTAssertEqual(decision.recommendation, .insufficientRAM)
        XCTAssertEqual(decision.reason, .profileUnvalidated)
        XCTAssertNil(decision.requiredBytes)
        XCTAssertNil(decision.artifactBytesUsedForAdmission)
    }
}

private final class CountingMemoryMetricsProvider: MemoryMetricsProviding, @unchecked Sendable {
    private(set) var processAvailableCallCount = 0
    let processAvailable: UInt64
    let total: UInt64

    init(processAvailable: UInt64, total: UInt64) {
        self.processAvailable = processAvailable
        self.total = total
    }

    func processAvailableMemory() -> UInt64 {
        processAvailableCallCount += 1
        return processAvailable
    }

    func totalRAM() -> UInt64 { total }
}

/// Hermetic flaky headroom: replays `values` in order, repeating the last.
private final class FlakyMemoryMetricsProvider: MemoryMetricsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let values: [UInt64]
    private(set) var processAvailableCallCount = 0
    let total: UInt64

    init(values: [UInt64], total: UInt64) {
        self.values = values
        self.total = total
    }

    func processAvailableMemory() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let index = min(processAvailableCallCount, values.count - 1)
        processAvailableCallCount += 1
        return values[index]
    }

    func totalRAM() -> UInt64 { total }
}
