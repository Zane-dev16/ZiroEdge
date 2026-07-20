#!/bin/bash
set -euo pipefail

# ZiroEdge Download Diagnostic Harness
# Builds, runs the download UI test, captures all output, and produces a
# structured analysis report.
#
# Usage:
#   bash Scripts/download-diagnose.sh                          # Full diagnostic
#   bash Scripts/download-diagnose.sh --quick                   # Button-exists only
#   bash Scripts/download-diagnose.sh --timeout 180             # Monitor seconds
#
# Output:
#   test-output/download-diagnose/
#     logs/full.log           — full xcodebuild output
#     logs/filtered.log       — download-related lines only
#     screenshots/            — XCTest screenshot attachments
#     report.md               — structured analysis report
#     analysis.json           — machine-readable findings

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/test-output/download-diagnose"
LOGS_DIR="$OUTPUT_DIR/logs"
SCREENSHOTS_DIR="$OUTPUT_DIR/screenshots"
PROJECT="$PROJECT_DIR/ZiroEdge.xcodeproj"

# --- Args ---
DEVICE_UDID="${DEVICE_UDID:-}"
TEST_CLASS="DownloadDiagnosticsTests"
TEST_METHOD="testDownloadDiagnostic"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--quick)
		TEST_METHOD="testDownloadButtonExists"
		shift
		;;
	--device)
		DEVICE_UDID="$2"
		shift 2
		;;
	--timeout)
		shift
		;;
	--test)
		TEST_METHOD="$2"
		shift 2
		;;
	*)
		echo "Unknown arg: $1"
		exit 1
		;;
	esac
done

# --- Detect device ---
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
echo ">> Using device: $DEVICE_UDID"

# --- Prepare output ---
rm -rf "$OUTPUT_DIR"
mkdir -p "$LOGS_DIR" "$SCREENSHOTS_DIR"

# --- Regenerate project ---
if command -v xcodegen &>/dev/null; then
	echo ">> Regenerating project..."
	cd "$PROJECT_DIR" && xcodegen generate
fi

# --- Build for testing ---
echo ">> Building for device..."
xcodebuild build-for-testing \
	-project "$PROJECT" \
	-scheme "ZiroEdgeUITests" \
	-destination "id=$DEVICE_UDID" \
	-derivedDataPath "$OUTPUT_DIR/DerivedData" \
	-quiet \
	SYMROOT="$OUTPUT_DIR/Build" \
	2>&1 | tail -5

# --- Run the UI test and capture ALL output ---
echo ">> Running download diagnostic test ($TEST_METHOD)..."
echo ">> This will monitor the download for up to 2 minutes..."
FULL_LOG="$LOGS_DIR/full.log"

TEST_EXIT=0
xcodebuild test-without-building \
	-project "$PROJECT" \
	-scheme "ZiroEdgeUITests" \
	-destination "id=$DEVICE_UDID" \
	-derivedDataPath "$OUTPUT_DIR/DerivedData" \
	-resultBundlePath "$OUTPUT_DIR/xcresult.xcresult" \
	-only-testing "ZiroEdgeUITests/$TEST_CLASS/$TEST_METHOD" \
	SYMROOT="$OUTPUT_DIR/Build" \
	2>&1 | tee "$FULL_LOG" || TEST_EXIT=$?

# --- Extract screenshots ---
echo ">> Extracting screenshots..."
if [[ -d "$OUTPUT_DIR/xcresult.xcresult" ]]; then
	python3 "$SCRIPT_DIR/extract-screenshots.py" \
		"$OUTPUT_DIR/xcresult.xcresult" \
		"$SCREENSHOTS_DIR" 2>/dev/null || echo "   (no screenshots extracted)"
fi

# --- Filter and analyze logs ---
echo ">> Analyzing logs..."
FILTERED_LOG="$LOGS_DIR/filtered.log"

