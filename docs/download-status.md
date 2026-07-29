# Download & Verification Status — Superseding Prior Completion Claims

**Date:** 2026-07-28
**Issue:** DOWNLOAD-SPEC-RELEASE-GATES (#17)

---

## Previously Overstated Completion Superseded

### Offline Verification (Issue #009)

**Prior status:** Marked "✅ Done" in PROGRESS.md.

**Actual status:** The offline verification test suite (OfflineVerificationTests) passes
in the iOS Simulator (239 tests, 0 failures, 2026-07-24). However, the following
acceptance criteria were unchecked when Issue #009 was closed:

1. **Physical-device offline proof:** Simulator evidence does not replace
   physical-device durability evidence. RELEASE-VALIDATION.md explicitly notes:
   "Not verified locally — Physical-device disk pressure and process-kill durability."
   Physical-device lifecycle QA is tracked as Issue #16.

2. **Airplane Mode relaunch:** `TestRelaunchInAirplaneModeShowsExistingConversations`
   and `TestColdStartShowsExistingConversationsAndCanLoadModel` pass in simulator
   but are not verified on hardware.

3. **Cellular→Wi-Fi handoff:** Not covered by simulator tests. Tracked by Issue #16.

**Superseding:** Issue #009 is reopened as incomplete until physical-device evidence
is produced. The following named regression tests must pass on a physical device:

- `TestRelaunchInAirplaneModeShowsExistingConversations`
- `TestColdStartShowsExistingConversationsAndCanLoadModel`
- `TestStreamingWorksOffline`
- `TestVerifiedFixtureIsAvailableOffline`
- `TestChatWorksOffline`
- `DownloadStatusCheckUsesFileManagerOnly`
- `SHA256VerificationIsLocal`
- `NetworkMonitorDoesNotAffectLocalOperations`

### SHA-256 Verification on Fresh Download (Issue #013)

**Prior status:** Marked "🔲 Pending" in PROGRESS.md.

**Actual status:** SHA-256 verification is implemented and tested:
- `ModelArtifactVerifier.failure(fileURL:expectedBytes:expectedSHA256:)` performs
  buffered 64 KiB SHA-256 verification off the main thread.
- `ModelArtifactVerificationTests` covers hash mismatch, size mismatch, GGUF header,
  and catalog integrity.
- `BoundedVerificationTests` verifies large generated fixtures with a 64 KiB buffer constraint.

**Superseding:** SHA-256 verification code and production catalog metadata are complete.
Release Gate 1 passes metadata validation and remains fail-closed for incomplete future
entries. Release Gate 2 still requires clean-source downloads and hashes for every
multi-gigabyte production artifact.

### Download Pause & Resume (Issues #7, #8, #9)

**Actual status:** Fully implemented and tested:
- Pause: `DownloadManager.pauseDownload(for:)` with graceful URLSession cancel +
  resume data preservation + durable state persistence.
- Resume: `resumeArtifactDownload(model:artifact:)` with resume-data-first strategy
  and canonical-URL fallback.
- Cold-start restore: `restoreDurableTransfers()` in `DownloadManager.init`.

**Named regression tests:**
- `StateTransitionDownloadingToPaused`
- `ModelDownloadStatusPreservesPausedProgress`
- `RecreationRestoresPausedProgressWithoutStartingTransfer`
- `CorruptMetadataDegradesToRestartableState`
- `StateTransitionFailedToDownloading`

---

## Current Completion Status

| Requirement | Code | Tests | Docs | Physical QA |
|-------------|------|-------|------|-------------|
| Pause | ✅ | ✅ | ✅ | 🔲 Issue #16 |
| Cancel | ✅ | ✅ | ✅ | 🔲 Issue #16 |
| Resume fallback | ✅ | ✅ | ✅ | 🔲 Issue #16 |
| Paired-artifact readiness | ✅ | ✅ | ✅ | 🔲 Issue #16 |
| Verification (SHA-256) | ✅ | ✅ | ✅ | ✅ Simulator |
| Repair | ✅ | ✅ | ✅ | 🔲 Issue #16 |
| Termination | ✅ | ✅ | ✅ | 🔲 Issue #16 |
| Staging | ✅ | ✅ | ✅ | 🔲 Issue #16 |
| Atomic promotion | ✅ | ✅ | ✅ | ✅ |
| Durable state | ✅ | ✅ | ✅ | ✅ |
| Reconciliation | ✅ | ✅ | ✅ | ✅ |
| Background restoration | ✅ | ✅ | ✅ | 🔲 Issue #16 |
| Transport fixtures | ✅ | ✅ | ✅ | N/A (test-only) |
| Isolated model dirs | ✅ | ✅ | ✅ | N/A (test-only) |
| Catalog verification | ✅ Metadata | ✅ | ✅ | 🔲 Clean-source downloads |
| Legacy repair | ✅ | ✅ | ✅ | ✅ |
| Offline proof | ⚠️ Simulator-only | ✅ | ✅ | 🔲 Issue #16 |

**Legend:** ✅ Complete | ⚠️ Partially complete | 🔲 Pending | ❌ Blocked
