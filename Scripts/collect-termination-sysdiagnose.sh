#!/bin/bash
set -euo pipefail

if (($# != 3)); then
	echo "Usage: $0 UI_TEST_LOG DEVICE_UDID DESTINATION" >&2
	exit 64
fi

UI_TEST_LOG="$1"
DEVICE_UDID="$2"
DESTINATION="$3"
TERMINATION_MARKER="Checking for crash reports corresponding to unexpected termination of com.zanish-labs.ziroedge"

if [[ ! -f "$UI_TEST_LOG" ]] || ! grep -Fq "$TERMINATION_MARKER" "$UI_TEST_LOG"; then
	exit 0
fi

mkdir -p "$(dirname "$DESTINATION")"
echo "[RAM-DIAGNOSE] Unexpected ZiroEdge termination detected; collecting full device sysdiagnose"
xcrun devicectl device sysdiagnose \
	--device "$DEVICE_UDID" \
	--gather-full-logs \
	--destination "$DESTINATION" \
	--timeout "${RAM_DIAGNOSTIC_SYSDIAGNOSE_TIMEOUT:-900}" \
	2>&1 | tee "${DESTINATION}.log"
