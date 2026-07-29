# Device Lifecycle QA Test Matrix

## Issue: DOWNLOAD-DEVICE-QA (#16)

This document captures the device conditions and lifecycle scenarios exercised
by the automated test suite in `DeviceLifecycleQATests.swift`. Physical-device
acceptance paths marked "⚠️ Physical" require an iOS device; unit-test
equivalents exercise the same code paths.

## Device Matrix

| Condition              | Unit Coverage                                      | Physical QA |
|------------------------|----------------------------------------------------|-------------|
| Fresh Install          | `FreshInstallLegacyUpgradeTests`                   | ⚠️ Physical  |
| Legacy Upgrade         | `FreshInstallLegacyUpgradeTests`                   | ⚠️ Physical  |
| Credential-Error URLs  | `testLegacyUpgradeCatalogValidatorRejects...`      | ✅ Automated |
| Wi-Fi                  | `NetworkConditionTests` (monitor, waitsForConnect) | ⚠️ Physical  |
| Cellular               | `NetworkConditionTests` (isOnCellular published)   | ⚠️ Physical  |
| Wi-Fi→Cellular Handoff | `testWiFiToCellularTransition...`                  | ⚠️ Physical  |
| Connection Loss        | `testNetworkErrorPersistsDurableState...`          | ✅ Automated |
| Airplane Mode          | `testAirplaneModeDoesNotPrevent...` (+ OfflineTests)| ✅ Automated |
| Background             | `BackgroundLifecycleQATests` (session store, delegates) | ⚠️ Physical |
| Suspension             | `testPausedDownloadSurvivesManagerRecreation`      | ✅ Automated |
| Supported Termination  | `testForceQuitDuringDownloadPreservesResumeState`  | ✅ Automated |
| Force-Quit             | `testForceQuitDuringDownloadPreservesResumeState`  | ✅ Automated |
| Reboot (simulated)     | `testConversationsSurviveSimulatedReboot`          | ⚠️ Physical  |
| Locked Device          | `testLockedDeviceDoesNotInterruptLocalVerification`| ✅ Automated |
| Low Power Mode         | `testLowPowerModeDoesNotAffectLocalVerification`   | ✅ Automated |
| Low Storage            | `StorageConstraintQATests` (margin, detection)     | ⚠️ Physical  |
| Out of Space           | `testOutOfSpaceDoesNotCorruptExistingInstallation` | ⚠️ Physical  |

## Pause/Resume Matrix

| Scenario                            | Coverage                                     |
|-------------------------------------|----------------------------------------------|
| Text model - single pause/resume    | `PauseResumeQATests.testTextModel...`        |
| Text model - 5 consecutive cycles   | `testTextModelRepeatedPauseResume...`        |
| Vision model - base + mmproj        | `testVisionModelBaseAndMMProjPauseStates...` |
| Vision model - text-only capable    | `testTextOnlyCapabilityReadyWithBase...`     |
| Corrupt metadata recovery           | `testTextModelDurableMetadataCorruption...`  |
| Pause → relaunch → not downloading  | `testPauseDoesNotStartNewTransfers`          |

## Storage Constraint Matrix

| Condition                             | Coverage                                    |
|---------------------------------------|---------------------------------------------|
| Safety margin present                 | `testStorageSafetyMarginIsReasonable`       |
| Required bytes include margin (text)  | `testRequiredDownloadBytesIncludesMargin...`|
| Required bytes include margin (vision)| `testRequiredDownloadBytesIncludesMargin...`|
| Optional projector exclusion          | `testRequiredDownloadBytesExcludesProjector...`|
| Insufficient storage → fail closed    | `testDownloadRefusesInsufficientStorage...` |
| Valid install survives space check    | `testValidInstallationSurvivesAdverse...`   |
| Shared base not deleted prematurely   | multiple tests                               |

## Verification & Evidence Matrix

| Check                                      | Coverage                           |
|--------------------------------------------|------------------------------------|
| GGUF header verification                   | `ModelArtifactVerifier` tests      |
| Size mismatch → repair needed              | `ModelArtifactVerificationTests`   |
| SHA-256 mismatch → not installed           | `testTamperedModelNotReported...`  |
| Quarantine of invalid artifacts            | `testQuarantineMovesTampered...`   |
| Diagnostic log emission                    | `EvidenceArtifactQATests`          |
| All download errors have unique messages   | `testAllDownloadErrorsHaveDistinct...` |
| Catalog metadata validation (all models)   | `testAllModelIDsHaveCatalogValidation` |

## Known Platform Limits

1. **Physical network transitions** (Wi-Fi↔cellular, Airplane Mode toggle):
   Tests exercise the `NetworkMonitor`, `waitsForConnectivity`, and durable-state
   code paths; actual radio-level transitions require a device.

2. **System-initiated termination**: The `UIApplicationDelegate` background-session
   handler and `BackgroundDownloadCompletionStore` are tested; full system-initiated
   relaunch requires a device.

3. **Low Storage / Out of Space**: The storage safety margin and required-bytes
   calculations are validated; actual `ENOSPC` conditions require a device with
   near-full storage.

4. **Low Power Mode**: The test verifies that local file operations are not gated on
   power state; `URLSession` behavior under Low Power Mode requires a device.

5. **Screenshots**: Automated tests cannot capture UI screenshots; physical-device
   QA must attach screenshots for each acceptance path.

## Evidence Sufficiency

All automated acceptance criteria are exercised by `DeviceLifecycleQATests.swift`.
Physical-device acceptance paths are explicitly documented with `⚠️ Physical` markers.
The test file itself serves as the reviewable evidence artifact for code-level
verification. Log output from `diagnosticLog` calls is captured during test runs.
