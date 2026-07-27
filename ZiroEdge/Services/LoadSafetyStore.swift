import Foundation

enum LoadSafetyError: Error, Equatable {
    case profileDisabled
    case persistenceFailed
    case corruptState
    case markerMismatch
}

private struct PendingLoadMarker: Codable, Equatable {
    let attemptID: UUID
    let profileID: String
    let startedAt: Date
}

private struct LoadAttemptOutcome: Codable, Equatable {
    let attemptID: UUID
    let unclean: Bool
}

private struct LoadSafetyState: Codable, Equatable {
    var pending: PendingLoadMarker?
    var outcomesByProfile: [String: [LoadAttemptOutcome]] = [:]
}

protocol LoadSafetyFileSystem: Sendable {
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func read(at url: URL) throws -> Data
    func writeAtomically(_ data: Data, to url: URL) throws
}

struct ProductionLoadSafetyFileSystem: LoadSafetyFileSystem {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func read(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

/// Atomic crash marker and exact five-attempt circuit breaker for native construction.
/// The pending marker and history are committed as one state document so a failed
/// cleanup can never be mistaken for a later jetsam event.
final class LoadSafetyStore: @unchecked Sendable {
    private let lock = NSLock()
    private let stateURL: URL
    private let fileSystem: any LoadSafetyFileSystem
    private var state: LoadSafetyState
    private(set) var lastLaunchClassification: NativeFailureKind?
    private(set) var lastInterruptedProfileID: String?

    init(
        directory: URL? = nil,
        fileSystem: any LoadSafetyFileSystem = ProductionLoadSafetyFileSystem()
    ) throws {
        let root = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ZiroEdge/LoadSafety", isDirectory: true)
        self.fileSystem = fileSystem
        stateURL = root.appendingPathComponent("load-safety-state.json")
        try fileSystem.createDirectory(at: root)

        if fileSystem.fileExists(at: stateURL) {
            do {
                state = try JSONDecoder().decode(LoadSafetyState.self, from: fileSystem.read(at: stateURL))
            } catch {
                throw LoadSafetyError.corruptState
            }
        } else {
            state = LoadSafetyState()
        }
        lastLaunchClassification = nil
        lastInterruptedProfileID = nil

        if let marker = state.pending {
            var recovered = state
            Self.record(
                LoadAttemptOutcome(attemptID: marker.attemptID, unclean: true),
                profileID: marker.profileID,
                in: &recovered
            )
            recovered.pending = nil
            do {
                try Self.persist(recovered, to: stateURL, fileSystem: fileSystem)
            } catch {
                throw LoadSafetyError.persistenceFailed
            }
            state = recovered
            lastLaunchClassification = .suspectedJetsam
            lastInterruptedProfileID = marker.profileID
        }
    }

    func beginLoad(profileID: String) throws {
        try withLockedMutation { next in
            guard !Self.isDisabled(profileID: profileID, state: next) else {
                throw LoadSafetyError.profileDisabled
            }
            guard next.pending == nil else { throw LoadSafetyError.persistenceFailed }
            next.pending = PendingLoadMarker(
                attemptID: UUID(),
                profileID: profileID,
                startedAt: Date()
            )
        }
    }

    /// Commit construction completion. A returned native failure is clean for
    /// crash-classification purposes and still occupies one sliding-window slot.
    func clearAfterNativeConstruction(profileID: String) throws {
        try withLockedMutation { next in
            guard let marker = next.pending, marker.profileID == profileID else {
                throw LoadSafetyError.markerMismatch
            }
            Self.record(
                LoadAttemptOutcome(attemptID: marker.attemptID, unclean: false),
                profileID: profileID,
                in: &next
            )
            next.pending = nil
        }
    }

    func clearAfterCleanUnload(profileID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state.pending != nil else { return }
        try mutateAndPersist { next in
            guard let marker = next.pending, marker.profileID == profileID else {
                throw LoadSafetyError.markerMismatch
            }
            Self.record(
                LoadAttemptOutcome(attemptID: marker.attemptID, unclean: false),
                profileID: profileID,
                in: &next
            )
            next.pending = nil
        }
    }

    func isDisabled(profileID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.isDisabled(profileID: profileID, state: state)
    }

    func recentUncleanAttemptCount(profileID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return state.outcomesByProfile[profileID, default: []].suffix(5).filter(\.unclean).count
    }

    func reset(profileID: String) throws {
        try withLockedMutation { next in
            next.outcomesByProfile[profileID] = []
            if next.pending?.profileID == profileID { next.pending = nil }
        }
    }

    private func withLockedMutation(_ body: (inout LoadSafetyState) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try mutateAndPersist(body)
    }

    private func mutateAndPersist(_ body: (inout LoadSafetyState) throws -> Void) throws {
        var next = state
        try body(&next)
        do {
            try Self.persist(next, to: stateURL, fileSystem: fileSystem)
        } catch let error as LoadSafetyError {
            throw error
        } catch {
            throw LoadSafetyError.persistenceFailed
        }
        state = next
    }

    private static func record(
        _ outcome: LoadAttemptOutcome,
        profileID: String,
        in state: inout LoadSafetyState
    ) {
        var outcomes = state.outcomesByProfile[profileID, default: []]
        if let existing = outcomes.firstIndex(where: { $0.attemptID == outcome.attemptID }) {
            outcomes[existing] = outcome
        } else {
            outcomes.append(outcome)
        }
        state.outcomesByProfile[profileID] = Array(outcomes.suffix(5))
    }

    private static func isDisabled(profileID: String, state: LoadSafetyState) -> Bool {
        state.outcomesByProfile[profileID, default: []].suffix(5).filter(\.unclean).count >= 2
    }

    private static func persist(
        _ state: LoadSafetyState,
        to url: URL,
        fileSystem: any LoadSafetyFileSystem
    ) throws {
        try fileSystem.writeAtomically(JSONEncoder().encode(state), to: url)
    }
}
