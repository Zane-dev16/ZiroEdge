#!/bin/bash
set -euo pipefail

# ZiroEdge Download Quick Diagnostic
# Launches the app with --uitesting-download, captures download logs from
# stdout for 90 seconds, then analyzes the output.
#
# Usage:
#   bash Scripts/download-quick-diagnose.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/test-output/download-quick"
PROJECT="$PROJECT_DIR/ZiroEdge.xcodeproj"

DEVICE_UDID="${DEVICE_UDID:-}"
if [[ -z "$DEVICE_UDID" ]]; then
	echo ">> Detecting device..."
	DEVICE_UDID=$(xcrun xctrace list devices 2>/dev/null |
		grep -E 'iPhone|iPad' | grep -v "Simulator" |
		grep -oE '([0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})' | head -1)
fi
echo ">> Device: $DEVICE_UDID"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Build
echo ">> Building..."
xcodebuild build -project "$PROJECT" -scheme ZiroEdge \
	-destination "id=$DEVICE_UDID" -quiet 2>&1 | tail -3

# Install
echo ">> Installing..."
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/ZiroEdge-*/Build/Products/Debug-iphoneos -name "ZiroEdge.app" -maxdepth 1 2>/dev/null | head -1)
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH" 2>&1 | tail -3

# Terminate any existing instance
xcrun devicectl device process terminate --device "$DEVICE_UDID" com.zanish-labs.ziroedge 2>/dev/null || true
sleep 1

# Launch with download flag and capture stdout
echo ">> Launching with --uitesting-download (capturing logs for 90s)..."
LOG_FILE="$OUTPUT_DIR/download.log"

xcrun devicectl device process launch \
	--device "$DEVICE_UDID" \
	--console \
	--terminate-existing \
	com.zanish-labs.ziroedge \
	--uitesting-download \
	>"$LOG_FILE" 2>&1 &
LAUNCH_PID=$!

# Wait for logs to accumulate
sleep 90

# Stop capturing
kill "$LAUNCH_PID" 2>/dev/null || true
wait "$LAUNCH_PID" 2>/dev/null || true

# Terminate the app
xcrun devicectl device process terminate --device "$DEVICE_UDID" com.zanish-labs.ziroedge 2>/dev/null || true

echo ">> Analyzing logs..."
FILTERED="$OUTPUT_DIR/filtered.log"
grep -E '\[DL-|\[TRANSPORT\]|\[UITEST-DL\]|download|error|Error|FAIL|bytes|offset|progress' \
	"$LOG_FILE" >"$FILTERED" 2>/dev/null || true

# Analysis
REPORT="$OUTPUT_DIR/report.md"
python3 - "$FILTERED" "$LOG_FILE" "$REPORT" <<'PYEOF'
import sys, re, json
from pathlib import Path
from datetime import datetime

filtered = Path(sys.argv[1]).read_text(errors="replace") if Path(sys.argv[1]).exists() else ""
raw = Path(sys.argv[2]).read_text(errors="replace") if Path(sys.argv[2]).exists() else ""
report_path = sys.argv[3]

lines = filtered.strip().split("\n") if filtered.strip() else []
all_lines = raw.strip().split("\n") if raw.strip() else []

findings = {
    "download_started": False,
    "max_progress": 0,
    "redirects": 0,
    "errors": [],
    "transport_passed": 0,
    "transport_failed": 0,
    "completed": False,
}

for line in lines:
    if "[DL-START]" in line or "[UITEST-DL] startDownload" in line:
        findings["download_started"] = True
    if "[DL-PROG]" in line:
        m = re.search(r'(\d+)%', line)
        if m:
            findings["max_progress"] = max(findings["max_progress"], int(m.group(1)))
    if "[DL-REDIRECT]" in line:
        findings["redirects"] += 1
    if "[TRANSPORT] ALL CHECKS PASSED" in line:
        findings["transport_passed"] += 1
    if "[TRANSPORT] FAIL" in line:
        findings["transport_failed"] += 1
        findings["errors"].append(line.strip())
    if "[DL-FAIL]" in line:
        findings["errors"].append(line.strip())
    if "[DL-VERIFY] SUCCESSFULLY" in line:
        findings["completed"] = True
    if "[DL-COMP] FAILED" in line or "[DL-COMP] NSError" in line:
        findings["errors"].append(line.strip())

# Root cause
if not findings["download_started"]:
    rc = "download_never_started"
    diag = "The download was never triggered. Check if --uitesting-download is working."
elif findings["completed"]:
    rc = "download_completed"
    diag = "Download completed successfully!"
elif findings["max_progress"] == 0:
    rc = "stuck_at_zero"
    diag = "Download started but no progress. Server not responding or connection issue."
elif findings["transport_failed"] > 0:
    rc = "transport_failed"
    diag = f"Download received data but transport validation rejected it ({findings['transport_failed']} failures)."
elif findings["errors"]:
    rc = "download_error"
    diag = f"Download failed with {len(findings['errors'])} error(s)."
else:
    rc = "incomplete"
    diag = f"Download reached {findings['max_progress']}% but didn't complete in the monitoring window."

with open(report_path, "w") as f:
    f.write("# Download Quick Diagnostic\n\n")
    f.write(f"**Date:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
    f.write(f"## Root Cause: `{rc}`\n\n{diag}\n\n")
    f.write(f"## Stats\n\n")
    f.write(f"- Download started: {'✅' if findings['download_started'] else '❌'}\n")
    f.write(f"- Max progress: {findings['max_progress']}%\n")
    f.write(f"- Redirects: {findings['redirects']}\n")
    f.write(f"- Transport passed: {findings['transport_passed']}\n")
    f.write(f"- Transport failed: {findings['transport_failed']}\n")
    f.write(f"- Completed: {'✅' if findings['completed'] else '❌'}\n")
    f.write(f"- Errors: {len(findings['errors'])}\n\n")
    if findings["errors"]:
        f.write("## Errors\n\n")
        for err in findings["errors"]:
            f.write(f"```\n{err}\n```\n")
        f.write("\n")
    f.write("## Filtered Log\n\n```\n")
    f.write(filtered if filtered else "(no download log lines)")
    f.write("\n```\n")

print(f">> Root cause: {rc}")
print(f">> Diagnosis: {diag}")
print(f">> Max progress: {findings['max_progress']}%")
print(f">> Errors: {len(findings['errors'])}")
PYEOF

echo ""
echo ">> Report: $REPORT"
echo ">> Full log: $LOG_FILE"
