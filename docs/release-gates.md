# Release Gates — Download & Model Integrity

Release gates that MUST pass before a build can be shipped. Each gate is automated
or has a defined verification procedure. A gate that fails blocks the release.

---

## Gate 1: Catalog Hash Completeness

**Requirement:** Every model in `ModelRegistry.allModels` must have a valid
SHA-256 hash (lowercase 64-character hex string) and a non-zero file size.

**Check:**
```bash
python3 -m unittest discover -s Scripts/Tests -p 'test_verify_model_catalog.py'
```

**Automated test:** `EveryCatalogArtifactHasDownloadIntegrityMetadata`

**Failure mode:** Any model with missing, invalid, or placeholder SHA-256 →
`ModelCatalogValidator.catalogFailureReason` returns non-nil → all downloads
are blocked with `.invalidCatalogMetadata`.

**Production status (2026-07-28):** Every production artifact has a canonical
HTTPS GGUF URL, positive byte size, and authoritative lowercase SHA-256. The
metadata validator passes and remains fail-closed for incomplete future entries.

**Regression test:** `CatalogValidatorRejectsSignedAndIncompleteEntries`

---

## Gate 2: Clean-Download Verification

**Requirement:** A fresh download of every registered model must pass:
1. HTTP transport validation (status, content type, body structure)
2. GGUF header check (magic + version)
3. File size match
4. Full SHA-256 verification (64 KiB buffer, off-main thread)

**Check:**
```bash
python3 Scripts/verify-model-catalog.py
```

**Automated tests:**
- `LargeGeneratedFixtureVerifiesOffMainWith64KiBBuffer`
- `PromotionRejectsStructurallyInvalidGGUFBeforeHashing`
- `PromotionRejectsMissingSHA256`

**Failure mode:** Any verification step fails → download state is `.failed(error:)`
with specific error. Staging data is discarded (except for disk-space failures).

**Note:** This gate requires network access to download actual model files.
Simulator tests use deterministic fixtures; physical-device tests use real downloads.

---

## Gate 3: Legacy Repair

**Requirement:** Models installed before the managed-directory migration
(`Documents/Models/`) must be migrated without data loss and without false
installation claims.

**Automated tests:**
- `ValidLegacyPairMovesIntoManagedInstalledLibrary` — valid pair migrates cleanly
- `MixedValidityPairInstallsOnlyValidArtifactAndMarksRepair` — partial validity handled
- `ResumeOnlyLegacyStateMovesToResumeLocation` — resume data preserved
- `OrphanedStagingDataMovesToManagedStagingLocation` — orphaned staging migrated
- `AbsentLegacyStorageCreatesCurrentMarkerAndIsIdempotent` — clean first run
- `InterruptedMigrationRecoversAfterPriorMoveCompleted` — crash during migration
- `ManagedLocationsAreDistinctAndBackupExcluded` — directory hygiene

**Failure mode:** Any migration test failure → `ModelMigrationService` cannot
guarantee data integrity for legacy users. Release blocked.

---

## Gate 4: Lifecycle QA

**Requirement:** The complete download lifecycle must pass on a physical device:
1. Fresh install → download model → verify → chat
2. Pause during download → resume → verify → chat
3. Cancel download → restart → verify → chat
4. Background during download → foreground → verify
5. Force-quit during download → relaunch → resume from durable state → verify
6. Low storage → download refused → existing models preserved
7. Airplane Mode → existing models still available → can chat

**Check:** `Scripts/device-test.sh` with the download lifecycle layer.

