import XCTest
@testable import ZiroEdge

final class AutoMetalTierTests: XCTestCase {
    func testTierMappingByPhysicalRAM() {
        XCTAssertEqual(ModelConfiguration.autoGpuLayers(physicalMemoryBytes: 0), 0)
        XCTAssertEqual(ModelConfiguration.autoGpuLayers(physicalMemoryBytes: 6_000_000_000), 0)
        XCTAssertEqual(ModelConfiguration.autoGpuLayers(physicalMemoryBytes: 7_999_999_999), 0)
        XCTAssertEqual(
            ModelConfiguration.autoGpuLayers(physicalMemoryBytes: 8_000_000_000),
            ModelConfiguration.fullMetalOffloadLayers
        )
        XCTAssertEqual(
            ModelConfiguration.autoGpuLayers(physicalMemoryBytes: 16_000_000_000),
            ModelConfiguration.fullMetalOffloadLayers
        )
    }

    func testPresetsFollowAutoTier() {
        let expected = ModelConfiguration.autoGpuLayers()
        XCTAssertEqual(ModelConfiguration.llama32.gpuLayers, expected)
        XCTAssertEqual(ModelConfiguration.gemma4.gpuLayers, expected)
        XCTAssertEqual(
            ModelConfiguration.imported(promptPath: .raw, contextLength: 1024).gpuLayers,
            expected
        )
    }

    func testCalibrationPresetStaysCPU() {
        XCTAssertEqual(ModelConfiguration.gemma4E4BTextCalibration.gpuLayers, 0)
    }

    func testCPUValidationUntouchedByMetalEntries() {
        let cpu = MemoryProfileRegistry.profile(for: ModelRegistry.gemma4_e2b.id, usesGPU: false)
        XCTAssertEqual(cpu?.id, "gemma4-e2b-vision-p1")
        XCTAssertEqual(cpu?.runtimeEligibility, .validated)
    }

    func testMetalEntriesExistButServeCPUUntilCalibrated() {
        // The Metal shapes exist with zero evidence (fail-closed):
        let metal = MemoryProfileRegistry.all.first { $0.id == "gemma4-e2b-vision-metal-p1" }
        XCTAssertEqual(metal?.evidenceStatus, .unvalidated)
        XCTAssertEqual(metal?.runtimeEligibility, .unavailable)
        // …but lookup serves what can serve, so the validated CPU shape
        // admits (and the engine follows it) until Metal calibrates:
        let served = MemoryProfileRegistry.profile(for: ModelRegistry.gemma4_e2b.id, usesGPU: true)
        XCTAssertEqual(served?.id, "gemma4-e2b-vision-p1")
        XCTAssertEqual(served?.gpuLayers, 0)
        XCTAssertEqual(served?.runtimeEligibility, .validated)
    }
}
