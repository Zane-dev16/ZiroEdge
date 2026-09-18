// FoundationModelsProvider.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Apple Intelligence engine behind `InferenceServiceProtocol`.
// Thin slice: text chat only. Vision throws `.visionNotSupported`
// (mmproj path stays authoritative). No downloads, no memory budget,
// no load-safety markers — the OS pages the ~3B model itself.
//
// File compiles on the iOS 18 baseline: FM calls live behind
// `canImport(FoundationModels)` + `#available(iOS 26, *)`.

import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Chat-only Apple Intelligence provider. One session per request —
/// `ChatSessionActor` already serializes generations via the protocol.
actor FoundationModelsProvider: InferenceServiceProtocol {
    static let providerModelID = AppleIntelligenceMarker.modelID

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "apple-intelligence")
    private var currentTask: Task<Void, Never>?
    private var loaded = false

    // MARK: - Lifecycle (no-ops with an availability gate)

    func loadModel(_ model: AIModel, baseURL: URL, mmprojURL: URL?) async throws {
        // Called via the router with the FM marker model. The artifact URLs
        // are meaningless for FM — only availability matters.
        let status = AppleIntelligenceAvailability.status()
        guard status.isReady else {
            throw InferenceError.modelNotLoaded
        }
        loaded = true
        logger.info("Apple Intelligence ready")
    }

    /// Direct readiness mark for callers that have no AIModel to pass.
    func markReady() async throws {
        let status = AppleIntelligenceAvailability.status()
        guard status.isReady else {
            throw InferenceError.modelNotLoaded
        }
        loaded = true
    }

    func unloadModel() async {
        loaded = false
        currentTask?.cancel()
        currentTask = nil
    }

    var isModelLoaded: Bool {
        loaded && AppleIntelligenceAvailability.isReady
    }

    var loadedModelID: String? {
        isModelLoaded ? Self.providerModelID : nil
    }

    // MARK: - Text chat

    func streamChat(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard AppleIntelligenceAvailability.isReady else {
            throw InferenceError.modelNotLoaded
        }
#if canImport(FoundationModels)
        if #available(iOS 26, *) {
            return try await foundationModelsStream(
                messages: messages, systemPrompt: systemPrompt, sampling: sampling
            )
        }
#endif
        throw InferenceError.modelNotLoaded
    }

    func streamVisionChat(
        messages: [ChatMessagePayload],
        images: [Data],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        // FM v1 is text-only. Vision stays on the GGUF/mmproj path.
        throw InferenceError.visionNotSupported
    }

    func cancelCurrentStream() async {
        currentTask?.cancel()
        currentTask = nil
    }

