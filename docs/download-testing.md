# Download Testing — Transport Fixtures, Isolation, Device Coverage

Testing strategy for model download and verification. Every test uses deterministic
fixtures, isolated model directories, and covers the physical-device contract.

---

## 1. Deterministic Transport Fixtures

### 1.1 GGUF Fixture Generator

Tests that need valid GGUF files use a deterministic helper:

```swift
func gguf() -> Data {
    Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0, 1, 2, 3, 4])
}
```

This produces a valid GGUF header (magic + version 3) followed by deterministic
padding. The 12-byte fixture is used by `DurableTransferStateTests` and
`BoundedVerificationTests`.

### 1.2 Large Fixture Generation

`BoundedVerificationTests.testLargeGeneratedFixtureVerifiesOffMainWith64KiBBuffer`
generates an 8 MiB fixture programmatically:

```swift
var bytes = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0])
bytes.append(Data(repeating: 0xA5, count: 8 * 1_024 * 1_024))
```

The SHA-256 is computed from the generated data — no pre-baked digest.

### 1.3 Runtime Model Fixtures

Tests create ephemeral model identities via `makeRuntimeModel(id:baseSHA256:vision:)`.
These models:
- Have unique IDs (UUID-based or explicit)
- Are NOT registered in `ModelRegistry.allModels`
- Have deterministic SHA-256 values (e.g., `String(repeating: "f", count: 64)`)
- Use `validGGUFData(length:)` to write GGUF files of exact specified length

**Key principle:** No test depends on network access or pre-existing disk state.
Every fixture is generated in the test and cleaned up in `tearDown`.

---

## 2. Isolated Model Directories

### 2.1 Per-Test Cleanup

Every test that writes model files cleans up via `tearDown`:

```swift
override func tearDown() {
    for model in ModelRegistry.allModels {
        ModelManagerService.deleteModel(model)
    }
    try? FileManager.default.removeItem(
        at: ModelManagerService.baseModelPath(for: ModelRegistry.gemma4_e4b)
    )
    downloadManager = nil
    super.tearDown()
}
```

### 2.2 Managed Directory Structure

`ModelMigrationService.ensureManagedDirectories()` creates the canonical directory
layout. Tests call this in `setUp` to ensure directories exist before any file
operations.

### 2.3 No Cross-Test Contamination

- `DurableTransferStateTests` uses `fixtureModel(bytes:)` with UUID-based IDs,
  writes to `resume/` and `staging/` subdirectories, and cleans up via `cleanup(task:model:)`
- `ModelArtifactVerificationTests` writes to canonical model paths determined by
  model ID, and deletes in `defer` blocks
- `BoundedVerificationTests` writes to `NSTemporaryDirectory()` with UUID filenames

### 2.4 Shared Artifact Awareness

Tests explicitly verify that shared base artifacts are not double-freed:

- `DeletingE4BTextPreservesBaseUsedByVision`: deleting the E2B text model leaves
  the shared base GGUF intact when E4B vision still references it
- `DeletingE4BVisionPreservesBaseUsedByTextAndDeletesProjector`: deleting the E4B
  vision model removes the projector but preserves the shared base
- `E4BTextAndVisionCannotClaimTwoBaseWriters`: verifies shared artifact write
  coordination

---

## 3. Physical-Device Coverage

### 3.1 Simulator Suite

The primary test suite runs on iOS Simulator (iPhone 17 Pro, iOS 26.5):