# Extract download-related lines from the full test output
grep -iE '\[DL-|\[TRANSPORT\]|download|DownloadManager|error:|FAIL|SUCCESS|PROG|REDIRECT|SESSION|COMP|START.*download|DONE|VERIFY|PAUSE|CANCEL|progress|staging|resume|URLSession|bytes|offset|content.range|HTTP.*[0-9]' \
	"$FULL_LOG" >"$FILTERED_LOG" 2>/dev/null || true

# Also extract UITEST lines
grep -E '\[UITEST\]' "$FULL_LOG" >>"$FILTERED_LOG" 2>/dev/null || true

# --- Build analysis report ---
REPORT="$OUTPUT_DIR/report.md"
ANALYSIS="$OUTPUT_DIR/analysis.json"

python3 - "$FILTERED_LOG" "$FULL_LOG" "$REPORT" "$ANALYSIS" "$TEST_EXIT" "$SCREENSHOTS_DIR" <<'PYTHON_SCRIPT'
import sys
import os
import json
import re
from datetime import datetime
from pathlib import Path

filtered_path = sys.argv[1]
raw_path = sys.argv[2]
report_path = sys.argv[3]
analysis_path = sys.argv[4]
test_exit = int(sys.argv[5])
screenshots_dir = sys.argv[6]

# Read logs
filtered = Path(filtered_path).read_text(errors="replace") if os.path.exists(filtered_path) else ""
raw = Path(raw_path).read_text(errors="replace") if os.path.exists(raw_path) else ""

# Parse log lines
lines = filtered.strip().split("\n") if filtered.strip() else []
all_lines = raw.strip().split("\n") if raw.strip() else []

# --- Analysis ---
findings = {
    "timestamp": datetime.now().isoformat(),
    "test_exit_code": test_exit,
    "total_log_lines": len(all_lines),
    "filtered_log_lines": len(lines),
    "download_started": False,
    "download_progress": [],
    "redirects": [],
    "transport_checks": [],
    "errors": [],
    "completions": [],
    "session_config": {},
    "uitest_observations": [],
    "final_state": "unknown",
    "root_cause": None,
}

# Parse structured log tags
for line in lines:
    # Download start
    if "[DL-START]" in line:
        findings["download_started"] = True
        if "sourceURL=" in line:
            url_match = re.search(r'sourceURL=(\S+)', line)
            if url_match:
                findings.setdefault("source_url", url_match.group(1))
        if "expectedBytes=" in line:
            size_match = re.search(r'expectedBytes=(\d+)', line)
            if size_match:
                findings.setdefault("expected_bytes", int(size_match.group(1)))
        if "RESUMING" in line:
            offset_match = re.search(r'offset (\d+)', line)
            if offset_match:
                findings.setdefault("resume_offset", int(offset_match.group(1)))
        if "FAILED to create" in line:
            findings["errors"].append(line.strip())

    # Progress
    if "[DL-PROG]" in line:
        pct_match = re.search(r'(\d+)%', line)
        if pct_match:
            findings["download_progress"].append({
                "percent": int(pct_match.group(1)),
                "line": line.strip()
            })

    # Redirects
    if "[DL-REDIRECT]" in line:
        findings["redirects"].append(line.strip())

    # Transport
    if "[TRANSPORT]" in line:
        if "FAIL" in line:
            fail_reason = re.search(r'FAIL:\s*(.+)', line)
            findings["transport_checks"].append({
                "passed": False,
                "reason": fail_reason.group(1).strip() if fail_reason else line.strip(),
                "line": line.strip()
            })
        elif "ALL CHECKS PASSED" in line:
            findings["transport_checks"].append({"passed": True, "line": line.strip()})

    # Errors
    if "[DL-FAIL]" in line:
        findings["errors"].append(line.strip())
    if "[DL-COMP]" in line and "FAILED" in line:
        findings["errors"].append(line.strip())
    if "[DL-COMP]" in line and "NSError" in line:
        findings["errors"].append(line.strip())
    if "[DL-COMP]" in line and "error=" in line and "error=nil" not in line:
        findings["errors"].append(line.strip())

    # Session config
    if "[DL-SESSION]" in line:
        if "timeoutIntervalForRequest=" in line:
            m = re.search(r'timeoutIntervalForRequest=(\S+)', line)
            if m: findings["session_config"]["timeout_request"] = m.group(1)
        if "waitsForConnectivity=" in line:
            m = re.search(r'waitsForConnectivity=(\S+)', line)
            if m: findings["session_config"]["waits_for_connectivity"] = m.group(1)

    # UITest observations
    if "[UITEST]" in line:
        findings["uitest_observations"].append(line.strip())
        if "ERROR BANNER" in line:
            findings["errors"].append(line.strip())
        if "DOWNLOAD COMPLETE" in line:
            findings["final_state"] = "downloaded"
        if "DOWNLOAD FAILED" in line:
            findings["final_state"] = "failed"

    # Completions
    if "[DL-VERIFY]" in line and "SUCCESSFULLY" in line:
        findings["completions"].append("verified_and_promoted")
        findings["final_state"] = "downloaded"
    if "[DL-DONE]" in line and "TRANSPORT VALIDATION FAILED" in line:
        findings["final_state"] = "transport_failed"
    if "[DL-COMP]" in line and "FAILED" in line:
        if findings["final_state"] != "downloaded":
            findings["final_state"] = "error"

