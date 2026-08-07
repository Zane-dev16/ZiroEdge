# Device Lifecycle QA Test Matrix

**Date:** 2026-07-31
**Issues:** 06 (Background Lifecycle), 07 (Offline Operation), 08 (Physical QA)

This document captures the device conditions and lifecycle scenarios exercised
by the automated test suite in `DeviceLifecycleQATests.swift` and the
operator-guided physical evidence collected by `Scripts/device-test.sh`.

Each row has:

- **Scenario:** What is tested
- **Simulator:** Coverage available in simulator tests
- **Physical status:** `PENDING`, `PASS`, or `FAIL` (filled during physical QA)
- **Evidence:** Location of machine-generated + operator-recorded evidence

---

## Device Matrix

| # | Scenario | Simulator Coverage | Physical Status | Evidence |
| --- | ---------- | ------------------- | ----------------- | ---------- |
| D1 | Fresh Install | `FreshInstallLegacyUpgradeTests` | PENDING | `docs/release-evidence/physical-qa/` |
| D2 | Legacy Upgrade | `FreshInstallLegacyUpgradeTests` | PENDING | `docs/release-evidence/physical-qa/` |
| D3 | Credential-Error URLs | `testLegacyUpgradeCatalogValidatorRejects...` | ✅ Automated | N/A |
| D4 | Wi-Fi connectivity | `NetworkConditionTests` | PENDING | `docs/release-evidence/physical-qa/` |
| D5 | Cellular connectivity | `NetworkConditionTests` | PENDING | `docs/release-evidence/physical-qa/` |
| D6 | Wi-Fi→Cellular Handoff | `testWiFiToCellularTransition...` | PENDING | `docs/release-evidence/physical-qa/` |
| D7 | Cellular→Wi-Fi Handoff | `testNetworkErrorPersistsDurableState...` | PENDING | `docs/release-evidence/physical-qa/` |
| D8 | Connection Loss | `testNetworkErrorPersistsDurableState...` | ✅ Automated | N/A |
| D9 | Airplane Mode | `OfflineVerificationTests` | PENDING | `docs/release-evidence/offline/` |
| D10 | Background during download | `BackgroundLifecycleQATests` | PENDING | `docs/release-evidence/lifecycle/` |
| D11 | Suspension during download | `testPausedDownloadSurvivesManagerRecreation` | ✅ Automated | N/A |
| D12 | OS-initiated Termination | `testForceQuitDuringDownloadPreservesResumeState` | PENDING | `docs/release-evidence/lifecycle/` |
| D13 | Force-Quit during download | `testForceQuitDuringDownloadPreservesResumeState` | PENDING | `docs/release-evidence/lifecycle/` |
| D14 | Reboot recovery | `testConversationsSurviveSimulatedReboot` | PENDING | `docs/release-evidence/lifecycle/` |
| D15 | Locked Device during download | `testLockedDeviceDoesNotInterruptLocalVerification` | PENDING | `docs/release-evidence/lifecycle/` |
| D16 | Low Power Mode | `testLowPowerModeDoesNotAffectLocalVerification` | ✅ Automated | N/A |
| D17 | Low Storage Warning | `StorageConstraintQATests` | PENDING | `docs/release-evidence/physical-qa/` |
| D18 | Out of Space (ENOSPC) | `testOutOfSpaceDoesNotCorruptExistingInstallation` | PENDING | `docs/release-evidence/physical-qa/` |

## Pause/Resume Matrix

| # | Scenario | Simulator Coverage | Physical Status | Evidence |
| --- | ---------- | ------------------- | ----------------- | ---------- |
| P1 | Text model — single pause/resume | `PauseResumeQATests.testTextModel...` | ✅ Automated | N/A |
| P2 | Text model — 5+ consecutive cycles | `testTextModelRepeatedPauseResume...` | PENDING | `docs/release-evidence/physical-qa/` |
| P3 | Vision model — base + mmproj | `testVisionModelBaseAndMMProjPauseStates...` | PENDING | `docs/release-evidence/physical-qa/` |
| P4 | Vision model — text-only capable | `testTextOnlyCapabilityReadyWithBase...` | ✅ Automated | N/A |
| P5 | Corrupt metadata recovery | `testTextModelDurableMetadataCorruption...` | ✅ Automated | N/A |
| P6 | Pause → relaunch → not downloading | `testPauseDoesNotStartNewTransfers` | ✅ Automated | N/A |

## Storage Constraint Matrix

