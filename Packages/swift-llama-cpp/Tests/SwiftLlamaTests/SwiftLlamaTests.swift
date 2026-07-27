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
        #expect(config.batchSize == 512)
        #expect(config.microBatchSize == 128)
        #expect(config.threadCount == 2)
        #expect(config.useMmap == true)
        #expect(config.f16KV == true)
        #expect(config.gpuLayers == 0)
    }

    @Test("Explicit batch controls are retained")
    func explicitBatchControls() {
        let config = LlamaConfigSwift(
            modelPath: "/tmp/test.gguf",
            contextLength: 512,
            batchSize: 256,
            microBatchSize: 64
        )
        #expect(config.contextLength == 512)
        #expect(config.batchSize == 256)
        #expect(config.microBatchSize == 64)
    }

    @Test("Prompt batching preserves every token in bounded chunks")
    func promptBatchPlan() throws {
        #expect(try LlamaEngine.promptBatchRanges(tokenCount: 513, batchSize: 256) == [0..<256, 256..<512, 512..<513])
    }

    @Test("SamplingConfigSwift defaults")
    func samplingDefaults() async throws {
        let sampling = SamplingConfigSwift()
        #expect(sampling.temperature == 0.7)
        #expect(sampling.topP == 0.9)
        #expect(sampling.topK == 40)
    }
}
