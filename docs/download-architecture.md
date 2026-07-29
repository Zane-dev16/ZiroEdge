# Download Architecture — Staging, Promotion, Durable State

Architecture-level documentation of the download pipeline's transactional mechanics.
Every mechanism described here is implemented and verified by named regression tests.

---

## 1. Directory Layout

```
Application Support/ZiroEdge/Models/
├── staging/              # In-progress downloads (partial files)
├── resume/               # Resume data + durable metadata
├── quarantine/           # Files that failed validation (preserved for diagnosis)
├── <model-id>.gguf       # Installed base model
├── <model-id>-mmproj.gguf # Installed multimodal projector
└── .repair-needed-<id>   # Repair marker (set when validation fails)
```

**Legacy migration:** `ModelMigrationService` moves artifacts from `Documents/Models/`
to the managed layout above. See `ModelMigrationTests` for coverage.

---

## 2. Staging Pipeline

### 2.1 Staging URL

Each `DownloadTask` has a `stagingURL`:
```
staging/<storageID>.partial
```
Where `storageID` is `base-<baseArtifactStorageID>` for base artifacts and
`mmproj-<model.id>` for projector artifacts.

### 2.2 Streaming (sub-2 GiB)

1. `URLSessionDownloadTask` downloads to a temporary location
2. `didFinishDownloadingTo:` validates the HTTP response via `DownloadTransportValidator`
3. On validation success, the temporary file is moved to `stagingURL`
4. `verifyAndPromoteOffMain` is called

### 2.3 Chunked (2+ GiB)

1. `resumableChunkOffset` determines the starting byte, truncating to chunk alignment
2. A new `FileHandle` is opened for writing at the staging URL
3. Each chunk sends an HTTP Range request: `bytes=<start>-<end>`
4. The `didReceive response` callback validates Content-Range against expected range
5. `didReceive data` writes each chunk body through the file handle, tracking `chunkBytesReceived`
6. `didCompleteWithError` triggers chunk completion or retry
7. After all chunks complete, `finishChunkedDownload` closes and synchronizes the handle,
   then calls `verifyAndPromoteOffMain`

### 2.4 Transport Validation

`DownloadTransportValidator.failure(response:bodyURL:expectedBytes:expectedOffset:)`
runs before SHA-256:

- HTTP 200-299: pass
- HTTP 401/403: `.authorizationRequired` (triggers canonical fallback)
- Other status codes: `.httpStatus`
- Content-Range validation for resume downloads (offset must match)
- Textual response detection (catches auth pages, error messages masquerading as 200 OK)
- GGUF header check on downloaded body
- File size verification

**Regression tests:** `DownloadTransportValidator` tests in `DownloadManagerTests`

---

## 3. Atomic Promotion

`DownloadManager.promoteAtomically(_:)` replaces the installed artifact with the
verified staging file without a window where no valid artifact exists.

### 3.1 Mechanism

1. If no existing destination: `FileManager.moveItem` (atomic on APFS within same volume)
2. If destination exists:
   a. Creates a backup: `<name>.promotion-backup`
   b. Calls `FileManager.replaceItemAt(_:withItemAt:backupItemName:options:)`
      with `.usingNewMetadataOnly`
   c. On success: removes the backup
   d. On failure:
      - If destination was lost and backup exists, restores backup to destination
      - Re-throws the error

### 3.2 Crash Recovery

`reconcileInterruptedPromotions()` runs on every `DownloadManager.init`:

- Iterates all model artifacts
- For each `.promotion-backup` file found:
  - Validates the current destination via `artifactValidationIssues`
  - If destination is valid: discards backup
  - If destination is invalid but backup is valid: restores backup

**Regression tests:** `InjectedPromotionFailurePreservesVerifiedInstallationByteForByte`,
`StoreRecoveryTests.testQuarantineCopiesExistingSQLiteTrioByteForByte`

---

## 4. Durable Transfer State

`DurableTransferState.swift` implements the persistence layer for resumable transfers.

### 4.1 Snapshot Format

```swift
struct DurableTransferSnapshot: Codable {
    let version: Int          // Schema version (currently 1)
    let modelID: String
    let artifact: String      // "base" or "mmproj"
    let expectedBytes: Int64
    let progress: Double      // 0.0 ... 1.0, clamped
    let resumeAvailable: Bool // Resume data or staging file exists
    let failed: Bool          // Failed vs. user-paused
}
```

