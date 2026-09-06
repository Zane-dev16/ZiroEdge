// StoreMigrationRoundTripTests.swift
// ZiroEdgeTests
//
// Launch-gate tests for the Core Data store: a file-backed store must
// reopen with conversations and messages intact (the migration path every
// 1.x schema change will travel), and per-message delete must remove only
// the targeted row. Rule after 1.0: never edit a shipped model in place —
// always add a new model version first, and these tests will catch a
// migration break on every build.

import XCTest
import CoreData
@testable import ZiroEdge

final class StoreMigrationRoundTripTests: XCTestCase {

    private func freshStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ziroedge-migration-\(UUID().uuidString).sqlite")
    }

    private func openStore(at url: URL) async throws -> PersistenceController {
        let result = await PersistenceController.open(configuration: .store(url))
        switch result {
        case .success(let controller):
            return controller
        case .failure(let failure):
            throw failure
        }
    }

    func testFileBackedStoreReopensWithConversationsAndMessagesIntact() async throws {
        let url = freshStoreURL()

        let first = try await openStore(at: url)
        let conversationID = try await first.createConversation(
            title: "Round Trip",
            modelID: "llama3.2-3b-q4"
        )
        _ = await first.insertMessage(conversationID: conversationID, role: .user, content: "Hello")
        _ = await first.insertMessage(conversationID: conversationID, role: .assistant, content: "Hi there")
        _ = await first.closePersistentStores()

        let second = try await openStore(at: url)
        let conversations = await second.fetchConversations()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.id, conversationID)

        let messages = await second.fetchMessages(conversationID: conversationID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].content, "Hello")
        XCTAssertEqual(messages[1].content, "Hi there")
        _ = await second.closePersistentStores()
    }

    func testDeleteMessageRemovesOnlyTargetedRow() async throws {
        let url = freshStoreURL()

        let store = try await openStore(at: url)
        let conversationID = try await store.createConversation(
            title: "Delete One",
            modelID: "llama3.2-3b-q4"
        )
        _ = await store.insertMessage(conversationID: conversationID, role: .user, content: "Keep me")
        let doomedID = await store.insertMessage(
            conversationID: conversationID, role: .assistant, content: "Delete me"
        )

        let deleteResult = await store.deleteMessageResult(messageID: doomedID!)
        guard case .success = deleteResult else {
            XCTFail("deleteMessageResult failed")
            return
        }

        let messages = await store.fetchMessages(conversationID: conversationID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "Keep me")
        _ = await store.closePersistentStores()
    }
}
