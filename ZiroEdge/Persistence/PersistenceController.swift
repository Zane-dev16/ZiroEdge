// PersistenceController.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Core Data stack with actor-isolated background writer.
// All writes flow through the background writer to prevent conflicts.
// Main context is read-only for UI, auto-merges from writer.

// swiftlint:disable file_length

import Foundation
import CoreData
import os

typealias PersistenceMutationError = PersistenceFailure

enum PersistenceConfiguration: Sendable {
    case production
    case inMemory
    case store(URL)

    var storeURL: URL? {
        switch self {
        case .production: PersistenceController.productionStoreURL
        case .inMemory: nil
        case .store(let url): url.standardizedFileURL
        }
    }
}

struct ConversationPayload: Sendable, Identifiable {
    let id: UUID
    let title: String
    let modelID: String
    let updatedAt: Date?
    let createdAt: Date?
    let systemPrompt: String?
    let temperature: Double
    let topP: Double
    let topK: Int32
    let messageCount: Int
    let isBranch: Bool
    let parentBranchID: UUID?
    let branchPointMessageID: UUID?
}

// MARK: - Persistence Controller

/// Manages the Core Data stack. All write operations go through the
/// actor-isolated background writer context. The main context is
/// read-only for SwiftUI bindings.
actor PersistenceController {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "persistence")

    /// The persistent container. It is exposed only after every store description has loaded.
    let container: NSPersistentContainer
    private let faultInjector: any PersistenceFaultInjecting
    private let recoveryJournalURL: URL?

    private struct RecoveryJournal: Codable, Sendable {
        enum TerminalState: String, Codable, Sendable { case streaming, completed, cancelled }
        let messageID: UUID
        let conversationID: UUID
        let createdAt: Date
        let targetContent: String
        let terminalState: TerminalState
    }

    private var recoveryJournal: RecoveryJournal?

    /// Background writer context — actor-isolated. All writes go here.
    private lazy var writerContext: NSManagedObjectContext = {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.automaticallyMergesChangesFromParent = true
        context.name = "writer"
        return context
    }()

    /// Token buffer for streaming — batched flush every N tokens or N ms.
    private var tokenBuffer: [UUID: String] = [:]     // messageID → accumulated tokens
    private var bufferFlushCount: [UUID: Int] = [:]   // messageID → tokens since last flush

    /// Flush thresholds.
    private let flushTokenCount = 20       // Flush every 20 tokens
    private let flushIntervalMs: UInt64 = 500  // Or every 500ms, whichever first
    private let maximumBufferedBytes = 1_048_576
    private var lastFlushTime: [UUID: UInt64] = [:]

    // MARK: - Initialization

    private init(configuration: PersistenceConfiguration, faultInjector: any PersistenceFaultInjecting) {
        let model: NSManagedObjectModel
        if let modelURL = Bundle.main.url(forResource: "ZiroEdge", withExtension: "momd")
            ?? Bundle.main.url(forResource: "ZiroEdge", withExtension: "mom"),
           let bundledModel = NSManagedObjectModel(contentsOf: modelURL) {
            model = bundledModel
        } else {
            model = Self.createManagedModel()
        }
        container = NSPersistentContainer(name: "ZiroEdge", managedObjectModel: model)
        self.faultInjector = faultInjector
        if let storeURL = configuration.storeURL {
            self.recoveryJournalURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent(".\(storeURL.lastPathComponent).stream-recovery.json")
        } else {
            self.recoveryJournalURL = nil
        }

        switch configuration {
        case .production:
            break
        case .inMemory:
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        case .store(let url):
            let description = NSPersistentStoreDescription(url: url)
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            container.persistentStoreDescriptions = [description]
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.name = "view"
        container.viewContext.shouldDeleteInaccessibleFaults = true
    }

    /// Opens every configured store before returning a usable controller.
    static func open(
        configuration: PersistenceConfiguration = .production,
        faultInjector: any PersistenceFaultInjecting = NoopPersistenceFaultInjector()
    ) async -> Result<PersistenceController, PersistenceFailure> {
        let controller = PersistenceController(configuration: configuration, faultInjector: faultInjector)
        if let injected = faultInjector.fault(for: .loadStore) {
            return .failure(.map(injected, operation: .loadStore))
        }

        let loadResult: Result<PersistenceController, PersistenceFailure> = await withCheckedContinuation { continuation in
            let lock = NSLock()
            var remaining = controller.container.persistentStoreDescriptions.count
            var firstFailure: PersistenceFailure?
            controller.container.loadPersistentStores { _, error in
                lock.lock()
                if let error, firstFailure == nil { firstFailure = .map(error, operation: .loadStore) }
                remaining -= 1
                let isFinished = remaining == 0
                let failure = firstFailure
                lock.unlock()
                guard isFinished else { return }
                continuation.resume(returning: failure.map(Result.failure) ?? .success(controller))
            }
        }
        if case .success = loadResult {
            switch await controller.restoreRecoveryJournal() {
            case .success:
                break
            case .failure(let failure):
                return .failure(failure)
            }
        }
        return loadResult
    }

    /// In-memory compatibility initializer for previews and legacy tests only.
    /// It never falls back to a disk store and never terminates the process.
    init(inMemory: Bool) {
        precondition(inMemory, "Use await PersistenceController.open() for disk-backed stores")
        let controller = PersistenceController(configuration: .inMemory, faultInjector: NoopPersistenceFaultInjector())
        self.container = controller.container
        self.faultInjector = controller.faultInjector
        self.recoveryJournalURL = nil
        let semaphore = DispatchSemaphore(value: 0)
        container.loadPersistentStores { _, _ in semaphore.signal() }
        semaphore.wait()
    }

    static var productionStoreURL: URL {
        NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("ZiroEdge.sqlite")
    }

    /// Closes loaded stores for deterministic recovery tests and orderly teardown.
    func closePersistentStores() -> Result<Void, PersistenceFailure> {
        do {
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
            return .success(())
        } catch {
            return .failure(.map(error, operation: .loadStore))
        }
    }

    // MARK: - Main Context (Read-Only for UI)

    /// The view context for SwiftUI. Read-only — do NOT write here.
    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    // MARK: - Conversation CRUD

    func createConversation(
        id: UUID = UUID(),
        title: String = "New Conversation",
        modelID: String,
        systemPrompt: String? = nil
    ) throws -> UUID {
        try createConversationResult(id: id, title: title, modelID: modelID, systemPrompt: systemPrompt).get()
    }

    func createConversationResult(
        id: UUID = UUID(),
        title: String = "New Conversation",
        modelID: String,
        systemPrompt: String? = nil
    ) -> Result<UUID, PersistenceMutationError> {
        let context = writerContext
        let injector = faultInjector
        let result: Result<UUID, PersistenceFailure> = context.performAndWait {
            CDConversation.create(in: context, id: id, title: title, modelID: modelID, systemPrompt: systemPrompt)
            switch Self.saveContext(context, faultInjector: injector) {
            case .success: return .success(id)
            case .failure(let failure): context.rollback(); return .failure(failure)
            }
        }
        logFailure(result, operation: "createConversation")
        return result
    }

    @discardableResult
    func deleteConversation(id: UUID) -> Result<Void, PersistenceFailure> {
        mutateConversation(id: id, operation: "deleteConversation") { context, conversation in
            context.delete(conversation)
        }
    }

    @discardableResult
    func updateConversationTitle(id: UUID, title: String) -> Result<Void, PersistenceFailure> {
        mutateConversation(id: id, operation: "updateConversationTitle") { _, conversation in
            conversation.title = title
            conversation.updatedAt = Date()
        }
    }

    @discardableResult
    func updateConversationTitleIfStill(
        id: UUID,
        newTitle: String,
        expectedCurrentTitle: String
    ) -> Result<Void, PersistenceFailure> {
        mutateConversation(id: id, operation: "updateConversationTitleIfStill") { _, conversation in
            guard conversation.title == expectedCurrentTitle else { return }
            conversation.title = newTitle
            conversation.updatedAt = Date()
        }
    }

    @discardableResult
    func updateConversationSampling(
        id: UUID,
        temperature: Double,
        topP: Double,
        topK: Int32
    ) -> Result<Void, PersistenceFailure> {
        mutateConversation(id: id, operation: "updateConversationSampling") { _, conversation in
            conversation.temperature = temperature
            conversation.topP = topP
            conversation.topK = topK
            conversation.updatedAt = Date()
        }
    }

    @discardableResult
    func updateConversationSystemPrompt(
        id: UUID,
        systemPrompt: String?
    ) -> Result<Void, PersistenceFailure> {
        mutateConversation(id: id, operation: "updateConversationSystemPrompt") { _, conversation in
            conversation.systemPrompt = systemPrompt
            conversation.updatedAt = Date()
        }
    }

    private func mutateConversation(
        id: UUID,
        operation: String,
        mutation: (NSManagedObjectContext, CDConversation) -> Void
    ) -> Result<Void, PersistenceFailure> {
        let context = writerContext
        let injector = faultInjector
        let result: Result<Void, PersistenceFailure> = context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            do {
                guard let conversation = try context.fetch(request).first else { return .failure(.notFound()) }
                mutation(context, conversation)
                switch Self.saveContext(context, faultInjector: injector) {
                case .success: return .success(())
                case .failure(let failure): context.rollback(); return .failure(failure)
                }
            } catch {
                context.rollback()
                return .failure(.map(error, operation: .fetch))
            }
        }
        logFailure(result, operation: operation)
        return result
    }

}

