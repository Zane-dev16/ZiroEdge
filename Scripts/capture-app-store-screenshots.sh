#!/bin/bash
set -euo pipefail

# ZiroEdge App Store Screenshot Capture
# ========================================
# Captures iPhone screenshots at the exact resolutions required by App Store
# Connect (1290x2796 for 6.7" and 1179x2556 for 6.1").
#
# Requirements:
#   - Xcode (full, not just CLI tools)
#   - iOS Simulator runtimes for iPhone 16 Pro Max and iPhone 16 Pro
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
OUTPUT_DIR="$PROJECT_DIR/test-output"
SCREENSHOTS_DIR="$OUTPUT_DIR/screenshots"
ASSETS_DIR="$PROJECT_DIR/ziroedge-docs/app-store-screenshots"
SCHEME="ZiroEdgeUITests"
PROJECT="$PROJECT_DIR/ZiroEdge.xcodeproj"

# --- Args ---
SIZE="all"
while [[ $# -gt 0 ]]; do
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
if ! command -v xcodebuild &>/dev/null; then
	echo "ERROR: xcodebuild not found. Install Xcode."
	exit 1
fi

# --- Regenerate project ---
if command -v xcodegen &>/dev/null; then
	echo ">> Regenerating project with xcodegen..."
	cd "$PROJECT_DIR" && xcodegen generate
fi

# --- Prepare output ---
rm -rf "$OUTPUT_DIR"
mkdir -p "$SCREENSHOTS_DIR"

# --- Capture function ---
capture_size() {
	local sim_name="$1"
	local size_label="$2"
	local output_subdir="$3"

	echo ""
	echo "============================================================"
	echo ">> Capturing $size_label screenshots on '$sim_name'..."
	echo "============================================================"

	# Check if simulator is available
	if ! xcrun simctl list devices | grep -q "$sim_name"; then
		echo ">> Simulator '$sim_name' not available. Checking available simulators..."
		xcrun simctl list devices available | grep -E "iPhone" | head -10
		echo ""
		echo "Please install the '$sim_name' runtime via Xcode > Settings > Platforms."
		return 1
	fi

	local DEVICE_UDID
	DEVICE_UDID=$(xcrun simctl list devices available |
		grep "$sim_name" | grep -v "Max" | head -1 |
		grep -oE '([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})')

	if [[ -z "$DEVICE_UDID" ]]; then
		# Try with Max in name (newer Xcode versions)
		DEVICE_UDID=$(xcrun simctl list devices available |
			grep "$sim_name" | head -1 |
			grep -oE '([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})')
	fi

	if [[ -z "$DEVICE_UDID" ]]; then
		echo "ERROR: Could not find UDID for '$sim_name'"
		return 1
	fi

	echo ">> Simulator UDID: $DEVICE_UDID"

	# Boot simulator if not already booted
	local boot_state
	boot_state=$(xcrun simctl list devices | grep "$DEVICE_UDID" | grep -oE '\(Booted\)' || true)
	if [[ -z "$boot_state" ]]; then
		echo ">> Booting simulator..."
		xcrun simctl boot "$DEVICE_UDID" 2>/dev/null || true
		sleep 5
	fi

	# Build for testing
	echo ">> Building for simulator..."
	xcodebuild build-for-testing \
		-project "$PROJECT" \
		-scheme "$SCHEME" \
		-destination "platform=iOS Simulator,id=$DEVICE_UDID" \
		-derivedDataPath "$OUTPUT_DIR/DerivedData" \
		-quiet \
		SYMROOT="$OUTPUT_DIR/Build" \
		2>&1 | tail -5

	# Run screenshot capture tests
	echo ">> Running screenshot capture tests..."
	xcodebuild test-without-building \
		-project "$PROJECT" \
		-scheme "$SCHEME" \
		-destination "platform=iOS Simulator,id=$DEVICE_UDID" \
		-derivedDataPath "$OUTPUT_DIR/DerivedData" \
		-resultBundlePath "$OUTPUT_DIR/xcresult-$size_label.xcresult" \
		-only-testing "ZiroEdgeUITests/AppStoreScreenshotCapture" \
		SYMROOT="$OUTPUT_DIR/Build" \
		2>&1 | tail -20

	# Extract screenshots from xcresult
	echo ">> Extracting screenshots..."
	if [[ -d "$OUTPUT_DIR/xcresult-$size_label.xcresult" ]]; then
		python3 "$SCRIPT_DIR/extract-screenshots.py" \
			"$OUTPUT_DIR/xcresult-$size_label.xcresult" \
			"$SCREENSHOTS_DIR" 2>/dev/null || echo "   (no screenshots extracted)"
	fi

	# Copy to app-store-screenshots directory
	local DEST_DIR="$ASSETS_DIR/$output_subdir"
	mkdir -p "$DEST_DIR"
	if ls "$SCREENSHOTS_DIR"/*.png &>/dev/null; then
		cp "$SCREENSHOTS_DIR"/*.png "$DEST_DIR/"
		echo ">> Copied screenshots to $DEST_DIR/"
		ls -la "$DEST_DIR/"
	else
		echo "ERROR: No real UI screenshots were captured"
		return 1
	fi

	echo ">> Done capturing $size_label screenshots"
	return 0
}

# --- Main ---
echo "ZiroEdge App Store Screenshot Capture"
echo "======================================"
echo ""

mkdir -p "$ASSETS_DIR/iphone-67" "$ASSETS_DIR/iphone-61"

if [[ "$SIZE" == "all" || "$SIZE" == "67" ]]; then
	capture_size "iPhone 16 Pro Max" "6.7-inch" "iphone-67"
fi

if [[ "$SIZE" == "all" || "$SIZE" == "61" ]]; then
	capture_size "iPhone 16 Pro" "6.1-inch" "iphone-61"
fi

echo ""
echo "============================================================"
echo ">> App Store screenshots:"
echo "   $ASSETS_DIR/iphone-67/"
echo "   $ASSETS_DIR/iphone-61/"
echo ""
echo ">> Verify with:"
echo "   python3 Scripts/verify-screenshots.py"
echo "============================================================"
