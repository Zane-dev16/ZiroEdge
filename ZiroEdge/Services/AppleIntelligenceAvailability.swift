// AppleIntelligenceAvailability.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Single gate for the Apple Intelligence (FoundationModels) engine.
// All FM availability decisions route through here so call sites never
// touch `SystemLanguageModel` directly. Builds on Xcode <26 / iOS 18 SDK
// via `canImport` — FM code only compiles where the framework exists.

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Conversation persistence marker for FM answers. Not an AIModel/GGUF.
enum AppleIntelligenceMarker {
    static let modelID = "apple-intelligence"
    static let displayName = "Apple Intelligence"
}

/// Why the FM engine cannot run right now. Raw values are user-safe.
enum AppleIntelligenceUnavailableReason: String, Sendable {
    case frameworkMissing = "framework-missing"
    case osUnsupported = "os-unsupported"
    case deviceNotEligible = "device-not-eligible"
    case notEnabled = "apple-intelligence-not-enabled"
    case modelNotReady = "model-not-ready"
    case unsupportedLocale = "unsupported-locale"
}

/// Availability verdict for the FM engine.
enum AppleIntelligenceStatus: Sendable, Equatable {
    case ready
    case unavailable(AppleIntelligenceUnavailableReason)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum AppleIntelligenceAvailability {
    /// Cheap, synchronous readiness check. No session is created.
    static func status(locale: Locale = .current) -> AppleIntelligenceStatus {
#if canImport(FoundationModels)
        if #available(iOS 26, *) {
            return foundationModelsStatus(locale: locale)
        } else {
            return .unavailable(.osUnsupported)
        }
#else
        return .unavailable(.frameworkMissing)
#endif
    }

    static var isReady: Bool { status().isReady }

#if canImport(FoundationModels)
    @available(iOS 26, *)
    private static func foundationModelsStatus(locale: Locale) -> AppleIntelligenceStatus {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(locale) ? .ready : .unavailable(.unsupportedLocale)
        case .unavailable(.deviceNotEligible):
            return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(.notEnabled)
        case .unavailable(.modelNotReady):
            return .unavailable(.modelNotReady)
        case .unavailable:
            return .unavailable(.modelNotReady)
        }
    }
#endif

    /// Minimalist fallback copy: one line, no engine badge.
    static func fallbackMessage(for status: AppleIntelligenceStatus) -> String {
        switch status {
        case .ready:
            return ""
        case .unavailable(.notEnabled):
            return "Apple Intelligence is turned off. Turn it on in Settings, or continue with a downloaded model."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading. Continue with a downloaded model for now."
        case .unavailable(.deviceNotEligible):
            return "This device does not support Apple Intelligence. Continue with a downloaded model."
        case .unavailable(.unsupportedLocale):
            return "Apple Intelligence does not support this language yet. Continue with a downloaded model."
        case .unavailable(.osUnsupported), .unavailable(.frameworkMissing):
            return "Apple Intelligence needs iOS 26. Continue with a downloaded model."
        }
    }
}
