// CDChatMessage.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Core Data managed object for a single chat message.
// All mutations must go through PersistenceController's background writer.

import Foundation
import CoreData

@objc(CDChatMessage)
public class CDChatMessage: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDChatMessage> {
        NSFetchRequest<CDChatMessage>(entityName: "CDChatMessage")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var role: String?
    @NSManaged public var content: String?
    @NSManaged public var imageData: Data?
    @NSManaged public var sequenceIndex: Int32
    @NSManaged public var isStreaming: Bool
    @NSManaged public var createdAt: Date?
    @NSManaged public var conversation: CDConversation?
}

// MARK: - Convenience

extension CDChatMessage {

    /// The role as a typed enum.
    var messageRole: MessageRole {
        get { MessageRole(rawValue: role ?? "user") ?? .user }
        set { role = newValue.rawValue }
    }

    /// Whether this message has an image attachment.
    var hasImage: Bool {
        imageData != nil && (imageData?.isEmpty == false)
    }

    /// Create a new message in a conversation.
    @discardableResult
    static func create(
        in context: NSManagedObjectContext,
        conversation: CDConversation,
        role: MessageRole,
        content: String,
        imageData: Data? = nil,
        sequenceIndex: Int32,
        isStreaming: Bool = false
    ) -> CDChatMessage {
        let message = CDChatMessage(context: context)
        message.id = UUID()
        message.role = role.rawValue
        message.content = content
        message.imageData = imageData
        message.sequenceIndex = sequenceIndex
        message.isStreaming = isStreaming
        message.createdAt = Date()
        message.conversation = conversation
        conversation.addToMessages(message)
        conversation.updatedAt = Date()
        return message
    }

    /// Append tokens to this message's content (used during streaming).
    /// Does NOT save — caller must flush via PersistenceController.
    func appendTokens(_ tokens: String) {
        let current = content ?? ""
        content = current + tokens
    }
}

// MARK: - Message Role

/// The role of a message in a conversation.
enum MessageRole: String, Sendable, Hashable {
    case user       = "user"
    case assistant  = "assistant"
    case system     = "system"
}

// MARK: - Chat Message Payload

/// A lightweight, Sendable representation of a chat message.
/// Used to pass messages across actor boundaries without Core Data dependencies.
struct ChatMessagePayload: Sendable, Hashable {
    let id: UUID
    let role: MessageRole
    let content: String
    let imageData: Data?
    let sequenceIndex: Int32
    let isStreaming: Bool
    let createdAt: Date?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        imageData: Data? = nil,
        sequenceIndex: Int32 = 0,
        isStreaming: Bool = false,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.imageData = imageData
        self.sequenceIndex = sequenceIndex
        self.isStreaming = isStreaming
        self.createdAt = createdAt
    }
}

// MARK: - Identifiable

extension CDChatMessage: Identifiable {}