```bash
xcodebuild test -project ZiroEdge.xcodeproj -scheme ZiroEdge \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath /tmp/ZiroEdge-FullTests4 \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

**Last verified:** 239 tests executed, 0 failures (RELEASE-VALIDATION.md, 2026-07-24).

### 3.2 Physical-Device QA (Issue #16 dependency)

Complete lifecycle QA on physical devices covers:

| Scenario | Coverage |
|----------|----------|
| Fresh install | Model download + verification |
| Legacy upgrade | Migration from pre-managed layout |
| Wi-Fi download | Full transfer, pause/resume |
| Cellular download | Warning, user opt-in |
| Wi-Fi→Cellular handoff | Transfer continuity |
| Connection loss | Pause + durable state preservation |
| Airplane Mode | Offline operation, existing models usable |
| Backgrounding | Transfer continues via background URLSession |
| Suspension | System-managed, resume on foreground |
| User force-quit | Durable state survives, restore on relaunch |
| Reboot | Cold start reads durable state |
| Locked device | Background session continues |
| Low Power Mode | Discretionary flag respected |
| Low storage | Download rejected, existing models preserved |
| Out of space mid-transfer | Durable state preserved, no corruption |

### 3.3 Device Test Script

`Scripts/device-test.sh` automates physical-device testing with screenshot capture.
See `docs/testing.md` (at project root) for the full device-testing guide.

### 3.4 Transport Fixture Verification

Before any physical-device download test, the test environment must:
1. Verify the `resume/` directory is empty
2. Verify the `staging/` directory is empty
3. Confirm `ModelManagerService.ensureManagedDirectories()` succeeds
4. Confirm catalog validation passes for all registered models

---

## 4. Named Regression Test Map

### Download State Machine
- `StateTransitionIdleToDownloading` — idle → downloading
- `StateTransitionDownloadingToPaused` — downloading → paused
- `StateTransitionDownloadingToCompleted` — downloading → verified → downloaded
- `StateTransitionDownloadingToFailed` — downloading → failed
- `StateTransitionFailedToDownloading` — failed → resume → downloading

### Pause / Resume / Cancel
- `DownloadStatePausingAndResumingAreActive` — pausing/resuming is `.isActive`
- `DownloadStatePausedProperties` — paused is not `.isActive`
- `DownloadStateCancelledProperties` — cancelled is terminal
- `ModelDownloadStatusPreservesPausedProgress` — progress survives pause
- `RecreationRestoresPausedProgressWithoutStartingTransfer` — cold start restores pause
- `CorruptMetadataDegradesToRestartableState` — corrupt metadata → clean state

### Verification & Repair
- `LargeGeneratedFixtureVerifiesOffMainWith64KiBBuffer` — 8 MiB fixture, off-main SHA-256
- `AuthenticationBodyAtBothGemmaDestinationsIsNotInstalled` — auth body ≠ valid model
- `ValidLengthWithWrongSHA256NeedsRepair` — repair-needed for hash mismatch
- `CorrectSHA256WithWrongByteCountNeedsRepair` — repair-needed for size mismatch
- `PromotionRejectsStructurallyInvalidGGUFBeforeHashing` — GGUF header checked first
- `PromotionRejectsMissingSHA256` — missing metadata rejected
- `SHA256MetadataMustBeLowercase64Hex` — format validation
- `SameSizeWrongDigestBaseRequiresFullReplacement` — same-size, wrong-hash → full redownload
- `SameSizeWrongDigestProjectorRequiresFullReplacement` — same for mmproj
- `InjectedPromotionFailurePreservesVerifiedInstallationByteForByte` — atomic promotion crash safety

### Paired Artifacts
- `VisionModelWithOnlyValidBaseIsNotInstalled` — partial ≠ installed
- `VisionModelWithOnlyValidMMProjIsNotInstalled` — partial ≠ installed
- `TextModelWithValidArtifactIsInstalled` — text model: base alone = ready
- `OptionalVisionProductIsTextReadyWithBaseButNotVisionReady` — text-only capability flag
- `DeletingE4BTextPreservesBaseUsedByVision` — shared artifact safety
- `DeletingE4BVisionPreservesBaseUsedByTextAndDeletesProjector` — shared artifact safety
- `E4BTextAndVisionCannotClaimTwoBaseWriters` — write coordination

### Offline Verification
- `DownloadStatusCheckUsesFileManagerOnly` — no network in status check
- `IsBaseDownloadedUsesVerifiedLocalFixture` — local-only validation
- `SHA256VerificationIsLocal` — SHA-256 uses CryptoKit, no network
- `ModelManagerServiceUsesOnlyFileManager` — service uses FileManager only
- `ModelManagerServiceDirectoryIsLocal` — directory paths are local

### Catalog Integrity
- `EveryCatalogArtifactHasDownloadIntegrityMetadata` — every model has SHA-256 + size
- `CatalogValidatorRejectsSignedAndIncompleteEntries` — incomplete entries rejected
- `MissingCatalogMetadataIsUnavailableWithoutCrashing` — graceful degradation
- `MissingIntegrityMetadataFailsClosed` — fail-closed on missing metadata
