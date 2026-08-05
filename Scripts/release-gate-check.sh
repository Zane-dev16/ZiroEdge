#!/bin/bash
set -euo pipefail

# ZiroEdge Release Gate Checker
# Consumes evidence from Workstreams 1, 2, and 3 and physical QA to produce
# a single READY / NOT_READY verdict.
#
# Usage:
#   bash Scripts/release-gate-check.sh --evidence-root docs/release-evidence
#
# Exit code: 0 if READY, nonzero if NOT_READY (missing/expired/incomplete evidence).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EVIDENCE_ROOT=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--evidence-root)
		EVIDENCE_ROOT="$2"
		shift 2
		;;
	*)
		echo "Unknown arg: $1"
		echo "Usage: $0 --evidence-root <path>"
		exit 2
		;;
	esac
done

if [[ -z "$EVIDENCE_ROOT" ]]; then
	echo "ERROR: --evidence-root is required."
	echo "Usage: $0 --evidence-root <path>"
	exit 2
fi

EVIDENCE_ROOT="$(cd "$EVIDENCE_ROOT" 2>/dev/null && pwd || echo "$EVIDENCE_ROOT")"
mkdir -p "$EVIDENCE_ROOT"

VERDICT_FILE="$EVIDENCE_ROOT/final-verdict.md"
GATE_CHECKLIST="$EVIDENCE_ROOT/gate-checklist.md"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_REVISION=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
SOURCE_TREE_CLEAN=true

# Evidence is generated after the clean-tree build identity is captured, so the
# evidence root itself may be new or modified without making the tested source
# dirty. Continue to fail closed for every change outside that root.
EVIDENCE_PATHSPEC=""
if EVIDENCE_PATHSPEC=$(
	python3 - "$PROJECT_DIR" "$EVIDENCE_ROOT" <<'PY'
import os
import sys
from pathlib import Path

project = Path(sys.argv[1]).resolve()
evidence = Path(sys.argv[2]).resolve()
try:
    relative = evidence.relative_to(project)
except ValueError:
    sys.exit(1)
if relative.parts:
    print(relative.as_posix())
else:
    sys.exit(1)
PY
); then
	SOURCE_STATUS=$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all -- . ":(exclude)$EVIDENCE_PATHSPEC/**" 2>/dev/null || true)
else
	SOURCE_STATUS=$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all 2>/dev/null || true)
fi
if [[ -n "$SOURCE_STATUS" ]]; then
	SOURCE_TREE_CLEAN=false
fi

# ─── Gate data (parallel indexed arrays) ───
GATE_COUNT=0

add_gate() {
	GATE_COUNT=$((GATE_COUNT + 1))
	eval "GATE_NAME_$GATE_COUNT=\"\$1\""
	eval "GATE_CHECK_$GATE_COUNT=\"\$2\""
}

add_gate "Catalog Hash Completeness" \
	"Every model in catalog has valid SHA-256 and non-zero size"

add_gate "Clean-Download Verification" \
	"Clean-source catalog verification produces evidence JSON"

add_gate "Legacy Repair" \
	"ModelMigrationTests pass"

add_gate "Privacy Policy Published" \
	"privacy.html is reachable at canonical URL"

add_gate "Submission Screenshots" \
	"All required screenshot sizes have valid images"

add_gate "Background Download Lifecycle" \
	"Physical-device lifecycle scenarios have operator observations"

add_gate "Offline Operation (E2B/E4B)" \
	"E2B and E4B models function with network disabled on physical device"

add_gate "Physical Download QA Matrix" \
	"Every matrix row has evidence and status"

add_gate "Durable State Integrity" \
	"DurableTransferStateTests pass"

add_gate "Atomic Promotion Safety" \
	"Crash-safety tests pass"

add_gate "Failure-to-Ticket Mapping" \
	"Every failed matrix row has a focused ticket URL"

# ─── Evidence checks ───

echo "===== ZiroEdge Release Gate Check ====="
echo "Timestamp:  $NOW"
echo "Build:      $BUILD_REVISION"
echo "Evidence:   $EVIDENCE_ROOT"
echo "========================================"
echo ""

