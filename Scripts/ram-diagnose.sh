#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_STAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
OUTPUT_DIR="${RAM_DIAGNOSTIC_OUTPUT_DIR:-$PROJECT_DIR/test-output/memory-diagnostic-$RUN_STAMP}"
PROJECT="$PROJECT_DIR/ZiroEdge.xcodeproj"
EXPECTATION="observe"
DESTINATION=""
MODE="device"
CALIBRATION_LOAD=0
CONTROLLED_WORKLOAD=0
PROFILE=text
MODEL=e4b

usage() {
	echo "Usage: $0 [--expect observe|load|block] [--calibration-load] [--controlled-workload] [--model llama|e2b|e4b] [--profile text|vision] [--device UDID|--simulator]"
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
	--calibration-load)
		CALIBRATION_LOAD=1
		shift
		;;
	--controlled-workload)
		CONTROLLED_WORKLOAD=1
		shift
		;;
	--model)
		MODEL="${2:?missing model}"
		shift 2
		;;
	--profile)
		PROFILE="${2:?missing profile}"
		shift 2
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
case "$PROFILE" in text | vision) ;; *)
	usage
	exit 64
	;;
esac
case "$MODEL" in llama | e2b | e4b) ;; *)
	usage
	exit 64
	;;
esac
if ((CALIBRATION_LOAD)) && [[ "$EXPECTATION" != load ]]; then
	echo "--calibration-load requires --expect load" >&2
	exit 64
fi
if [[ "$EXPECTATION" == load ]] && ((!CONTROLLED_WORKLOAD)); then
	echo "load requires --controlled-workload --calibration-load" >&2
	exit 64
fi
if ((CONTROLLED_WORKLOAD)) && ((!CALIBRATION_LOAD)); then
	echo "--controlled-workload requires --calibration-load" >&2
	exit 64
fi
if [[ "$MODEL" == llama && "$PROFILE" != text ]]; then
	echo "Llama supports only the text profile" >&2
	exit 64
fi
if [[ "$MODEL" == e2b && "$PROFILE" != vision ]]; then
	echo "E2B text prompts run inside its paired vision profile; calibrate that exact shape with --profile vision" >&2
	exit 64
fi

cd "$PROJECT_DIR"
xcodegen generate
if [[ -e "$OUTPUT_DIR" ]] && [[ -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
	echo "Refusing to overwrite existing diagnostic artifacts: $OUTPUT_DIR" >&2
	exit 73
fi
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

case "$MODEL:$PROFILE" in
llama:text)
	CALIBRATION_MODEL_ID=llama3.2-3b-q4
	TARGET_SUFFIX=Llama
	;;
e2b:vision)
	CALIBRATION_MODEL_ID=gemma-4-e2b-q4
	TARGET_SUFFIX=E2BVision
	;;
e4b:text)
	CALIBRATION_MODEL_ID=gemma-4-e4b-q4-text-calibration
	TARGET_SUFFIX=E4BText
	;;
e4b:vision)
	CALIBRATION_MODEL_ID=gemma-4-e4b-q4
	TARGET_SUFFIX=E4BVision
	;;
esac

case "$EXPECTATION:$CALIBRATION_LOAD:$CONTROLLED_WORKLOAD" in
observe:0:0) UI_TEST="testObserve${TARGET_SUFFIX}MemoryOutcome" ;;
load:1:1) UI_TEST="testControlled${TARGET_SUFFIX}Workload" ;;
block:0:0) UI_TEST="testBlock${TARGET_SUFFIX}UnvalidatedProfile" ;;
*)
	usage
	exit 64
	;;
esac

echo "destination=$DESTINATION expectation=$EXPECTATION model=$CALIBRATION_MODEL_ID profile=$PROFILE"
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
	-only-testing:ZiroEdgeTests/MemoryProfileTests \
	-only-testing:ZiroEdgeTests/InferenceDiagnosticTests \
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

if [[ "$MODE" == device ]] && ((CONTROLLED_WORKLOAD)) && ((UI_TEST_STATUS != 0)); then
	DEVICE_ID="${DESTINATION#id=}"
	if ! "$SCRIPT_DIR/collect-termination-sysdiagnose.sh" \
		"$OUTPUT_DIR/ui-tests.log" \
		"$DEVICE_ID" \
		"$OUTPUT_DIR/sysdiagnose"; then
		echo "[RAM-DIAGNOSE] WARNING: full sysdiagnose collection failed; do not retry the workload blindly" >&2
	fi
fi

grep -E '\[ZIRO-MEMORY(-OUTCOME)?\]' "$OUTPUT_DIR/ui-tests.log" >"$OUTPUT_DIR/records.log" || true

ARTIFACT_FAILURE=0
for required in unit-tests.log ui-tests.log unit-tests.xcresult ui-tests.xcresult run-start-utc.txt; do
	if [[ ! -e "$OUTPUT_DIR/$required" ]]; then
		echo "[RAM-DIAGNOSE] ERROR: required artifact missing: $required" >&2
		ARTIFACT_FAILURE=1
	fi
done
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
				if ((CONTROLLED_WORKLOAD)); then
					if ! python3 "$SCRIPT_DIR/validate_memory_calibration.py" \
						"$JSONL_DEST" \
						--model-id "$CALIBRATION_MODEL_ID" \
						--mode "$PROFILE" \
						--summary "$OUTPUT_DIR/calibration-summary.json"; then
						ARTIFACT_FAILURE=1
					fi
				fi
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

	INFERENCE_DEST="$OUTPUT_DIR/inference-diagnostic.jsonl"
	if ! xcrun devicectl device copy from \
		--device "$DEVICE_ID" \
		--domain-type appDataContainer \
		--domain-identifier com.zanish-labs.ziroedge \
		--source Documents/inference-diagnostic.jsonl \
		--destination "$INFERENCE_DEST" \
		--timeout 60 2>&1 || [[ ! -s "$INFERENCE_DEST" ]]; then
		echo "[RAM-DIAGNOSE] ERROR: complete inference checkpoint JSONL was not retained" >&2
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

printf 'Memory diagnostic passed: expectation=%s profile=%s destination=%s\n' "$EXPECTATION" "$PROFILE" "$DESTINATION"