extension PersistenceController {
    // MARK: - Message CRUD

    @discardableResult
    func insertMessage(
        conversationID: UUID,
        role: MessageRole,
        content: String,
        imageData: Data? = nil,
        attachments: [Data]? = nil
    ) -> UUID? {
        try? insertMessageResult(
            conversationID: conversationID,
            role: role,
            content: content,
            imageData: imageData,
            attachments: attachments
        ).get()
    }

    func insertMessageResult(
        conversationID: UUID,
        role: MessageRole,
        content: String,
        imageData: Data? = nil,
        attachments: [Data]? = nil
    ) -> Result<UUID, PersistenceMutationError> {
        let context = writerContext
        let injector = faultInjector
        let result: Result<UUID, PersistenceFailure> = context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            request.fetchLimit = 1
            do {
                guard let conversation = try context.fetch(request).first else { return .failure(.notFound()) }
                let message = CDChatMessage.create(
                    in: context,
                    conversation: conversation,
                    role: role,
                    content: content,
                    imageData: attachments.map(MessageAttachmentCodec.encode) ?? imageData,
                    sequenceIndex: Int32(conversation.messageCount)
                )
                guard let id = message.id else { context.rollback(); return .failure(.notFound(operation: .save)) }
                switch Self.saveContext(context, faultInjector: injector) {
                case .success: return .success(id)
                case .failure(let failure): context.rollback(); return .failure(failure)
                }
            } catch {
                context.rollback()
                return .failure(.map(error, operation: .fetch))
            }
        }
        logFailure(result, operation: "insertMessage")
        return result
    }

    // MARK: - Streaming Support

    func beginStreamingMessage(conversationID: UUID) -> UUID? {
        try? beginStreamingMessageResult(conversationID: conversationID).get()
    }

    func beginStreamingMessageResult(conversationID: UUID) -> Result<UUID, PersistenceFailure> {
        guard recoveryJournal == nil, tokenBuffer.isEmpty else { return .failure(.recoveryBufferFull) }
        let context = writerContext
        let injector = faultInjector
        let createdAt = Date()
        let result: Result<UUID, PersistenceFailure> = context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            request.fetchLimit = 1
            do {
                guard let conversation = try context.fetch(request).first else { return .failure(.notFound()) }
                let message = CDChatMessage.create(
                    in: context,
                    conversation: conversation,
                    role: .assistant,
                    content: "",
                    sequenceIndex: Int32(conversation.messageCount),
                    isStreaming: true
                )
                message.createdAt = createdAt
                guard let id = message.id else { context.rollback(); return .failure(.notFound(operation: .save)) }
                switch Self.saveContext(context, faultInjector: injector) {
                case .success: return .success(id)
                case .failure(let failure): context.rollback(); return .failure(failure)
                }
            } catch {
                context.rollback()
                return .failure(.map(error, operation: .fetch))
            }
        }
        guard case .success(let messageID) = result else {
            logFailure(result, operation: "beginStreamingMessage")
            return result
        }
        let journal = RecoveryJournal(
            messageID: messageID,
            conversationID: conversationID,
            createdAt: createdAt,
            targetContent: "",
            terminalState: .streaming
        )
        do {
            try persistRecoveryJournal(journal)
            recoveryJournal = journal
            tokenBuffer[messageID] = ""
            bufferFlushCount[messageID] = 0
            lastFlushTime[messageID] = currentTimeMs()
            return .success(messageID)
        } catch {
            // Compensate: the streaming row was saved but the journal is missing.
            // Terminalize the row so the next stream can begin without a false recovery-buffer-full.
            compensateStreamingBegin(messageID: messageID)
            return .failure(.map(error, operation: .journalWrite))
        }
    }

    /// Marks a freshly-created streaming row as interrupted when the recovery journal
    /// could not be persisted. This prevents a durable streaming row with no
    /// RecoveryHandle from blocking future streams.
    private func compensateStreamingBegin(messageID: UUID) {
        let context = writerContext
        let injector = faultInjector
        context.performAndWait {
            let request = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1
            guard let message = try? context.fetch(request).first,
                  message.isStreaming else { return }
            message.isStreaming = false
            message.content = "_[Generation was interrupted]_"
            _ = Self.saveContext(context, faultInjector: injector)
        }
    }

    /// Atomically journals the canonical target before acknowledging generated bytes.
    @discardableResult
    func bufferTokens(messageID: UUID, tokens: String) -> Result<Void, PersistenceMutationError> {
        guard var journal = recoveryJournal, journal.messageID == messageID else { return .failure(.notFound()) }
        let target = journal.targetContent + tokens
        guard target.utf8.count <= maximumBufferedBytes else { return .failure(.recoveryBufferFull) }
        journal = RecoveryJournal(
            messageID: journal.messageID,
            conversationID: journal.conversationID,
            createdAt: journal.createdAt,
            targetContent: target,
            terminalState: .streaming
        )
        do {
            try persistRecoveryJournal(journal)
        } catch {
            return .failure(.map(error, operation: .save))
        }
        recoveryJournal = journal
        tokenBuffer[messageID] = target
        bufferFlushCount[messageID, default: 0] += 1
        let now = currentTimeMs()
        let elapsed = now - (lastFlushTime[messageID] ?? 0)
        if bufferFlushCount[messageID, default: 0] >= flushTokenCount || elapsed >= flushIntervalMs {
            return flushBuffer(messageID: messageID)
        }
        return .success(())
    }

    @discardableResult
    func endStreamingMessage(messageID: UUID) -> Result<Void, PersistenceMutationError> {
        finalizeStreamingMessage(messageID: messageID, terminalState: .completed)
    }

    @discardableResult
    func cancelStreamingMessage(messageID: UUID) -> Result<Void, PersistenceMutationError> {
        finalizeStreamingMessage(messageID: messageID, terminalState: .cancelled)
    }

    private func finalizeStreamingMessage(
        messageID: UUID,
        terminalState: RecoveryJournal.TerminalState
    ) -> Result<Void, PersistenceFailure> {
        guard var journal = recoveryJournal, journal.messageID == messageID else {
            return messageTerminalState(messageID: messageID)
        }
        var target = journal.targetContent
        if terminalState == .cancelled {
            let marker = "_[Generation cancelled]_"
            if !target.contains(marker) { target = target.isEmpty ? marker : target + "\n\n" + marker }
        }
        journal = RecoveryJournal(
            messageID: journal.messageID,
            conversationID: journal.conversationID,
            createdAt: journal.createdAt,
            targetContent: target,
            terminalState: terminalState
        )
        do { try persistRecoveryJournal(journal) } catch { return .failure(.map(error, operation: .save)) }
        recoveryJournal = journal
        tokenBuffer[messageID] = target
        return applyRecoveryJournal(journal)
    }

    private func messageTerminalState(messageID: UUID) -> Result<Void, PersistenceFailure> {
        let context = writerContext
        return context.performAndWait {
            let request = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1
            do {
                guard let message = try context.fetch(request).first else { return .failure(.notFound()) }
                return message.isStreaming ? .failure(.notFound(operation: .save)) : .success(())
            } catch { return .failure(.map(error, operation: .fetch)) }
        }
    }

    func recoveryHandle(messageID: UUID) -> RecoveryHandle? {
        guard let journal = recoveryJournal, journal.messageID == messageID else { return nil }
        return RecoveryHandle(
            id: journal.messageID,
            conversationID: journal.conversationID,
            messageID: journal.messageID,
            createdAt: journal.createdAt
        )
    }

    func retryStreamingSave(_ handle: RecoveryHandle) -> Result<Void, PersistenceFailure> {
        guard let journal = recoveryJournal, journal.messageID == handle.messageID else {
            return messageTerminalState(messageID: handle.messageID)
        }
        if journal.terminalState == .streaming {
            let finalized = RecoveryJournal(
                messageID: journal.messageID,
                conversationID: journal.conversationID,
                createdAt: journal.createdAt,
                targetContent: journal.targetContent,
                terminalState: .completed
            )
            do { try persistRecoveryJournal(finalized) } catch { return .failure(.map(error, operation: .save)) }
            recoveryJournal = finalized
            tokenBuffer[finalized.messageID] = finalized.targetContent
            return applyRecoveryJournal(finalized)
        }
        return applyRecoveryJournal(journal)
    }

    func exportPartialResponse(_ handle: RecoveryHandle) -> Result<Data, PersistenceFailure> {
        do {
            if let injected = faultInjector.fault(for: .export) { throw injected }
            guard let journal = recoveryJournal, journal.messageID == handle.messageID else {
                return .failure(.notFound(operation: .export))
            }
            let export = PartialResponseExport(
                recoveryID: handle.id,
                conversationID: handle.conversationID,
                messageID: handle.messageID,
                createdAt: handle.createdAt,
                role: MessageRole.assistant.rawValue,
                content: journal.targetContent,
                terminalState: journal.terminalState.rawValue,
                attachments: []
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return .success(try encoder.encode(export))
        } catch {
            return .failure(.map(error, operation: .export))
        }
    }

    func discardRecovery(_ handle: RecoveryHandle) -> Result<Void, PersistenceFailure> {
        guard let journal = recoveryJournal, journal.messageID == handle.messageID else {
            return .failure(.notFound(operation: .save))
        }
        let discarded = RecoveryJournal(
            messageID: journal.messageID,
            conversationID: journal.conversationID,
            createdAt: journal.createdAt,
            targetContent: "_[Partial response discarded]_",
            terminalState: .cancelled
        )
        do { try persistRecoveryJournal(discarded) } catch { return .failure(.map(error, operation: .save)) }
        recoveryJournal = discarded
        tokenBuffer[handle.messageID] = discarded.targetContent
        return applyRecoveryJournal(discarded)
    }

    func streamingRecoverySnapshot(messageID: UUID) -> Data? {
        guard recoveryJournal?.messageID == messageID else { return nil }
        return recoveryJournal?.targetContent.data(using: .utf8)
    }

    func flushPendingWrites() -> [UUID: PersistenceFailure] {
        guard let messageID = recoveryJournal?.messageID else { return [:] }
        if case .failure(let failure) = flushBuffer(messageID: messageID) { return [messageID: failure] }
        return [:]
    }

    private func flushBuffer(messageID: UUID) -> Result<Void, PersistenceFailure> {
        guard let journal = recoveryJournal, journal.messageID == messageID else { return .success(()) }
        let context = writerContext
        let injector = faultInjector
        let result: Result<Void, PersistenceFailure> = context.performAndWait {
            let request = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1
            do {
                guard let message = try context.fetch(request).first else { return .failure(.notFound()) }
                message.content = journal.targetContent
                switch Self.saveContext(context, faultInjector: injector) {
                case .success: return .success(())
                case .failure(let failure): context.rollback(); return .failure(failure)
                }
            } catch {
                context.rollback()
                return .failure(.map(error, operation: .fetch))
            }
        }
        if case .success = result {
            bufferFlushCount[messageID] = 0
            lastFlushTime[messageID] = currentTimeMs()
        }
        logFailure(result, operation: "flushBuffer")
        return result
    }

    private func applyRecoveryJournal(_ journal: RecoveryJournal) -> Result<Void, PersistenceFailure> {
        let context = writerContext
        let injector = faultInjector
        let result: Result<Void, PersistenceFailure> = context.performAndWait {
            let request = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", journal.messageID as CVarArg)
            request.fetchLimit = 1
            do {
                guard let message = try context.fetch(request).first else { return .failure(.notFound()) }
                message.content = journal.targetContent
                message.isStreaming = journal.terminalState == .streaming
                switch Self.saveContext(context, faultInjector: injector) {
                case .success: return .success(())
                case .failure(let failure): context.rollback(); return .failure(failure)
                }
            } catch {
                context.rollback()
                return .failure(.map(error, operation: .fetch))
            }
        }
        if case .success = result, journal.terminalState != .streaming { clearRecoveryState(messageID: journal.messageID) }
        logFailure(result, operation: "applyRecoveryJournal")
        return result
    }

    @discardableResult
    func restoreRecoveryJournal() -> Result<Void, PersistenceFailure> {
        guard let url = recoveryJournalURL else { return .success(()) }
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(()) }

        // Read the journal file.
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 1_048_576 else {
                preserveCorruptJournal(at: url, reason: "oversized (\(size) bytes)")
                return .success(())
            }
            if let injected = faultInjector.fault(for: .journalRestore) { throw injected }
            data = try Data(contentsOf: url)
        } catch let error as PersistenceFailure {
            return .failure(error)
        } catch {
            return .failure(.map(error, operation: .journalRestore))
        }

        // Decode the journal.
        let journal: RecoveryJournal
        do {
            journal = try JSONDecoder().decode(RecoveryJournal.self, from: data)
        } catch {
            preserveCorruptJournal(at: url, reason: "malformed JSON")
            return .success(())
        }

        // Validate content size.
        guard journal.targetContent.utf8.count <= maximumBufferedBytes else {
            preserveCorruptJournal(at: url, reason: "target content exceeds maximum")
            return .success(())
        }

        recoveryJournal = journal
        tokenBuffer[journal.messageID] = journal.targetContent
        bufferFlushCount[journal.messageID] = 0
        lastFlushTime[journal.messageID] = currentTimeMs()
        return .success(())
    }

    /// Rename a corrupt recovery journal so it is preserved for diagnostics
    /// but does not block startup.
    private func preserveCorruptJournal(at url: URL, reason: String) {
        logger.warning("Preserving corrupt recovery journal (\(reason, privacy: .public))")
        let preserved = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: preserved)
    }

    private func persistRecoveryJournal(_ journal: RecoveryJournal) throws {
        guard let url = recoveryJournalURL else { return }
        if let injected = faultInjector.fault(for: .journalWrite) { throw injected }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: url, options: [.atomic])
    }

    private func clearRecoveryState(messageID: UUID) {
        tokenBuffer.removeValue(forKey: messageID)
        bufferFlushCount.removeValue(forKey: messageID)
        lastFlushTime.removeValue(forKey: messageID)
        recoveryJournal = nil
        if let recoveryJournalURL {
            if faultInjector.fault(for: .journalRemove) == nil {
                try? FileManager.default.removeItem(at: recoveryJournalURL)
            }
        }
    }
}


