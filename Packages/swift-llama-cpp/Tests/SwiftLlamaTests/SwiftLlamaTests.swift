// SwiftLlamaTests.swift
// SwiftLlama — placeholder test file

import Testing
@testable import SwiftLlama

@Suite("LlamaEngine Tests")
struct LlamaEngineTests {
    @Test("LlamaConfigSwift defaults")
    func configDefaults() async throws {
        let config = LlamaConfigSwift(modelPath: "/tmp/test.gguf")
        #expect(config.contextLength == 4096)
        #expect(config.threadCount == 2)
        #expect(config.useMmap == true)
        #expect(config.f16KV == true)
        #expect(config.gpuLayers == 0)
    }

    @Test("SamplingConfigSwift defaults")
    func samplingDefaults() async throws {
        let sampling = SamplingConfigSwift()
        #expect(sampling.temperature == 0.7)
        #expect(sampling.topP == 0.9)
        #expect(sampling.topK == 40)
    }
}
