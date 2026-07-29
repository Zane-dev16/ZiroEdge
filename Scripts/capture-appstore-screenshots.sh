#!/bin/bash
# App Store iPad Screenshot Capture
#
# Builds and runs AppStoreScreenshotTests on two iPad simulators,
# extracts PNGs from the xcresult bundles, and validates resolutions.
#
# Prerequisites: Xcode 15+, iOS 18.0 simulators available.
# Usage: ./capture-appstore-screenshots.sh [output_dir]
#
# The default output directory is test-output/appstore-screenshots/.

set -euo pipefail
OUTPUT_DIR="${1:-test-output/appstore-screenshots}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="ZiroEdgeUITests"

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# iPad simulator definitions (App Store required sizes in landscape)
# ---------------------------------------------------------------------------
declare -A DEVICES=(
  ["iPad-Pro-12.9-2048x2732"]="iPad Pro (12.9-inch) (6th generation)"
  ["iPad-Pro-11-1668x2388"]="iPad Pro (11-inch) (4th generation)"
)

declare -A EXPECTED_WIDTH=(
  ["iPad-Pro-12.9-2048x2732"]=2048
  ["iPad-Pro-11-1668x2388"]=1668
)

declare -A EXPECTED_HEIGHT=(
  ["iPad-Pro-12.9-2048x2732"]=2732
  ["iPad-Pro-11-1668x2388"]=2388
)

# ---------------------------------------------------------------------------
# Ensure simulators exist; create if needed
# ---------------------------------------------------------------------------
echo "=== Checking simulators ==="
for key in "${!DEVICES[@]}"; do
  DEVICE_NAME="${DEVICES[$key]}"
  UDID=$(xcrun simctl list devices booted 2>/dev/null \
    | grep -F "$DEVICE_NAME" | head -1 | grep -oE '[A-F0-9-]{36}' || true)
  if [ -z "${UDID:-}" ]; then
    UDID=$(xcrun simctl list devices "$DEVICE_NAME" available 2>/dev/null \
      | grep -F "$DEVICE_NAME" | head -1 | grep -oE '[A-F0-9-]{36}' || true)
  fi
  if [ -z "${UDID:-}" ]; then
    echo "Creating simulator: $DEVICE_NAME"
    RUNTIME=$(xcrun simctl list runtimes iOS 2>/dev/null \
      | grep "iOS" | tail -1 | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]+' || true)
    if [ -n "${RUNTIME:-}" ]; then
      UDID=$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_NAME" "$RUNTIME" 2>/dev/null || true)
    fi
  fi
  if [ -n "${UDID:-}" ]; then
    echo "  $key -> $UDID"
    echo "$UDID" > "$OUTPUT_DIR/${key}.udid"
  else
    echo "  ERROR: Cannot find or create $DEVICE_NAME"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Build the test runner once
# ---------------------------------------------------------------------------
echo "=== Building ==="
cd "$PROJECT_DIR"
xcodebuild \
  -scheme "$SCHEME" \
  -destination 'generic/platform=iOS Simulator' \
  build-for-testing \
  | tail -5

# ---------------------------------------------------------------------------
# Run tests on each device + extract screenshots
# ---------------------------------------------------------------------------
for key in "${!DEVICES[@]}"; do
  DEVICE_NAME="${DEVICES[$key]}"
  UDID=$(cat "$OUTPUT_DIR/${key}.udid")
  EXPECTED_W="${EXPECTED_WIDTH[$key]}"
  EXPECTED_H="${EXPECTED_HEIGHT[$key]}"

  echo ""
  echo "=== Running on $DEVICE_NAME (${EXPECTED_W}x${EXPECTED_H}) ==="

  # Boot simulator if not already booted
  xcrun simctl boot "$UDID" 2>/dev/null || true
  sleep 5

  # Set orientation to landscape before running tests
  xcrun simctl status_bar "$UDID" override \
    --time "9:41" \
    --dataNetwork "wifi" \
    --batteryState "charged" \
    --batteryLevel 100 2>/dev/null || true

  RESULT_PATH="$OUTPUT_DIR/${key}.xcresult"

  xcodebuild \
    -scheme "$SCHEME" \
    -destination "id=$UDID" \
    test-without-building \
    -resultBundlePath "$RESULT_PATH" \
    2>&1 | tail -20

  TEST_EXIT=$?

  echo "Test exit code: $TEST_EXIT"
  echo "xcresult: $RESULT_PATH"

  # -----------------------------------------------------------------------
  # Extract PNG screenshots from xcresult
  # -----------------------------------------------------------------------
  SCREENSHOTS_DIR="$OUTPUT_DIR/${key}_screenshots"
  mkdir -p "$SCREENSHOTS_DIR"

  # Use xcresulttool to export attachments
  xcrun xcresulttool export attachments \
    --path "$RESULT_PATH" \
    --output-path "$SCREENSHOTS_DIR" 2>/dev/null || true

  # If the newer export command didn't work, try the older one
  if [ -z "$(ls -A "$SCREENSHOTS_DIR" 2>/dev/null)" ]; then
    xcrun xcresulttool export \
      --type directory \
      --path "$RESULT_PATH" \
      --output-path "$SCREENSHOTS_DIR" 2>/dev/null || true
  fi

  # Rename PNGs to descriptive names based on the test class and step
  PNG_COUNT=0
  for png in "$SCREENSHOTS_DIR"/*.png; do
    [ -f "$png" ] || continue
    PNG_COUNT=$((PNG_COUNT + 1))
    # Validate resolution
    W=$(sips -g pixelWidth "$png" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "0")
    H=$(sips -g pixelHeight "$png" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "0")
    echo "  Screenshot $PNG_COUNT: ${W}x${H}"
    if [ "$W" = "$EXPECTED_W" ] && [ "$H" = "$EXPECTED_H" ]; then
      echo "    Resolution: OK"
    else
      echo "    Resolution: MISMATCH (expected ${EXPECTED_W}x${EXPECTED_H})"
    fi
  done

  echo "Extracted $PNG_COUNT PNGs for $key"

  if [ $PNG_COUNT -lt 3 ]; then
    echo "  WARNING: Fewer than 3 screenshots. Expected sidebar/chat, models, and settings."
  fi
done

echo ""
echo "=== Done ==="
echo "Screenshots: $OUTPUT_DIR/{iPad-Pro-*_screenshots/}"
echo "xcresults:   $OUTPUT_DIR/{iPad-Pro-*.xcresult}"
