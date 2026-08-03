import Foundation
import os

enum InferenceDiagnosticStage: String, Codable, CaseIterable, Sendable {
    case modelLoad
    case baseLoad
    case projectorLoad
    case projectorInitialization
    case imageDecode
    case imagePreprocess
    case imageEmbedding
    case imageEvaluation
    case promptTokenization
    case promptPrefill
    case firstToken
    case firstTokenEOS
    case completion
    case error
    case cancellation
    case memory
}

enum InferenceDiagnosticState: String, Codable, Sendable {
    case start
    case end
    case event
    case failure
    case cancelled
}

/// Fixed-schema diagnostics intentionally have no free-form payload field. Prompts,
/// responses, images, token values, URLs, paths, and native error text cannot be encoded.
struct InferenceDiagnosticEvent: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let timestamp: Date
    let runID: String
    let modelID: String
    let requestID: String?
    let sequence: UInt64
    let stage: InferenceDiagnosticStage
    let state: InferenceDiagnosticState
    let elapsedMilliseconds: UInt64?
    let primaryCount: Int?
    let secondaryCount: Int?
    let processAvailableBytes: UInt64
    let physicalFootprintBytes: UInt64

#if DEBUG
    static func fixture(
        sequence: UInt64,
        stage: InferenceDiagnosticStage,
        state: InferenceDiagnosticState
    ) -> Self {
        Self(
            schemaVersion: 1,
            timestamp: Date(timeIntervalSince1970: 0),
            runID: "fixture-run",
            modelID: "gemma-4-e4b-q4",
            requestID: nil,
            sequence: sequence,
            stage: stage,
            state: state,
            elapsedMilliseconds: nil,
            primaryCount: nil,
            secondaryCount: nil,
            processAvailableBytes: 1_000_000_000,
            physicalFootprintBytes: 100_000_000
        )
    }
#endif
}

final class InferenceDiagnosticRecorder: @unchecked Sendable {
    static let shared = InferenceDiagnosticRecorder()
    static let fileName = "inference-diagnostic.jsonl"

    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let maximumRetainedEvents: Int
    private let enabledOverride: Bool?
    private var nextSequence: UInt64 = 1
    let runID: String
    let logURL: URL

    var isEnabled: Bool {
        if let enabledOverride { return enabledOverride }
#if DEBUG
        return CommandLine.arguments.contains("--vision-diagnostic")
            || MemoryDiagnosticRecorder.shared.isEnabled
#else
        return false
#endif
    }

    convenience init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.init(
            directory: documents,
            maximumRetainedEvents: 4_000,
            enabled: nil,
            runID: UUID().uuidString.lowercased()
        )
    }

    init(
        directory: URL,
        maximumRetainedEvents: Int,
        enabled: Bool?,
        runID: String
    ) {
        precondition(maximumRetainedEvents > 0)
        self.maximumRetainedEvents = maximumRetainedEvents
        self.enabledOverride = enabled
        self.runID = Self.safeIdentifier(runID)
        self.logURL = directory.appendingPathComponent(Self.fileName)
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if DEBUG
        if enabled == nil, CommandLine.arguments.contains("--vision-diagnostic-reset") {
            try? FileManager.default.removeItem(at: logURL)
        }
#endif
    }

    func record(
        modelID: String,
        requestID: String?,
        stage: InferenceDiagnosticStage,
        state: InferenceDiagnosticState,
        elapsedMilliseconds: UInt64? = nil,
        primaryCount: Int? = nil,
        secondaryCount: Int? = nil
    ) {
        guard isEnabled else { return }
        let memory = MemorySnapshotReader.capture(.periodic)
        lock.lock()
        defer { lock.unlock() }
        let event = InferenceDiagnosticEvent(
            schemaVersion: 1,
            timestamp: Date(),
            runID: runID,
            modelID: Self.safeIdentifier(modelID),
            requestID: requestID.map(Self.safeIdentifier),
            sequence: nextSequence,
            stage: stage,
            state: state,
            elapsedMilliseconds: elapsedMilliseconds,
            primaryCount: primaryCount,
            secondaryCount: secondaryCount,
            processAvailableBytes: memory.processAvailableBytes,
            physicalFootprintBytes: memory.physicalFootprintBytes
        )
        nextSequence &+= 1
        persistLocked(event)
    }

    func readEvents() throws -> [InferenceDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return try readEventsLocked()
    }

    private func persistLocked(_ event: InferenceDiagnosticEvent) {
        do {
            var events = (try? readEventsLocked()) ?? []
            events.append(event)
            if events.count > maximumRetainedEvents {
                events.removeFirst(events.count - maximumRetainedEvents)
            }
            var output = Data()
            for item in events {
                output.append(try encoder.encode(item))
                output.append(0x0A)
            }
            try output.write(to: logURL, options: .atomic)
        } catch {
            Logger(subsystem: "com.zanish-labs.ziroedge", category: "inference-diagnostics")
                .error("Failed to persist fixed-schema inference diagnostic event")
        }
    }

    private func readEventsLocked() throws -> [InferenceDiagnosticEvent] {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
        return try Data(contentsOf: logURL)
            .split(separator: 0x0A)
            .map { try decoder.decode(InferenceDiagnosticEvent.self, from: Data($0)) }
    }

    private static func safeIdentifier(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return String(value.unicodeScalars.filter(allowed.contains).prefix(80))
    }
}

enum InferenceDiagnosticValidator {
    private static let requiredVisionCheckpoints: [(InferenceDiagnosticStage, InferenceDiagnosticState)] = [
        (.baseLoad, .start), (.baseLoad, .end),
        (.projectorInitialization, .start), (.projectorInitialization, .end),
        (.imageDecode, .start), (.imageDecode, .end),
        (.imagePreprocess, .start), (.imagePreprocess, .end),
        (.promptTokenization, .start), (.promptTokenization, .end),
        (.imageEmbedding, .start), (.imageEmbedding, .end),
        (.imageEvaluation, .start), (.imageEvaluation, .end),
        (.promptPrefill, .start), (.promptPrefill, .end),
        (.firstToken, .event), (.completion, .end)
    ]

    static func firstOrderingViolation(in events: [InferenceDiagnosticEvent]) -> String? {
        for pair in zip(events, events.dropFirst()) where pair.1.sequence <= pair.0.sequence {
            return "non-monotonic-sequence"
        }
        var openStages: [InferenceDiagnosticStage: Int] = [:]
        for event in events {
            if event.state == .start { openStages[event.stage, default: 0] += 1 }
            if event.state == .end {
                guard openStages[event.stage, default: 0] > 0 else {
                    return "end-without-start-\(event.stage.rawValue)"
                }
                openStages[event.stage, default: 0] -= 1
            }
        }
        return nil
    }

    static func lastCompletedAndFirstMissing(in events: [InferenceDiagnosticEvent]) -> String {
        var last = "none"
        for checkpoint in requiredVisionCheckpoints {
            if events.contains(where: { $0.stage == checkpoint.0 && $0.state == checkpoint.1 }) {
                if checkpoint.1 != .start {
                    last = "\(checkpoint.0.rawValue).\(checkpoint.1.rawValue)"
                }
            } else {
                return "\(last) → \(checkpoint.0.rawValue).\(checkpoint.1.rawValue)"
            }
        }
        return "completed"
    }
}