# Determine root cause
if not findings["download_started"]:
    # Check if UITest even navigated to models
    uitest_nav = [l for l in findings["uitest_observations"] if "models_nav_failed" in l or "no_model_cells" in l]
    if uitest_nav:
        findings["root_cause"] = "ui_navigation_failed"
        findings["diagnosis"] = "The UI test could not navigate to the Models view. The app UI may have changed or onboarding is blocking."
    else:
        findings["root_cause"] = "download_never_started"
        findings["diagnosis"] = "The download task was never created. Check if startDownload() was called and if the URL is valid."
elif findings["download_progress"]:
    max_pct = max(p["percent"] for p in findings["download_progress"])
    if max_pct == 0:
        findings["root_cause"] = "stuck_at_zero_percent"
        findings["diagnosis"] = "Download started but no progress was observed. The server may not be responding with data, or the connection is too slow. Check redirect logs and transport validation."
    elif max_pct < 100 and findings["final_state"] not in ("downloaded",):
        findings["root_cause"] = "download_interrupted"
        findings["diagnosis"] = f"Download reached {max_pct}% but did not complete. Check network stability, timeout settings, and error logs."
    elif findings["final_state"] == "transport_failed":
        findings["root_cause"] = "transport_validation_failed"
        findings["diagnosis"] = "The downloaded file passed some progress but failed transport validation (size, range, or content checks). See transport_checks."
    elif findings["final_state"] == "error":
        findings["root_cause"] = "verification_failed"
        findings["diagnosis"] = "The file downloaded but failed SHA-256 verification or file promotion."
    else:
        findings["root_cause"] = "download_completed"
        findings["diagnosis"] = "Download completed successfully."
elif findings["final_state"] == "transport_failed":
    findings["root_cause"] = "transport_validation_failed"
    findings["diagnosis"] = "Transport validation rejected the response before any progress was recorded."
elif findings["errors"]:
    findings["root_cause"] = "download_error"
    findings["diagnosis"] = f"Download failed with {len(findings['errors'])} error(s). See errors list."
else:
    findings["root_cause"] = "no_progress_observed"
    findings["diagnosis"] = "Download may have started but no progress events were captured. The download may be stuck or the monitoring window was too short."

# --- Write analysis JSON ---
with open(analysis_path, "w") as f:
    json.dump(findings, f, indent=2)

# --- Write report ---
screenshot_files = sorted(Path(screenshots_dir).glob("*.png")) if os.path.isdir(screenshots_dir) else []