#if canImport(FoundationModels)
    // MARK: - FoundationModels bridge (iOS 26+ only)

    @available(iOS 26, *)
    private func foundationModelsStream(
        messages: [ChatMessagePayload],
        systemPrompt: String?,
        sampling: SamplingConfig
    ) async throws -> AsyncThrowingStream<String, Error> {
        // Instructions: the user's configured prompt passes through verbatim.
        // Blank/nil means NO instructions — the session runs under the model's
        // built-in persona. Never invent an identity here: the llama path
        // sends no system text at all in this case, and FM must match it.
        let session: LanguageModelSession
        if let prompt = systemPrompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session = LanguageModelSession(instructions: prompt)
        } else {
            session = LanguageModelSession()
        }
        let prompt = Self.formatTranscript(messages)
        // Map the shared sampling config. FM exposes no repeat/frequency/
        // presence penalties — temperature + topK/topP carry the load, and
        // the stop-scan below (no FM stop-list exists) cuts role-play loops.
        var options = GenerationOptions()
        if sampling.temperature <= 0.05 {
            options.sampling = .greedy
            options.temperature = 0.0
        } else {
            if sampling.topK > 1 {
                options.sampling = .random(top: sampling.topK, seed: nil)
            } else if sampling.topP < 1.0 {
                options.sampling = .random(probabilityThreshold: Double(sampling.topP), seed: nil)
            }
            options.temperature = Double(sampling.temperature)
        }
        options.maximumResponseTokens = sampling.maxTokens

        let task = Task<Void, Never> {}
        currentTask = task
        return AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let stream = session.streamResponse(to: prompt, options: options)
                    // Snapshots are CUMULATIVE partials, not deltas (WWDC25#286:
                    // "we stream snapshots"). Yield only the unseen suffix, or
                    // the UI appends the whole prefix per token (fake looping).
                    var emitted = ""
                    var held = ""
                    var stopped = false
                    for try await snapshot in stream {
                        if Task.isCancelled { break }
                        let full = String(snapshot.content)
                        // Reconcile against what the consumer already has.
                        let accounted = emitted + held
                        let fresh: String
                        if full.hasPrefix(accounted) {
                            fresh = String(full.dropFirst(accounted.count))
                        } else if full.hasPrefix(emitted) {
                            fresh = String(full.dropFirst(emitted.count))
                            held = ""
                        } else {
                            fresh = full
                            emitted = ""
                            held = ""
                        }
                        var window = held + fresh
                        held = ""
                        let atStart = emitted.isEmpty
                        // Full role header: cut it and end the stream. These
                        // headers only exist because formatTranscript flattens
                        // history as text; the model must never emit them.
                        if let cut = Self.stopIndex(in: window, atStart: atStart) {
                            let kept = String(window[..<cut])
                                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                            if !kept.isEmpty { continuation.yield(kept) }
                            stopped = true
                            break
                        }
                        // Trailing split header ("\n" / "\nUs" / …): hold it
                        // back one snapshot to disambiguate, else a cut header
                        // leaks half its marker into the chat.
                        let holdCount = Self.trailingPartialMarkerLength(in: window, atStart: atStart)
                        if holdCount > 0, holdCount < window.count {
                            let split = window.index(window.endIndex, offsetBy: -holdCount)
                            held = String(window[split...])
                            window = String(window[..<split])
                        }
                        if !window.isEmpty {
                            continuation.yield(window)
                            emitted += window
                        }
                    }
                    // Natural end with a held tail means it was normal text.
                    if !stopped, !Task.isCancelled, !held.isEmpty {
                        continuation.yield(held)
                    }
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    if case .guardrailViolation = error {
                        continuation.finish(throwing: InferenceError.nativeFailure(
                            kind: .inference, diagnostic: "apple-intelligence-refusal"
                        ))
                    } else {
                        continuation.finish(throwing: InferenceError.nativeFailure(
                            kind: .inference, diagnostic: "apple-intelligence-generation-failed"
                        ))
                    }
                } catch {
                    if error is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: InferenceError.nativeFailure(
                            kind: .inference, diagnostic: "apple-intelligence-generation-failed"
                        ))
                    }
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
#endif

    // MARK: - Prompt formatting

    /// FM sessions are stateful, but our protocol hands full history per
    /// call. Collapse to one transcript prompt; roles preserved as text.
    /// The bridge's stop-scan pairs with this exact format: anything the
    /// model emits that looks like one of these headers ends the stream.
    private static func formatTranscript(_ messages: [ChatMessagePayload]) -> String {
        messages.map { message in
            switch message.role {
            case .user: "User: \(message.content)"
            case .assistant: "Assistant: \(message.content)"
            case .system: "System: \(message.content)"
            }
        }.joined(separator: "\n")
    }

    /// Headers the model must never emit (see formatTranscript).
    private static let stopMarkers = ["\nUser:", "\nAssistant:", "\nSystem:"]
    /// Same headers anchored at response start ("Assistant: …" as first token).
    private static let leadingStopMarkers = ["User:", "Assistant:", "System:"]

    /// First index where emitted text must be cut, if any.
    static func stopIndex(in text: String, atStart: Bool) -> String.Index? {
        var best: String.Index?
        for marker in stopMarkers {
            if let range = text.range(of: marker),
               best == nil || range.lowerBound < best! {
                best = range.lowerBound
            }
        }
        if atStart {
            for marker in leadingStopMarkers where text.hasPrefix(marker) {
                return text.startIndex
            }
        }
        return best
    }

    /// Length of a trailing split-header tail ("\n", "\nUs", …) to hold
    /// back one snapshot. 0 means the tail is clean to emit.
    static func trailingPartialMarkerLength(in text: String, atStart: Bool) -> Int {
        var markers = stopMarkers
        if atStart { markers += leadingStopMarkers }
        var longest = 0
        for marker in markers {
            let maxK = min(marker.count - 1, text.count)
            guard maxK >= 1 else { continue }
            for length in 1...maxK {
                if text.hasSuffix(String(marker.prefix(length))) {
                    longest = max(longest, length)
                }
            }
        }
        return longest
    }
}
