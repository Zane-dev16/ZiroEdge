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

struct ConversationPayload: Sendable, Identifiable {
    let id: UUID
    let title: String
    let modelID: String
    let updatedAt: Date?
    let createdAt: Date?
    let messageCount: Int
    let isBranch: Bool
}

// MARK: - Persistence Controller

/// Manages the Core Data stack. All write operations go through the
/// actor-isolated background writer context. The main context is
/// read-only for SwiftUI bindings.
actor PersistenceController {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.zanish-labs.ziroedge", category: "persistence")

    /// The persistent container.
    let container: NSPersistentContainer

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
    private var lastFlushTime: [UUID: UInt64] = [:]

    // MARK: - Initialization

    init(inMemory: Bool = false) {
        // Try to load from bundle first. If not found (e.g. in test targets),
        // create the model programmatically.
        if let modelURL = Bundle.main.url(forResource: "ZiroEdge", withExtension: "momd")
            ?? Bundle.main.url(forResource: "ZiroEdge", withExtension: "mom"),
           let model = NSManagedObjectModel(contentsOf: modelURL) {
            container = NSPersistentContainer(name: "ZiroEdge", managedObjectModel: model)
        } else {
            // Programmatic model creation for test targets.
            let model = Self.createManagedModel()
            container = NSPersistentContainer(name: "ZiroEdge", managedObjectModel: model)
        }

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        }

        container.loadPersistentStores { [logger] description, error in
            if let error {
                logger.error("Core Data failed to load: \(error.localizedDescription, privacy: .public)")
                fatalError("Core Data failed to load: \(error)")
            }
            logger.info("Core Data store loaded: \(description.url?.absoluteString ?? "in-memory", privacy: .public)")
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.name = "view"
        // View context is read-only — set it to refresh on save notifications.
        container.viewContext.shouldDeleteInaccessibleFaults = true
    }

    // MARK: - Main Context (Read-Only for UI)

    /// The view context for SwiftUI. Read-only — do NOT write here.
    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    // MARK: - Conversation CRUD

    /// Create a new conversation. Returns the conversation ID.
    func createConversation(
        id: UUID = UUID(),
        title: String = "New Conversation",
        modelID: String,
        systemPrompt: String? = nil
    ) -> UUID {
        let context = writerContext
        context.performAndWait {
            CDConversation.create(
                in: context,
                id: id,
                title: title,
                modelID: modelID,
                systemPrompt: systemPrompt
            )
            saveContext(context, operation: "createConversation")
        }
        return id
    }

    /// Delete a conversation and all its messages.
    func deleteConversation(id: UUID) {
        let context = writerContext
        context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1

            do {
                if let conversation = try context.fetch(request).first {
                    context.delete(conversation)
                    saveContext(context, operation: "deleteConversation")
                }
            } catch {
                logger.error("Failed to fetch conversation for deletion: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Update conversation title.
    func updateConversationTitle(id: UUID, title: String) {
        let context = writerContext
        context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1

            do {
                if let conversation = try context.fetch(request).first {
                    conversation.title = title
                    conversation.updatedAt = Date()
                    saveContext(context, operation: "updateConversationTitle")
                }
            } catch {
                logger.error("Failed to fetch conversation for title update: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Update a conversation title only when it still matches the expected value.
    func updateConversationTitleIfStill(
        id: UUID,
        newTitle: String,
        expectedCurrentTitle: String
    ) {
        let context = writerContext
        context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1

            do {
                guard let conversation = try context.fetch(request).first,
                      conversation.title == expectedCurrentTitle else {
                    return
                }
                conversation.title = newTitle
                conversation.updatedAt = Date()
                saveContext(context, operation: "updateConversationTitleIfStill")
            } catch {
                logger.error("Failed to fetch conversation for conditional title update: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Update conversation sampling config.
    func updateConversationSampling(id: UUID, temperature: Double, topP: Double, topK: Int32) {
        let context = writerContext
        context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1

            do {
                if let conversation = try context.fetch(request).first {
                    conversation.temperature = temperature
                    conversation.topP = topP
                    conversation.topK = topK
                    conversation.updatedAt = Date()
                    saveContext(context, operation: "updateConversationSampling")
                }
            } catch {
                logger.error("Failed to fetch conversation for sampling update: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Update conversation system prompt.
    func updateConversationSystemPrompt(id: UUID, systemPrompt: String?) {
        let context = writerContext
        context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1

            do {
                if let conversation = try context.fetch(request).first {
                    conversation.systemPrompt = systemPrompt
                    conversation.updatedAt = Date()
                    saveContext(context, operation: "updateConversationSystemPrompt")
                }
            } catch {
                logger.error("Failed to fetch conversation for system prompt update: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Message CRUD

    /// Insert a complete message (user or system message — not streaming).
    func insertMessage(
        conversationID: UUID,
        role: MessageRole,
        content: String,
        imageData: Data? = nil
    ) -> UUID? {
        let context = writerContext
        var messageID: UUID?

        context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            request.fetchLimit = 1

            do {
                guard let conversation = try context.fetch(request).first else {
                    logger.error("Conversation not found: \(conversationID, privacy: .public)")
                    return
                }

                let nextIndex = Int32(conversation.messageCount)
                let message = CDChatMessage.create(
                    in: context,
                    conversation: conversation,
                    role: role,
                    content: content,
                    imageData: imageData,
                    sequenceIndex: nextIndex
                )
                messageID = message.id
                saveContext(context, operation: "insertMessage")
            } catch {
                logger.error("Failed to fetch conversation for message insert: \(error.localizedDescription, privacy: .public)")
            }
        }

        return messageID
    }

    // MARK: - Streaming Support

    /// Begin a streaming assistant message. Returns the message ID.
    /// The message starts with `isStreaming = true` and empty content.
    func beginStreamingMessage(conversationID: UUID) -> UUID? {
        let context = writerContext
        var messageID: UUID?

        context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            request.fetchLimit = 1

            do {
                guard let conversation = try context.fetch(request).first else {
                    logger.error("Conversation not found for streaming: \(conversationID, privacy: .public)")
                    return
                }

                let nextIndex = Int32(conversation.messageCount)
                let message = CDChatMessage.create(
                    in: context,
                    conversation: conversation,
                    role: .assistant,
                    content: "",
                    sequenceIndex: nextIndex,
                    isStreaming: true
                )
                messageID = message.id

                // Initialize buffer for this message.
                if let id = messageID {
                    tokenBuffer[id] = ""
                    bufferFlushCount[id] = 0
                    lastFlushTime[id] = currentTimeMs()
                }

                saveContext(context, operation: "beginStreamingMessage")
            } catch {
                logger.error("Failed to begin streaming message: \(error.localizedDescription, privacy: .public)")
            }
        }

        return messageID
    }

    /// Buffer tokens during streaming. Flushes to Core Data periodically.
    /// This is called on every token — must be fast.
    func bufferTokens(messageID: UUID, tokens: String) {
        // Accumulate in buffer.
        tokenBuffer[messageID, default: ""] += tokens
        bufferFlushCount[messageID, default: 0] += 1

        let count = bufferFlushCount[messageID] ?? 0
        let lastFlush = lastFlushTime[messageID] ?? 0
        let now = currentTimeMs()
        let elapsed = now - lastFlush

        // Flush if we hit the token count threshold or the time threshold.
        if count >= flushTokenCount || elapsed >= flushIntervalMs {
            flushBuffer(messageID: messageID)
        }
    }

    /// Finalize a streaming message by appending buffered tokens and clearing
    /// `isStreaming` in a single save.
    func endStreamingMessage(messageID: UUID) {
        let buffered = tokenBuffer[messageID] ?? ""
        let context = writerContext
        var didSave = false

        context.performAndWait {
            let request = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1

            do {
                if let message = try context.fetch(request).first {
                    message.appendTokens(buffered)
                    message.isStreaming = false
                    didSave = saveContext(context, operation: "endStreamingMessage")
                    if !didSave {
                        context.rollback()
                    }
                }
            } catch {
                logger.error("Failed to end streaming message: \(error.localizedDescription, privacy: .public)")
            }
        }

        if didSave {
            clearBufferState(messageID: messageID)
        }
    }

    /// Cancel a streaming message by appending buffered tokens and marking it
    /// cancelled in a single save.
    func cancelStreamingMessage(messageID: UUID) {
        let buffered = tokenBuffer[messageID] ?? ""
        let context = writerContext
        var didSave = false

        context.performAndWait {
            let request = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1

            do {
                if let message = try context.fetch(request).first {
                    message.appendTokens(buffered)
                    message.isStreaming = false
                    let current = message.content ?? ""
                    message.content = current + "\n\n_[Generation cancelled]_"
                    didSave = saveContext(context, operation: "cancelStreamingMessage")
                    if !didSave {
                        context.rollback()
                    }
                }
            } catch {
                logger.error("Failed to cancel streaming message: \(error.localizedDescription, privacy: .public)")
            }
        }

        if didSave {
            clearBufferState(messageID: messageID)
        }
    }

    /// Persist all buffered streaming tokens before the app is suspended.
    func flushPendingWrites() {
        for messageID in Array(tokenBuffer.keys) {
            flushBuffer(messageID: messageID)
        }
    }

    /// Flush the token buffer for a specific message to Core Data.
    private func flushBuffer(messageID: UUID) {
        guard let buffered = tokenBuffer[messageID], !buffered.isEmpty else { return }

        let context = writerContext
        var didSave = false
        context.performAndWait {
            let request = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageID as CVarArg)
            request.fetchLimit = 1

            do {
                if let message = try context.fetch(request).first {
                    message.appendTokens(buffered)
                    didSave = saveContext(context, operation: "flushBuffer")
                    if !didSave {
                        context.rollback()
                    }
                }
            } catch {
                logger.error("Failed to flush token buffer: \(error.localizedDescription, privacy: .public)")
            }
        }

        if didSave {
            tokenBuffer[messageID] = ""
            bufferFlushCount[messageID] = 0
            lastFlushTime[messageID] = currentTimeMs()
        }
    }

}

extension PersistenceController {
    // MARK: - Fetch Helpers

    /// Fetch all conversations, sorted by most recently updated.
    func fetchConversations() -> [ConversationPayload] {
        let context = viewContext
        var results: [ConversationPayload] = []
        context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
            do {
                let objects = try context.fetch(request)
                results = objects.map { conversation in
                    ConversationPayload(
                        id: conversation.id ?? UUID(),
                        title: conversation.title ?? "Untitled",
                        modelID: conversation.modelID ?? "",
                        updatedAt: conversation.updatedAt,
                        createdAt: conversation.createdAt,
                        messageCount: conversation.messageCount,
                        isBranch: conversation.isBranch
                    )
                }
            } catch {
                logger.error("Failed to fetch conversations: \(error.localizedDescription, privacy: .public)")
            }
        }
        return results
    }

    /// Fetch messages for a conversation, sorted by sequence index.
    func fetchMessages(conversationID: UUID) -> [ChatMessagePayload] {
        let context = viewContext
        var results: [ChatMessagePayload] = []
        context.performAndWait {
            let request = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "conversation.id == %@", conversationID as CVarArg)
            request.sortDescriptors = [NSSortDescriptor(key: "sequenceIndex", ascending: true)]
            do {
                let objects = try context.fetch(request)
                results = objects.map { message in
                    ChatMessagePayload(
                        id: message.id ?? UUID(),
                        role: message.messageRole,
                        content: message.content ?? "",
                        imageData: message.imageData,
                        sequenceIndex: message.sequenceIndex,
                        isStreaming: message.isStreaming,
                        createdAt: message.createdAt
                    )
                }
            } catch {
                logger.error("Failed to fetch messages: \(error.localizedDescription, privacy: .public)")
            }
        }
        return results
    }

    /// Recover any messages left in streaming state (e.g. after a crash).
    /// Called on app launch.
    func recoverIncompleteStreams() {
        let context = writerContext
        context.performAndWait {
            let request = CDChatMessage.fetchRequest()
            request.predicate = NSPredicate(format: "isStreaming == YES")

            do {
                let incomplete = try context.fetch(request)
                for message in incomplete {
                    message.isStreaming = false
                    let current = message.content ?? ""
                    if !current.isEmpty {
                        message.content = current + "\n\n_[Interrupted — app was closed]_"
                    } else {
                        message.content = "_[Generation was interrupted]_"
                    }
                    let messageID = message.id?.uuidString ?? "unknown"
                    logger.info("Recovered incomplete message: \(messageID, privacy: .public)")
                }
                if !incomplete.isEmpty {
                    saveContext(context, operation: "recoverIncompleteStreams")
                }
            } catch {
                logger.error("Failed to recover incomplete streams: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Delete conversations that have zero messages (stale "New Conversation" entries).
    /// Called on app launch to clean up abandoned conversations.
    func purgeEmptyConversations() {
        let context = writerContext
        context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.predicate = NSPredicate(format: "messages.@count == 0")

            do {
                let empties = try context.fetch(request)
                if empties.isEmpty { return }

                for conversation in empties {
                    context.delete(conversation)
                    let conversationID = conversation.id?.uuidString ?? "unknown"
                    logger.info("Purged empty conversation: \(conversationID, privacy: .public)")
                }
                saveContext(context, operation: "purgeEmptyConversations")
                logger.info("Purged \(empties.count, privacy: .public) empty conversation(s)")
            } catch {
                logger.error("Failed to purge empty conversations: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Stress Test Support

    /// Generate test data for the 5,000-message stress test.
    func generateStressTestData(conversationCount: Int = 10, messagesPerConversation: Int = 500) {
        let context = writerContext
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
                saveContext(context, operation: "stressTestConversation\(convIndex)")
            }
        }
    }

    // MARK: - Branching

    /// Branch a conversation from a specific message. Creates a new conversation
    /// with all messages up to (and including) the branch point.
    func branchConversation(sourceID: UUID, fromMessageID: UUID, newTitle: String) -> UUID? {
        let context = writerContext
        var newConversationID: UUID?

        context.performAndWait {
            let request = CDConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", sourceID as CVarArg)
            request.fetchLimit = 1

            do {
                guard let source = try context.fetch(request).first else { return }

                // Find the branch point message index.
                let sourceMessages = source.sortedMessages
                guard let branchIndex = sourceMessages.firstIndex(where: { $0.id == fromMessageID }) else { return }

                // Create new conversation.
                let newConversation = CDConversation.create(
                    in: context,
                    title: newTitle,
                    modelID: source.modelID ?? "llama3.2-3b-q4",
                    systemPrompt: source.systemPrompt
                )
                newConversation.parentBranchID = sourceID
                newConversation.branchPointMessageID = fromMessageID
                newConversation.temperature = source.temperature
                newConversation.topP = source.topP
                newConversation.topK = source.topK
                newConversationID = newConversation.id

                // Copy messages up to branch point.
                for (index, message) in sourceMessages[...branchIndex].enumerated() {
                    CDChatMessage.create(
                        in: context,
                        conversation: newConversation,
                        role: message.messageRole,
                        content: message.content ?? "",
                        imageData: message.imageData,
                        sequenceIndex: Int32(index)
                    )
                }

                saveContext(context, operation: "branchConversation")
            } catch {
                logger.error("Failed to branch conversation: \(error.localizedDescription, privacy: .public)")
            }
        }

        return newConversationID
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

    @discardableResult
    private func saveContext(_ context: NSManagedObjectContext, operation: String) -> Bool {
        guard context.hasChanges else { return true }
        do {
            try context.save()
            return true
        } catch {
            let description = error.localizedDescription
            logger.error("Core Data save failed (\(operation, privacy: .public)): \(description, privacy: .public)")
            return false
        }
    }

    private func clearBufferState(messageID: UUID) {
        tokenBuffer.removeValue(forKey: messageID)
        bufferFlushCount.removeValue(forKey: messageID)
        lastFlushTime.removeValue(forKey: messageID)
    }

    private func currentTimeMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - Shared Instance

extension PersistenceController {
    /// Shared instance for the app. Use `PersistenceController(inMemory: true)` for previews/tests.
    @MainActor
    static let shared = PersistenceController()
}
