#!/bin/bash
set -euo pipefail

# ZiroEdge Device Test Runner
# Builds, installs, runs UI tests on physical device, collects screenshots,
# diagnostic exports, and hashes, and generates structured evidence.
#
# Usage:
#   bash Scripts/device-test.sh                    # Smoke only (L0)
#   bash Scripts/device-test.sh --layer feature    # Smoke + feature tests (L0+L1)
#   bash Scripts/device-test.sh --layer model      # Smoke + model tests (L0+L2)
#   bash Scripts/device-test.sh --layer all        # All layers
#   bash Scripts/device-test.sh --layer lifecycle  # Issue 06: background/lifecycle
#   bash Scripts/device-test.sh --layer offline     # Issue 07: offline operation
#   bash Scripts/device-test.sh --layer qa-full     # Issue 08: full QA matrix
#   bash Scripts/device-test.sh --test SmokeTests  # Specific test class
#   bash Scripts/device-test.sh --evidence-dir PATH # Write evidence to PATH

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="ZiroEdgeUITests"
UNIT_SCHEME="ZiroEdge"
PROJECT="$PROJECT_DIR/ZiroEdge.xcodeproj"

# --- Args ---
LAYER="smoke"
TEST_CLASS=""
EVIDENCE_DIR=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--layer)
		LAYER="$2"
		shift 2
		;;
	--test)
		TEST_CLASS="$2"
		shift 2
		;;
	--evidence-dir)
		EVIDENCE_DIR="$2"
		shift 2
		;;
	*)
		echo "Unknown arg: $1"
		exit 1
		;;
	esac
done

if [[ "$LAYER" == "lifecycle" || "$LAYER" == "offline" || "$LAYER" == "qa-full" ]]; then
	if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all)" ]]; then
		echo "ERROR: Refusing to record physical release evidence from a dirty source tree."
		exit 1
	fi
fi

# --- Device ---
DEVICE_UDID="${DEVICE_UDID:-}"
if [[ -z "$DEVICE_UDID" ]]; then
	echo ">> Detecting connected device..."
	DEVICE_UDID=$(xcrun xctrace list devices 2>/dev/null |
		grep -E 'iPhone|iPad' | grep -v "Simulator" |
		grep -oE '([0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})' | head -1)
	if [[ -z "$DEVICE_UDID" ]]; then
		echo "ERROR: No physical device found. Set DEVICE_UDID or connect a device."
		exit 1
	fi
fi
DEVICE_INFO=$(xcrun xctrace list devices 2>/dev/null | grep "$DEVICE_UDID" | head -1 || true)
if [[ "$LAYER" == "lifecycle" || "$LAYER" == "offline" || "$LAYER" == "qa-full" ]]; then
	if [[ -z "$DEVICE_INFO" || "$DEVICE_INFO" == *Simulator* ]]; then
		echo "ERROR: Release evidence layers require a connected physical device; '$DEVICE_UDID' was not verified as physical."
		exit 1
	fi
fi
echo ">> Using device: $DEVICE_UDID"

# --- Set output root ---
if [[ -n "$EVIDENCE_DIR" ]]; then
	OUTPUT_DIR="$EVIDENCE_DIR"
else
	OUTPUT_DIR="$PROJECT_DIR/test-output"
fi
SCREENSHOTS_DIR="$OUTPUT_DIR/screenshots"
DIAGNOSTICS_DIR="$OUTPUT_DIR/diagnostics"
RETAINED_XCRESULTS_DIR="$OUTPUT_DIR/retained-xcresults"
EVIDENCE_JSON="$OUTPUT_DIR/evidence.json"
OBSERVATIONS_FILE="$OUTPUT_DIR/operator-observations.txt"

# --- Prepare output ---
rm -rf "$OUTPUT_DIR"
mkdir -p "$SCREENSHOTS_DIR" "$DIAGNOSTICS_DIR" "$RETAINED_XCRESULTS_DIR"

