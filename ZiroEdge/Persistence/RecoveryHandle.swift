import Foundation

struct RecoveryHandle: Sendable, Equatable, Identifiable {
    let id: UUID
    let conversationID: UUID
    let messageID: UUID
    let createdAt: Date
}

struct PartialResponseExport: Codable, Sendable, Equatable {
    let recoveryID: UUID
    let conversationID: UUID
    let messageID: UUID
    let createdAt: Date
    let role: String
    let content: String
    let terminalState: String
    let attachments: [Data]
}
