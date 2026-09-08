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

@Suite("P3 Sampler, Stop-Token, and Context-Window Helpers")
struct P3EngineHelperTests {
    @Test("Penalty params present by default, absent when disabled")
    func penaltyDefaults() {
        let def = SamplingConfigSwift()
        let params = LlamaEngine.penaltyChainParameters(for: def)
        #expect(params?.lastN == 64)
        #expect(params?.repeatPenalty == 1.1)
        #expect(params?.frequencyPenalty == 0.0)
        #expect(params?.presencePenalty == 0.0)
        #expect(LlamaEngine.penaltyChainParameters(for: SamplingConfigSwift.greedyLike) == nil)
    }

    @Test("Greedy path keeps penalties when configured")
    func penaltyGreedyKept() {
        let greedyPenalty = SamplingConfigSwift(
            temperature: 0, topP: 1, topK: 1, maxTokens: 64,
            repeatPenalty: 1.2, penaltyLastN: 32
        )
        #expect(LlamaEngine.penaltyChainParameters(for: greedyPenalty)?.lastN == 32)
        let freqOnly = SamplingConfigSwift(
            temperature: 0, topP: 1, topK: 1, maxTokens: 64,
            repeatPenalty: 1.0, penaltyLastN: 64, frequencyPenalty: 0.5
        )
        #expect(LlamaEngine.penaltyChainParameters(for: freqOnly)?.frequencyPenalty == 0.5)
        let zeroN = SamplingConfigSwift(repeatPenalty: 1.5, penaltyLastN: 0)
        #expect(LlamaEngine.penaltyChainParameters(for: zeroN) == nil)
    }

    @Test("Partial-stop prefix withholds flush, full text flushes")
    func stopPrefixGate() {
        let stops = ["<|eot_id|>", "<|end_of_text|>"]
        #expect(LlamaEngine.isPotentialStopPrefix("<|e", stopStrings: stops) == true)
        #expect(LlamaEngine.isPotentialStopPrefix("hello <|eot", stopStrings: stops) == true)
        #expect(LlamaEngine.isPotentialStopPrefix("hello world", stopStrings: stops) == false)
        #expect(LlamaEngine.isPotentialStopPrefix("", stopStrings: stops) == false)
        #expect(LlamaEngine.shouldFlushTail("<|e", stopStrings: stops) == false)
        #expect(LlamaEngine.shouldFlushTail("hello world", stopStrings: stops) == true)
        #expect(LlamaEngine.shouldFlushTail("", stopStrings: stops) == false)
    }

    @Test("Sliding-window truncation keeps prefix plus recent tail")
    func slidingWindow() {
        let tokens: [Int32] = (0..<100).map(Int32.init)
        let fit = LlamaEngine.truncatedPromptTokens(tokens, contextLength: 4096, maxTokens: 2048)
        #expect(fit.didTruncate == false)
        #expect(fit.tokens.count == 100)
        let over = LlamaEngine.truncatedPromptTokens(tokens, contextLength: 64, maxTokens: 16, keepPrefix: 8)
        #expect(over.didTruncate == true)
        #expect(over.tokens.count == 64 - 16 - 1)
        #expect(Array(over.tokens.prefix(8)) == (0..<8).map(Int32.init))
        #expect(Array(over.tokens.suffix(8)) == (92..<100).map(Int32.init))
    }
}

private extension SamplingConfigSwift {
    static var greedyLike: SamplingConfigSwift {
        SamplingConfigSwift(temperature: 0, topP: 1, topK: 1, maxTokens: 64, repeatPenalty: 1.0)
    }
}
