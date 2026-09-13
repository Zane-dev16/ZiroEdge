// ChatAttachmentPipeline.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Image-attachment ingestion for ChatViewModel: clipboard and photo-picker
// bytes are validated, capped, and downsampled entirely off the main actor
// via ImageIO so multi-megabyte photos never block the UI. Extracted from
// ChatViewModel.swift to keep the send/streaming core focused (no behavior
// change — the pipeline is byte-for-byte identical).

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension ChatViewModel {
    // MARK: - Image Attachment

    /// Maximum image dimension (width or height) in pixels.
    nonisolated static let maxImageDimension: CGFloat = 1024
    /// Maximum raw image data size before forced downsample (10 MB).
    private nonisolated static let maxImageBytes = 10 * 1024 * 1024

    /// Outcome of attachment preprocessing (legacy validation semantics).
    enum AttachmentPreparation: Equatable {
        /// Final bytes to attach (downsampled JPEG or pass-through original).
        case ready(Data)
        /// Oversize payload that could not be read as an image.
        case unreadable
        /// Oversize payload that was readable but could not be re-encoded.
        case downsampleFailed
        /// Small payload over the pixel budget whose re-encode failed; dropped silently.
        case dropped
    }

    /// Result of running the attachment pipeline, including the executor it ran on.
    struct AttachmentPipelineOutput {
        let preparation: AttachmentPreparation
        /// True iff preprocessing executed on the main thread. Must always be false;
        /// exposed for tests and diagnostics.
        let ranOnMainThread: Bool
    }

    /// Add an image to the pending attachments. Validates size and downsamples if needed.
    /// Decoding/downsampling runs off the main actor via ImageIO, so multi-megabyte
    /// photos never freeze the UI.
    func addImage(_ data: Data) async {
        let output = await Self.prepareAttachment(data)
        switch output.preparation {
        case .ready(let bytes):
            pendingImages.append(bytes)
            visionWarning = nil
        case .unreadable:
            visionWarning = "Could not read image data."
        case .downsampleFailed:
            visionWarning = "Image is too large and could not be resized."
        case .dropped:
            break // Legacy behavior: silently drop.
        }
    }

    /// Decode, validate, and downsample attachment data using ImageIO.
    ///
    /// Nonisolated async functions execute on the cooperative thread pool, never on
    /// the main thread, so full-resolution bitmaps are never materialized for the UI.
    nonisolated static func prepareAttachment(_ data: Data) async -> AttachmentPipelineOutput {
        let startedOnMainThread = isExecutingOnMainThread

        // Read pixel bounds without decoding the bitmap.
        let dimensions = Self.pixelDimensions(of: data)
        let exceedsPixelBudget = dimensions.map {
            $0.width > Int(Self.maxImageDimension) || $0.height > Int(Self.maxImageDimension)
        } ?? false

        let preparation: AttachmentPreparation
        if !exceedsPixelBudget && data.count <= Self.maxImageBytes {
            // Small enough already: attach as-is (matches legacy pass-through,
            // including undecodable payloads, which report no dimensions).
            preparation = .ready(data)
        } else if let cgImage = Self.downsampledCGImage(from: data, maxPixelSize: Int(Self.maxImageDimension)),
                  let jpeg = Self.jpegData(from: cgImage, quality: 0.8) {
            preparation = .ready(jpeg)
        } else if data.count > Self.maxImageBytes {
            preparation = dimensions == nil ? .unreadable : .downsampleFailed
        } else {
            preparation = .dropped
        }

        return AttachmentPipelineOutput(preparation: preparation, ranOnMainThread: startedOnMainThread)
    }

    /// Synchronous accessor avoids the async-context availability warning on
    /// `Thread.isMainThread` while still reporting the actually-executing thread.
    private nonisolated static var isExecutingOnMainThread: Bool { Thread.isMainThread }

    /// Create a thumbnail bounded by `maxPixelSize` on the long edge, preserving
    /// aspect ratio and baking in EXIF orientation. Returns nil when undecodable.
    private nonisolated static func downsampledCGImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Read pixel width/height from image metadata without decoding the bitmap.
    private nonisolated static func pixelDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Encode a CGImage as JPEG entirely in CoreGraphics (no UIKit round-trip).
    private nonisolated static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Remove an image at the specified index.
    func removeImage(at index: Int) {
        guard pendingImages.indices.contains(index) else { return }
        pendingImages.remove(at: index)
    }

    /// Clear all pending images.
    func clearImages() {
        pendingImages.removeAll()
        visionWarning = nil
    }

    /// Attempt to paste an image from the clipboard.
    /// Returns true if an image was found and added.
    @discardableResult
    func pasteImage() async -> Bool {
        guard UIPasteboard.general.hasImages,
              let image = UIPasteboard.general.image,
              let data = image.pngData() else {
            return false
        }
        await addImage(data)
        return true
    }

    /// Whether the currently selected model supports vision.
    var isVisionModel: Bool {
        selectedModel?.modelType == .vision
    }
}

// MARK: - Composer Focus + Draft Persistence (P2 items 6-8)

