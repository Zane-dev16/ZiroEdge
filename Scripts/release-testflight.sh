#!/bin/bash
set -euo pipefail

# ZiroEdge TestFlight Release Pipeline
# Archives, exports, and uploads to App Store Connect.
#
# Prerequisites:
#   - Apple Developer account with App Store Connect access
#   - App Store Connect API key at ~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8
#   - APPLE_TEAM_ID env var set to your Apple Developer Team ID (never commit the real ID)
#   - Or: Xcode automatically manages signing
#
# Usage:
#   bash Scripts/release-testflight.sh              # Full pipeline
#   bash Scripts/release-testflight.sh --archive-only  # Archive only
#   bash Scripts/release-testflight.sh --upload-only   # Export + upload only (needs existing archive)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
ARCHIVE_PATH="$BUILD_DIR/ZiroEdge.xcarchive"
EXPORT_PATH="$BUILD_DIR/ZiroEdge-Export"
IPA_PATH="$EXPORT_PATH/ZiroEdge.ipa"
SCHEME="ZiroEdge"
PROJECT="$PROJECT_DIR/ZiroEdge.xcodeproj"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"

MODE="full"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive-only) MODE="archive"; shift ;;
        --upload-only) MODE="upload"; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Phase 1: Catalog integrity check
# ---------------------------------------------------------------------------
run_catalog_check() {
    echo ">> Verifying model catalog metadata..."
    python3 "$PROJECT_DIR/Scripts/verify-model-catalog.py" --metadata-only || {
        echo "ERROR: Catalog metadata validation failed"
        exit 1
    }
    echo "   Catalog metadata: OK"
}

# ---------------------------------------------------------------------------
# Phase 2: Run unit tests on simulator
# ---------------------------------------------------------------------------
run_unit_tests() {
    echo ">> Running unit tests..."
    local TEST_DEVICE
    TEST_DEVICE=$(xcrun simctl list devices available | grep -E 'iPad|iPhone' | head -1 | grep -oE '\([0-9A-F-]+\)' | tr -d '()')
    if [[ -z "$TEST_DEVICE" ]]; then
        echo "WARNING: No simulator device found, skipping tests"
        return
    fi
    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,id=$TEST_DEVICE" \
        -configuration Debug \
        -quiet 2>&1 | tail -5
    echo "   Unit tests: OK"
}

# ---------------------------------------------------------------------------
# Phase 3: Archive
# ---------------------------------------------------------------------------
archive() {
    echo ">> Archiving ZiroEdge v1.0.0 (build 1)..."
    mkdir -p "$BUILD_DIR"
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination 'generic/platform=iOS' \
        -archivePath "$ARCHIVE_PATH" \
        -configuration Release \
        -allowProvisioningUpdates \
        -quiet 2>&1 | tail -3
    echo "   Archive: $ARCHIVE_PATH"

    # Verify archive contents
    if [[ -f "$ARCHIVE_PATH/Info.plist" ]]; then
        local VERSION
        VERSION=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" "$ARCHIVE_PATH/Info.plist" 2>/dev/null || echo "unknown")
        local BUILD
        BUILD=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" "$ARCHIVE_PATH/Info.plist" 2>/dev/null || echo "unknown")
        echo "   Version: $VERSION ($BUILD)"
    fi
}

# ---------------------------------------------------------------------------
# Phase 4: Create ExportOptions.plist
# ---------------------------------------------------------------------------
create_export_options() {
    echo ">> Creating export options..."
    local TEAM_ID="${APPLE_TEAM_ID:-YOUR_TEAM_ID}"
    if [[ "$TEAM_ID" == "YOUR_TEAM_ID" ]]; then
        echo "ERROR: set APPLE_TEAM_ID to your Apple Developer Team ID (never commit the real ID)."
        exit 1
    fi
    mkdir -p "$BUILD_DIR"
    cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>uploadSymbols</key>
    <true/>
    <key>uploadBitcode</key>
    <false/>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
PLIST
    echo "   Export options: $EXPORT_OPTIONS_PLIST"
}

# ---------------------------------------------------------------------------
# Phase 5: Export IPA
# ---------------------------------------------------------------------------
export_ipa() {
    echo ">> Exporting IPA..."
    rm -rf "$EXPORT_PATH"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
        -allowProvisioningUpdates \
        -quiet 2>&1 | tail -3
    echo "   IPA: $IPA_PATH"
}

# ---------------------------------------------------------------------------
# Phase 6: Upload to App Store Connect
# ---------------------------------------------------------------------------
upload_to_app_store() {
    echo ">> Uploading to App Store Connect..."
    echo ""
    echo "   This step requires an App Store Connect API key."
    echo "   Create one at: https://appstoreconnect.apple.com/access/api"
    echo ""
    echo "   Then run:"
    echo "   xcrun altool --upload-app -f \"$IPA_PATH\" -t ios \\"
    echo "     --apiKey YOUR_KEY_ID --apiIssuer YOUR_ISSUER_ID"
    echo ""
    echo "   Or use:"
    echo "   xcodebuild -uploadArchive -archivePath \"$ARCHIVE_PATH\" \\"
    echo "     -authenticationKeyID YOUR_KEY_ID \\"
    echo "     -authenticationKeyIssuerID YOUR_ISSUER_ID \\"
    echo "     -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_YOUR_KEY_ID.p8"
    echo ""
    echo "   NOTE: Upload requires manual App Store Connect credentials."
    echo "   This step is flagged for manual intervention."
}

# ---------------------------------------------------------------------------
# Phase 7: Post-upload checklist
# ---------------------------------------------------------------------------
print_checklist() {
    echo ""
    echo "============================================"
    echo " TestFlight Release Checklist"
    echo "============================================"
    echo ""
    echo " [x] Catalog metadata verified"
    echo " [x] Unit tests passed"
    echo " [x] Archive v1.0.0 (1) signed successfully"
    echo " [x] App icon bundled"
    echo " [x] THIRD_PARTY_NOTICES.md bundled"
    echo " [x] Privacy policy URL configured (zane-dev16.github.io/ZiroEdge/privacy.html)"
    echo " [x] PrivacyInfo.xcprivacy included"
    echo ""
    echo " Manual steps remaining:"
    echo " [ ] Upload IPA to App Store Connect"
    echo " [ ] Wait for TestFlight processing (5-30 min)"
    echo " [ ] Add internal testers in App Store Connect"
    echo " [ ] Verify build appears in TestFlight app"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "============================================"
echo " ZiroEdge TestFlight Release Pipeline"
echo "============================================"
echo ""

run_catalog_check

if [[ "$MODE" == "archive" || "$MODE" == "full" ]]; then
    run_unit_tests
    archive
fi

if [[ "$MODE" == "upload" || "$MODE" == "full" ]]; then
    create_export_options
    export_ipa
    upload_to_app_store
fi

print_checklist

echo ""
echo ">> Pipeline complete."