# --- Regenerate project (xcodegen) ---
if command -v xcodegen &>/dev/null; then
	echo ">> Regenerating project with xcodegen..."
	cd "$PROJECT_DIR" && xcodegen generate
fi
if [[ "$LAYER" == "lifecycle" || "$LAYER" == "offline" || "$LAYER" == "qa-full" ]]; then
	if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all)" ]]; then
		echo "ERROR: Project generation changed the source tree; commit or restore generated files before recording evidence."
		exit 1
	fi
fi

# --- Record machine-generated facts ---
RECORD_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_REVISION=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
DEVICE_INFO="${DEVICE_INFO:-unknown}"
DEVICE_NAME=$(echo "$DEVICE_INFO" | sed -E 's/\([0-9A-Fa-f-]+\)//' | xargs || echo "unknown")
DEVICE_OS=$(echo "$DEVICE_INFO" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "unknown")

# Catalog version from Config/Info.plist (the project-level Info.plist used by xcodegen)
CATALOG_VERSION="unknown"
if [[ -f "$PROJECT_DIR/Config/Info.plist" ]]; then
	CATALOG_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :ModelCatalogVersion' "$PROJECT_DIR/Config/Info.plist" 2>/dev/null || echo "unknown")
fi

echo ""
echo "===== Machine Record ====="
echo "  Timestamp:     $RECORD_START"
echo "  Device UDID:   $DEVICE_UDID"
echo "  Device Name:   $DEVICE_NAME"
echo "  Device OS:     $DEVICE_OS"
echo "  Build rev:     $BUILD_REVISION"
echo "  Catalog ver:   $CATALOG_VERSION"
echo "  Command:       $0 --layer $LAYER"
echo "  Evidence dir:  $OUTPUT_DIR"
echo "==========================="
echo ""

# --- Operator observation prompt for physical-only scenarios ---
if [[ "$LAYER" == "lifecycle" || "$LAYER" == "offline" || "$LAYER" == "qa-full" ]]; then
	echo "============================================================"
	echo "  OPERATOR OBSERVATIONS REQUIRED"
	echo "  This layer requires physical actions that XCTest cannot"
	echo "  verify: Airplane Mode, lock/unlock, reboot, etc."
	echo "  Observations will be recorded to: $OBSERVATIONS_FILE"
	echo "============================================================"
	echo ""

	# Initialize observations file with header
	cat >"$OBSERVATIONS_FILE" <<OBSHEADER
# Operator Observations — $LAYER
# Recorded: $RECORD_START
# Device: $DEVICE_NAME ($DEVICE_UDID) running $DEVICE_OS
# Build: $BUILD_REVISION
#
# Lines starting with '#' are comments.
# Add exactly one explicit passing observation per required scenario:
#   [HH:MM:SS] <scenario> — PASS — <specific observed result>
# FAIL and PENDING observations are retained for diagnosis but cannot pass a gate.
#
OBSHEADER

	echo "Operator observation file initialized at $OBSERVATIONS_FILE"
	echo "Add observations with:  echo '[HH:MM:SS] <scenario> — PASS — <specific observed result>' >> $OBSERVATIONS_FILE"
	echo ""
fi

# --- Build for testing ---
echo ">> Building for device (this may take a minute)..."
xcodebuild build-for-testing \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-destination "id=$DEVICE_UDID" \
	-derivedDataPath "$OUTPUT_DIR/DerivedData" \
	-quiet \
	SYMROOT="$OUTPUT_DIR/Build" \
	2>&1 | tail -5

# --- Determine test filter ---
if [[ -n "$TEST_CLASS" ]]; then
	# Specific class
	TEST_FILTER="ZiroEdgeUITests/$TEST_CLASS"
