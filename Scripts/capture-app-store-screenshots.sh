#!/bin/bash
set -euo pipefail

# ZiroEdge App Store Screenshot Capture (iPhone)
# ================================================
# Captures iPhone screenshots at the exact resolutions required by App Store
# Connect (1290x2796 for 6.7" and 1179x2556 for 6.1").
#
# Simulators are selected by device-type identifier, not by brittle
# display-name parsing. Each size gets a clean extraction directory so
# images cannot leak between runs. The script runs verify-screenshots.py
# before reporting success.
#
# Requirements:
#   - Xcode (full, not just CLI tools)
#   - iOS Simulator runtime matching the device types below
#   - xcodegen available on PATH (or pre-generated project)
#
# Usage:
#   bash Scripts/capture-app-store-screenshots.sh              # both sizes
#   bash Scripts/capture-app-store-screenshots.sh --size 67    # 6.7" only
#   bash Scripts/capture-app-store-screenshots.sh --size 61    # 6.1" only
#
# Output:
#   ziroedge-docs/app-store-screenshots/iphone-67/*.png
#   ziroedge-docs/app-store-screenshots/iphone-61/*.png

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_DIR="$PROJECT_DIR/ziroedge-docs/app-store-screenshots"
SCHEME="ZiroEdgeUITests"
PROJECT="$PROJECT_DIR/ZiroEdge.xcodeproj"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"

IPHONE_67_DIR="$ASSETS_DIR/iphone-67"
IPHONE_61_DIR="$ASSETS_DIR/iphone-61"

# --- Args ---
SIZE="all"
while [ $# -gt 0 ]; do
	case "$1" in
	--size)
		SIZE="$2"
		shift 2
		;;
	*)
		echo "Unknown arg: $1"
		exit 1
		;;
	esac
done

# --- Validate environment ---
if ! command -v xcodebuild >/dev/null 2>&1; then
	echo "ERROR: xcodebuild not found. Install Xcode."
	exit 1
fi

if ! xcrun simctl list runtimes | grep -q "iOS"; then
	echo "ERROR: No iOS Simulator runtime found."
	exit 1
fi

# --- Regenerate project ---
if command -v xcodegen >/dev/null 2>&1; then
	echo ">> Regenerating project with xcodegen..."
	cd "$PROJECT_DIR" && xcodegen generate
fi

mkdir -p "$IPHONE_67_DIR" "$IPHONE_61_DIR"

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

# --- Capture one size ---
capture_size() {
	local size_key="$1"
	local sim_name device_type label dest_dir

	case "$size_key" in
	67)
		sim_name="ZiroEdge Screenshot iPhone 16 Pro Max"
		device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max"
		label="6.7-inch"
		dest_dir="$IPHONE_67_DIR"
		;;
	61)
		sim_name="ZiroEdge Screenshot iPhone 16 Pro"
		device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
		label="6.1-inch"
		dest_dir="$IPHONE_61_DIR"
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

	# Clean extraction area for this run — prevents image leakage between sizes
	local WORK_DIR
	WORK_DIR=$(mktemp -d "/tmp/ziroedge-screenshots-${size_key}-XXXX")
	local DERIVED="$WORK_DIR/DerivedData"
	local XCRESULT="$WORK_DIR/xcresult-${size_key}.xcresult"
	local EXTRACT_DIR="$WORK_DIR/extracted"

	# Build for testing
	echo ">> Building for simulator..."
	xcodebuild build-for-testing \
		-project "$PROJECT" \
		-scheme "$SCHEME" \
		-destination "platform=iOS Simulator,id=$DEVICE_UDID" \
		-derivedDataPath "$DERIVED" \
		-quiet \
		SYMROOT="$WORK_DIR/Build" \
		2>&1 | tail -5

	# Run screenshot capture tests — the three required images:
	# 1. chat_view (empty or with existing conversations)
	# 2. models_page (Settings → Manage Models)
	# 3. settings (gear sheet)
	#
	# testCaptureChatWithMessages is excluded here because it requires a
	# pre-seeded production model. Run it separately after model seeding:
	#   xcodebuild test ... -only-testing "ZiroEdgeUITests/AppStoreScreenshotCapture/testCaptureChatWithMessages"
	echo ">> Running screenshot capture tests..."
	local test_exit=0
	xcodebuild test-without-building \
		-project "$PROJECT" \
		-scheme "$SCHEME" \
		-destination "platform=iOS Simulator,id=$DEVICE_UDID" \
		-derivedDataPath "$DERIVED" \
		-resultBundlePath "$XCRESULT" \
		-only-testing "ZiroEdgeUITests/AppStoreScreenshotCapture/testCaptureChatEmptyState" \
		-only-testing "ZiroEdgeUITests/AppStoreScreenshotCapture/testCaptureModelsPage" \
		-only-testing "ZiroEdgeUITests/AppStoreScreenshotCapture/testCaptureSettings" \
		SYMROOT="$WORK_DIR/Build" \
		2>&1 | tail -20 || test_exit=$?

	if [ $test_exit -ne 0 ]; then
		echo "ERROR: Screenshot capture tests failed (exit $test_exit). See xcresult: $XCRESULT"
		rm -rf "$WORK_DIR"
		return 1
	fi

	# Extract screenshots from xcresult
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

	# Copy to canonical asset directory (clean first for this size)
	rm -rf "$dest_dir"
	mkdir -p "$dest_dir"

	# Resize screenshots to App Store required dimensions
	# Simulators render at native device resolution; App Store Connect requires
	# specific pixel dimensions that differ from the native rendering.
	local target_w target_h
	case "$size_key" in
	67)
		target_w=1290
		target_h=2796
		;;
	61)
		target_w=1179
		target_h=2556
		;;
	esac

	if ls "$EXTRACT_DIR"/*.png >/dev/null 2>&1; then
		for png in "$EXTRACT_DIR"/*.png; do
			[ -f "$png" ] || continue
			local basename
			basename=$(basename "$png")
			# Strip trailing UUID suffix for cleaner filenames
			local clean_name
			clean_name=$(echo "$basename" | sed -E 's/_[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}//')
			clean_name="${clean_name%.png}.png"
			sips -z "$target_h" "$target_w" "$png" --out "$dest_dir/$clean_name" >/dev/null 2>&1
			echo "  $clean_name (${target_w}x${target_h})"
		done
		echo ">> Copied and resized screenshots to $dest_dir/"
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
echo "ZiroEdge App Store Screenshot Capture (iPhone)"
echo "==============================================="
echo ""

if [ "$SIZE" = "all" ] || [ "$SIZE" = "67" ]; then
	capture_size "67" || exit 1
fi

if [ "$SIZE" = "all" ] || [ "$SIZE" = "61" ]; then
	capture_size "61" || exit 1
fi

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
echo ">> App Store screenshots (iPhone):"
echo "   $IPHONE_67_DIR/"
echo "   $IPHONE_61_DIR/"
echo "============================================================"
