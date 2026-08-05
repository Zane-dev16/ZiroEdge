# QA Failure-to-Ticket Map

**Purpose:** Every failed physical QA matrix row must link to a focused follow-up
ticket. Missing ticket URLs are blocking — generic exceptions are not accepted.

**Generated:** <!-- TIMESTAMP --> (to be filled by release-gate-check.sh)
**Build:** <!-- BUILD --> (to be filled by release-gate-check.sh)
**Local owner while rows are pending:** physical QA owner

---

## How to use

1. Run `bash Scripts/device-test.sh --layer qa-full --evidence-dir docs/release-evidence/physical-qa`
2. For every scenario that fails, create a GitHub issue with precise reproduction steps.
3. Add the ticket URL to the corresponding row below.
4. Re-run `bash Scripts/release-gate-check.sh --evidence-root docs/release-evidence`

An observed `FAIL` row without a ticket URL is **blocking**. A `PENDING` row
remains blocked by its physical QA gate and local owner; it does not authorize
creating a remote ticket or inventing a URL.

---

## Physical QA Failure Rows

| # | Scenario | Status | Ticket URL | Notes |
| --- | ---------- | -------- | ------------ | ------- |
| 1 | Wi-Fi loss during download → reconnect → resume | PENDING | <!-- REQUIRED if FAIL --> | |
| 2 | Wi-Fi→Cellular handoff during download | PENDING | <!-- REQUIRED if FAIL --> | |
| 3 | Cellular→Wi-Fi handoff during download | PENDING | <!-- REQUIRED if FAIL --> | |
| 4 | Repeated pause/resume (5+ cycles) on text model | PENDING | <!-- REQUIRED if FAIL --> | |
| 5 | Repeated pause/resume (5+ cycles) on vision model | PENDING | <!-- REQUIRED if FAIL --> | |
| 6 | Cancel → redownload (text model) | PENDING | <!-- REQUIRED if FAIL --> | |
| 7 | Cancel → redownload (vision model) | PENDING | <!-- REQUIRED if FAIL --> | |
| 8 | Low-storage warning — download refused | PENDING | <!-- REQUIRED if FAIL --> | |
| 9 | Out-of-space (ENOSPC) — existing models preserved | PENDING | <!-- REQUIRED if FAIL --> | |
| 10 | Storage freed after low-space → download resumes | PENDING | <!-- REQUIRED if FAIL --> | |
| 11 | Repeated E2B transfer — no orphaned artifacts | PENDING | <!-- REQUIRED if FAIL --> | |
| 12 | Repeated E4B transfer — no orphaned artifacts | PENDING | <!-- REQUIRED if FAIL --> | |
| 13 | Reboot recovery — all installed models verified | PENDING | <!-- REQUIRED if FAIL --> | |
| 14 | Force-quit during download → state reconciled | PENDING | <!-- REQUIRED if FAIL --> | |
| 15 | Background→foreground cycle — download survives | PENDING | <!-- REQUIRED if FAIL --> | |
| 16 | OS termination during download → relaunch recovers | PENDING | <!-- REQUIRED if FAIL --> | |

## Physical Lifecycle Failure Rows

| # | Scenario | Status | Ticket URL | Notes |
| --- | ---------- | -------- | ------------ | ------- |
| 17 | Background suspension — progress preserved | PENDING | <!-- REQUIRED if FAIL --> | |
| 18 | Lock/unlock during download — resume works | PENDING | <!-- REQUIRED if FAIL --> | |
| 19 | OS termination — restore exactly once | PENDING | <!-- REQUIRED if FAIL --> | |
| 20 | Force-quit — no false completion reported | PENDING | <!-- REQUIRED if FAIL --> | |
| 21 | Reboot — durable state reconciled | PENDING | <!-- REQUIRED if FAIL --> | |

## Physical Offline Failure Rows

| # | Scenario | Status | Ticket URL | Notes |
| --- | ---------- | -------- | ------------ | ------- |
| 22 | Airplane Mode launch — only complete models ready | PENDING | <!-- REQUIRED if FAIL --> | |
| 23 | E2B text response offline | PENDING | <!-- REQUIRED if FAIL --> | |
| 24 | E4B text response offline | PENDING | <!-- REQUIRED if FAIL --> | |
| 25 | E2B vision interaction offline | PENDING | <!-- REQUIRED if FAIL --> | |
| 26 | E4B vision interaction offline | PENDING | <!-- REQUIRED if FAIL --> | |
| 27 | Invalid pair shows repair, not ready | PENDING | <!-- REQUIRED if FAIL --> | |
| 28 | Conversation history browsable offline | PENDING | <!-- REQUIRED if FAIL --> | |

## Overdue Tickets

<!-- Tickets that have been open for >7 days without resolution: -->
<!-- (fill in during review) -->

---

## Instructions for creating tickets

Each ticket must include:

1. **Exact scenario** from the row above
2. **Device model, OS version, and build revision** (from evidence.json)
3. **Steps to reproduce** (copy from operator observations)
4. **Observed behavior** vs expected behavior
5. **Attached evidence:** xcresult path, screenshot hashes, diagnostic logs
6. **Severity:** `release-blocker` (must fix before submission) or `follow-up` (can defer)

Tickets without reproduction steps and evidence will be rejected.