# Arrays to collect results

EVIDENCE_VALIDATOR="$SCRIPT_DIR/validate-release-evidence.py"

validate_named_unit_suite() {
	python3 "$EVIDENCE_VALIDATOR" suite \
		--evidence "$1" --name "$2" --revision "$3"
}

validate_physical_layer() {
	local evidence_file="$1"
	local observations_file="$2"
	local layers="$3"
	local suites="$4"
	local scenarios="$5"
	python3 "$EVIDENCE_VALIDATOR" physical \
		--evidence "$evidence_file" \
		--observations "$observations_file" \
		--layers "$layers" \
		--revision "$BUILD_REVISION" \
		--suites "$suites" \
		--scenarios "$scenarios"
}

check_gate() {
	local num="$1"
	local name_var="GATE_NAME_$num"
	local name="${!name_var}"
	local status="PENDING"
	local blocker=""

	echo -n "Gate $num — $name: "

	case "$num" in
	1)
		if python3 -m unittest discover -s "$SCRIPT_DIR/Tests" -p 'test_verify_model_catalog.py' >/dev/null 2>&1; then
			status="PASS"
		else
			status="FAIL"
			blocker="Catalog hash validation failed. Run: python3 Scripts/verify-model-catalog.py --metadata-only"
		fi
		;;

	2)
		CATALOG_EVIDENCE="$EVIDENCE_ROOT/catalog-verification.json"
		if [[ -f "$CATALOG_EVIDENCE" ]]; then
			if python3 "$EVIDENCE_VALIDATOR" catalog \
				--evidence "$CATALOG_EVIDENCE" \
				--verifier "$SCRIPT_DIR/verify-model-catalog.py" \
				--revision "$BUILD_REVISION" >/dev/null 2>&1; then
				status="PASS"
			else
				status="FAIL"
				blocker="Catalog evidence does not exactly match the current catalog version, revision, complete canonical artifact set, sizes, hashes, and successful download/structure outcomes."
			fi
		else
			status="FAIL"
			CATALOG_ATTEMPT="$EVIDENCE_ROOT/catalog-verification-attempt.json"
			if [[ -f "$CATALOG_ATTEMPT" ]]; then
				attempt_failure=$(python3 -c "import json; print(json.load(open('$CATALOG_ATTEMPT')).get('failureSummary', 'clean-source verification failed'))" 2>/dev/null || echo "clean-source verification failed")
				blocker="Clean-source verification has no passing evidence. Latest attempt: $attempt_failure"
			else
				blocker="Missing catalog-verification.json. Run: python3 Scripts/verify-model-catalog.py --evidence $EVIDENCE_ROOT/catalog-verification.json"
			fi
		fi
		;;

	3)
		UNIT_EVIDENCE="$EVIDENCE_ROOT/automated-ios/evidence.json"
		if [[ "$SOURCE_TREE_CLEAN" == true && -f "$UNIT_EVIDENCE" ]] && validate_named_unit_suite "$UNIT_EVIDENCE" "ModelMigrationTests" "$BUILD_REVISION" >/dev/null 2>&1; then
			status="PASS"
		else
			status="FAIL"
			blocker="No valid clean-tree ModelMigrationTests outcome with exact command, individual pass result, and matching retained xcresult archive digest. Run from a clean tree: bash Scripts/record-automated-release-evidence.sh"
		fi
		;;

	4)
		PRIVACY_CHECK="$SCRIPT_DIR/verify-privacy-policy.py"
		if [[ -f "$PRIVACY_CHECK" ]]; then
			if python3 "$PRIVACY_CHECK" --local-only >/dev/null 2>&1; then
				if python3 "$PRIVACY_CHECK" >/dev/null 2>&1; then
					status="PASS"
				else
					status="FAIL"
					blocker="Privacy policy page is not publicly reachable. Publish app/docs/privacy.html via GitHub Pages, then re-run verify-privacy-policy.py"
				fi
			else
				status="FAIL"
				blocker="Local privacy policy check failed. Verify app/docs/privacy.html exists with required sections."
			fi
		else
			status="FAIL"
			blocker="verify-privacy-policy.py not found"
		fi
		;;

	5)
		SCREENSHOT_DIR="$PROJECT_DIR/ziroedge-docs/app-store-screenshots"
		SCREENSHOT_MANIFEST="$EVIDENCE_ROOT/screenshot-manifest.json"
		SCREENSHOT_CHECK="$SCRIPT_DIR/verify-screenshots.py"
		if [[ ! -d "$SCREENSHOT_DIR" ]]; then
			status="FAIL"
			blocker="Screenshot directory not found: $SCREENSHOT_DIR"
		elif [[ ! -f "$SCREENSHOT_CHECK" ]] || ! python3 "$SCREENSHOT_CHECK" "$SCREENSHOT_DIR" >/dev/null 2>&1; then
			status="FAIL"
			blocker="Screenshot technical verification failed. Run: python3 Scripts/verify-screenshots.py ziroedge-docs/app-store-screenshots"
		elif [[ ! -f "$SCREENSHOT_MANIFEST" ]] || ! python3 - "$SCREENSHOT_MANIFEST" <<'PY' >/dev/null 2>&1; then
