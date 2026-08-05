#!/bin/bash
set -euo pipefail

# ZiroEdge App Store Screenshot Capture (iPad)
# ==============================================
# Captures iPad screenshots at the exact resolutions required by App Store
# Connect (2048x2732 for 12.9" and 1668x2388 for 11").
#
# Simulators are selected by device-type identifier, not by brittle
# display-name parsing. Each size gets a clean extraction directory so
# images cannot leak between runs. Only AppStoreScreenshotTests runs;
# the script uses portrait orientation and verifies output with
# verify-screenshots.py before reporting success.
#
# Requirements:
#   - Xcode (full, not just CLI tools)
#   - iOS Simulator runtime for iPad Pro
#   - xcodegen available on PATH (or pre-generated project)
#
# Usage:
#   bash Scripts/capture-appstore-screenshots.sh
#
# Output:
#   ziroedge-docs/app-store-screenshots/ipad-13/*.png
#   ziroedge-docs/app-store-screenshots/ipad-11/*.png

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_DIR="$PROJECT_DIR/ziroedge-docs/app-store-screenshots"
SCHEME="ZiroEdgeUITests"
PROJECT="$PROJECT_DIR/ZiroEdge.xcodeproj"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"

IPAD_13_DIR="$ASSETS_DIR/ipad-13"
IPAD_11_DIR="$ASSETS_DIR/ipad-11"

# --- Validate environment ---
if ! command -v xcodebuild >/dev/null 2>&1; then
	echo "ERROR: xcodebuild not found. Install Xcode."
	exit 1
fi

# --- Regenerate project ---
if command -v xcodegen >/dev/null 2>&1; then
	echo ">> Regenerating project with xcodegen..."
	cd "$PROJECT_DIR" && xcodegen generate
fi

mkdir -p "$IPAD_13_DIR" "$IPAD_11_DIR"

# --- Helpers ---

ensure_simulator() {
	local device_type="$1"
	local sim_name="$2"

	# Search all devices (not just "available" — that subcommand conflicts with name search)
	local udid
	udid=$(xcrun simctl list devices 2>/dev/null |
		grep -F "$sim_name" | head -1 | grep -oE '[A-F0-9-]{36}' || true)

	if [ -z "${udid:-}" ]; then
		echo ">> Creating simulator '$sim_name' (device type: $device_type)..." >&2
		udid=$(xcrun simctl create "$sim_name" "$device_type" "$RUNTIME" 2>/dev/null || true)
		if [ -z "${udid:-}" ]; then
			echo "ERROR: Could not create simulator '$sim_name' with type '$device_type' and runtime '$RUNTIME'" >&2
			return 1
		fi
	fi
	echo "$udid"
}

is_booted() {
	local udid="$1"
	xcrun simctl list devices | grep "$udid" | grep -oE '\(Booted\)' >/dev/null 2>&1
}

