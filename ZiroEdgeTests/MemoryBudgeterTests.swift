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

    func testRecommendationProceedWithFixedMetrics() async {
        let budgeter = MemoryBudgeter(metrics: FixedMemoryMetricsProvider(available: 4_000_000_000, total: 8_000_000_000))
        let result = await budgeter.recommendation(for: model)
        guard case .proceed = result else { return XCTFail("Expected proceed, got \(result)") }
        let canLoad = await budgeter.canLoad(model)
        XCTAssertTrue(canLoad)
    }

    func testRecommendationUnloadCurrentFirstWithFixedMetrics() async {
        let budgeter = MemoryBudgeter(metrics: FixedMemoryMetricsProvider(available: 2_500_000_000, total: 8_000_000_000))
        let result = await budgeter.recommendation(for: model)
        guard case .unloadCurrentFirst = result else { return XCTFail("Expected unloadCurrentFirst, got \(result)") }
    }

    func testRecommendationInsufficientWithFixedMetrics() async {
        let budgeter = MemoryBudgeter(metrics: FixedMemoryMetricsProvider(available: 1_000_000_000, total: 128_000_000_000))
        let result = await budgeter.recommendation(for: model)
        guard case .insufficientRAM = result else { return XCTFail("Expected insufficientRAM, got \(result)") }
        let canLoad = await budgeter.canLoad(model)
        XCTAssertFalse(canLoad)
    }

    func testSystemMetricsSmoke() async throws {
        let budgeter = MemoryBudgeter()
        let available = await budgeter.availableRAM()
        let total = await budgeter.totalDeviceRAM()
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThanOrEqual(available, total)
        let formattedAvailable = await budgeter.formattedAvailableRAM()
        let formattedTotal = await budgeter.formattedTotalRAM()
        XCTAssertFalse(formattedAvailable.isEmpty)
        XCTAssertFalse(formattedTotal.isEmpty)
    }
}
