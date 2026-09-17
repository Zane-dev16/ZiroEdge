#!/bin/bash
set -euo pipefail

# /build-iphone — signed device build, install, and optional console launch.
# Encodes the signing that works from this Mac (team 36V92GAJBT, automatic
# style against the downloaded Xcode-managed wildcard profile). Needs the
# device connected (USB or Wi-Fi paired) and unlocked.
#
# Usage:
#   bash Scripts/build-iphone.sh                        # build + install
#   bash Scripts/build-iphone.sh --device <UDID>        # target a device
#   bash Scripts/build-iphone.sh --launch -- <args>     # + console launch,
#                                                       #   remaining args go to the app
#     e.g. bash Scripts/build-iphone.sh --launch -- \
#       --switch-proof \
#       --switch-proof-prior-id hf-cf4a0dfb60e5eb160978dd9e \
#       --switch-proof-qwen-id hf-ec6e37fe3e99bf0d922fe1fc

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$PROJECT_DIR/ZiroEdge.xcodeproj"
SCHEME="ZiroEdge"
CONFIGURATION="Debug"
TEAM="36V92GAJBT"

DEVICE_UDID="${DEVICE_UDID:-}"
LAUNCH=0
APP_ARGS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--device)
		DEVICE_UDID="${2:?missing UDID}"
		shift 2
		;;
	--launch)
		LAUNCH=1
		shift
		if [[ "${1:-}" == "--" ]]; then shift; fi
		APP_ARGS=("$@")
		break
		;;
	-h | --help)
		sed -n '3,18p' "$0"
		exit 0
		;;
	*)
		echo "Unknown arg: $1" >&2
		exit 64
		;;
	esac
done

if [[ -z "$DEVICE_UDID" ]]; then
	echo ">> Detecting device..."
	DEVICE_UDID=$(xcrun xctrace list devices 2>/dev/null |
		grep -E 'iPhone|iPad' | grep -v "Simulator" |
		grep -oE '([0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})' | head -1)
	if [[ -z "$DEVICE_UDID" ]]; then
		# Wi-Fi-paired devices show offline to xctrace but reachable to devicectl.
		DEVICE_UDID=$(xcrun devicectl list devices 2>/dev/null |
			awk '/iPhone|iPad/ {print $NF}' | head -1)
	fi
	if [[ -z "$DEVICE_UDID" ]]; then
		echo "ERROR: No device found. Set DEVICE_UDID or connect/unlock a device." >&2
		exit 1
	fi
fi
echo ">> Device: $DEVICE_UDID"

if command -v xcodegen &>/dev/null; then
	echo ">> Regenerating project with xcodegen..."
	cd "$PROJECT_DIR" && xcodegen generate
fi

echo ">> Building $SCHEME ($CONFIGURATION) for device..."
xcodebuild build \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-destination "generic/platform=iOS" \
	-configuration "$CONFIGURATION" \
	-derivedDataPath "$PROJECT_DIR/test-output/build-iphone" \
	DEVELOPMENT_TEAM="$TEAM" \
	CODE_SIGN_STYLE=Automatic \
	2>&1 | tail -3

APP_PATH=$(find "$PROJECT_DIR/test-output/build-iphone/Build/Products/$CONFIGURATION-iphoneos" \
	-maxdepth 1 -name "$SCHEME.app" 2>/dev/null | head -1)
if [[ -z "$APP_PATH" ]]; then
	echo "ERROR: Built app not found." >&2
	exit 1
fi
echo ">> App: $APP_PATH"

echo ">> Installing..."
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH" 2>&1 | tail -2

if [[ "$LAUNCH" -eq 1 ]]; then
	echo ">> Launching with console (Ctrl-C to stop capturing)..."
	# shellcheck disable=SC2068
	xcrun devicectl device process launch \
		--device "$DEVICE_UDID" \
		--console \
		--terminate-existing \
		com.zanish-labs.ziroedge \
		${APP_ARGS[@]+"${APP_ARGS[@]}"}
fi

echo ">> Done."