else
	case "$LAYER" in
	smoke)
		TEST_FILTER="ZiroEdgeUITests/SmokeTests"
		;;
	feature)
		TEST_FILTER="ZiroEdgeUITests/SmokeTests:ZiroEdgeUITests/FeatureTests"
		;;
	model)
		TEST_FILTER="ZiroEdgeUITests/SmokeTests:ZiroEdgeUITests/ModelTests"
		;;
	lifecycle)
		TEST_FILTER="ZiroEdgeUITests/SmokeTests:ZiroEdgeUITests/DownloadDiagnosticsTests"
		;;
	offline)
		TEST_FILTER="ZiroEdgeUITests/SmokeTests:ZiroEdgeUITests/ModelTests:ZiroEdgeUITests/DownloadDiagnosticsTests"
		;;
	qa-full)
		TEST_FILTER="ZiroEdgeUITests/SmokeTests:ZiroEdgeUITests/FeatureTests:ZiroEdgeUITests/ModelTests:ZiroEdgeUITests/DownloadDiagnosticsTests"
		;;
	all)
		TEST_FILTER="" # no filter = run everything
		;;
	*)
		echo "Unknown layer: $LAYER"
		exit 1
		;;
	esac
fi

# --- Run tests ---
echo ">> Running tests (layer: $LAYER)..."
TEST_CMD=(
	xcodebuild test-without-building
	-project "$PROJECT"
	-scheme "$SCHEME"
	-destination "id=$DEVICE_UDID"
	-derivedDataPath "$OUTPUT_DIR/DerivedData"
	-resultBundlePath "$OUTPUT_DIR/xcresult.xcresult"
	SYMROOT="$OUTPUT_DIR/Build"
)

if [[ -n "$TEST_FILTER" ]]; then
	# Split on : and add -only-testing for each
	IFS=':' read -ra FILTERS <<<"$TEST_FILTER"
	for f in "${FILTERS[@]}"; do
		TEST_CMD+=(-only-testing "$f")
	done
fi
if [[ "$LAYER" == "offline" ]]; then
	TEST_CMD=(env ZIROEDGE_REQUIRE_OFFLINE_MODELS=1 "${TEST_CMD[@]}")
fi

TEST_EXIT=0
"${TEST_CMD[@]}" 2>&1 | tail -20 || TEST_EXIT=$?

# --- Record the invoked xcodebuild command for evidence ---
XCODEBUILD_CMD="${TEST_CMD[*]}"

