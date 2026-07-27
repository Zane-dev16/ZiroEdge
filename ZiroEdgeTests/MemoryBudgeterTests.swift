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
