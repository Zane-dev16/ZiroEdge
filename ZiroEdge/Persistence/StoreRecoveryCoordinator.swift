import Foundation
import CoreData
import CryptoKit

struct StoreRecoveryManifestEntry: Sendable, Equatable, Codable {
    let fileName: String
    let byteCount: Int64
    let sha256: String
}

struct StoreRecoveryArtifact: Sendable, Equatable {
    let directory: URL
    let sourceStoreURL: URL
    let manifest: [StoreRecoveryManifestEntry]

    var copiedFiles: [URL] {
        manifest.map { directory.appendingPathComponent($0.fileName) }
    }
}

actor StoreRecoveryCoordinator {
    private let fileManager: FileManager
    private let faultInjector: any PersistenceFaultInjecting
    private let recoveryRoot: URL?

    init(
        fileManager: FileManager = .default,
        faultInjector: any PersistenceFaultInjecting = NoopPersistenceFaultInjector(),
        recoveryRoot: URL? = nil
    ) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
        self.recoveryRoot = recoveryRoot
    }

    func quarantine(storeURL: URL, failure: PersistenceFailure) -> Result<StoreRecoveryArtifact, PersistenceFailure> {
        let canonicalStoreURL = storeURL.standardizedFileURL
        let root = recoveryRoot ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recovery", isDirectory: true)
        let identifier = UUID().uuidString
        let temporary = root.appendingPathComponent(".incomplete-\(identifier)", isDirectory: true)
        let destination = root.appendingPathComponent(identifier, isDirectory: true)

        do {
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
            let candidates = [
                canonicalStoreURL,
                URL(fileURLWithPath: canonicalStoreURL.path + "-wal"),
                URL(fileURLWithPath: canonicalStoreURL.path + "-shm")
            ]
            let sources = candidates.filter { fileManager.fileExists(atPath: $0.path) }
            guard !sources.isEmpty else { throw NSError(domain: "ZiroEdge.Persistence", code: 404) }

            var manifest: [StoreRecoveryManifestEntry] = []
            for source in sources {
                if let injected = faultInjector.fault(for: .quarantine) { throw injected }
                let target = temporary.appendingPathComponent(source.lastPathComponent)
                try copyAndSynchronize(source: source, target: target)
                let sourceEntry = try manifestEntry(for: source)
                let targetEntry = try manifestEntry(for: target)
                guard sourceEntry.byteCount == targetEntry.byteCount,
                      sourceEntry.sha256 == targetEntry.sha256 else {
                    throw NSError(domain: "ZiroEdge.Persistence", code: 409)
                }
                manifest.append(sourceEntry)
            }

            let metadata = [
                "createdAt=\(ISO8601DateFormatter().string(from: Date()))",
                failure.sanitizedDiagnostic
            ].joined(separator: "\n")
            try Data(metadata.utf8).write(to: temporary.appendingPathComponent("diagnostics.txt"), options: .atomic)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(to: temporary.appendingPathComponent("manifest.json"), options: .atomic)
            try fileManager.moveItem(at: temporary, to: destination)
            return .success(StoreRecoveryArtifact(
                directory: destination,
                sourceStoreURL: canonicalStoreURL,
                manifest: manifest
            ))
        } catch {
            try? fileManager.removeItem(at: temporary)
            return .failure(.map(error, operation: .quarantine))
        }
    }

    /// Destruction is reachable only after a complete, verified artifact for this exact store is confirmed.
    func destroyStore(at storeURL: URL, after artifact: StoreRecoveryArtifact) -> Result<Void, PersistenceFailure> {
        let canonicalStoreURL = storeURL.standardizedFileURL
        guard artifact.sourceStoreURL == canonicalStoreURL,
              !artifact.manifest.isEmpty,
              fileManager.fileExists(atPath: artifact.directory.path) else {
            return .failure(PersistenceFailure(
                category: .quarantineFailed,
                operation: .quarantine,
                domain: "ZiroEdge.Persistence",
                code: 412
            ))
        }

        do {
            // Verify the quarantined artifact is intact.
            for expected in artifact.manifest {
                let actual = try manifestEntry(for: artifact.directory.appendingPathComponent(expected.fileName))
                guard actual == expected else { throw NSError(domain: "ZiroEdge.Persistence", code: 409) }
            }

            // Re-hash the current canonical source files against the artifact manifest.
            // Destruction is refused if any source file was added, removed, or changed
            // between quarantine and confirmation.
            let currentFiles = [
                canonicalStoreURL,
                URL(fileURLWithPath: canonicalStoreURL.path + "-wal"),
                URL(fileURLWithPath: canonicalStoreURL.path + "-shm")
            ].filter { fileManager.fileExists(atPath: $0.path) }

            guard currentFiles.count == artifact.manifest.count else {
                return .failure(PersistenceFailure(
                    category: .quarantineFailed,
                    operation: .destroyStore,
                    domain: "ZiroEdge.Persistence",
                    code: 412
                ))
            }

            for file in currentFiles {
                let entry = try manifestEntry(for: file)
                guard artifact.manifest.contains(where: { $0 == entry }) else {
                    return .failure(PersistenceFailure(
                        category: .quarantineFailed,
                        operation: .destroyStore,
                        domain: "ZiroEdge.Persistence",
                        code: 409
                    ))
                }
            }

            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
            try coordinator.destroyPersistentStore(at: canonicalStoreURL, type: .sqlite, options: nil)
            return .success(())
        } catch {
            return .failure(.map(error, operation: .destroyStore))
        }
    }

    private func copyAndSynchronize(source: URL, target: URL) throws {
        try fileManager.copyItem(at: source, to: target)
        let handle = try FileHandle(forWritingTo: target)
        try handle.synchronize()
        try handle.close()
    }

    private func manifestEntry(for url: URL) throws -> StoreRecoveryManifestEntry {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return StoreRecoveryManifestEntry(
            fileName: url.lastPathComponent,
            byteCount: byteCount,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }
}
