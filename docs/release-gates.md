# Release Gates — Download & Model Integrity

Release gates that MUST pass before a build can be shipped. Each gate is
automated or has a defined verification procedure. A gate that fails blocks
the release.

**Automated checker:** Run `bash Scripts/release-gate-check.sh --evidence-root docs/release-evidence`
for a single verdict and structured gate checklist.

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

**Status:** Every production artifact has a canonical HTTPS GGUF URL, positive
byte size, and authoritative lowercase SHA-256. The metadata validator passes
and remains fail-closed for incomplete future entries. The current catalog
contains SHA-256 digests at `AIModel.swift:207`.

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
python3 Scripts/verify-model-catalog.py --evidence docs/release-evidence/catalog-verification.json
```

**Automated tests:**

- `LargeGeneratedFixtureVerifiesOffMainWith64KiBBuffer`
- `PromotionRejectsStructurallyInvalidGGUFBeforeHashing`
- `PromotionRejectsMissingSHA256`

**Failure mode:** Any verification step fails → download state is `.failed(error:)`
with specific error. Staging data is discarded (except for disk-space failures).

**Note:** This gate requires network access to download actual model files (~11.5 GB).
Simulator tests use deterministic fixtures; physical-device tests use real downloads.
`--metadata-only` is explicitly insufficient for Gate 2.

---

## Gate 3: Legacy Repair

**Requirement:** Models installed before the managed-directory migration
(`Documents/Models/`) must be migrated without data loss and without false
installation claims.

**Automated tests:**

- `ValidLegacyPairMovesIntoManagedInstalledLibrary`
- `MixedValidityPairInstallsOnlyValidArtifactAndMarksRepair`
- `ResumeOnlyLegacyStateMovesToResumeLocation`
- `OrphanedStagingDataMovesToManagedStagingLocation`
- `AbsentLegacyStorageCreatesCurrentMarkerAndIsIdempotent`
- `InterruptedMigrationRecoversAfterPriorMoveCompleted`
- `ManagedLocationsAreDistinctAndBackupExcluded`

**Retained evidence rule:** Gate 3 passes only when the canonical automated iOS
evidence at `docs/release-evidence/automated-ios/evidence.json` identifies the
current clean build revision, exact xcodebuild command, immutable retained
xcresult archive path and matching SHA-256, and an individual passing
`ModelMigrationTests` outcome. A generic aggregate exit code or mutable xcresult
directory hash is insufficient.

**Failure mode:** Any migration test failure or missing retained named-suite
evidence → release blocked.

---

## Gate 4: Privacy Policy Published

**Requirement:** The privacy policy page must be publicly reachable at the
canonical URL published in the app and `AppStore/listing-metadata.json`.

**Check:**

```bash
python3 Scripts/verify-privacy-policy.py          # live check
python3 Scripts/verify-privacy-policy.py --local-only  # local content check
```

**Failure mode:** 404 or unreachable → release blocked. Live reachability is
fail-closed; 404 is not downgraded to a warning.

---

## Gate 5: Submission Screenshots

**Requirement:** All required App Store screenshot sizes must have technically
valid images and authorized human visual approval of review-ready real-app chat,
models, and settings content, with iPad chat proving split view.

**Check:**

```bash
bash Scripts/capture-app-store-screenshots.sh
bash Scripts/capture-appstore-screenshots.sh
python3 Scripts/verify-screenshots.py ziroedge-docs/app-store-screenshots
```

**Failure mode:** Any size missing images, failed technical validation, missing
authorized human visual approval, hermetic/placeholder content, or misleading
model state → release blocked. Technical validation alone is not review-ready
evidence. The current manifest is retained as provenance only.

---

## Gate 6: Background Download Lifecycle (Issue #06)

**Requirement:** On a physical device, an in-progress model download must
preserve truthful state and recover safely across backgrounding, suspension,
locking, OS termination, force-quit, and reboot.

**Check:**

```bash
bash Scripts/device-test.sh --layer lifecycle --evidence-dir docs/release-evidence/lifecycle
```

**Evidence required:**

- Machine-generated: device identifier/name, OS, build revision, catalog version,
  invoked command, exit status, xcresult hash, screenshot hashes.
- Operator-entered observations for steps XCTest cannot prove (Airplane Mode,
  lock/unlock, reboot, radio handoff, storage pressure). Every required scenario
  must have exactly one `[time] scenario — PASS — specific result` line; mention,
  `FAIL`, `PENDING`, and free-form presence alone never pass.
- UI tests and every layer-required unit suite must exit zero, identify the
  current clean source revision, and retain immutable xcresult archives whose
  recorded SHA-256 values verify.

**Lifecycle unit suites:** The lifecycle layer runs the seven real test classes
in `ZiroEdgeTests/DeviceLifecycleQATests.swift` individually —
`FreshInstallLegacyUpgradeTests` (10), `NetworkConditionTests` (9),
`BackgroundLifecycleQATests` (8), `StorageConstraintQATests` (10),
`PauseResumeQATests` (7), `EvidenceArtifactQATests` (9), and
`EndToEndLifecycleQATests` (6), 59 tests total — each with its own retained
xcresult archive. The harness maps real class names only; a suite name matching
no test class is a harness error and the layer fails closed instead of
reporting a vacuous pass.

**Fail-closed exit behavior:** `device-test.sh --layer lifecycle` exits nonzero
until a human records exactly one explicit PASS observation per required
scenario (`background-suspension`, `lock-unlock`, `os-termination`,
`force-quit`, `reboot`). A run without operator observations therefore exits
nonzero even when all 59 unit tests and the UI stage pass; that nonzero exit is
expected and correct while the gate is incomplete.

**Regression tests:**

- `RecreationRestoresPausedProgressWithoutStartingTransfer`
- `CorruptMetadataDegradesToRestartableState`
- `InjectedPromotionFailurePreservesVerifiedInstallationByteForByte`

---

## Gate 7: Offline Operation — E2B/E4B (Issue #07)

**Requirement:** Installed E2B and E4B models must remain discoverable, loadable,
and usable for advertised capabilities with network access disabled on a
physical device.

**Check:**

```bash
bash Scripts/device-test.sh --layer offline --evidence-dir docs/release-evidence/offline
```

**Named E2B/E4B offline tests** (fail, do not skip, when physical-device layer
requires those models):

- Airplane Mode launch shows only models with complete artifacts passing
  current readiness checks.
- E2B and E4B each load and produce a text response while offline.
- Vision-ready installs expose correct capability and complete an offline
  image interaction.
- Invalid model pairs do not appear ready and provide recovery feedback.
- Existing conversation history remains usable without network access.

**Offline unit suites:** The offline layer runs the nine real test classes in
`ZiroEdgeTests/OfflineVerificationTests.swift` and
`ZiroEdgeTests/OfflineAvailabilityGuardTests.swift` individually —
`ChatSessionCancellationTests` (2), `OfflineModelLoadingTests` (6),
`OfflineConversationPersistenceTests` (9), `OfflineInferencePathTests` (5),
`OfflineOnboardingTests` (3), `OfflineModelsPageTests` (5),
`NetworkIsolationTests` (4), `OfflineFlowIntegrationTests` (7), and
`OfflineAvailabilityGuardTests` (26), 67 tests total — each with its own
retained xcresult archive. The harness maps real class names only; a suite name
matching no test class is a harness error and the layer fails closed instead of
reporting a vacuous pass.

**Fail-closed exit behavior:** `device-test.sh --layer offline` exits nonzero
until a human records exactly one explicit PASS observation per required
scenario (`airplane-mode-launch`, `e2b-text-offline`, `e4b-text-offline`,
`e2b-vision-offline`, `e4b-vision-offline`, `invalid-pair-recovery`,
`conversation-history`). A run without operator observations therefore exits
nonzero even when all 67 unit tests and the UI stage pass; that nonzero exit is
expected and correct while the gate is incomplete.

**Failure mode:** Any hot-path network call during model loading, inference,
or conversation persistence → release blocked.

---

## Gate 8: Physical Download QA Matrix (Issue #08)

**Requirement:** Every network, repetition, and storage condition must have
an observed result on a physical device, traced to a focused follow-up ticket
when failing.

**Check:**

```bash
bash Scripts/device-test.sh --layer qa-full --evidence-dir docs/release-evidence/physical-qa
```

**Matrix rows:** One row per physical scenario. Each row records setup,
expectations, observations, evidence, and status (`PENDING`, `PASS`, `FAIL`).
Simulator coverage is a separate column.

**Hugging Face import regression suites:** The physical `qa-full` run must
record individual passing outcomes and retained xcresult archives for all 14
import suites: `HuggingFaceImportTests`, `ImportRejectionTests`,
`ImportRelaunchPersistenceTests`, `ImportStoragePreflightTests`,
`ImportTransferLifecycleTests`, `ImportVariantSelectionTests`,
`ImportedModelConfigurationTests`, `ImportedModelLoadFailureTests`,
`ImportedModelRelaunchTests`, `ImportedModelRemovalTests`,
`ImportedModelUpdateTests`, `VisionImportTests`,
`VisionRejectionRepairTests`, and `VisionUpdateTests`.

**Full qa-full suite set:** The `qa-full` layer runs 22 unit suites — the 14
import suites above plus `SubmissionReadinessTests`, `DownloadDiagnosticTests`,
`ModelMigrationTests`, `ImportedChatCompositionTests`,
`VariantCapabilityEstimateTests`, `MemoryProfileTests`,
`DurableTransferStateTests`, and `StoreRecoveryTests`. Gate 8 requires exactly
this 22-suite set, and a script test keeps the device-test.sh qa-full arm and
the release-gate-check.sh Gate 8 suite list identical.

**Failure mapping:** Every failed row must link to a focused ticket URL in
`docs/qa-failure-map.md`. Missing ticket URLs remain blocking.

---

## Gate 9: Durable State Integrity

**Requirement:** Paused and failed transfers must survive app termination,
relaunch, and device reboot without corruption or false state.

**Automated tests:**

- `RecreationRestoresPausedProgressWithoutStartingTransfer`
- `CorruptMetadataDegradesToRestartableState`

**Retained evidence rule:** Gate 9 passes only when the canonical automated iOS
evidence records the current clean revision, exact command, matching retained
xcresult archive digest, and an individual passing `DurableTransferStateTests`
outcome. A generic aggregate exit code or mutable directory hash is insufficient.

**Failure mode:** Corrupt durable state must not prevent the app from functioning,
and missing retained named-suite evidence blocks release. Corruption must degrade
to a clean `notDownloaded` state.

---

## Gate 10: Atomic Promotion Safety

**Requirement:** A crash during artifact promotion must not leave the model
in an unverifiable state. Either the old verified artifact or the new verified
staging file must survive.

**Automated tests:**

- `InjectedPromotionFailurePreservesVerifiedInstallationByteForByte`
- `StoreRecoveryTests.testQuarantineCopiesExistingSQLiteTrioByteForByte`

**Retained evidence rule:** Gate 10 passes only when the canonical automated iOS
evidence records the current clean revision, exact command, matching retained
xcresult archive digest, and an individual passing `StoreRecoveryTests` outcome.
A generic aggregate exit code or mutable directory hash is insufficient.

**Failure mode:** Loss of both old and new artifact during promotion or missing
retained named-suite evidence is a release blocker.

---

## Gate 11: Failure-to-Ticket Mapping

**Requirement:** Every failed physical QA or offline scenario must link to a
focused follow-up ticket with reproduction steps and evidence. Generic
exceptions are not accepted.

**Check:**

```bash
grep -c 'https://github.com/' docs/qa-failure-map.md
```

**Failure mode:** Any observed `FAIL` row without a focused ticket URL →
release blocked. `PENDING` rows remain blocked by Gates 6–8 and carry a local
owner; they do not justify fabricating or creating a remote ticket without
authorization.

---

## Gate Execution Order

```text
Gate 1 (Catalog Hashes) ──┐
Gate 2 (Clean Download)  ─┤── Must pass before any model download
                          │