import json
import sys
with open(sys.argv[1]) as manifest_file:
    manifest = json.load(manifest_file)
review = manifest.get("reviewReadiness", {})
if review.get("status") != "approved" or review.get("humanVisualReview") != "pass":
    sys.exit(1)
PY
			status="FAIL"
			blocker="Screenshots pass technical/provenance checks but lack authorized human visual approval and real-app review-ready captures."
		else
			status="PASS"
		fi
		;;

	6)
		LIFECYCLE_DIR="$EVIDENCE_ROOT/lifecycle"
		if [[ "$SOURCE_TREE_CLEAN" == true && -f "$LIFECYCLE_DIR/evidence.json" ]] && validate_physical_layer \
			"$LIFECYCLE_DIR/evidence.json" "$LIFECYCLE_DIR/operator-observations.txt" \
			"lifecycle" "DeviceLifecycleQATests" \
			"background-suspension,lock-unlock,os-termination,force-quit,reboot" >/dev/null 2>&1; then
			status="PASS"
		else
			status="FAIL"
			blocker="Lifecycle evidence must match the current clean build, record UI and DeviceLifecycleQATests passes with retained archive digests, and contain exactly one explicit PASS observation for every required scenario."
		fi
		;;

	7)
		OFFLINE_DIR="$EVIDENCE_ROOT/offline"
		if [[ "$SOURCE_TREE_CLEAN" == true && -f "$OFFLINE_DIR/evidence.json" ]] && validate_physical_layer \
			"$OFFLINE_DIR/evidence.json" "$OFFLINE_DIR/operator-observations.txt" \
			"offline" "OfflineVerificationTests,OfflineAvailabilityGuardTests" \
			"airplane-mode-launch,e2b-text-offline,e4b-text-offline,e2b-vision-offline,e4b-vision-offline,invalid-pair-recovery,conversation-history" >/dev/null 2>&1; then
			status="PASS"
		else
			status="FAIL"
			blocker="Offline evidence must match the current clean build, record UI and both required unit-suite passes with retained archive digests, and contain exactly one explicit PASS observation for every required scenario."
		fi
		;;

	8)
		QA_DIR="$EVIDENCE_ROOT/physical-qa"
		if [[ "$SOURCE_TREE_CLEAN" == true && -f "$QA_DIR/evidence.json" ]] && validate_physical_layer \
			"$QA_DIR/evidence.json" "$QA_DIR/operator-observations.txt" \
			"qa-full,all" "SubmissionReadinessTests,DownloadDiagnosticTests,ModelMigrationTests,DurableTransferStateTests,StoreRecoveryTests" \
			"wifi-loss-reconnect,cellular-handoff,repeated-pause-resume,cancel-redownload,low-storage-warn,out-of-space-recovery,repeated-transfer-e2b,repeated-transfer-e4b,reboot-recovery,storage-pressure-recover" >/dev/null 2>&1; then
			status="PASS"
		else
			status="FAIL"
			blocker="Physical QA evidence must match the current clean build, record UI and every required unit-suite pass with retained archive digests, and contain exactly one explicit PASS observation for every required scenario."
		fi
		;;

	9)
		UNIT_EVIDENCE="$EVIDENCE_ROOT/automated-ios/evidence.json"
		if [[ "$SOURCE_TREE_CLEAN" == true && -f "$UNIT_EVIDENCE" ]] && validate_named_unit_suite "$UNIT_EVIDENCE" "DurableTransferStateTests" "$BUILD_REVISION" >/dev/null 2>&1; then
			status="PASS"
		else
			status="FAIL"
			blocker="No valid clean-tree DurableTransferStateTests outcome with exact command, individual pass result, and matching retained xcresult archive digest. Run from a clean tree: bash Scripts/record-automated-release-evidence.sh"
		fi
		;;

	10)
		UNIT_EVIDENCE="$EVIDENCE_ROOT/automated-ios/evidence.json"
		if [[ "$SOURCE_TREE_CLEAN" == true && -f "$UNIT_EVIDENCE" ]] && validate_named_unit_suite "$UNIT_EVIDENCE" "StoreRecoveryTests" "$BUILD_REVISION" >/dev/null 2>&1; then
			status="PASS"
		else
			status="FAIL"
			blocker="No valid clean-tree StoreRecoveryTests outcome with exact command, individual pass result, and matching retained xcresult archive digest. Run from a clean tree: bash Scripts/record-automated-release-evidence.sh"
		fi
		;;

	11)
		FAILURE_MAP="$PROJECT_DIR/docs/qa-failure-map.md"
		if [[ -f "$FAILURE_MAP" ]]; then
			# Only require ticket URLs for observed FAIL rows, not PENDING
			if python3 -c "
