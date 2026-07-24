import Foundation

protocol PersistenceFaultInjecting: Sendable {
    /// Fault checks are synchronous because Core Data mutation blocks use performAndWait.
    func fault(for operation: PersistenceOperation) -> Error?
}

struct NoopPersistenceFaultInjector: PersistenceFaultInjecting {
    func fault(for operation: PersistenceOperation) -> Error? { nil }
}

/// Ordered, lock-protected test seam. Each matching operation consumes exactly one scripted entry.
final class ScriptedPersistenceFaultInjector: PersistenceFaultInjecting, @unchecked Sendable {
    struct Step: @unchecked Sendable {
        let operation: PersistenceOperation
        let error: Error?

        static func fail(_ operation: PersistenceOperation, error: Error) -> Step {
            Step(operation: operation, error: error)
        }

        static func succeed(_ operation: PersistenceOperation) -> Step {
            Step(operation: operation, error: nil)
        }
    }

    private let lock = NSLock()
    private var steps: [Step]

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func fault(for operation: PersistenceOperation) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = steps.first, first.operation == operation else { return nil }
        steps.removeFirst()
        return first.error
    }

    var remainingStepCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return steps.count
    }
}
