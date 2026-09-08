// ModelEvictionPresentation.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Single source of truth for the memory-eviction surface: the AppShell
// "Model Unloaded" alert, the chat inline retry banner, and the composer
// picker tail all project this copy. One edit here updates every surface;
// accessibility IDs stay pinned so UI tests never drift.

import Foundation

/// Canonical copy + identifiers for the memory-pressure eviction surface.
/// Tokens/44pt live at the call sites (ZiroTheme + minHeight 44); this type
/// owns only strings and IDs so copy cannot diverge across the triple surface.
enum ModelEvictionPresentation {
    /// Alert title (AppShell modal).
    static let alertTitle = "Model Unloaded"
    /// Inline banner title (chat surface).
    static func inlineTitle(modelName: String?) -> String { "Model unloaded" }
    /// Shared body: the model was released to protect memory. The alert
    /// carries the device clause; the inline banner appends the reload
    /// affordance via its button, so both read from this one sentence.
    static func message(modelName: String?) -> String {
        "\(modelName ?? "The model") was released to protect memory."
    }
    /// Alert body extends the shared sentence with the reload invitation.
    static func alertMessage(modelName: String?) -> String {
        "\(message(modelName: modelName)) Reload it when you are ready to continue."
    }
    /// VoiceOver announcement for the inline banner appearance.
    static func announcement(modelName: String?) -> String {
        "\(message(modelName: modelName)) Reload available."
    }
    static let okButtonTitle = "OK"
    static let reloadButtonTitle = "Reload"
    static let chooseAnotherModelTitle = "Choose Another Model"
    // Pinned accessibility identifiers (do not rename without updating UI tests).
    static let retryButtonID = "modelRetryButton"
    static let retryBannerID = "modelRetryBanner"
    /// In-place retry-blocked hint below the disabled Retry/Reload row.
    static let retryHintID = "modelRetryHint"
    /// Delete-failure alert (ModelsView / ModelDetailView / SettingsPage).
    static let deleteFailureTitle = "Deletion Failed"
    static let deleteFailureID = "deleteFailureAlert"
    /// Rename Save buttons (SidebarView + ChatsView): disabled while empty.
    static let renameSaveButtonID = "renameSaveButton"
}

/// Single queued alert identity for the chat + shell surfaces.
///
/// Collapses ChatView's 2 alerts (experimental consent, delete confirm)
/// and AppShellView's 3 alerts (eviction, load failure, insufficient
/// memory) into one alert per view driven by this queue, so only one modal
/// can win at a time (stacked `.alert` modifiers compete and silently drop
/// all but one). Copy/buttons mirror the pre-queue alerts exactly — the
/// enum owns only routing + per-case payloads; ZiroTheme/44pt/a11y IDs
/// stay at the call sites (banner buttons keep minHeight 44, IDs pinned
/// above). Priority is resolved by `chatQueue`/`shellQueue` (first non-nil
/// flag wins); dismissal clears only the presented case's flag.
/// There is no modern `.alert(item:)` in this SDK (deprecated since iOS 15
/// in favor of presenting-data), so call sites drive `isPresented` +
/// `presenting:` from this queue. The onboarding `fullScreenCover` is NOT
/// an alert case — it takes precedence by gating the shell queue (nil
/// while the cover is up).
enum ZiroAlert: Identifiable, Equatable {
    case experimentalConsent
    case deleteConversation
    case memoryWarning(modelName: String?)
    case loadFailure(message: String)
    case insufficientMemory(message: String)

    var id: String {
        switch self {
        case .experimentalConsent: return "experimentalConsent"
        case .deleteConversation: return "deleteConversation"
        case .memoryWarning: return "memoryWarning"
        case .loadFailure: return "loadFailure"
        case .insufficientMemory: return "insufficientMemory"
        }
    }

    /// Alert title copy (pre-queue strings, verbatim).
    var title: String {
        switch self {
        case .experimentalConsent: return "Enable Experimental Runtime?"
        case .deleteConversation: return "Delete Conversation?"
        case .memoryWarning: return ModelEvictionPresentation.alertTitle
        case .loadFailure: return "Model Load Failed"
        case .insufficientMemory: return "Model Needs More Memory"
        }
    }

    /// Alert message copy (pre-queue strings, verbatim).
    var message: String {
        switch self {
        case .experimentalConsent:
            return "This imported profile has not passed the full physical workload. " +
                "ZiroEdge will still enforce its measured admission floor and reserve."
        case .deleteConversation:
            return "This will permanently delete the conversation and all its messages."
        case .memoryWarning(let modelName):
            return ModelEvictionPresentation.alertMessage(modelName: modelName)
        case .loadFailure(let message):
            return message
        case .insufficientMemory(let message):
            return message
        }
    }

    /// Chat queue priority (pure for tests): experimental consent wins over
    /// the delete confirmation.
    static func chatQueue(experimentalConsent: Bool, deleteConversation: Bool) -> ZiroAlert? {
        if experimentalConsent { return .experimentalConsent }
        if deleteConversation { return .deleteConversation }
        return nil
    }

    /// Shell queue priority (pure for tests): eviction wins over load
    /// failure, which wins over insufficient memory. Nil while the
    /// onboarding cover is up so a modal never stacks over it.
    static func shellQueue(
        onboarding: Bool,
        memoryWarning: Bool,
        memoryModelName: String?,
        loadFailure: String?,
        insufficientMemory: String?
    ) -> ZiroAlert? {
        if onboarding { return nil }
        if memoryWarning { return .memoryWarning(modelName: memoryModelName) }
        if let loadFailure { return .loadFailure(message: loadFailure) }
        if let insufficientMemory { return .insufficientMemory(message: insufficientMemory) }
        return nil
    }
}
