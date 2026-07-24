// PersistenceTests.swift
// ZiroEdgeTests
//
// Tests for Core Data persistence layer: CRUD, streaming, crash recovery,
// branching, and stress test data generation.

import XCTest
import CoreData
@testable import ZiroEdge

final class PersistenceTests: XCTestCase {

    var persistence: PersistenceController!

    override func setUp() async throws {
        persistence = PersistenceController(inMemory: true)
    }

    // MARK: - Conversation CRUD

    func testCreateConversation() async throws {
        let id = try await persistence.createConversation(
            title: "Test Conversation",
            modelID: "llama3.2-3b-q4"
        )

        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.id, id)
        XCTAssertEqual(conversations.first?.title, "Test Conversation")
        XCTAssertEqual(conversations.first?.modelID, "llama3.2-3b-q4")
        XCTAssertEqual(conversations.first?.temperature, 0.7)
        XCTAssertEqual(conversations.first?.topP, 0.9)
        XCTAssertEqual(conversations.first?.topK, 40)
    }

    func testDeleteConversation() async throws {
        let id = try await persistence.createConversation(
            title: "To Delete",
            modelID: "llama3.2-3b-q4"
        )

        await persistence.deleteConversation(id: id)

        let conversations = await persistence.fetchConversations()
        XCTAssertTrue(conversations.isEmpty)
    }

    func testUpdateConversationTitle() async throws {
        let id = try await persistence.createConversation(
            title: "Original",
            modelID: "llama3.2-3b-q4"
        )

        await persistence.updateConversationTitle(id: id, title: "Renamed")

        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.first?.title, "Renamed")
    }

    func testUpdateConversationSampling() async throws {
        let id = try await persistence.createConversation(
            title: "Sampling Test",
            modelID: "llama3.2-3b-q4"
        )

        await persistence.updateConversationSampling(
            id: id,
            temperature: 1.2,
            topP: 0.95,
            topK: 50
        )

        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.first?.temperature, 1.2)
        XCTAssertEqual(conversations.first?.topP, 0.95)
        XCTAssertEqual(conversations.first?.topK, 50)
    }

    func testUpdateConversationSystemPrompt() async throws {
        let id = try await persistence.createConversation(
            title: "System Prompt Test",
            modelID: "llama3.2-3b-q4",
            systemPrompt: "You are helpful."
        )

        await persistence.updateConversationSystemPrompt(
            id: id,
            systemPrompt: "You are a pirate."
        )

        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.first?.systemPrompt, "You are a pirate.")
    }

    // MARK: - Message CRUD

    func testInsertMessage() async throws {
        let convID = try await persistence.createConversation(
            title: "Message Test",
            modelID: "llama3.2-3b-q4"
        )

        let msgID = await persistence.insertMessage(
            conversationID: convID,
            role: .user,
            content: "Hello, world!"
        )

        XCTAssertNotNil(msgID)

        let messages = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "Hello, world!")
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertEqual(messages.first?.sequenceIndex, 0)
        XCTAssertFalse(messages.first?.isStreaming ?? true)
    }

    func testMultipleMessagesOrdering() async throws {
        let convID = try await persistence.createConversation(
            title: "Order Test",
            modelID: "llama3.2-3b-q4"
        )

        await persistence.insertMessage(conversationID: convID, role: .user, content: "First")
        await persistence.insertMessage(conversationID: convID, role: .assistant, content: "Second")
        await persistence.insertMessage(conversationID: convID, role: .user, content: "Third")

        let messages = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].content, "First")
        XCTAssertEqual(messages[0].sequenceIndex, 0)
        XCTAssertEqual(messages[1].content, "Second")
        XCTAssertEqual(messages[1].sequenceIndex, 1)
        XCTAssertEqual(messages[2].content, "Third")
        XCTAssertEqual(messages[2].sequenceIndex, 2)
    }

    // MARK: - Streaming

    func testStreamingLifecycle() async throws {
        let convID = try await persistence.createConversation(
            title: "Streaming Test",
            modelID: "llama3.2-3b-q4"
        )

        // Begin streaming message.
        let msgID = await persistence.beginStreamingMessage(conversationID: convID)
        XCTAssertNotNil(msgID)

        // Verify message is in streaming state.
        let messages1 = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages1.count, 1)
        XCTAssertTrue(messages1.first?.isStreaming ?? false)
        XCTAssertEqual(messages1.first?.role, .assistant)

        // Buffer some tokens.
        await persistence.bufferTokens(messageID: msgID!, tokens: "Hello")
        await persistence.bufferTokens(messageID: msgID!, tokens: " world")

        // End streaming.
        await persistence.endStreamingMessage(messageID: msgID!)

        // Verify message is finalized.
        let messages2 = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages2.count, 1)
        XCTAssertFalse(messages2.first?.isStreaming ?? true)
        XCTAssertFalse(messages2.first?.content.isEmpty ?? true)
    }

    func testStreamingCancellation() async throws {
        let convID = try await persistence.createConversation(
            title: "Cancel Test",
            modelID: "llama3.2-3b-q4"
        )

        let msgID = await persistence.beginStreamingMessage(conversationID: convID)!
        await persistence.bufferTokens(messageID: msgID, tokens: "Partial ")
        await persistence.cancelStreamingMessage(messageID: msgID)
        await persistence.cancelStreamingMessage(messageID: msgID)

        let messages = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(messages.first?.isStreaming ?? true)
        XCTAssertEqual(messages.first?.content.components(separatedBy: "_[Generation cancelled]_" ).count, 2)
    }

    func testMultipleAttachmentsSurviveColdFetchInOrder() async throws {
        let convID = try await persistence.createConversation(title: "Images", modelID: "vision")
        let attachments = [Data([1, 2]), Data([3, 4, 5]), Data([6])]

        let messageID = await persistence.insertMessage(
            conversationID: convID,
            role: .user,
            content: "compare",
            attachments: attachments
        )
        XCTAssertNotNil(messageID)

        let messages = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages.first?.attachments, attachments)
    }

    func testLegacyRawImageDecodesAsSingleAttachment() {
        let legacy = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(MessageAttachmentCodec.decode(legacy), [legacy])
    }

    func testAttachmentCodecRejectsMalformedArchiveAsLegacyData() {
        let malformed = Data([0x5A, 0x45, 0x49, 0x4D, 1, 1, 0, 0, 0, 100])
        XCTAssertEqual(MessageAttachmentCodec.decode(malformed), [malformed])
    }

    // MARK: - Crash Recovery

    func testCrashRecovery() async throws {
        let convID = try await persistence.createConversation(
            title: "Crash Test",
            modelID: "llama3.2-3b-q4"
        )

        // Begin streaming message.
        let msgID = await persistence.beginStreamingMessage(conversationID: convID)!

        // Verify it's streaming.
        let messages1 = await persistence.fetchMessages(conversationID: convID)
        XCTAssertTrue(messages1.first?.isStreaming ?? false)

        // Recover incomplete streams (simulates app relaunch).
        await persistence.recoverIncompleteStreams()

        // After recovery, the message should no longer be streaming.
        // Note: fetch from viewContext may need a moment to merge.
        // The key assertion is that isStreaming is set to false.
        let messages2 = await persistence.fetchMessages(conversationID: convID)
        XCTAssertEqual(messages2.count, 1)
        XCTAssertFalse(messages2.first?.isStreaming ?? true,
                        "After recovery, message should not be streaming")
    }

    // MARK: - Branching

    func testConversationBranching() async throws {
        let sourceID = try await persistence.createConversation(
            title: "Original",
            modelID: "llama3.2-3b-q4"
        )

        // Insert 3 messages.
        await persistence.insertMessage(conversationID: sourceID, role: .user, content: "Q1")
        await persistence.insertMessage(conversationID: sourceID, role: .assistant, content: "A1")
        let msg3ID = await persistence.insertMessage(conversationID: sourceID, role: .user, content: "Q2")!
        await persistence.insertMessage(conversationID: sourceID, role: .assistant, content: "A2")

        // Branch from message 3 (Q2).
        let branchID = await persistence.branchConversation(
            sourceID: sourceID,
            fromMessageID: msg3ID,
            newTitle: "Branched"
        )

        XCTAssertNotNil(branchID)

        // Verify branch has messages up to branch point (Q1, A1, Q2 = 3 messages).
        let branchMessages = await persistence.fetchMessages(conversationID: branchID!)
        XCTAssertEqual(branchMessages.count, 3)
        XCTAssertEqual(branchMessages[0].content, "Q1")
        XCTAssertEqual(branchMessages[1].content, "A1")
        XCTAssertEqual(branchMessages[2].content, "Q2")

        // Verify original still has all 4 messages.
        let sourceMessages = await persistence.fetchMessages(conversationID: sourceID)
        XCTAssertEqual(sourceMessages.count, 4)

        // Verify branch metadata.
        let conversations = await persistence.fetchConversations()
        let branch = conversations.first { $0.id == branchID }
        XCTAssertNotNil(branch)
        XCTAssertEqual(branch?.parentBranchID, sourceID)
        XCTAssertEqual(branch?.branchPointMessageID, msg3ID)
    }

    // MARK: - Stress Test

    func testStressTestDataGeneration() async throws {
        // Generate 10 conversations x 500 messages = 5,000 messages.
        await persistence.generateStressTestData(conversationCount: 10, messagesPerConversation: 500)

        let conversations = await persistence.fetchConversations()
        XCTAssertEqual(conversations.count, 10)

        // Verify total message count.
        var totalMessages = 0
        for conv in conversations {
            let messages = await persistence.fetchMessages(conversationID: conv.id)
            totalMessages += messages.count
        }
        XCTAssertEqual(totalMessages, 5000)
    }

    // MARK: - Edge Cases

    func testEmptyConversationFetch() async throws {
        let conversations = await persistence.fetchConversations()
        XCTAssertTrue(conversations.isEmpty)
    }

    func testEmptyMessageFetch() async throws {
        let convID = try await persistence.createConversation(
            title: "Empty",
            modelID: "llama3.2-3b-q4"
        )
        let messages = await persistence.fetchMessages(conversationID: convID)
        XCTAssertTrue(messages.isEmpty)
    }

    func testInsertMessageToNonexistentConversation() async throws {
        let msgID = await persistence.insertMessage(
            conversationID: UUID(),
            role: .user,
            content: "Should fail"
        )
        XCTAssertNil(msgID)
    }
}
