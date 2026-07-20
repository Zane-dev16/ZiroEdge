// MemoryBudgeterTests.swift
// ZiroEdgeTests
//
// Tests for MemoryBudgeter: RAM checking, model fit, recommendations.

import XCTest
@testable import ZiroEdge

final class MemoryBudgeterTests: XCTestCase {

    var budgeter: MemoryBudgeter!

    override func setUp() async throws {
        budgeter = MemoryBudgeter()
    }

    func testAvailableRAMIsNonZero() async throws {
        let ram = await budgeter.availableRAM()
        XCTAssertGreaterThan(ram, 0, "availableRAM should return > 0 on a real device")
    }

    func testTotalDeviceRAMIsNonZero() async throws {
        let total = await budgeter.totalDeviceRAM()
        XCTAssertGreaterThan(total, 0, "totalDeviceRAM should return > 0")
    }

    func testAvailableRAMIsLessThanTotal() async throws {
        let available = await budgeter.availableRAM()
        let total = await budgeter.totalDeviceRAM()
        XCTAssertLessThanOrEqual(available, total, "Available should be <= total")
    }

    func testCanLoadSmallModelOnDevice() async throws {
        // On a real device with 6GB+ RAM, check the recommendation.
        // We can't guarantee enough FREE RAM (other apps may be using it),
        // so we just verify the budgeter returns a valid recommendation.
        let total = await budgeter.totalDeviceRAM()
        guard total > 6_000_000_000 else {
            throw XCTSkip("Device has less than 6GB RAM, skipping fit check")
        }

        let recommendation = await budgeter.recommendation(for: ModelRegistry.llama32ThreeB)
        // Should be one of the valid recommendations.
        switch recommendation {
        case .proceed, .unloadCurrentFirst, .insufficientRAM:
            break // All valid — depends on current free RAM.
        }
        // The key check: on a 6GB+ device, the budgeter should not
        // report insufficientRAM if there's enough free memory.
        let available = await budgeter.availableRAM()
        let modelSize = UInt64(ModelRegistry.llama32ThreeB.totalFileSizeBytes)
        if available > modelSize + 1_500_000_000 {
            // If there IS enough free RAM, canLoad should be true.
            let canLoad = await budgeter.canLoad(ModelRegistry.llama32ThreeB)
            XCTAssertTrue(canLoad, "Should be able to load when enough RAM is free")
        }
    }

    func testCannotLoadHugeModel() async throws {
        // Create a fake model that requires 999TB of RAM.
        let hugeModel = AIModel(
            id: "fake-huge",
            displayName: "Huge",
            description: "Fake",
            modelType: .text,
            baseURL: URL(string: "https://example.com/fake.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 999_000_000_000_000,
            mmprojFileSizeBytes: nil,
            baseSHA256: "",
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            minimumDeviceRAM: 999_000_000_000_000,
            license: LicenseInfo(
                name: "Test",
                url: URL(string: "https://example.com")!,
                copyright: "Test"
            )
        )

        let canLoad = await budgeter.canLoad(hugeModel)
        XCTAssertFalse(canLoad, "A 999TB model should not fit on any device")
    }

    func testRecommendationMatchesAvailableMemory() async throws {
        // The simulator's free memory changes as the suite runs. Assert the
        // recommendation against the budgeter's measured contract instead of
        // assuming a 6GB device has a fixed amount of free RAM.
        let tinyModel = AIModel(
            id: "recommendation-tiny",
            displayName: "Tiny",
            description: "Test",
            modelType: .text,
            baseURL: URL(string: "https://example.com/tiny.gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: 1,
            mmprojFileSizeBytes: nil,
            baseSHA256: String(repeating: "a", count: 64),
            mmprojSHA256: nil,
            quantization: "Q4",
            config: .llama32,
            minimumDeviceRAM: 0,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com")!, copyright: "Test")
        )
        let available = await budgeter.availableRAM()
        let recommendation = await budgeter.recommendation(for: tinyModel)
        let required = UInt64(tinyModel.baseFileSizeBytes) + 1_500_000_000

        switch recommendation {
        case .proceed:
            XCTAssertGreaterThanOrEqual(available, required)
        case .unloadCurrentFirst:
            XCTAssertGreaterThanOrEqual(available, UInt64(tinyModel.baseFileSizeBytes))
            XCTAssertLessThan(available, required)
        case .insufficientRAM:
            XCTAssertLessThan(available, UInt64(tinyModel.baseFileSizeBytes))
        }
    }

    func testFormattedRAMStrings() async throws {
        let available = await budgeter.formattedAvailableRAM()
        let total = await budgeter.formattedTotalRAM()

        XCTAssertFalse(available.isEmpty)
        XCTAssertFalse(total.isEmpty)
        // Should contain "MB" or "GB"
        XCTAssertTrue(available.contains("MB") || available.contains("GB"))
        XCTAssertTrue(total.contains("MB") || total.contains("GB"))
    }
}
