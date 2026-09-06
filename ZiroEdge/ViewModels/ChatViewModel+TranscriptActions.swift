// ChatViewModel+TranscriptActions.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Transcript-level message actions: branching, retry, export, and delete.
// Split from ChatViewModel.swift to keep the main file within limits.

import Foundation
import UIKit

extension ChatViewModel {
    // MARK: - Branching

    func branchFromMessage(_ messageID: UUID) async {
        guard let sourceID = activeConversationID else { return }
        switch await persistence.branchConversationResult(
            sourceID: sourceID,
            fromMessageID: messageID,
            newTitle: "Branched Conversation"
        ) {
        case .success(let newID):
            await loadConversation(newID)
            // Mirror draft materialization/sendtest: refresh the sidebar and
            // select the new branch so the highlighted row matches the
            // visible transcript. The shell's onChange load is a no-op here
            // because activeConversationID already == newID.
            await conversationListViewModel?.loadConversations()
            conversationListViewModel?.selectedConversationID = newID
        case .failure(let failure):
            errorMessage = failure.localizedDescription
            showError = true
        }
    }

    // MARK: - Retry

    /// Retry is available when a user message exists and no stream is running.
    var canRetryLastResponse: Bool {
        !isStreaming && !isLoadingConversation
            && messages.contains(where: { $0.role == .user })
    }

    /// Regenerate the response to the last user message without duplicating
    /// it: history is truncated to that message and a fresh assistant reply
    /// is streamed and persisted by the normal completion path.
    func retryLastResponse() async {
        guard !isStreaming, !isLoadingConversation else { return }
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else { return }
        let lastUser = messages[lastUserIndex]
        guard let conversationID = await validateSendPreconditions(
            text: lastUser.content, hasImages: !lastUser.attachments.isEmpty
        ) else { return }
        let history = Array(messages[...lastUserIndex])
        let images = lastUser.attachments
        isStreaming = true; streamingText = ""; errorMessage = nil; visionWarning = nil
        resetStreamingBuffer()
        let generationID = UUID()
        activeGenerationID = generationID
        streamedConversationID = conversationID
        await startStreaming(
            generationID: generationID,
            conversationID: conversationID, history: history, images: images,
            hasImages: !images.isEmpty, isFirstExchange: false,
            firstUserMessage: lastUser.content
        )
    }

    // MARK: - Export

    /// Write the visible transcript as Markdown and stage it for ShareLink.
    func exportTranscript() {
        var lines = ["# Conversation", ""]
        for message in messages {
            lines.append(message.role == .user ? "## You" : "## Assistant")
            lines.append(message.content)
            lines.append("")
        }
        let text = lines.joined(separator: "\n")
        let name: String
        if let conversationID = activeConversationID {
            name = "ziroedge-transcript-\(conversationID.uuidString.prefix(8)).md"
        } else {
            name = "ziroedge-transcript.md"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            transcriptExportURL = url
        } catch {
            errorMessage = "Could not write transcript export."
            showError = true
        }
    }

    // MARK: - Delete

    /// Copy helper taking plain text so SwiftUI rows can capture the string
    /// instead of the whole payload in action closures.
    func copyMessageText(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// Delete a single message from disk and the visible transcript.
    func deleteMessage(_ messageID: UUID) async {
        switch await persistence.deleteMessageResult(messageID: messageID) {
        case .success:
            messages.removeAll { $0.id == messageID }
            await conversationListViewModel?.loadConversations()
        case .failure(let failure):
            errorMessage = failure.localizedDescription
            showError = true
        }
    }
}
