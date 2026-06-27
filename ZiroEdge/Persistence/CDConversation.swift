// CDConversation.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Core Data managed object for a conversation.
// All mutations must go through PersistenceController's background writer.

import Foundation
import CoreData

@objc(CDConversation)
public class CDConversation: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDConversation> {
        NSFetchRequest<CDConversation>(entityName: "CDConversation")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var title: String?
    @NSManaged public var systemPrompt: String?
    @NSManaged public var modelID: String?
    @NSManaged public var temperature: Double
    @NSManaged public var topP: Double
    @NSManaged public var topK: Int32
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var parentBranchID: UUID?
    @NSManaged public var branchPointMessageID: UUID?
    @NSManaged public var messages: NSSet?
}

// MARK: - Generated accessors for messages

extension CDConversation {

    @objc(addMessagesObject:)
    @NSManaged public func addToMessages(_ value: CDChatMessage)

    @objc(removeMessagesObject:)
    @NSManaged public func removeFromMessages(_ value: CDChatMessage)

    @objc(addMessages:)
    @NSManaged public func addToMessages(_ values: NSSet)

    @objc(removeMessages:)
    @NSManaged public func removeFromMessages(_ values: NSSet)
}

// MARK: - Convenience

extension CDConversation {

    /// Messages sorted by sequence index.
    var sortedMessages: [CDChatMessage] {
        let set = messages as? Set<CDChatMessage> ?? []
        return set.sorted { $0.sequenceIndex < $1.sequenceIndex }
    }

    /// Number of messages in this conversation.
    var messageCount: Int {
        (messages as? Set<CDChatMessage>)?.count ?? 0
    }

    /// Whether this conversation is a branch of another.
    var isBranch: Bool {
        parentBranchID != nil
    }

    /// Create a new conversation with defaults.
    @discardableResult
    static func create(
        in context: NSManagedObjectContext,
        id: UUID = UUID(),
        title: String = "New Conversation",
        modelID: String,
        systemPrompt: String? = nil
    ) -> CDConversation {
        let conversation = CDConversation(context: context)
        conversation.id = id
        conversation.title = title
        conversation.modelID = modelID
        conversation.systemPrompt = systemPrompt
        conversation.temperature = 0.7
        conversation.topP = 0.9
        conversation.topK = 40
        conversation.createdAt = Date()
        conversation.updatedAt = Date()
        return conversation
    }
}

// MARK: - Identifiable

extension CDConversation: Identifiable {}
