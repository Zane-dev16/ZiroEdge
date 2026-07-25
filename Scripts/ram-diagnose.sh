#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/test-output/memory-diagnostic"
PROJECT="$PROJECT_DIR/ZiroEdge.xcodeproj"
EXPECTATION="observe"
DESTINATION=""
MODE="device"
UNSAFE_OVERRIDE=0
CONTROLLED_WORKLOAD=0

usage() {
	echo "Usage: $0 [--expect observe|load|block] [--unsafe-override] [--controlled-workload] [--device UDID|--simulator]"
}

while (($#)); do
	case "$1" in
	--expect)
		EXPECTATION="${2:?missing expectation}"
		shift 2
		;;
	--device)
		MODE=device
		DESTINATION="id=${2:?missing UDID}"
		shift 2
		;;
	--simulator)
		MODE=simulator
		shift
		;;
	--unsafe-override)
		UNSAFE_OVERRIDE=1
		shift
		;;
	--controlled-workload)
		CONTROLLED_WORKLOAD=1
		shift
		;;
	*)
		usage
		exit 64
		;;
	esac
done

case "$EXPECTATION" in observe | load | block) ;; *)
	usage
	exit 64
	;;
esac
if ((UNSAFE_OVERRIDE)) && [[ "$EXPECTATION" != load ]]; then
	echo "--unsafe-override requires --expect load" >&2
	exit 64
fi
if ((CONTROLLED_WORKLOAD)) && ((!UNSAFE_OVERRIDE)); then
	echo "--controlled-workload requires --unsafe-override" >&2
	exit 64
fi

case "$EXPECTATION:$UNSAFE_OVERRIDE:$CONTROLLED_WORKLOAD" in
observe:0:0) UI_TEST=testObserveGemmaMemoryOutcome ;;
load:0:0) UI_TEST=testAssertGemmaLoads ;;
load:1:0) UI_TEST=testAssertGemmaLoadsWithUnsafeOverride ;;
load:1:1) UI_TEST=testControlledGemmaWorkloadWithUnsafeOverride ;;
block:0:0) UI_TEST=testAssertGemmaIsBlocked ;;
*)
	usage
	exit 64
	;;
esac

cd "$PROJECT_DIR"
xcodegen generate
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
date -u +'%Y-%m-%dT%H:%M:%SZ' >"$OUTPUT_DIR/run-start-utc.txt"

if [[ "$MODE" == simulator ]]; then
	SIM_UDID="$(xcrun simctl list devices available | sed -nE 's/.*iPhone 17 Pro \(([0-9A-F-]+)\).*/\1/p' | head -1)"
	[[ -n "$SIM_UDID" ]] || {
		echo "No iPhone 17 Pro simulator available" >&2
		exit 69
	}
	DESTINATION="platform=iOS Simulator,id=$SIM_UDID"
elif [[ -z "$DESTINATION" ]]; then
	echo "Physical-device diagnostics require --device UDID." >&2
	echo "Find it with: xcrun xctrace list devices" >&2
	exit 64
fi

echo "destination=$DESTINATION expectation=$EXPECTATION"
set +e
xcodebuild test \
	-project "$PROJECT" \
	-scheme ZiroEdge \
	-destination "$DESTINATION" \
	-derivedDataPath "$OUTPUT_DIR/DerivedData" \
	-resultBundlePath "$OUTPUT_DIR/unit-tests.xcresult" \
	-parallel-testing-enabled NO \
	-only-testing:ZiroEdgeTests/MemoryBudgeterTests \
	-only-testing:ZiroEdgeTests/RAMDiagnosticTests \
	2>&1 | tee "$OUTPUT_DIR/unit-tests.log"
UNIT_TEST_STATUS=${PIPESTATUS[0]}

xcodebuild test \
	-project "$PROJECT" \
	-scheme ZiroEdgeUITests \
	-destination "$DESTINATION" \
	-derivedDataPath "$OUTPUT_DIR/DerivedData" \
	-resultBundlePath "$OUTPUT_DIR/ui-tests.xcresult" \
	-parallel-testing-enabled NO \
	-only-testing:ZiroEdgeUITests/RAMDiagnosticUITests/$UI_TEST \
	2>&1 | tee "$OUTPUT_DIR/ui-tests.log"
UI_TEST_STATUS=${PIPESTATUS[0]}
set -e

grep -E '\[ZIRO-MEMORY(-OUTCOME)?\]' "$OUTPUT_DIR/ui-tests.log" >"$OUTPUT_DIR/records.log" || true

ARTIFACT_FAILURE=0
if [[ "$MODE" == device ]]; then
	DEVICE_ID="${DESTINATION#id=}"

	JSONL_DEST="$OUTPUT_DIR/memory-diagnostic.jsonl"
	if xcrun devicectl device copy from \
		--device "$DEVICE_ID" \
		--domain-type appDataContainer \
		--domain-identifier com.zanish-labs.ziroedge \
		--source Documents/memory-diagnostic.jsonl \
		--destination "$JSONL_DEST" \
		--timeout 60 2>&1; then
		if [[ -s "$JSONL_DEST" ]]; then
			if CHECKPOINTS=$(
				python3 - "$JSONL_DEST" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    checkpoints = [json.loads(line).get("checkpoint", "?") for line in stream]
print(" ".join(checkpoints))
PY
			); then
				echo "[RAM-DIAGNOSE] Recovered JSONL with checkpoints: $CHECKPOINTS"
			else
				echo "[RAM-DIAGNOSE] ERROR: recovered JSONL is not valid" >&2
				ARTIFACT_FAILURE=1
			fi
		else
			echo "[RAM-DIAGNOSE] ERROR: JSONL file is empty or missing on device" >&2
			ARTIFACT_FAILURE=1
		fi
	else
		echo "[RAM-DIAGNOSE] ERROR: devicectl copy of memory-diagnostic.jsonl failed (device may be locked or app terminated)" >&2
		ARTIFACT_FAILURE=1
	fi
fi

if ((ARTIFACT_FAILURE)); then
	echo "Memory diagnostic failed: required measurement artifacts were not retained" >&2
	exit 74
fi
if ((UNIT_TEST_STATUS != 0)); then
	echo "Memory diagnostic failed: unit tests exited $UNIT_TEST_STATUS" >&2
	exit "$UNIT_TEST_STATUS"
fi
if ((UI_TEST_STATUS != 0)); then
	echo "Memory diagnostic failed: UI tests exited $UI_TEST_STATUS" >&2
	exit "$UI_TEST_STATUS"
fi

printf 'Memory diagnostic passed: expectation=%s destination=%s\n' "$EXPECTATION" "$DESTINATION"