Each snapshot is written atomically to `resume/<storageID>.json`.

### 4.2 Persistence Points

- **Download start:** `persistDurableState(for:)` in `startArtifactDownload`
- **Pause:** `persistDurableState(for:)` after resume data is written
- **Chunk completion:** `persistDurableState(for:)` after each chunk
- **Failure:** `persistDurableState(for:failed:true)` on errors
- **Stuck watchdog retry:** no explicit persist (task remains in activeTasks)

### 4.3 Restoration

`restoreDurableTransfers()` runs on `DownloadManager.init`:

1. Iterates all model artifacts
2. Reads `<storageID>.json` from `resume/`
3. Validates snapshot version, model ID, artifact, expected bytes match
4. Confirms resume data or staging file exists
5. Restores `progress`, `isPaused`, `isChunked`, `totalChunks`
6. Sets state to `.paused(progress:)` or `.failed(error: .networkError)`
7. Inserts restored task into `activeTasks`

**Corrupt metadata:** Automatically removed with staging data, leaving a clean
`notDownloaded` state.

### 4.4 Removal

`removeDurableState(for:discardStaging:)` deletes metadata JSON, resume data,
and optionally the staging file. Called on cancel, promotion success, and
verification failure.

**Regression tests:** `RecreationRestoresPausedProgressWithoutStartingTransfer`,
`CorruptMetadataDegradesToRestartableState`

---

## 5. Reconciliation

Two reconciliation passes run on every `DownloadManager.init`.

### 5.1 Interrupted Promotions

`reconcileInterruptedPromotions()` (see Section 3.2).

### 5.2 Background Task Reconciliation

`reconcileBackgroundTasks()` re-attaches to in-flight `URLSessionDownloadTask`
instances that survived app termination:

- Queries the background URLSession for all tasks via `getAllTasks`
- Matches system tasks to `activeTasks` entries by `taskDescription`
- Cancels unmatched system tasks
- Re-attaches matched tasks, clearing `isPaused` and setting state to `.downloading`

### 5.3 Background Session Event Drain

`ZiroEdgeAppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`
retains the completion handler in `BackgroundDownloadCompletionStore`.
`urlSessionDidFinishEvents(forBackgroundURLSession:)` drains and invokes it.

---

## 6. Background Restoration

### 6.1 URLSession Configuration

Non-test sessions use `URLSessionConfiguration.background(withIdentifier:)` with:
- `isDiscretionary = false`
- `sessionSendsLaunchEvents = true`
- `timeoutIntervalForRequest = 300`
- `waitsForConnectivity = true`

### 6.2 App Delegate Integration

`ZiroEdgeAppDelegate` (in `BackgroundDownloadLifecycle.swift`) conforms to
`UIApplicationDelegate` and handles `handleEventsForBackgroundURLSession`.

### 6.3 Chunk Session

Chunked downloads use a separate `URLSessionConfiguration.default` session
(`_chunkSession`) because background sessions do not support data tasks.
Chunk progress is durable (staging file persists each chunk), so a terminated
chunked download resumes from the last committed chunk on next launch.

**Regression tests:** `RecreationRestoresPausedProgressWithoutStartingTransfer`
(validates the full pause→cold-start→restore cycle)

---

## 7. Model Artifact Verifier

`ModelArtifactVerifier.failure(fileURL:expectedBytes:expectedSHA256:)` is a
static, synchronous function designed for detached task execution:

- **Buffer size:** 64 KiB (verified by `BoundedVerificationTests`)
- **Checks in order:** SHA-256 format validity → file size → GGUF header → SHA-256 hash
- **Cancellation:** Checks `Task.isCancelled` between each 64 KiB read
- **Off-main guarantee:** Called via `Task.detached(priority: .utility)`

### 7.1 Catalog Validation

`ModelCatalogValidator.catalogFailureReason(models:)` validates all registered
models before any download starts:

- Every model must have a valid SHA-256 (lowercase 64-hex string)
- Missing or invalid metadata returns `.invalidCatalogMetadata`, blocking all downloads

**Regression tests:** `EveryCatalogArtifactHasDownloadIntegrityMetadata`,
`CatalogValidatorRejectsSignedAndIncompleteEntries`,
`MissingCatalogMetadataIsUnavailableWithoutCrashing`,
`MissingIntegrityMetadataFailsClosed`