| # | Scenario | Simulator Coverage | Physical Status | Evidence |
| --- | ---------- | ------------------- | ----------------- | ---------- |
| S1 | Safety margin present | `testStorageSafetyMarginIsReasonable` | ✅ Automated | N/A |
| S2 | Required bytes include margin (text) | `testRequiredDownloadBytesIncludesMargin...` | ✅ Automated | N/A |
| S3 | Required bytes include margin (vision) | `testRequiredDownloadBytesIncludesMargin...` | ✅ Automated | N/A |
| S4 | Optional projector exclusion | `testRequiredDownloadBytesExcludesProjector...` | ✅ Automated | N/A |
| S5 | Insufficient storage → fail closed | `testDownloadRefusesInsufficientStorage...` | PENDING | `docs/release-evidence/physical-qa/` |
| S6 | Valid install survives space check | `testValidInstallationSurvivesAdverse...` | ✅ Automated | N/A |

## Verification & Evidence Matrix

| # | Scenario | Simulator Coverage | Physical Status | Evidence |
| --- | ---------- | ------------------- | ----------------- | ---------- |
| V1 | GGUF header verification | `ModelArtifactVerifier` tests | ✅ Automated | N/A |
| V2 | Size mismatch → repair needed | `ModelArtifactVerificationTests` | ✅ Automated | N/A |
| V3 | SHA-256 mismatch → not installed | `testTamperedModelNotReported...` | ✅ Automated | N/A |
| V4 | Quarantine of invalid artifacts | `testQuarantineMovesTampered...` | ✅ Automated | N/A |
| V5 | Diagnostic log emission | `EvidenceArtifactQATests` | ✅ Automated | N/A |
| V6 | All download errors have unique messages | `testAllDownloadErrorsHaveDistinct...` | ✅ Automated | N/A |
| V7 | Catalog metadata (all models) | `testAllModelIDsHaveCatalogValidation` | ✅ Automated | N/A |

## Offline Operation Matrix (Issue 07)

| # | Scenario | Simulator Coverage | Physical Status | Evidence |
| --- | ---------- | ------------------- | ----------------- | ---------- |
| O1 | Airplane Mode — only complete models ready | `OfflineAvailabilityGuardTests` | PENDING | `docs/release-evidence/offline/` |
| O2 | E2B text response offline | N/A (requires model) | PENDING | `docs/release-evidence/offline/` |
| O3 | E4B text response offline | N/A (requires model) | PENDING | `docs/release-evidence/offline/` |
| O4 | E2B vision interaction offline | N/A (requires model) | PENDING | `docs/release-evidence/offline/` |
| O5 | E4B vision interaction offline | N/A (requires model) | PENDING | `docs/release-evidence/offline/` |
| O6 | Invalid pair shows repair, not ready | `testSweepReturnsRepairNeededForCorruptFile` | PENDING | `docs/release-evidence/offline/` |
| O7 | Conversation history browsable offline | `testRelaunchInAirplaneModeShowsExistingConversations` | PENDING | `docs/release-evidence/offline/` |

## Background Lifecycle Matrix (Issue 06)

| # | Scenario | Simulator Coverage | Physical Status | Evidence |
| --- | ---------- | ------------------- | ----------------- | ---------- |
| L1 | Background suspension — progress preserved | `BackgroundLifecycleQATests` | PENDING | `docs/release-evidence/lifecycle/` |
| L2 | Lock/unlock during download — resume works | `testLockedDeviceDoesNotInterruptLocalVerification` | PENDING | `docs/release-evidence/lifecycle/` |
| L3 | OS termination — restore exactly once | `testForceQuitDuringDownloadPreservesResumeState` | PENDING | `docs/release-evidence/lifecycle/` |
| L4 | Force-quit — no false completion | `testForceQuitDuringDownloadPreservesResumeState` | PENDING | `docs/release-evidence/lifecycle/` |
| L5 | Reboot — durable state reconciled | `testConversationsSurviveSimulatedReboot` | PENDING | `docs/release-evidence/lifecycle/` |

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

## Evidence Collection Commands

```bash
# Issue 06 — Background lifecycle
bash Scripts/device-test.sh --layer lifecycle --evidence-dir docs/release-evidence/lifecycle

# Issue 07 — Offline operation
bash Scripts/device-test.sh --layer offline --evidence-dir docs/release-evidence/offline

# Issue 08 — Full QA matrix
# Also records each of the 14 Hugging Face import unit suites as an individual
# physical-device outcome with a retained xcresult archive.
bash Scripts/device-test.sh --layer qa-full --evidence-dir docs/release-evidence/physical-qa

# Issue 09 — Gate reconciliation
bash Scripts/release-gate-check.sh --evidence-root docs/release-evidence
```

Each command records `evidence.json` with machine facts and prompts for
operator-entered observations. Observations are never inferred from elapsed time.