# --- Capture one iPad size ---
capture_size() {
	local size_key="$1"
	local sim_name device_type label dest_dir

	case "$size_key" in
	13)
		sim_name="ZiroEdge Screenshot iPad Pro 12.9"
		device_type="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-12-9-inch-6th-generation-16GB"
		label="iPad 12.9-inch"
		dest_dir="$IPAD_13_DIR"
		;;
	11)
		sim_name="ZiroEdge Screenshot iPad Pro 11"
		device_type="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-4th-generation-16GB"
		label="iPad 11-inch"
		dest_dir="$IPAD_11_DIR"
		;;
	*)
		echo "ERROR: unknown size key '$size_key'"
		return 1
		;;
	esac

	echo ""
	echo "============================================================"
	echo ">> Capturing $label screenshots on '$sim_name'..."
	echo "============================================================"

	local DEVICE_UDID
	DEVICE_UDID=$(ensure_simulator "$device_type" "$sim_name") || return 1
	echo ">> Simulator UDID: $DEVICE_UDID"

	if ! is_booted "$DEVICE_UDID"; then
		echo ">> Booting simulator..."
		xcrun simctl boot "$DEVICE_UDID" 2>/dev/null || true
		sleep 5
	fi

	# Clean extraction area for this run
	local WORK_DIR
	WORK_DIR=$(mktemp -d "/tmp/ziroedge-ipad-screenshots-${size_key}-XXXX")
	local DERIVED="$WORK_DIR/DerivedData"
	local XCRESULT="$WORK_DIR/xcresult-ipad-${size_key}.xcresult"
	local EXTRACT_DIR="$WORK_DIR/extracted"

	# Build once per size
	echo ">> Building for iPad simulator..."
	xcodebuild build-for-testing \
		-project "$PROJECT" \
		-scheme "$SCHEME" \
		-destination "platform=iOS Simulator,id=$DEVICE_UDID" \
		-derivedDataPath "$DERIVED" \
		-quiet \
		SYMROOT="$WORK_DIR/Build" \
		2>&1 | tail -5

	# Run iPad screenshot tests — three required images:
	# 1. sidebar_chat (NavigationSplitView with sidebar + detail)
	# 2. models (Settings → Manage Models)
	# 3. settings (gear sheet)
	echo ">> Running iPad screenshot tests..."
	local test_exit=0
	xcodebuild test-without-building \
		-project "$PROJECT" \
		-scheme "$SCHEME" \
		-destination "platform=iOS Simulator,id=$DEVICE_UDID" \
		-derivedDataPath "$DERIVED" \
		-resultBundlePath "$XCRESULT" \
		-only-testing "ZiroEdgeUITests/AppStoreScreenshotTests/testSidebarAndChat" \
		-only-testing "ZiroEdgeUITests/AppStoreScreenshotTests/testModelsScreen" \
		-only-testing "ZiroEdgeUITests/AppStoreScreenshotTests/testSettingsScreen" \
		SYMROOT="$WORK_DIR/Build" \
		2>&1 | tail -20 || test_exit=$?

	if [ $test_exit -ne 0 ]; then
		echo "ERROR: iPad screenshot tests failed (exit $test_exit). See xcresult: $XCRESULT"
		rm -rf "$WORK_DIR"
		return 1
	fi

	# Extract screenshots
	echo ">> Extracting screenshots..."
	mkdir -p "$EXTRACT_DIR"
	if [ -d "$XCRESULT" ]; then
		python3 "$SCRIPT_DIR/extract-screenshots.py" \
			"$XCRESULT" \
			"$EXTRACT_DIR" 2>/dev/null || {
			echo "ERROR: Screenshot extraction failed"
			rm -rf "$WORK_DIR"
			return 1
		}
	fi

	# Copy to canonical asset directory (clean first)
	rm -rf "$dest_dir"
	mkdir -p "$dest_dir"
	if ls "$EXTRACT_DIR"/*.png >/dev/null 2>&1; then
		cp "$EXTRACT_DIR"/*.png "$dest_dir/"
		echo ">> Copied screenshots to $dest_dir/"
		ls -la "$dest_dir/"
	else
		echo "ERROR: No real UI screenshots were captured for $label"
		rm -rf "$WORK_DIR"
		return 1
	fi

	rm -rf "$WORK_DIR"
	echo ">> Done capturing $label screenshots"
	return 0
}

# --- Main ---
echo "ZiroEdge App Store Screenshot Capture (iPad)"
echo "============================================="
echo ""

capture_size "13" || exit 1
capture_size "11" || exit 1

# --- Run verification ---
echo ""
echo "============================================================"
echo ">> Verifying screenshots..."
python3 "$SCRIPT_DIR/verify-screenshots.py" "$ASSETS_DIR" || {
	echo "ERROR: Screenshot verification failed — images are not submission-ready"
	exit 1
}

echo ""
echo "============================================================"
echo ">> App Store screenshots (iPad):"
echo "   $IPAD_13_DIR/"
echo "   $IPAD_11_DIR/"
echo "============================================================"