**Dependency:** This gate is covered by [Issue #16: Complete model-download device lifecycle QA](https://github.com/Zane-dev16/ZiroEdge/issues/16).

**Evidence required:** Logs, screenshots, and assertions covering each lifecycle
scenario. No model is reported installed unless all required artifacts are verified.

**Regression tests:**
- `RecreationRestoresPausedProgressWithoutStartingTransfer` (cold start)
- `CorruptMetadataDegradesToRestartableState` (graceful degradation)
- `InjectedPromotionFailurePreservesVerifiedInstallationByteForByte` (crash safety)
- `TestRelaunchInAirplaneModeShowsExistingConversations` (offline after relaunch)
- `TestColdStartShowsExistingConversationsAndCanLoadModel` (cold start)

---

## Gate 5: Offline Proof

**Requirement:** After models are downloaded, the app MUST operate with zero
network dependency in the hot path:
1. Model loading: no network calls
2. Inference: no network calls
3. Conversation persistence: no network calls
4. Model status checks: `FileManager` only
5. Onboarding: `UserDefaults` only

**Automated tests (OfflineVerificationTests):**
- `DownloadStatusCheckUsesFileManagerOnly`
- `IsBaseDownloadedUsesVerifiedLocalFixture`
- `SHA256VerificationIsLocal`
- `ModelManagerServiceUsesOnlyFileManager`
- `ModelManagerServiceDirectoryIsLocal`
- `InferenceServiceProtocolHasNoNetworkMethods`
- `StreamChatReturnsLocalAsyncStream`
- `NetworkMonitorDoesNotAffectLocalOperations`
- `TestRelaunchInAirplaneModeShowsExistingConversations`
- `TestColdStartShowsExistingConversationsAndCanLoadModel`
- `TestStreamingWorksOffline`
- `TestVerifiedFixtureIsAvailableOffline`
- `TestChatWorksOffline`

**Check:**
```bash
xcodebuild test -project ZiroEdge.xcodeproj -scheme ZiroEdge \
  -only-testing:ZiroEdgeTests/OfflineVerificationTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

**Failure mode:** Any test that triggers a network call in the hot path is a
release blocker. The offline verification suite must pass with 0 failures.

**Status note:** The offline verification suite passes in the simulator (see
RELEASE-VALIDATION.md). Physical-device offline proof is tracked by Issue #16.

---

## Gate 6: Durable State Integrity

**Requirement:** Paused and failed transfers must survive app termination,
relaunch, and device reboot without corruption or false state.

**Automated tests:**
- `RecreationRestoresPausedProgressWithoutStartingTransfer`
- `CorruptMetadataDegradesToRestartableState`

**Failure mode:** Corrupt durable state must not prevent the app from functioning.
It must degrade to a clean `notDownloaded` state.

---

## Gate 7: Atomic Promotion Safety

**Requirement:** A crash during artifact promotion must not leave the model
in an unverifiable state. Either the old verified artifact or the new verified
staging file must survive.

**Automated tests:**
- `InjectedPromotionFailurePreservesVerifiedInstallationByteForByte`
- `StoreRecoveryTests.testQuarantineCopiesExistingSQLiteTrioByteForByte`

**Failure mode:** Loss of both old and new artifact during promotion is a
release blocker.

---

## Gate Execution Order

```
Gate 1 (Catalog Hashes) ──┐
                           ├── Must pass before any download
Gate 2 (Clean Download)  ──┘
                           │
Gate 3 (Legacy Repair)   ──┤── Must pass before release
Gate 6 (Durable State)   ──┤
Gate 7 (Atomic Promotion) ──┤
                           │
Gate 4 (Lifecycle QA)    ──┤── Requires physical device (Issue #16)
                           │
Gate 5 (Offline Proof)   ──┘
```

---

## Current Gate Status (2026-07-28)

| Gate | Status | Blocker |
|------|--------|---------|
| 1. Catalog Hashes | ✅ Passing | Production metadata validation passes |
| 2. Clean Download | ⚠️ Metadata-only | Clean-source multi-GB download verification remains pending |
| 3. Legacy Repair | ✅ Passing | All migration tests pass |
| 4. Lifecycle QA | 🔲 Pending | Blocked by Issue #16 |
| 5. Offline Proof | ⚠️ Simulator-only | Physical-device evidence pending (Issue #16) |
| 6. Durable State | ✅ Passing | DurableTransferStateTests pass |
| 7. Atomic Promotion | ✅ Passing | Promotion crash-safety verified |
