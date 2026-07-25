import XCTest
@testable import ZiroEdge

final class MemoryBudgeterTests: XCTestCase {
    private let model = AIModel(
        id: "memory-fixture", displayName: "Fixture", description: "Fixture", modelType: .text,
        baseURL: URL(string: "https://example.com/model.gguf")!, mmprojURL: nil,
        baseFileSizeBytes: 2_000_000_000, mmprojFileSizeBytes: nil,
        baseSHA256: String(repeating: "a", count: 64), mmprojSHA256: nil,
        quantization: "Q4", config: .llama32, minimumDeviceRAM: 0,
        license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
    )

    func testDecisionUsesExactlyOneProcessHeadroomSample() async {
        let metrics = CountingMemoryMetricsProvider(processAvailable: 4_000_000_000, total: 8_000_000_000)
        let decision = await MemoryBudgeter(metrics: metrics).decision(for: model)

        XCTAssertEqual(decision.recommendation, .proceed)
        XCTAssertEqual(decision.processAvailableBytes, 4_000_000_000)
        XCTAssertEqual(metrics.processAvailableCallCount, 1)
    }

    func testCapturedPhysicalDeviceFixtureBlocksGemmaWithoutHostVMFallback() async throws {
        let gemma = try XCTUnwrap(ModelRegistry.model(for: "gemma-4-e2b-q4"))
        let metrics = FixedMemoryMetricsProvider(
            processAvailable: 3_488_300_112,
            total: 8_054_095_872
        )

        let decision = await MemoryBudgeter(metrics: metrics).decision(for: gemma)

        XCTAssertEqual(decision.modelBytes, 3_985_228_864)
        XCTAssertEqual(decision.requiredBytes, 5_485_228_864)
        XCTAssertEqual(decision.recommendation, .insufficientRAM)
        XCTAssertEqual(decision.processAvailableBytes, 3_488_300_112)
    }

    func testZeroProcessHeadroomFailsClosedInsteadOfUsingHostMemory() async {
        let decision = await MemoryBudgeter(
            metrics: FixedMemoryMetricsProvider(processAvailable: 0, total: 128_000_000_000)
        ).decision(for: model)

        XCTAssertEqual(decision.recommendation, .insufficientRAM)
        XCTAssertEqual(decision.processAvailableBytes, 0)
    }

    func testDecisionOwnsRecommendationFormattingAndAlertWording() async {
        let decision = await MemoryBudgeter(
            metrics: FixedMemoryMetricsProvider(processAvailable: 1_000_000_000, total: 8_000_000_000)
        ).decision(for: model)

        XCTAssertEqual(decision.recommendation, .insufficientRAM)
        XCTAssertTrue(decision.alertMessage(modelName: model.displayName).contains("App Memory Headroom"))
        XCTAssertTrue(decision.logSummary.contains("processHeadroomBytes=1000000000"))
    }

    func testUnloadRecommendationUsesSameCapturedSample() async {
        let metrics = CountingMemoryMetricsProvider(processAvailable: 2_500_000_000, total: 8_000_000_000)
        let decision = await MemoryBudgeter(metrics: metrics).decision(for: model)

        XCTAssertEqual(decision.recommendation, .unloadCurrentFirst)
        XCTAssertEqual(metrics.processAvailableCallCount, 1)
    }

    func testSettingsFormattingReusesLatestDecisionSample() async {
        let metrics = CountingMemoryMetricsProvider(processAvailable: 2_500_000_000, total: 8_000_000_000)
        let budgeter = MemoryBudgeter(metrics: metrics)
        let decision = await budgeter.decision(for: model)
        let displayedHeadroom = await budgeter.formattedAppMemoryHeadroom()

        XCTAssertEqual(displayedHeadroom, decision.formattedAppMemoryHeadroom)
        XCTAssertEqual(metrics.processAvailableCallCount, 1)
    }

    func testMemoryFormattingClampsValuesAboveInt64Max() {
        let decision = MemoryLoadDecision(
            recommendation: .proceed,
            processAvailableBytes: .max,
            modelBytes: 1,
            requiredBytes: 1
        )

        XCTAssertFalse(decision.formattedAppMemoryHeadroom.isEmpty)
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