extension PersistenceController {
    // MARK: - Fetch Helpers

    /// Compatibility read for non-UI tests. User-visible code uses the typed result below.
    func fetchConversations() -> [ConversationPayload] {
        (try? fetchConversationsResult().get()) ?? []
    }

    func fetchConversationsResult() -> Result<[ConversationPayload], PersistenceFailure> {
        let context = viewContext
        var result: Result<[ConversationPayload], PersistenceFailure> = .success([])
        context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
            do {
                if let injected = faultInjector.fault(for: .fetch) { throw injected }
                let objects = try context.fetch(request)
                var payloads: [ConversationPayload] = []
                for conversation in objects {
                    guard let id = conversation.id, let title = conversation.title, let modelID = conversation.modelID else {
                        result = .failure(PersistenceFailure(category: .corruptData, operation: .fetch, domain: "ZiroEdge.Persistence", code: 422))
                        return
                    }
                    payloads.append(ConversationPayload(
                        id: id, title: title, modelID: modelID,
                        updatedAt: conversation.updatedAt, createdAt: conversation.createdAt,
                        systemPrompt: conversation.systemPrompt, temperature: conversation.temperature,
                        topP: conversation.topP, topK: conversation.topK,
                        messageCount: conversation.messageCount, isBranch: conversation.isBranch,
                        parentBranchID: conversation.parentBranchID,
                        branchPointMessageID: conversation.branchPointMessageID
                    ))
                }
                result = .success(payloads)
            } catch {
                result = .failure(.map(error, operation: .fetch))
            }
        }
        return result
    }

    /// Compatibility read for non-UI tests. User-visible code uses the typed result below.
    func fetchMessages(conversationID: UUID) -> [ChatMessagePayload] {
        (try? fetchMessagesResult(conversationID: conversationID).get()) ?? []
    }

    func fetchMessagesResult(conversationID: UUID) -> Result<[ChatMessagePayload], PersistenceFailure> {
        let context = viewContext
        var result: Result<[ChatMessagePayload], PersistenceFailure> = .success([])
        context.performAndWait {
            let request = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "conversation.id == %@", conversationID as CVarArg)
            request.sortDescriptors = [NSSortDescriptor(key: "sequenceIndex", ascending: true)]
            do {
                if let injected = faultInjector.fault(for: .fetch) { throw injected }
                let objects = try context.fetch(request)
                var payloads: [ChatMessagePayload] = []
                for message in objects {
                    guard let id = message.id, let role = message.validatedMessageRole else {
                        result = .failure(PersistenceFailure(category: .corruptData, operation: .fetch, domain: "ZiroEdge.Persistence", code: 422))
                        return
                    }
                    payloads.append(ChatMessagePayload(
                        id: id, role: role, content: message.content ?? "",
                        attachments: MessageAttachmentCodec.decode(message.imageData),
                        sequenceIndex: message.sequenceIndex, isStreaming: message.isStreaming,
                        createdAt: message.createdAt
                    ))
                }
                result = .success(payloads)
            } catch {
                result = .failure(.map(error, operation: .fetch))
            }
        }
        return result
    }

    /// Replays the durable journal idempotently, then marks any legacy incomplete rows interrupted.
    @discardableResult
    func recoverIncompleteStreams() -> Result<Void, PersistenceFailure> {
        if let journal = recoveryJournal {
            let replay: RecoveryJournal
            if journal.terminalState == .streaming {
                let marker = journal.targetContent.isEmpty
                    ? "_[Generation was interrupted]_"
                    : journal.targetContent + "\n\n_[Interrupted — app was closed]_"
                replay = RecoveryJournal(
                    messageID: journal.messageID,
                    conversationID: journal.conversationID,
                    createdAt: journal.createdAt,
                    targetContent: marker,
                    terminalState: .completed
                )
                do { try persistRecoveryJournal(replay) } catch { return .failure(.map(error, operation: .save)) }
                recoveryJournal = replay
                tokenBuffer[replay.messageID] = replay.targetContent
            } else {
                replay = journal
            }
            if case .failure(let failure) = applyRecoveryJournal(replay) { return .failure(failure) }
        }

        let context = writerContext
        let injector = faultInjector
        let result: Result<Void, PersistenceFailure> = context.performAndWait {
            let request = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "isStreaming == YES")
            do {
                let incomplete = try context.fetch(request)
                for message in incomplete {
                    message.isStreaming = false
                    let current = message.content ?? ""
                    message.content = current.isEmpty
                        ? "_[Generation was interrupted]_"
                        : current + "\n\n_[Interrupted — app was closed]_"
                }
                switch Self.saveContext(context, faultInjector: injector) {
                case .success: return .success(())
                case .failure(let failure): context.rollback(); return .failure(failure)
                }
            } catch {
                context.rollback()
                return .failure(.map(error, operation: .fetch))
            }
        }
        logFailure(result, operation: "recoverIncompleteStreams")
        return result
    }

    // MARK: - Stress Test Support

    /// Generate test data for the 5,000-message stress test.
    func generateStressTestData(conversationCount: Int = 10, messagesPerConversation: Int = 500) {
        let context = writerContext
        let injector = faultInjector
        context.performAndWait {
            for convIndex in 0..<conversationCount {
                let conversation = CDConversation.create(
                    in: context,
                    title: "Stress Test Conversation \(convIndex + 1)",
                    modelID: "llama3.2-3b-q4"
                )

                for msgIndex in 0..<messagesPerConversation {
                    let role: MessageRole = msgIndex % 2 == 0 ? .user : .assistant
                    let content = "Stress test message \(msgIndex + 1) in conversation \(convIndex + 1). " +
                                  String(repeating: "Lorem ipsum dolor sit amet. ", count: 5)
                    CDChatMessage.create(
                        in: context,
                        conversation: conversation,
                        role: role,
                        content: content,
                        sequenceIndex: Int32(msgIndex)
                    )
                }

                // Save every conversation to avoid massive context.
                _ = Self.saveContext(context, faultInjector: injector)
            }
        }
    }

    // MARK: - Branching

    func branchConversation(sourceID: UUID, fromMessageID: UUID, newTitle: String) -> UUID? {
        try? branchConversationResult(sourceID: sourceID, fromMessageID: fromMessageID, newTitle: newTitle).get()
    }

    func branchConversationResult(
        sourceID: UUID,
        fromMessageID: UUID,
        newTitle: String
    ) -> Result<UUID, PersistenceFailure> {
        let context = writerContext
        let injector = faultInjector
        let result: Result<UUID, PersistenceFailure> = context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", sourceID as CVarArg)
            request.fetchLimit = 1
            do {
                guard let source = try context.fetch(request).first,
                      let branchIndex = source.sortedMessages.firstIndex(where: { $0.id == fromMessageID }) else {
                    return .failure(.notFound())
                }
                let conversation = CDConversation.create(
                    in: context,
                    title: newTitle,
                    modelID: source.modelID ?? "llama3.2-3b-q4",
                    systemPrompt: source.systemPrompt
                )
                conversation.parentBranchID = sourceID
                conversation.branchPointMessageID = fromMessageID
                conversation.temperature = source.temperature
                conversation.topP = source.topP
                conversation.topK = source.topK
                guard let id = conversation.id else { context.rollback(); return .failure(.notFound(operation: .save)) }
                for (index, message) in source.sortedMessages[...branchIndex].enumerated() {
                    CDChatMessage.create(
                        in: context,
                        conversation: conversation,
                        role: message.messageRole,
                        content: message.content ?? "",
                        imageData: message.imageData,
                        sequenceIndex: Int32(index)
                    )
                }
                switch Self.saveContext(context, faultInjector: injector) {
                case .success: return .success(id)
                case .failure(let failure): context.rollback(); return .failure(failure)
                }
            } catch {
                context.rollback()
                return .failure(.map(error, operation: .fetch))
            }
        }
        logFailure(result, operation: "branchConversation")
        return result
    }

    // MARK: - Programmatic Model Creation

    /// Creates the Core Data model programmatically.
    /// Used when the .xcdatamodeld isn't available (e.g. test targets).
    private static func createManagedModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let conversationEntity = createConversationEntity()
        let messageEntity = createMessageEntity()
        configureRelationships(
            conversationEntity: conversationEntity,
            messageEntity: messageEntity
        )
        model.entities = [conversationEntity, messageEntity]
        return model
    }

    private static func createConversationEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CDConversation"
        entity.managedObjectClassName = "CDConversation"
        entity.properties = [
            attribute("id", type: .UUIDAttributeType, isOptional: true),
            attribute(
                "title",
                type: .stringAttributeType,
                isOptional: true,
                defaultValue: "New Conversation"
            ),
            attribute("systemPrompt", type: .stringAttributeType, isOptional: true),
            attribute("modelID", type: .stringAttributeType, isOptional: true),
            attribute("temperature", type: .doubleAttributeType, defaultValue: 0.7),
            attribute("topP", type: .doubleAttributeType, defaultValue: 0.9),
            attribute("topK", type: .integer32AttributeType, defaultValue: 40),
            attribute("createdAt", type: .dateAttributeType, isOptional: true),
            attribute("updatedAt", type: .dateAttributeType, isOptional: true),
            attribute("parentBranchID", type: .UUIDAttributeType, isOptional: true),
            attribute("branchPointMessageID", type: .UUIDAttributeType, isOptional: true)
        ]
        return entity
    }

    private static func createMessageEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CDChatMessage"
        entity.managedObjectClassName = "CDChatMessage"
        entity.properties = [
            attribute("id", type: .UUIDAttributeType, isOptional: true),
            attribute("role", type: .stringAttributeType, isOptional: true),
            attribute("content", type: .stringAttributeType, isOptional: true, defaultValue: ""),
            attribute("imageData", type: .binaryDataAttributeType, isOptional: true),
            attribute("sequenceIndex", type: .integer32AttributeType, defaultValue: 0),
            attribute("isStreaming", type: .booleanAttributeType, defaultValue: false),
            attribute("createdAt", type: .dateAttributeType, isOptional: true)
        ]
        return entity
    }

    private static func attribute(
        _ name: String,
        type: NSAttributeType,
        isOptional: Bool = false,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = isOptional
        attribute.defaultValue = defaultValue
        return attribute
    }

    private static func configureRelationships(
        conversationEntity: NSEntityDescription,
        messageEntity: NSEntityDescription
    ) {
        let messagesRelationship = NSRelationshipDescription()
        messagesRelationship.name = "messages"
        messagesRelationship.destinationEntity = messageEntity
        messagesRelationship.isOptional = true
        messagesRelationship.maxCount = 0
        messagesRelationship.deleteRule = .cascadeDeleteRule

        let conversationRelationship = NSRelationshipDescription()
        conversationRelationship.name = "conversation"
        conversationRelationship.destinationEntity = conversationEntity
        conversationRelationship.isOptional = true
        conversationRelationship.maxCount = 1
        conversationRelationship.deleteRule = .nullifyDeleteRule

        messagesRelationship.inverseRelationship = conversationRelationship
        conversationRelationship.inverseRelationship = messagesRelationship
        conversationEntity.properties.append(messagesRelationship)
        messageEntity.properties.append(conversationRelationship)
    }

    // MARK: - Helpers

    private nonisolated static func saveContext(
        _ context: NSManagedObjectContext,
        faultInjector: any PersistenceFaultInjecting
    ) -> Result<Void, PersistenceFailure> {
        guard context.hasChanges else { return .success(()) }
        do {
            if let injected = faultInjector.fault(for: .save) { throw injected }
            try context.save()
            return .success(())
        } catch {
            return .failure(.map(error, operation: .save))
        }
    }

    private func logFailure<T>(_ result: Result<T, PersistenceFailure>, operation: String) {
        guard case .failure(let failure) = result else { return }
        logger.error("Core Data operation failed (\(operation, privacy: .public)): \(failure.sanitizedDiagnostic, privacy: .public)")
    }

    private func currentTimeMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}