/// Composer chrome state, housed with the attachment pipeline (the composer's
/// other input state) to keep ChatViewModel.swift within the file-length
/// gate. Owns the shell-driven keyboard-resign token (P2-6) and the
/// per-conversation draft park/persist/restore cycle (P2-8). Reaches the
/// main file's stored draft/input state through internal (not private)
/// members; behavior is pinned hermetically in P2BatchTests.
extension ChatViewModel {
    /// Request the composer to resign keyboard/focus (P2-6). `reason` is a
    /// stable short tag (`openSidebar`, `selectConversation`,
    /// `newConversation`, `openRoute`) naming the navigation that covered the
    /// composer. Bumps `composerResignGeneration`, which ChatView observes to
    /// clear its `@FocusState`. The reason is logged with public privacy;
    /// only the generation counter is recorded.
    func requestComposerResign(reason: String) {
        composerResignGeneration &+= 1
        let generation = composerResignGeneration
        logger.info("Composer resign reason=\(reason, privacy: .public) generation=\(generation, privacy: .public)")
    }

    /// Suggestion-tap focus gate (P2-6): the field takes focus unless the
    /// message field is disabled (conversation-load, or no model at all).
    /// Typing stays enabled while the model loads, so model residency no
    /// longer refuses focus — requesting focus on the disabled field is
    /// ignored by the system but leaves the accent ring stuck on, so the
    /// refusal is the correct outcome — logged, never silent.
    func shouldTakeSuggestionFocus() -> Bool {
        let ready = !isLoadingConversation && modelLoadPhase != .needsDownload
        if !ready {
            logger.info("Suggestion focus refused: conversation loading")
        }
        return ready
    }

    /// Release-focus condition (P2-7): true exactly when the composer's
    /// enabled condition fails (conversation-load, or no model at all).
    /// ChatView releases `@FocusState` on this so a focused field never
    /// slides into disabled with the keyboard up or the accent ring stuck
    /// on. Pure over published state for hermetic tests.
    var composerShouldReleaseFocus: Bool {
        isLoadingConversation || modelLoadPhase == .needsDownload
    }

    /// Mirror the live composer text into the per-conversation memory store
    /// (P2-8). Called on every keystroke (via ChatView's
    /// `onChange(of: inputText)`), on conversation switches, and on
    /// backgrounding. Memory-only — the UserDefaults flush stays
    /// background/explicit-only so typing never pays I/O per keystroke.
    func parkCurrentDraft() {
        parkInputTextIntoMemory()
    }

    /// Background entry point (P2-8): park the live text, then flush the
    /// store so an OS kill still recovers every per-conversation draft.
    func noteBackgroundTransition() {
        parkInputTextIntoMemory()
        persistDraftsToDefaults()
    }

    /// Foreground entry point (P2-8): re-hydrate the memory store from
    /// UserDefaults (merge-only — live memory always wins), then restore the
    /// current context's draft into an *empty* composer. Never clobbers live
    /// typing. Idempotent: repeated foreground kicks converge.
    func noteForegroundTransition() {
        restoreDraftsFromDefaults()
        guard inputText.isEmpty else { return }
        if let id = activeConversationID {
            if let parked = draftStore[id], !parked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputText = parked
            }
        } else if !draftForNewChat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = draftForNewChat
        }
    }

    /// Test seam (P2-8): parked text for a conversation, nil when none/blank.
    func parkedDraft(for conversationID: UUID) -> String? {
        guard let parked = draftStore[conversationID],
              !parked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return parked
    }

    /// Test seam (P2-8): parked unsaved-draft text (empty when none).
    var parkedNewChatDraft: String { draftForNewChat }

    /// Shared park implementation (internal: used by the conversation
    /// switches in the main file): persisted conversations keep their UUID
    /// key; the unsaved draft (nil ID) lands in the new-chat slot instead of
    /// being dropped.
    func parkInputTextIntoMemory() {
        if let id = activeConversationID {
            draftStore[id] = inputText
        } else {
            draftForNewChat = inputText
        }
    }

    /// Flush non-blank drafts to UserDefaults (P2-8; internal: also flushed
    /// by explicit fresh-draft starts in the main file). Blanks remove their
    /// key so empty composers never linger in storage. Logs counts only —
    /// draft content is user text and never logged.
    func persistDraftsToDefaults() {
        let defaults = UserDefaults.standard
        let nonBlank = draftStore.filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if nonBlank.isEmpty {
            defaults.removeObject(forKey: DefaultsKeys.draftsByConversation)
        } else {
            defaults.set(
                Dictionary(uniqueKeysWithValues: nonBlank.map { ($0.key.uuidString, $0.value) }),
                forKey: DefaultsKeys.draftsByConversation
            )
        }
        if draftForNewChat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: DefaultsKeys.newChatDraft)
        } else {
            defaults.set(draftForNewChat, forKey: DefaultsKeys.newChatDraft)
        }
        let hasNewChat = draftForNewChat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        logger.info("Drafts persisted conversations=\(nonBlank.count, privacy: .public) newChat=\(hasNewChat, privacy: .public)")
    }

    /// Merge persisted drafts into memory (P2-8; internal: also hydrated at
    /// init in the main file): fills only keys absent from memory so live
    /// (fresher) state always wins within a session, while a fresh launch
    /// hydrates everything the previous run flushed.
    func restoreDraftsFromDefaults() {
        let defaults = UserDefaults.standard
        var restored = 0
        if let stored = defaults.dictionary(forKey: DefaultsKeys.draftsByConversation) {
            for (key, value) in stored {
                guard let id = UUID(uuidString: key),
                      let text = value as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      draftStore[id] == nil else { continue }
                draftStore[id] = text
                restored += 1
            }
        }
        if draftForNewChat.isEmpty,
           let newChat = defaults.string(forKey: DefaultsKeys.newChatDraft),
           !newChat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftForNewChat = newChat
            restored += 1
        }
        if restored > 0 {
            logger.info("Drafts restored count=\(restored, privacy: .public)")
        }
    }
}
