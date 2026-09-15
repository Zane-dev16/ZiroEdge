// ChatTranscriptPresentationTests.swift
// ZiroEdgeTests
//
// Transcript chrome rules that the chat surface's screenshots depend on:
// day dividers, and the action-row gate on message bubbles.

import XCTest
@testable import ZiroEdge

final class ChatTranscriptPresentationTests: XCTestCase {

    /// Same-day transcripts render no divider at all; a day change opens
    /// exactly one divider, on the first message of the new day.
    func testDayDividersSuppressSingleDayTranscripts() throws {
        let calendar = Calendar.current
        let day1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 9)))
        let day1Later = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 18)))
        let day2 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 8)))

        func message(_ content: String, _ date: Date?) -> ChatMessagePayload {
            ChatMessagePayload(role: .user, content: content, createdAt: date)
        }

        let sameDay = [message("a", day1), message("b", day1Later)]
        XCTAssertTrue(
            ChatView.dayDividerLabels(for: sameDay, calendar: calendar).isEmpty,
            "one day of messages must render no divider"
        )

        let undated = [message("a", nil), message("b", nil)]
        XCTAssertTrue(
            ChatView.dayDividerLabels(for: undated, calendar: calendar).isEmpty,
            "undated messages never open a divider"
        )

        let twoDays = [message("a", day1), message("b", day2), message("c", day2)]
        let dividers = ChatView.dayDividerLabels(for: twoDays, calendar: calendar)
        XCTAssertEqual(dividers.count, 1, "only the day change opens a divider")
        XCTAssertNotNil(dividers[twoDays[1].id], "the first message of the new day carries it")
        XCTAssertNil(dividers[twoDays[0].id], "the opening day needs no divider")
    }

    /// The action row is gated by `showsActions` — the transcript passes it
    /// for the live (latest assistant) turn only.
    func testMessageBubbleActionRowIsGated() {
        let gated = MessageBubble(
            message: ChatMessagePayload(role: .assistant, content: "Hi"),
            showsActions: false,
            onBranch: {}, onCopy: {}, onRetry: {}
        )
        XCTAssertFalse(gated.showsActions, "past replies render no action row")

        let live = MessageBubble(
            message: ChatMessagePayload(role: .assistant, content: "Hi"),
            onBranch: {}, onCopy: {}, onRetry: {}
        )
        XCTAssertTrue(live.showsActions, "the row defaults to visible for the live turn")
    }
}