with open(report_path, "w") as f:
    f.write("# ZiroEdge Download Diagnostic Report\n\n")
    f.write(f"**Date:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}  \n")
    f.write(f"**Test exit code:** {test_exit}  \n")
    f.write(f"**Log lines captured:** {len(all_lines)}  \n")
    f.write(f"**Filtered lines:** {len(lines)}  \n")
    f.write(f"**Screenshots:** {len(screenshot_files)}  \n\n")

    f.write("## Root Cause\n\n")
    f.write(f"**Category:** `{findings['root_cause']}`  \n")
    f.write(f"**Diagnosis:** {findings.get('diagnosis', 'N/A')}  \n\n")

    f.write("## Download State\n\n")
    f.write(f"- Download started: {'✅' if findings['download_started'] else '❌'}\n")
    if "source_url" in findings:
        f.write(f"- Source URL: `{findings['source_url']}`\n")
    if "expected_bytes" in findings:
        size_mb = findings['expected_bytes'] / (1024 * 1024)
        f.write(f"- Expected size: {size_mb:.1f} MB ({findings['expected_bytes']:,} bytes)\n")
    if "resume_offset" in findings:
        offset_mb = findings['resume_offset'] / (1024 * 1024)
        f.write(f"- Resume offset: {offset_mb:.1f} MB ({findings['resume_offset']:,} bytes)\n")
    max_pct = max((p['percent'] for p in findings['download_progress']), default=0)
    f.write(f"- Max progress: {max_pct}%\n")
    f.write(f"- Redirects: {len(findings['redirects'])}\n")
    transport_passed = sum(1 for c in findings['transport_checks'] if c['passed'])
    transport_failed = sum(1 for c in findings['transport_checks'] if not c['passed'])
    f.write(f"- Transport checks: {transport_passed} passed, {transport_failed} failed\n")
    f.write(f"- Errors: {len(findings['errors'])}\n")
    f.write(f"- Completions: {len(findings['completions'])}\n")
    f.write(f"- Final state: `{findings['final_state']}`\n\n")

    if findings["session_config"]:
        f.write("## URLSession Configuration\n\n")
        for k, v in findings["session_config"].items():
            f.write(f"- {k}: `{v}`\n")
        f.write("\n")

    if findings["redirects"]:
        f.write("## Redirects\n\n")
        for r in findings["redirects"]:
            f.write(f"```\n{r}\n```\n")
        f.write("\n")

    if findings["transport_checks"]:
        f.write("## Transport Validation\n\n")
        for check in findings["transport_checks"]:
            if check["passed"]:
                f.write(f"- ✅ PASSED\n")
            else:
                f.write(f"- ❌ FAILED: {check.get('reason', '')}\n")
        f.write("\n")

    if findings["download_progress"]:
        f.write("## Progress Timeline\n\n")
        f.write("| # | Percent |\n|---|--------|\n")
        for idx, p in enumerate(findings["download_progress"]):
            f.write(f"| {idx+1} | {p['percent']}% |\n")
        f.write("\n")

    if findings["uitest_observations"]:
        f.write("## UI Test Observations\n\n")
        for obs in findings["uitest_observations"]:
            f.write(f"- `{obs}`\n")
        f.write("\n")

    if findings["errors"]:
        f.write("## Errors\n\n")
        for err in findings["errors"]:
            f.write(f"```\n{err}\n```\n")
        f.write("\n")

    if screenshot_files:
        f.write("## Screenshots\n\n")
        for sf in screenshot_files:
            f.write(f"![{sf.name}](screenshots/{sf.name})\n\n")

    f.write("## Filtered Log\n\n")
    f.write("```\n")
    f.write(filtered if filtered else "(no download-related log lines captured)")
    f.write("\n```\n")

print(f">> Report: {report_path}")
print(f">> Analysis: {analysis_path}")
print(f">> Root cause: {findings['root_cause']}")
print(f">> Diagnosis: {findings.get('diagnosis', 'N/A')}")
PYTHON_SCRIPT

echo ""
echo ">> Done!"
echo "   Report:     $REPORT"
echo "   Analysis:   $ANALYSIS"
echo "   Logs:       $LOGS_DIR/"
echo "   Screenshots: $SCREENSHOTS_DIR/"
echo "   xcresult:   $OUTPUT_DIR/xcresult.xcresult"
exit $TEST_EXIT
