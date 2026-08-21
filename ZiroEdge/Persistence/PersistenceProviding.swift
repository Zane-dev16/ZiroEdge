// PersistenceProviding.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Minimal persistence surface consumed by ChatSessionActor and ChatViewModel.
// PersistenceController conforms directly (its actor-isolated methods satisfy
// the async requirements); tests may substitute isolated fakes without Core Data.

import Foundation

/// The slice of the Core Data stack actually consumed by chat flows.
protocol PersistenceProviding: Sendable {
    // MARK: Conversation reads/writes (ChatViewModel)

    func fetchConversationsResult(historyEligibleOnly: Bool) async -> Result<[ConversationPayload], PersistenceFailure>

    func fetchMessagesResult(conversationID: UUID) async -> Result<[ChatMessagePayload], PersistenceFailure>

    func createConversationResult(
        id: UUID,
        title: String,
        modelID: String,
        systemPrompt: String?
    ) async -> Result<UUID, PersistenceFailure>

    func insertMessageResult(
        conversationID: UUID,
        role: MessageRole,
        content: String,
        imageData: Data?,
        attachments: [Data]?
    ) async -> Result<UUID, PersistenceFailure>

    func updateConversationSystemPrompt(
        id: UUID,
        systemPrompt: String?
    ) async -> Result<Void, PersistenceFailure>

    func updateConversationTitleIfStill(
        id: UUID,
        newTitle: String,
        expectedCurrentTitle: String
    ) async -> Result<Void, PersistenceFailure>

    func branchConversationResult(
        sourceID: UUID,
        fromMessageID: UUID,
        newTitle: String
    ) async -> Result<UUID, PersistenceFailure>

    // MARK: Streaming pipeline (ChatSessionActor)

    func beginStreamingMessageResult(conversationID: UUID) async -> Result<UUID, PersistenceFailure>

    func bufferTokens(messageID: UUID, tokens: String) async -> Result<Void, PersistenceMutationError>

    func endStreamingMessage(messageID: UUID) async -> Result<Void, PersistenceMutationError>

    func cancelStreamingMessage(messageID: UUID) async -> Result<Void, PersistenceMutationError>

    func recoveryHandle(messageID: UUID) async -> RecoveryHandle?

    func retryStreamingSave(_ handle: RecoveryHandle) async -> Result<Void, PersistenceFailure>

    func exportPartialResponse(_ handle: RecoveryHandle) async -> Result<Data, PersistenceFailure>

    func discardRecovery(_ handle: RecoveryHandle) async -> Result<Void, PersistenceFailure>
}

extension PersistenceController: PersistenceProviding {}
