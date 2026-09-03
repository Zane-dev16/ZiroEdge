// ChatPersistenceRecovery.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Persistence-recovery surface for ChatViewModel: the "Response not saved
// yet" banner actions (retry save, export, discard) plus the background
// failure presenter. Extracted from ChatViewModel.swift (no behavior change
// beyond the r6 .notFound contract below — the private(set) recovery state
// and the session actor handle are reached through seams in the main file).

import Foundation

extension ChatViewModel {
    /// Retry persisting the partial response held by the session actor.
    /// A `.notFound` result means the recovery was already consumed
    /// elsewhere (e.g. its conversation was deleted, which drops the
    /// recovery journal with it): treat it as settled and release the
    /// banner instead of wedging on a recovery that can no longer exist.
    func retryPersistenceRecovery() async {
        switch await sessionActor.retryRecoverySave() {
        case .success:
            await finishPersistenceRecoveryReload()
        case .failure(let failure) where failure.category == .notFound:
            await finishPersistenceRecoveryReload()
        case .failure(let failure):
            presentBackgroundPersistenceFailure(failure)
        }
    }

    /// Export the partial response to a temporary JSON file. `.notFound`
    /// releases the banner for the same consumed-elsewhere reason as retry:
    /// with the journal gone, Retry/Discard can never succeed either.
    func exportPersistenceRecovery() async {
        switch await sessionActor.exportRecovery() {
        case .success(let data):
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ZiroEdge-partial-response-\(UUID().uuidString).json")
                try data.write(to: url, options: .atomic)
                stageRecoveryExport(url)
            } catch {
                errorMessage = PersistenceFailure.map(error, operation: .export).localizedDescription
                showError = true
            }
        case .failure(let failure) where failure.category == .notFound:
            releasePersistenceRecovery()
        case .failure(let failure):
            presentBackgroundPersistenceFailure(failure)
        }
    }

    /// Discard the partial response. `.notFound` is settled the same way as
    /// retry: the journal is already gone, so release the banner.
    func discardPersistenceRecovery() async {
        switch await sessionActor.discardRecovery() {
        case .success:
            await finishPersistenceRecoveryReload()
        case .failure(let failure) where failure.category == .notFound:
            await finishPersistenceRecoveryReload()
        case .failure(let failure):
            presentBackgroundPersistenceFailure(failure)
        }
    }

    func presentBackgroundPersistenceFailure(_ failure: PersistenceFailure) {
        errorMessage = failure.localizedDescription
        showError = true
    }

    /// Shared settled path for retry/discard: clear the banner and stream
    /// remnants, then refresh the transcript from persistence.
    private func finishPersistenceRecoveryReload() async {
        releasePersistenceRecovery()
        errorMessage = nil
        showError = false
        if let activeConversationID { await loadConversation(activeConversationID) }
    }
}
