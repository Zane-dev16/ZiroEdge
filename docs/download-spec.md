# Download Specifications — Product Contract

Product-level behavioral contract for model downloads. Every assertion is backed by implemented code and verified by named regression tests.

---

## 1. Paired-Artifact Downloads

Vision models require two artifacts: a base GGUF and a multimodal projector (mmproj).
Text models require only the base GGUF. `AIModel.requiresMMProj` gates the second artifact.

### Capability Readiness

| State | Base GGUF | mmproj GGUF | `isReady` | `isVisionReady` |
|-------|-----------|-------------|-----------|-----------------|
| Not downloaded | missing | missing | false | false |
| Text-ready | verified | — | true | N/A |
| Vision: base only | verified | missing | false | false |
| Vision: mmproj only | missing | verified | false | false |
| Vision: both | verified | verified | true | true |
| Vision: base + text-only flag | verified | missing | true | false |

**Regression tests:** `ModelDownloadStatusReady`, `ModelDownloadStatusVisionReady`,
`OptionalVisionProductIsTextReadyWithBaseButNotVisionReady`,
`VisionModelWithOnlyValidBaseIsNotInstalled`, `VisionModelWithOnlyValidMMProjIsNotInstalled`,
`VisionModelDownloadStatusBothNeeded`, `VisionModelDownloadStatusBothReady`,
`E2BBaseOnlyExposesOneTextRuntimeAndDisablesVision`

Models with `allowsTextOnlyCapability` report as text-ready when base is verified even
without the mmproj artifact.

---

## 2. Pause

`DownloadManager.pauseDownload(for:)` triggers graceful pause of both artifacts.

**Mechanism:**
1. Sets `task.isPaused = true`, transitions state to `.pausing(progress:)`
2. **Chunked transfers:** Cancels the current chunk data task, closes and synchronizes
   the staging file handle, persists durable state, transitions to `.paused(progress:)`
3. **Streaming transfers:** Calls `URLSessionDownloadTask.cancel(byProducingResumeData:)`.
   On success, writes resume data to `resume/` directory atomically, persists
   durable state, transitions to `.paused(progress:)`. On failure (empty resume data),
   falls back to `.failed(error: .networkError)` with durable failure state.

**Durable guarantee:** Every pause persists a `DurableTransferSnapshot` (model ID,
artifact, progress, resume availability, expected bytes, version). A subsequent
cold start restores the paused state without starting any transfer.

**Regression tests:** `StateTransitionDownloadingToPaused`,
`ModelDownloadStatusPreservesPausedProgress`,
`RecreationRestoresPausedProgressWithoutStartingTransfer`

---

## 3. Cancel

`DownloadManager.cancelDownload(for:)` terminates all active transfers immediately.

**Mechanism:**
1. Sets `task.isCancelled = true`
2. Cancels the URLSession task and any active chunk data task
3. Cancels any in-flight verification `Task`
4. Closes the chunk file handle
5. Transitions state to `.cancelled`
6. Removes ALL durable state (metadata JSON, resume data, staging file)
7. Removes task from `activeTasks` dictionary

A cancelled download leaves no partial state on disk. The next `startDownload` call
begins from zero.

**Regression tests:** `DownloadStateCancelledProperties`, `CleanupPartialFiles`,
`CleanupPartialFilesMMProj`, `CleanupIsIdempotent`

---

## 4. Resume Fallback

`DownloadManager.resumeDownload(for:)` attempts to restore from durable state first.

**Mechanism:**
1. If a task exists in `activeTasks` with `.paused` or `.failed(error: .networkError)` state,
   clears the paused/cancelled flag and transitions to `.resuming(progress:)`.
2. **Chunked transfers:** Resumes from the last committed chunk offset.
   Staging bytes below the chunk boundary are preserved.
3. **Streaming transfers:** Uses `resumeData` (from memory or `resume/` directory)
   to create a `downloadTask(withResumeData:)`. Falls back to `downloadTask(with:)`
   if no resume data is available.
4. If no active task exists, delegates to `startArtifactDownload` as a fresh start.

**Canonical fallback:** If a resumed streaming download fails with authorization,
range, or content-rejection errors and resume data exists, the manager retries
exactly once from the canonical (non-redirected) source URL via
`retryOnceFromCanonicalURL(_:key:)`. This handles expired signed CDN URLs.
The canonical retry flag ensures only one fallback attempt.

**Regression tests:** `StateTransitionFailedToDownloading`,
`StateTransitionDownloadingToFailed`

---

## 5. Verification

Every completed download is verified before promotion.

**Checks (in order):**
1. SHA-256 metadata validity (must be lowercase 64-hex, non-empty)
2. File size matches `expectedBytes`
3. GGUF header: magic bytes `GGUF` (0x47 0x47 0x55 0x46) plus version field
4. Full SHA-256 hash of file contents via `CryptoKit.SHA256` with 64 KiB buffer