Gate 3 (Legacy Repair)   ─┤── Code-level integrity
Gate 9 (Durable State)   ─┤
Gate 10 (Atomic Promo)   ─┤
                          │
Gate 4 (Privacy URL)     ─┤── External / manual
Gate 5 (Screenshots)     ─┤
                          │
Gate 6 (Lifecycle QA)    ─┐
Gate 7 (Offline Proof)   ─┤── Physical device required
Gate 8 (QA Matrix)       ─┘
                          │
Gate 11 (Ticket Map)     ─┘── Final reconciliation
```

---

## Current Gate Status

| Gate | Status | Notes |
| ------ | -------- | ------- |
| 1. Catalog Hashes | ✅ Pass | Production metadata validation passes |
| 2. Clean Download | ❌ Blocking | Round-1 clean-source transfer timed out; success evidence is not available |
| 3. Legacy Repair | ❌ Blocking | Existing mutable-directory hash evidence is not reproducible; regenerate immutable retained evidence from a clean tree |
| 4. Privacy Policy | ❌ Blocking | Canonical URL returns HTTP 404; publication requires authorization |
| 5. Screenshots | ❌ Blocking | Files pass technical checks, but captures are not review-ready and no authorized human visual review is retained; manifest is provenance only |
| 6. Lifecycle QA | 🔲 Blocking | Physical-device evidence needed; owner: physical QA owner |
| 7. Offline Proof | 🔲 Blocking | Physical-device offline proof needed; owner: physical QA owner |
| 8. QA Matrix | 🔲 Blocking | Physical-device QA matrix needed; owner: physical QA owner |
| 9. Durable State | ❌ Blocking | Regenerate verifiable retained `DurableTransferStateTests` evidence from a clean tree |
| 10. Atomic Promotion | ❌ Blocking | Regenerate verifiable retained `StoreRecoveryTests` evidence from a clean tree |
| 11. Ticket Map | ✅ Pass | No observed `FAIL` row currently lacks a ticket; pending rows remain blocked by Gates 6–8 |

**Verdict: NOT_READY** — Gates 2–10 include blockers. Authorized review-ready
screenshots, live privacy, clean-source catalog verification, physical-device
evidence, and regenerated clean-tree automated evidence with verifiable retained
xcresult archives are required. The historical named-suite record remains
inspectable but does not currently pass Gates 3, 9, or 10.
