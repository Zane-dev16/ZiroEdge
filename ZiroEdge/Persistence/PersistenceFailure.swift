import Foundation

enum PersistenceOperation: String, Sendable, Codable {
    case loadStore
    case fetch
    case save
    case export
    case quarantine
    case destroyStore
    case journalWrite
    case journalRemove
    case journalRestore
}

enum PersistenceFailureCategory: String, Sendable, Codable {
    case storeUnavailable
    case notFound
    case corruptData
    case insufficientStorage
    case saveFailed
    case fetchFailed
    case exportFailed
    case quarantineFailed
    case destructionFailed
    case recoveryBufferFull
    case journalCorrupt
}

/// A user-presentable persistence failure. Diagnostics intentionally contain no paths or user content.
struct PersistenceFailure: Error, LocalizedError, Sendable, Equatable, Codable {
    let category: PersistenceFailureCategory
    let operation: PersistenceOperation
    let domain: String
    let code: Int

    var errorDescription: String? {
        switch category {
        case .storeUnavailable: return "Local history could not be opened. Your data has not been changed."
        case .notFound: return "The requested local item no longer exists."
        case .corruptData: return "Local history contains data that cannot be read safely."
        case .insufficientStorage: return "There is not enough available storage to save this change."
        case .saveFailed: return "The change could not be saved. Your previous data is unchanged."
        case .fetchFailed: return "Local history is temporarily unavailable."
        case .exportFailed: return "Recovery data could not be exported."
        case .quarantineFailed: return "Local history could not be copied for recovery. Nothing was deleted."
        case .destructionFailed: return "The recovery copy is intact, but local history could not be reset."
        case .recoveryBufferFull: return "A response is already awaiting recovery. Retry, export, or discard it before continuing."
        case .journalCorrupt: return "Session recovery data is damaged. Your conversation history is safe."
        }
    }

    var sanitizedDiagnostic: String {
        "operation=\(operation.rawValue) category=\(category.rawValue) domain=\(domain) code=\(code)"
    }

    static func map(_ error: Error, operation: PersistenceOperation) -> PersistenceFailure {
        let nsError = error as NSError
        let category: PersistenceFailureCategory
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileWriteOutOfSpaceError, NSFileWriteVolumeReadOnlyError].contains(nsError.code) {
            category = .insufficientStorage
        } else {
            switch operation {
            case .loadStore: category = .storeUnavailable
            case .fetch: category = .fetchFailed
            case .save: category = .saveFailed
            case .export: category = .exportFailed
            case .quarantine: category = .quarantineFailed
            case .destroyStore: category = .destructionFailed
            case .journalWrite, .journalRemove, .journalRestore: category = .journalCorrupt
            }
        }
        return PersistenceFailure(category: category, operation: operation, domain: nsError.domain, code: nsError.code)
    }

    static func notFound(operation: PersistenceOperation = .fetch) -> PersistenceFailure {
        PersistenceFailure(category: .notFound, operation: operation, domain: "ZiroEdge.Persistence", code: 404)
    }

    static func objectNotFound(_ ignoredDescription: String) -> PersistenceFailure {
        _ = ignoredDescription // Never include record IDs in user-facing diagnostics.
        return .notFound()
    }

    static func saveFailed(operation ignoredDescription: String) -> PersistenceFailure {
        _ = ignoredDescription
        return PersistenceFailure(category: .saveFailed, operation: .save, domain: "ZiroEdge.Persistence", code: 1)
    }

    static let recoveryBufferFull = PersistenceFailure(
        category: .recoveryBufferFull,
        operation: .save,
        domain: "ZiroEdge.Persistence",
        code: 413
    )
}
