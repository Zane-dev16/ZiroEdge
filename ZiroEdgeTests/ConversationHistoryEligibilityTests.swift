import XCTest
@testable import ZiroEdge

final class ConversationHistoryEligibilityTests: XCTestCase {

    // MARK: - Exclusion: empty and user-only

    func testEmptyAndUserOnlyConversationsAreExcludedFromHistory() async throws {
        let persistence = PersistenceController(inMemory: true)
        _ = try await persistence.createConversation(title: "Empty", modelID: "fixture")
        let userOnly = try await persistence.createConversation(title: "User Only", modelID: "fixture")
        _ = await persistence.insertMessage(conversationID: userOnly, role: .user, content: "Hello")

        let result = await persistence.fetchConversationsResult(historyEligibleOnly: true)
        XCTAssertTrue(try result.get().isEmpty)
    }

    // MARK: - Inclusion: completed response

    func testCompletedAssistantResponseMakesConversationVisible() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await persistence.createConversation(title: "Answered", modelID: "fixture")
        _ = await persistence.insertMessage(conversationID: id, role: .user, content: "Hello")
        _ = await persistence.insertMessage(conversationID: id, role: .assistant, content: "Hi")

        let result = await persistence.fetchConversationsResult(historyEligibleOnly: true)
        XCTAssertEqual(try result.get().map(\.id), [id])
    }

    // MARK: - Exclusion: cancellation and interruption markers (exact-match)

    func testCancellationAndInterruptedMarkersDoNotCreateHistoryRows() async throws {
        let persistence = PersistenceController(inMemory: true)
        for marker in ["_[Generation cancelled]_", "_[Interrupted — app was closed]_"] {
            let id = try await persistence.createConversation(title: marker, modelID: "fixture")
            _ = await persistence.insertMessage(conversationID: id, role: .user, content: "Hello")
            _ = await persistence.insertMessage(conversationID: id, role: .assistant, content: marker)
        }

        let result = await persistence.fetchConversationsResult(historyEligibleOnly: true)
        XCTAssertTrue(try result.get().isEmpty)
    }

    // MARK: - Exclusion: markers embedded in partial response content

    func testPartialResponseBeforeCancellationMarkerIsNotEligible() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await persistence.createConversation(title: "Partial Cancel", modelID: "fixture")
        _ = await persistence.insertMessage(conversationID: id, role: .user, content: "Tell me a story")
        _ = await persistence.insertMessage(
            conversationID: id, role: .assistant,
            content: "Once upon a time, in a land far away\n\n_[Generation cancelled]_"
        )

        let result = await persistence.fetchConversationsResult(historyEligibleOnly: true)
        XCTAssertTrue(try result.get().isEmpty)
    }

    func testPartialResponseBeforeInterruptedMarkerIsNotEligible() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await persistence.createConversation(title: "Partial Interrupt", modelID: "fixture")
        _ = await persistence.insertMessage(conversationID: id, role: .user, content: "Explain quantum physics")
        _ = await persistence.insertMessage(
            conversationID: id, role: .assistant,
            content: "Quantum physics is the study of matter at the smallest scales\n\n_[Interrupted — app was closed]_"
        )

        let result = await persistence.fetchConversationsResult(historyEligibleOnly: true)
        XCTAssertTrue(try result.get().isEmpty)
    }

    func testGenerationWasInterruptedMarkerBlocksEligibility() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await persistence.createConversation(title: "Gen Interrupted", modelID: "fixture")
        _ = await persistence.insertMessage(conversationID: id, role: .user, content: "Hi")
        _ = await persistence.insertMessage(
            conversationID: id, role: .assistant,
            content: "_[Generation was interrupted]_"
        )

        let result = await persistence.fetchConversationsResult(historyEligibleOnly: true)
        XCTAssertTrue(try result.get().isEmpty)
    }

    // MARK: - Multi-message: completed conversation with earlier cancelled exchange

    func testEarlierCancellationDoesNotBlockLaterValidExchange() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await persistence.createConversation(title: "Multi-Turn", modelID: "fixture")
        // First exchange was cancelled
        _ = await persistence.insertMessage(conversationID: id, role: .user, content: "First question")
        _ = await persistence.insertMessage(
            conversationID: id, role: .assistant,
            content: "Partial answer\n\n_[Generation cancelled]_"
        )
        // Second exchange completed normally
        _ = await persistence.insertMessage(conversationID: id, role: .user, content: "Second question")
        _ = await persistence.insertMessage(conversationID: id, role: .assistant, content: "Complete answer")

        let result = await persistence.fetchConversationsResult(historyEligibleOnly: true)
        XCTAssertEqual(try result.get().map(\.id), [id])
    }

    // MARK: - Existing eligible history is preserved

    func testExistingEligibleHistoryRemainsUnchanged() async throws {
        let persistence = PersistenceController(inMemory: true)
        // Create a normally completed conversation
        let id = try await persistence.createConversation(title: "Valid History", modelID: "fixture")
        _ = await persistence.insertMessage(conversationID: id, role: .user, content: "What is Swift?")
        _ = await persistence.insertMessage(
            conversationID: id, role: .assistant,
            content: "Swift is a powerful and intuitive programming language created by Apple."
        )

        // Verify it appears in history
        let result = await persistence.fetchConversationsResult(historyEligibleOnly: true)
        let eligible = try result.get()
        XCTAssertEqual(eligible.map(\.id), [id])
        XCTAssertEqual(eligible.first?.title, "Valid History")
        XCTAssertEqual(eligible.first?.messageCount, 2)
    }

    // MARK: - No false-positive: normal text resembling markers

    func testAssistantResponseContainingBracketUnderscoreIsStillEligible() async throws {
        let persistence = PersistenceController(inMemory: true)
        let id = try await persistence.createConversation(title: "Bracket Text", modelID: "fixture")
        _ = await persistence.insertMessage(conversationID: id, role: .user, content: "Show me code")
        _ = await persistence.insertMessage(
            conversationID: id, role: .assistant,
            content: "Here is a function:\n```swift\nfunc _[debug]() { print(\"ok\") }\n```"
        )

        let result = await persistence.fetchConversationsResult(historyEligibleOnly: true)
        XCTAssertEqual(try result.get().map(\.id), [id])
    }
}