import re, sys
with open('$FAILURE_MAP') as f:
    content = f.read()
# Every FAIL row must link to a focused issue in this repository.
table_rows = re.findall(r'\|[^|]+\|[^|]+\|\s*FAIL\s*\|([^|]+)\|', content)
issue_url = re.compile(r'https://github\.com/Zane-dev16/ZiroEdge/issues/[1-9][0-9]*(?:\b|/)')
missing = [r for r in table_rows if not issue_url.search(r)]
if missing:
    print(f'{len(missing)} FAIL row(s) missing focused ZiroEdge issue URLs')
    sys.exit(1)
sys.exit(0)
" 2>/dev/null; then
				status="PASS"
			else
				status="FAIL"
				blocker="Failure map has FAIL rows without ticket URLs. Add focused ticket URLs to every FAIL row in docs/qa-failure-map.md"
			fi
		else
			status="FAIL"
			blocker="qa-failure-map.md not found at $FAILURE_MAP"
		fi
		;;

	*)
		status="UNKNOWN"
		blocker="No check defined for gate $num"
		;;
	esac

	# Store results
	eval "GATE_STATUS_$num=\"\$status\""
	eval "GATE_BLOCKER_$num=\"\$blocker\""

	case "$status" in
	PASS) echo "✅ PASS" ;;
	FAIL) echo "❌ FAIL — $blocker" ;;
	*) echo "🔲 $status" ;;
	esac
}

# Run all gate checks
for g in $(seq 1 $GATE_COUNT); do
	check_gate "$g"
done

# ─── Determine verdict ───
ALL_PASS=true
for g in $(seq 1 $GATE_COUNT); do
	status_var="GATE_STATUS_$g"
	if [[ "${!status_var}" != "PASS" ]]; then
		ALL_PASS=false
		break
	fi
done

VERDICT="NOT_READY"
if $ALL_PASS; then
	VERDICT="READY"
fi

echo ""
echo "========================================"
echo "  VERDICT: $VERDICT"
echo "========================================"