# --- Unit tests (ZiroEdgeTests) for lifecycle / offline / qa-full layers ---
# Each suite is invoked separately so retained evidence records an individual
# outcome, exact command, and xcresult hash instead of inferring suite success
# from one aggregate exit code.
UNIT_TEST_EXIT=-1
UNIT_XCRESULT_HASH=""
UNIT_XCODEBUILD_CMD=""
UNIT_SUITES_FILE="$OUTPUT_DIR/unit-test-suites.tsv"
: >"$UNIT_SUITES_FILE"
if [[ "$LAYER" == "lifecycle" || "$LAYER" == "offline" || "$LAYER" == "qa-full" ]]; then
	echo ">> Building for unit testing (ZiroEdgeTests)..."
	xcodebuild build-for-testing \
		-project "$PROJECT" \
		-scheme "$UNIT_SCHEME" \
		-destination "id=$DEVICE_UDID" \
		-derivedDataPath "$OUTPUT_DIR/DerivedDataUnit" \
		-quiet \
		SYMROOT="$OUTPUT_DIR/Build" \
		2>&1 | tail -5

	case "$LAYER" in
	lifecycle)
		UNIT_TEST_SUITES=("DeviceLifecycleQATests")
		;;
	offline)
		UNIT_TEST_SUITES=("OfflineVerificationTests" "OfflineAvailabilityGuardTests")
		;;
	qa-full)
		UNIT_TEST_SUITES=(
			"SubmissionReadinessTests"
			"DownloadDiagnosticTests"
			"ModelMigrationTests"
			"DurableTransferStateTests"
			"StoreRecoveryTests"
		)
		;;
	esac

	UNIT_TEST_EXIT=0
	mkdir -p "$OUTPUT_DIR/unit-xcresults"
	for suite in "${UNIT_TEST_SUITES[@]}"; do
		result_bundle="$OUTPUT_DIR/unit-xcresults/$suite.xcresult"
		UNIT_TEST_CMD=(
			xcodebuild test-without-building
			-project "$PROJECT"
			-scheme "$UNIT_SCHEME"
			-destination "id=$DEVICE_UDID"
			-derivedDataPath "$OUTPUT_DIR/DerivedDataUnit"
			-resultBundlePath "$result_bundle"
			SYMROOT="$OUTPUT_DIR/Build"
			-only-testing "ZiroEdgeTests/$suite"
		)
		command_text="${UNIT_TEST_CMD[*]}"
		suite_exit=0
		"${UNIT_TEST_CMD[@]}" 2>&1 | tail -20 || suite_exit=$?
		if [[ "$suite_exit" -eq 0 ]]; then
			outcome="pass"
		else
			outcome="fail"
			UNIT_TEST_EXIT="$suite_exit"
		fi
		archive="$RETAINED_XCRESULTS_DIR/$suite.xcresult.tar"
		archive_hash=""
		archive_relative="retained-xcresults/$suite.xcresult.tar"
		if [[ -d "$result_bundle" ]]; then
			COPYFILE_DISABLE=1 tar -cf "$archive" -C "$(dirname "$result_bundle")" "$(basename "$result_bundle")"
			archive_hash=$(shasum -a 256 "$archive" | cut -d' ' -f1)
		fi
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$suite" "$outcome" "$suite_exit" "$archive_hash" "$command_text" "$archive_relative" >>"$UNIT_SUITES_FILE"
		if [[ -n "$UNIT_XCODEBUILD_CMD" ]]; then
			UNIT_XCODEBUILD_CMD+=" ; "
		fi
		UNIT_XCODEBUILD_CMD+="$command_text"
	done
	UNIT_XCRESULT_HASH=$(shasum -a 256 "$UNIT_SUITES_FILE" | cut -d' ' -f1)
fi

RECORD_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Extract screenshots from xcresult ---
echo ">> Extracting screenshots..."
if [[ -d "$OUTPUT_DIR/xcresult.xcresult" ]]; then
	python3 "$SCRIPT_DIR/extract-screenshots.py" \
		"$OUTPUT_DIR/xcresult.xcresult" \
		"$SCREENSHOTS_DIR" 2>/dev/null || echo "   (no screenshots extracted — tests may have failed early)"
fi

# --- Archive mutable xcresult bundles, then hash the immutable retained files ---
echo ">> Computing artifact hashes..."
XCRESULT_ARCHIVE_PATH="retained-xcresults/ui-tests.xcresult.tar"
XCRESULT_ARCHIVE_HASH=""
if [[ -d "$OUTPUT_DIR/xcresult.xcresult" ]]; then
	COPYFILE_DISABLE=1 tar -cf "$OUTPUT_DIR/$XCRESULT_ARCHIVE_PATH" -C "$OUTPUT_DIR" xcresult.xcresult
	XCRESULT_ARCHIVE_HASH=$(shasum -a 256 "$OUTPUT_DIR/$XCRESULT_ARCHIVE_PATH" | cut -d' ' -f1)
fi

