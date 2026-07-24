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
        get { MessageRole(rawValue: role ?? "") ?? .system }
        set { role = newValue.rawValue }
    }

    var validatedMessageRole: MessageRole? {
        guard let role else { return nil }
        return MessageRole(rawValue: role)
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

// MARK: - Attachment Storage

/// Versioned codec stored in the existing Core Data binary field.
/// Data written before multi-image support is treated as one legacy attachment.
enum MessageAttachmentCodec {
    private static let magic = Data([0x5A, 0x45, 0x49, 0x4D]) // "ZEIM"
    private static let version: UInt8 = 1

    static func encode(_ attachments: [Data]) -> Data? {
        guard !attachments.isEmpty else { return nil }
        var encoded = magic
        encoded.append(version)
        appendUInt32(UInt32(attachments.count), to: &encoded)
        for attachment in attachments {
            guard attachment.count <= Int(UInt32.max) else { return nil }
            appendUInt32(UInt32(attachment.count), to: &encoded)
            encoded.append(attachment)
        }
        return encoded
    }

    static func decode(_ stored: Data?) -> [Data] {
        guard let stored, !stored.isEmpty else { return [] }
        guard stored.count >= 9, stored.prefix(4) == magic, stored[4] == version else {
            return [stored]
        }

        var offset = 5
        guard let count = readUInt32(from: stored, offset: &offset) else { return [stored] }
        var attachments: [Data] = []
        attachments.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let length = readUInt32(from: stored, offset: &offset),
                  Int(length) <= stored.count - offset else { return [stored] }
            attachments.append(stored.subdata(in: offset..<(offset + Int(length))))
            offset += Int(length)
        }
        guard offset == stored.count else { return [stored] }
        return attachments
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func readUInt32(from data: Data, offset: inout Int) -> UInt32? {
        guard offset <= data.count - 4 else { return nil }
        let value = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        offset += 4
        return value
    }
}

// MARK: - Chat Message Payload

/// A lightweight, Sendable representation of a chat message.
/// Used to pass messages across actor boundaries without Core Data dependencies.
struct ChatMessagePayload: Sendable, Hashable {
    let id: UUID
    let role: MessageRole
    let content: String
    let attachments: [Data]
    let sequenceIndex: Int32
    let isStreaming: Bool
    let createdAt: Date?

    /// Compatibility accessor for call sites that only need the first image.
    var imageData: Data? { attachments.first }

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        imageData: Data? = nil,
        attachments: [Data]? = nil,
        sequenceIndex: Int32 = 0,
        isStreaming: Bool = false,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments ?? imageData.map { [$0] } ?? []
        self.sequenceIndex = sequenceIndex
        self.isStreaming = isStreaming
        self.createdAt = createdAt
    }
}

// MARK: - Identifiable

extension CDChatMessage: Identifiable {}
