#!/bin/bash
set -euo pipefail

# ZiroEdge Device Test Runner
# Builds, installs, runs UI tests on physical device, collects screenshots, generates report.
#
# Usage:
#   bash Scripts/device-test.sh                    # Smoke only (L0)
#   bash Scripts/device-test.sh --layer feature    # Smoke + feature tests (L0+L1)
#   bash Scripts/device-test.sh --layer model      # Smoke + model tests (L0+L2)
#   bash Scripts/device-test.sh --layer all        # All layers
#   bash Scripts/device-test.sh --test SmokeTests  # Specific test class

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/test-output"
SCREENSHOTS_DIR="$OUTPUT_DIR/screenshots"
SCHEME="ZiroEdgeUITests"
PROJECT="$PROJECT_DIR/ZiroEdge.xcodeproj"

# --- Args ---
LAYER="smoke"
TEST_CLASS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --layer) LAYER="$2"; shift 2 ;;
        --test)  TEST_CLASS="$2"; shift 2 ;;
        *)       echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# --- Device ---
DEVICE_UDID="${DEVICE_UDID:-}"
if [[ -z "$DEVICE_UDID" ]]; then
    echo ">> Detecting connected device..."
    DEVICE_UDID=$(xcrun xctrace list devices 2>/dev/null \
        | grep -v "Simulator" | grep -v "Mac" \
        | grep -oE '[0-9a-f]{40}' | head -1)
    if [[ -z "$DEVICE_UDID" ]]; then
        echo "ERROR: No physical device found. Set DEVICE_UDID or connect a device."
        exit 1
    fi
fi
echo ">> Using device: $DEVICE_UDID"

# --- Prepare output ---
rm -rf "$OUTPUT_DIR"
mkdir -p "$SCREENSHOTS_DIR"

# --- Regenerate project (xcodegen) ---
if command -v xcodegen &>/dev/null; then
    echo ">> Regenerating project with xcodegen..."
    cd "$PROJECT_DIR" && xcodegen generate
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
        all)
            TEST_FILTER=""  # no filter = run everything
            ;;
        *)
            echo "Unknown layer: $LAYER"; exit 1 ;;
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
    IFS=':' read -ra FILTERS <<< "$TEST_FILTER"
    for f in "${FILTERS[@]}"; do
        TEST_CMD+=(-only-testing "$f")
    done
fi

TEST_EXIT=0
"${TEST_CMD[@]}" 2>&1 | tail -20 || TEST_EXIT=$?

# --- Extract screenshots from xcresult ---
echo ">> Extracting screenshots..."
if [[ -d "$OUTPUT_DIR/xcresult.xcresult" ]]; then
    # xcrun xcresulttool to extract attachments
    python3 "$SCRIPT_DIR/extract-screenshots.py" \
        "$OUTPUT_DIR/xcresult.xcresult" \
        "$SCREENSHOTS_DIR" 2>/dev/null || echo "   (no screenshots extracted — tests may have failed early)"
fi

# --- Generate report ---
echo ">> Generating report..."
python3 "$SCRIPT_DIR/generate-report.py" \
    "$OUTPUT_DIR" \
    "$LAYER" \
    "$TEST_EXIT"

echo ""
echo ">> Done!"
echo "   Screenshots: $SCREENSHOTS_DIR/"
echo "   Report:      $OUTPUT_DIR/report.html"
echo "   Report:      $OUTPUT_DIR/report.md"
echo "   xcresult:    $OUTPUT_DIR/xcresult.xcresult"
exit $TEST_EXIT