SCREENSHOT_HASHES_FILE="$OUTPUT_DIR/screenshot-hashes.txt"
: >"$SCREENSHOT_HASHES_FILE"
if compgen -G "$SCREENSHOTS_DIR/*.png" >/dev/null 2>&1; then
	for png in "$SCREENSHOTS_DIR"/*.png; do
		shasum -a 256 "$png" >>"$SCREENSHOT_HASHES_FILE" 2>/dev/null || true
	done
fi

# --- Write machine evidence JSON ---
SCREENSHOT_COUNT=$(find "$SCREENSHOTS_DIR" -name '*.png' -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')

python3 - "$EVIDENCE_JSON" "$RECORD_START" "$RECORD_END" "$DEVICE_UDID" "$DEVICE_NAME" \
	"$DEVICE_OS" "$BUILD_REVISION" "$CATALOG_VERSION" "$LAYER" "$TEST_EXIT" \
	"$XCRESULT_ARCHIVE_HASH" "$XCRESULT_ARCHIVE_PATH" "$SCREENSHOT_COUNT" "$SCREENSHOT_HASHES_FILE" \
	"$XCODEBUILD_CMD" "$UNIT_TEST_EXIT" "$UNIT_XCRESULT_HASH" "$UNIT_XCODEBUILD_CMD" \
	"$UNIT_SUITES_FILE" "physical" <<'PYEVIDENCE'
import sys, json, os

out_path = sys.argv[1]
record = {
    "recorded_at":      sys.argv[2],
    "completed_at":     sys.argv[3],
    "device_udid":      sys.argv[4],
    "device_name":      sys.argv[5],
    "device_os":        sys.argv[6],
    "build_revision":   sys.argv[7],
    "catalog_version":  sys.argv[8],
    "layer":            sys.argv[9],
    "exit_code":        int(sys.argv[10]),
    "xcresult_archive_sha256": sys.argv[11] or None,
    "xcresult_archive_path": sys.argv[12],
    "screenshot_count": int(sys.argv[13]),
    "command":          sys.argv[15] if len(sys.argv) > 15 else "",
    "unit_test_exit_code":   int(sys.argv[16]) if len(sys.argv) > 16 and sys.argv[16] != "-1" else None,
    "unit_xcresult_hash":    sys.argv[17] if len(sys.argv) > 17 and sys.argv[17] else None,
    "unit_xcodebuild_command": sys.argv[18] if len(sys.argv) > 18 else "",
    "source_tree_clean": True,
    "device_kind": sys.argv[20] if len(sys.argv) > 20 else "unknown",
}

record["unit_test_suites"] = []
suites_file = sys.argv[19] if len(sys.argv) > 19 else ""
if suites_file and os.path.exists(suites_file):
    with open(suites_file) as fh:
        for line in fh:
            name, outcome, exit_code, archive_hash, command, archive_path = line.rstrip("\n").split("\t", 5)
            record["unit_test_suites"].append({
                "name": name,
                "outcome": outcome,
                "exit_code": int(exit_code),
                "xcresult_archive_sha256": archive_hash or None,
                "xcresult_archive_path": archive_path,
                "xcodebuild_command": command,
            })

# Read screenshot hashes if available
hashes_file = sys.argv[14]
record["screenshot_hashes"] = {}
if os.path.exists(hashes_file):
    with open(hashes_file) as fh:
        for line in fh:
            line = line.strip()
            if line:
                parts = line.split(maxsplit=1)
                if len(parts) == 2:
                    record["screenshot_hashes"][parts[1]] = parts[0]

with open(out_path, "w") as fh:
    json.dump(record, fh, indent=2)
print(f"Evidence written to {out_path}")
PYEVIDENCE

# --- Append operator prompt if observations file is empty ---
if [[ -f "$OBSERVATIONS_FILE" ]]; then
	obs_lines=$(grep -cv '^#' "$OBSERVATIONS_FILE" 2>/dev/null || echo 0)
	if [[ "$obs_lines" -eq 0 ]]; then
		echo "" >>"$OBSERVATIONS_FILE"
		echo "# ⚠️  NO OPERATOR OBSERVATIONS RECORDED" >>"$OBSERVATIONS_FILE"
		echo "# Evidence for this layer is INCOMPLETE until physical actions are recorded." >>"$OBSERVATIONS_FILE"
		echo "#" >>"$OBSERVATIONS_FILE"

		case "$LAYER" in
		lifecycle)
			cat >>"$OBSERVATIONS_FILE" <<OBSMISSING
# Required scenarios (record exactly one explicit PASS line per scenario):
#   [HH:MM:SS] background-suspension — PASS — <specific observed result>
#   [HH:MM:SS] lock-unlock — PASS — <specific observed result>
#   [HH:MM:SS] os-termination — PASS — <specific observed result>
#   [HH:MM:SS] force-quit — PASS — <specific observed result>
#   [HH:MM:SS] reboot — PASS — <specific observed result>
OBSMISSING
			;;
		offline)
			cat >>"$OBSERVATIONS_FILE" <<OBSMISSING
# Required scenarios (record exactly one explicit PASS line per scenario):
#   [HH:MM:SS] airplane-mode-launch — PASS — <specific observed result>
#   [HH:MM:SS] e2b-text-offline — PASS — <specific observed result>
#   [HH:MM:SS] e4b-text-offline — PASS — <specific observed result>
#   [HH:MM:SS] e2b-vision-offline — PASS — <specific observed result>
#   [HH:MM:SS] e4b-vision-offline — PASS — <specific observed result>
#   [HH:MM:SS] invalid-pair-recovery — PASS — <specific observed result>
#   [HH:MM:SS] conversation-history — PASS — <specific observed result>
OBSMISSING
			;;
		qa-full)
			cat >>"$OBSERVATIONS_FILE" <<OBSMISSING
# Required scenarios (record exactly one explicit PASS line per scenario):
#   [HH:MM:SS] wifi-loss-reconnect — PASS — <specific observed result>
#   [HH:MM:SS] cellular-handoff — PASS — <specific observed result>
#   [HH:MM:SS] repeated-pause-resume — PASS — <specific observed result>
#   [HH:MM:SS] cancel-redownload — PASS — <specific observed result>
#   [HH:MM:SS] low-storage-warn — PASS — <specific observed result>
#   [HH:MM:SS] out-of-space-recovery — PASS — <specific observed result>
#   [HH:MM:SS] repeated-transfer-e2b — PASS — <specific observed result>
#   [HH:MM:SS] repeated-transfer-e4b — PASS — <specific observed result>
#   [HH:MM:SS] reboot-recovery — PASS — <specific observed result>
#   [HH:MM:SS] storage-pressure-recover — PASS — <specific observed result>
OBSMISSING
			;;
		esac

		echo ""
		echo "⚠️  OPERATOR OBSERVATIONS ARE MISSING for layer '$LAYER'."
		echo "   Required prompt has been added to $OBSERVATIONS_FILE"
		echo "   Run each physical scenario and record observations before claiming completion."
	fi
fi

# --- Evidence completeness validation (fail-closed) ---
EVIDENCE_ERRORS=0

echo ""
echo ">> Validating evidence completeness..."

# Core machine facts must be known
for fact in "device_udid:$DEVICE_UDID" "catalog_version:$CATALOG_VERSION" "build_revision:$BUILD_REVISION"; do
	key="${fact%%:*}"
	val="${fact#*:}"
	if [[ -z "$val" || "$val" == "unknown" ]]; then
		echo "   ❌ Missing machine fact: $key (value: '$val')"
		EVIDENCE_ERRORS=$((EVIDENCE_ERRORS + 1))
	fi
done

# UI tests must pass and produce a retained immutable archive.
if [[ "$TEST_EXIT" -ne 0 ]]; then
	echo "   ❌ UI tests failed with exit code $TEST_EXIT"
	EVIDENCE_ERRORS=$((EVIDENCE_ERRORS + 1))
fi
if [[ ! -f "$OUTPUT_DIR/$XCRESULT_ARCHIVE_PATH" || -z "$XCRESULT_ARCHIVE_HASH" ]]; then
	echo "   ❌ Missing retained UI-test xcresult archive or digest"
	EVIDENCE_ERRORS=$((EVIDENCE_ERRORS + 1))
fi

# For lifecycle / offline / qa-full layers: operator observations required
if [[ "$LAYER" == "lifecycle" || "$LAYER" == "offline" || "$LAYER" == "qa-full" ]]; then
	if [[ ! -f "$OBSERVATIONS_FILE" ]]; then
		echo "   ❌ Missing operator observations file for layer '$LAYER'"
		EVIDENCE_ERRORS=$((EVIDENCE_ERRORS + 1))
	elif [[ $(grep -cvE '^\s*#|^\s*$' "$OBSERVATIONS_FILE" 2>/dev/null || echo 0) -eq 0 ]]; then
		echo "   ❌ Operator observations file is empty for layer '$LAYER'"
		EVIDENCE_ERRORS=$((EVIDENCE_ERRORS + 1))
	fi

	# Every required unit suite must pass and retain an immutable xcresult archive.
	if [[ ! -s "$UNIT_SUITES_FILE" ]] || ! awk -F '\t' 'NF != 6 || $2 != "pass" || $3 != 0 || $4 == "" || $6 == "" { bad=1 } END { exit bad }' "$UNIT_SUITES_FILE"; then
		echo "   ❌ Missing or failed individual unit-test suite outcome/xcresult for layer '$LAYER'"
		EVIDENCE_ERRORS=$((EVIDENCE_ERRORS + 1))
	fi

	case "$LAYER" in
	lifecycle)
		VALIDATION_LAYERS="lifecycle"
		VALIDATION_SUITES="DeviceLifecycleQATests"
		VALIDATION_SCENARIOS="background-suspension,lock-unlock,os-termination,force-quit,reboot"
		;;
	offline)
		VALIDATION_LAYERS="offline"
		VALIDATION_SUITES="OfflineVerificationTests,OfflineAvailabilityGuardTests"
		VALIDATION_SCENARIOS="airplane-mode-launch,e2b-text-offline,e4b-text-offline,e2b-vision-offline,e4b-vision-offline,invalid-pair-recovery,conversation-history"
		;;
	qa-full)
		VALIDATION_LAYERS="qa-full"
		VALIDATION_SUITES="SubmissionReadinessTests,DownloadDiagnosticTests,ModelMigrationTests,DurableTransferStateTests,StoreRecoveryTests"
		VALIDATION_SCENARIOS="wifi-loss-reconnect,cellular-handoff,repeated-pause-resume,cancel-redownload,low-storage-warn,out-of-space-recovery,repeated-transfer-e2b,repeated-transfer-e4b,reboot-recovery,storage-pressure-recover"
		;;
	esac
	if ! python3 "$SCRIPT_DIR/validate-release-evidence.py" physical \
		--evidence "$EVIDENCE_JSON" --observations "$OBSERVATIONS_FILE" \
		--layers "$VALIDATION_LAYERS" --revision "$BUILD_REVISION" \
		--suites "$VALIDATION_SUITES" --scenarios "$VALIDATION_SCENARIOS"; then
		echo "   ❌ Physical release evidence failed strict validation"
		EVIDENCE_ERRORS=$((EVIDENCE_ERRORS + 1))
	fi
fi

if [[ $EVIDENCE_ERRORS -gt 0 ]]; then
	echo ""
	echo "❌ EVIDENCE GENERATION FAILED — $EVIDENCE_ERRORS completeness error(s) detected."
	echo "   Required machine facts, test results, or observations are missing."
	echo "   Evidence JSON was written but is INCOMPLETE."
	exit 1
fi

echo "   ✅ Evidence completeness checks passed."

# --- Generate report ---
echo ">> Generating report..."
python3 "$SCRIPT_DIR/generate-report.py" \
	"$OUTPUT_DIR" \
	"$LAYER" \
	"$TEST_EXIT"

echo ""
echo ">> Done!"
echo "   Screenshots:   $SCREENSHOTS_DIR/"
echo "   Report:        $OUTPUT_DIR/report.html"
echo "   Report:        $OUTPUT_DIR/report.md"
echo "   Evidence JSON: $EVIDENCE_JSON"
echo "   Observations:  $OBSERVATIONS_FILE"
echo "   xcresult:      $OUTPUT_DIR/xcresult.xcresult"
if [[ "$UNIT_TEST_EXIT" -gt 0 ]]; then
	exit "$UNIT_TEST_EXIT"
fi
exit "$TEST_EXIT"
