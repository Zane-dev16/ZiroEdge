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

    func testE4BPresetsAndShapesNeverOffloadToMetal() {
        // Measured twice on iPhone 16: full Metal offload of the 4.97 GB E4B base
        // is admitted by the RAM tier and then fails every decode with
        // `kIOGPUCommandBufferCallbackErrorOutOfMemory` (docs/memory-profiles.md).
        // Weights allocated in GPU memory are invisible to process-headroom
        // admission, so the only fail-closed shape is no offload at all.
        for model in [ModelRegistry.gemma4_e4b, ModelRegistry.gemma4_e4b_text] {
            XCTAssertEqual(model.config.gpuLayers, 0, "\(model.id) must not offload")
            XCTAssertEqual(
                MemoryProfileRegistry.profile(for: model.id, usesGPU: true)?.gpuLayers, 0,
                "\(model.id) must not serve a Metal shape to an 8 GB+ device"
            )
        }
    }

    func testE4BRegistersNoMetalShapeAtAll() {
        let e4bIDs: Set<String> = [
            ModelRegistry.gemma4_e4b.id,
            ModelRegistry.gemma4_e4b_text.id,
            ModelRegistry.gemma4E4BTextCalibration.id,
        ]
        let metal = MemoryProfileRegistry.all.filter { e4bIDs.contains($0.modelID) && $0.gpuLayers > 0 }
        XCTAssertTrue(metal.isEmpty, "Metal shapes were re-added for \(metal.map(\.id))")
    }

    func testCPUValidationUntouchedByMetalEntries() {
        let cpu = MemoryProfileRegistry.profile(for: ModelRegistry.gemma4_e2b.id, usesGPU: false)
        XCTAssertEqual(cpu?.id, "gemma4-e2b-vision-p1")
        XCTAssertEqual(cpu?.runtimeEligibility, .validated)
    }

    func testMetalEntriesExistButServeCPUUntilCalibrated() {
        // The Metal shape has no measurement, so it carries only an estimate —
        // loadable, but weaker evidence than the validated CPU shape:
        let metal = MemoryProfileRegistry.all.first { $0.id == "gemma4-e2b-vision-metal-p1" }
        XCTAssertEqual(metal?.evidenceStatus, .unvalidated)
        XCTAssertNil(metal?.measuredFullWorkloadPeakDeltaBytes)
        XCTAssertEqual(metal?.runtimeEligibility, .estimated)
        // …but lookup serves what can serve, so the validated CPU shape
        // admits (and the engine follows it) until Metal calibrates:
        let served = MemoryProfileRegistry.profile(for: ModelRegistry.gemma4_e2b.id, usesGPU: true)
        XCTAssertEqual(served?.id, "gemma4-e2b-vision-p1")
        XCTAssertEqual(served?.gpuLayers, 0)
        XCTAssertEqual(served?.runtimeEligibility, .validated)
    }
}