EVIDENCE_DISPLAY="$EVIDENCE_ROOT"
if [[ "$EVIDENCE_ROOT" == "$PROJECT_DIR"/* ]]; then
	EVIDENCE_DISPLAY="${EVIDENCE_ROOT#"$PROJECT_DIR"/}"
fi

# ─── Write gate checklist ───
{
	printf '# Release Gate Checklist\n\n'
	printf '**Generated:** %s\n' "$NOW"
	printf '**Build:** %s\n' "$BUILD_REVISION"
	printf '**Evidence root:** %s\n\n' "$EVIDENCE_DISPLAY"
	printf '| # | Gate | Status | Blocker |\n'
	printf '|---|------|--------|----------|\n'

	for g in $(seq 1 $GATE_COUNT); do
		name_var="GATE_NAME_$g"
		status_var="GATE_STATUS_$g"
		blocker_var="GATE_BLOCKER_$g"
		name="${!name_var}"
		status="${!status_var}"
		blocker="${!blocker_var:--}"

		case "$status" in
		PASS) icon="✅" ;;
		FAIL) icon="❌" ;;
		*) icon="🔲" ;;
		esac

		printf '| %s | %s | %s %s | %s |\n' "$g" "$name" "$icon" "$status" "$blocker"
	done

	printf '\n## Verdict: **%s**\n' "$VERDICT"

	if [[ "$VERDICT" != "READY" ]]; then
		printf '\n### Blockers\n'
		for g in $(seq 1 $GATE_COUNT); do
			status_var="GATE_STATUS_$g"
			if [[ "${!status_var}" != "PASS" ]]; then
				name_var="GATE_NAME_$g"
				blocker_var="GATE_BLOCKER_$g"
				printf -- '- **Gate %s — %s:** %s\n' "$g" "${!name_var}" "${!blocker_var:-No blocker specified}"
			fi
		done
	fi
} >"$GATE_CHECKLIST"

echo "Gate checklist written to $GATE_CHECKLIST"

# ─── Write final verdict ───
{
	printf '# Release Verdict — %s\n\n' "$VERDICT"
	printf '**Date:** %s\n' "$NOW"
	printf '**Build revision:** %s\n' "$BUILD_REVISION"
	printf '**Evidence root:** %s\n\n' "$EVIDENCE_DISPLAY"
	printf '## Gate Status\n\n'

	for g in $(seq 1 $GATE_COUNT); do
		name_var="GATE_NAME_$g"
		status_var="GATE_STATUS_$g"
		blocker_var="GATE_BLOCKER_$g"
		printf -- '- **%s. %s:** %s\n' "$g" "${!name_var}" "${!status_var}"
		if [[ "${!status_var}" != "PASS" && -n "${!blocker_var:-}" ]]; then
			printf '  - Blocker: %s\n' "${!blocker_var}"
		fi
	done

	printf '\n## Verdict\n\n**%s**\n\n' "$VERDICT"

	if [[ "$VERDICT" != "READY" ]]; then
		printf 'The release is **not ready**. All gates marked FAIL must be resolved before\n'
		printf 'submission. See the gate checklist for specific actions per gate.\n\n'
		printf '### Next actions\n\n'
		for g in $(seq 1 $GATE_COUNT); do
			status_var="GATE_STATUS_$g"
			if [[ "${!status_var}" != "PASS" ]]; then
				name_var="GATE_NAME_$g"
				blocker_var="GATE_BLOCKER_$g"
				printf -- '- **Gate %s:** %s\n' "$g" "${!blocker_var:-Investigate and resolve}"
			fi
		done
	else
		printf 'All gates pass with current evidence. The build may proceed to submission\n'
		printf 'after a final human review of screenshots, privacy page, and physical QA\n'
		printf 'observations.\n'
	fi
} >"$VERDICT_FILE"

echo "Final verdict written to $VERDICT_FILE"

# Exit with nonzero if not ready
if [[ "$VERDICT" != "READY" ]]; then
	exit 1
fi
exit 0