**Off-main execution:** Chunked downloads verify via `Task.detached(priority: .utility)`,
confirming `Thread.isMainThread == false`. Streaming downloads verify synchronously
on the delegate callback (already off-main from URLSession).

**Failure behavior:**
- Validation failures discard staging data (except disk-space failures, which preserve it)
- State transitions to `.failed(error:)` with the specific error
- Catalog metadata failures (missing/invalid SHA-256) are rejected before download starts

**Regression tests:** `LargeGeneratedFixtureVerifiesOffMainWith64KiBBuffer`,
`AuthenticationBodyAtBothGemmaDestinationsIsNotInstalled`,
`ValidLengthWithWrongSHA256NeedsRepair`, `CorrectSHA256WithWrongByteCountNeedsRepair`,
`PromotionRejectsStructurallyInvalidGGUFBeforeHashing`,
`PromotionRejectsMissingSHA256`, `SHA256MetadataMustBeLowercase64Hex`

---

## 6. Repair

Models that have partial or corrupted artifacts enter a repair-needed state.

**Detection:** `ModelManagerService.availability(for:)` returns `.repairNeeded(issues:)`
when any artifact exists on disk but fails validation.

**Auto-cleanup:** `isBaseDownloaded` and `isMMProjDownloaded` automatically delete
files that fail GGUF header validation or size checks. This prevents corrupted
artifacts from accumulating.

**`ModelDownloadStatus.isRepairNeeded`:**
- `true` when any artifact file exists but `isReady` is `false`
- `true` when `availability(for:)` returns `.repairNeeded`
- `false` when no files exist (clean `notDownloaded` state) or all artifacts pass

**Repair action:** `DownloadManager.startDownload(for:)` treats `repairNeeded`
models like `notDownloaded` — it initiates a fresh download which, after successful
verification and promotion, calls `ModelManagerService.clearRepairNeeded(for:)`.

**Regression tests:** `ValidLengthWithWrongSHA256NeedsRepair`,
`CorrectSHA256WithWrongByteCountNeedsRepair`,
`AuthenticationBodyAtBothGemmaDestinationsIsNotInstalled`,
`VisionModelWithOnlyValidBaseIsNotInstalled`, `VisionModelWithOnlyValidMMProjIsNotInstalled`,
`SameSizeWrongDigestBaseRequiresFullReplacement`,
`SameSizeWrongDigestProjectorRequiresFullReplacement`

---

## 7. Termination Behavior

**Cancel (user-initiated):** See Section 3. Removes all state.

**Delete model:** `DownloadManager.deleteModel(_:)` cancels active downloads, deletes
installed model files via `ModelManagerService.deleteModel`, removes resume data,
and refreshes disk status. Shared base artifacts (E2B text and vision share one base
GGUF) are preserved when another model identity still references them.

**Deinit:** The `DownloadManager.deinit` cancels chunk sessions and invalidates the
stuck-timer watchdog. In tests, the background URLSession is invalidated.

**Background termination:** The background URLSession (`sessionSendsLaunchEvents = true`)
survives app termination. On relaunch, `reconcileBackgroundTasks()` re-attaches to
in-flight system tasks and `handleEventsForBackgroundURLSession` drains the
completion handler.

**Crash during promotion:** `reconcileInterruptedPromotions()` runs on every
`DownloadManager.init`. If a `.promotion-backup` file exists, it checks whether the
current destination is valid. If valid, the backup is discarded. If the destination
is invalid but the backup is valid, the backup is restored.

**Regression tests:** `InjectedPromotionFailurePreservesVerifiedInstallationByteForByte`,
`DeleteModelClearsStatus`, `DeletingE4BTextPreservesBaseUsedByVision`,
`DeletingE4BVisionPreservesBaseUsedByTextAndDeletesProjector`

---

## 8. Stuck-Transfer Watchdog

A 30-second repeating timer (`stuckTimer`) monitors non-chunked downloads. If any
`.downloading` task has not reported progress for 120 seconds, the task is cancelled
and a retry is scheduled after a 2-second delay via `startArtifactDownload`.

Chunked downloads have their own retry mechanism (Section 9).

---

## 9. Chunked Download Resilience

Downloads exceeding 2 GiB use HTTP Range requests in 100 MiB chunks.

- Up to 3 retries per chunk (exponential backoff: 2s, 4s, 6s)
- Chunk-level validation: Content-Range header must match expected range
- Byte-exact boundary tracking: partial chunks are truncated to chunk alignment
- Staging file is synchronized after each successful chunk
- Failed chunks preserve all previously committed staging bytes
