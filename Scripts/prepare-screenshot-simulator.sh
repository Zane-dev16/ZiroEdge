#!/bin/bash
set -euo pipefail

# ZiroEdge Prepare Screenshot Simulators
# =======================================
# Creates the four simulators required for App Store screenshot capture
# using stable device-type identifiers and the current iOS runtime.
#
# Device types and target resolutions:
#   iPhone 16 Pro Max → 1290x2796 (6.7")
#   iPhone 16 Pro      → 1179x2556 (6.1")
#   iPad Pro 12.9" 6th → 2048x2732 (12.9")
#   iPad Pro 11" 4th   → 1668x2388 (11")
#
# Usage:
#   bash Scripts/prepare-screenshot-simulator.sh              # create all four
#   bash Scripts/prepare-screenshot-simulator.sh --list       # list existing
#   bash Scripts/prepare-screenshot-simulator.sh --delete     # delete all four
#
# After creation, use:
#   bash Scripts/capture-app-store-screenshots.sh    (iPhone)
#   bash Scripts/capture-appstore-screenshots.sh     (iPad)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Simulator definitions (parallel indexed arrays) ---
SIM_KEYS=("iphone-67" "iphone-61" "ipad-13" "ipad-11")
SIM_NAMES=(
	"ZiroEdge Screenshot iPhone 16 Pro Max"
	"ZiroEdge Screenshot iPhone 16 Pro"
	"ZiroEdge Screenshot iPad Pro 12.9"
	"ZiroEdge Screenshot iPad Pro 11"
)
SIM_DEVICE_TYPES=(
	"com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max"
	"com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
	"com.apple.CoreSimulator.SimDeviceType.iPad-Pro-12-9-inch-6th-generation-16GB"
	"com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-4th-generation-16GB"
)

# --- Detect current iOS runtime ---
RUNTIME=$(xcrun simctl list runtimes iOS 2>/dev/null |
	grep "iOS" | tail -1 | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]+' || true)
if [ -z "${RUNTIME:-}" ]; then
	echo "ERROR: No iOS Simulator runtime found. Install one via Xcode > Settings > Platforms."
	exit 1
fi
echo "Runtime: $RUNTIME"

# --- Helpers ---
find_udid() {
	local sim_name="$1"
	xcrun simctl list devices 2>/dev/null |
		grep -F "$sim_name" | head -1 | grep -oE '[A-F0-9-]{36}' || true
}

is_booted() {
	local udid="$1"
	xcrun simctl list devices | grep "$udid" | grep -oE '\(Booted\)' >/dev/null 2>&1
}

# --- Actions ---
ACTION="${1:-create}"

case "$ACTION" in
--list | -l | list)
	echo ""
	echo "=== Existing ZiroEdge screenshot simulators ==="
	for i in "${!SIM_KEYS[@]}"; do
		key="${SIM_KEYS[$i]}"
		name="${SIM_NAMES[$i]}"
		udid=$(find_udid "$name")
		if [ -n "${udid:-}" ]; then
			boot_tag=""
			is_booted "$udid" && boot_tag=" BOOTED"
			echo "  $key: $name ($udid)${boot_tag}"
		else
			echo "  $key: $name — NOT CREATED"
		fi
	done
	;;

--delete | delete)
	echo "Deleting ZiroEdge screenshot simulators..."
	for i in "${!SIM_KEYS[@]}"; do
		name="${SIM_NAMES[$i]}"
		udid=$(find_udid "$name")
		if [ -n "${udid:-}" ]; then
			echo "  Deleting $name ($udid)..."
			xcrun simctl delete "$udid" 2>/dev/null || true
		fi
	done
	echo "Done."
	;;

create | --create | *)
	echo "Creating ZiroEdge screenshot simulators..."
	echo ""
	CREATED=0
	for i in "${!SIM_KEYS[@]}"; do
		key="${SIM_KEYS[$i]}"
		name="${SIM_NAMES[$i]}"
		dtype="${SIM_DEVICE_TYPES[$i]}"

		existing=$(find_udid "$name")
		if [ -n "${existing:-}" ]; then
			echo "  $key: already exists — $name ($existing)"
			continue
		fi

		udid=$(xcrun simctl create "$name" "$dtype" "$RUNTIME" 2>/dev/null || true)
		if [ -n "${udid:-}" ]; then
			echo "  $key: created — $name ($udid)"
			CREATED=$((CREATED + 1))
		else
			echo "  $key: FAILED to create $name (device type: $dtype)"
		fi
	done
	echo ""
	echo "Created $CREATED new simulator(s)."

	# For iPad simulators, pre-set the status bar for clean screenshots
	for i in "${!SIM_KEYS[@]}"; do
		key="${SIM_KEYS[$i]}"
		name="${SIM_NAMES[$i]}"
		# Only configure iPads
		case "$key" in
		ipad-*)
			udid=$(find_udid "$name")
			if [ -n "${udid:-}" ]; then
				if ! is_booted "$udid"; then
					xcrun simctl boot "$udid" 2>/dev/null || true
					sleep 3
				fi
				xcrun simctl status_bar "$udid" override \
					--time "9:41" \
					--dataNetwork "wifi" \
					--batteryState "charged" \
					--batteryLevel 100 2>/dev/null || true
				xcrun simctl shutdown "$udid" 2>/dev/null || true
				echo "  $key: status bar configured"
			fi
			;;
		esac
	done

	echo ""
	echo "=== Ready ==="
	echo "  bash Scripts/capture-app-store-screenshots.sh    # iPhone"
	echo "  bash Scripts/capture-appstore-screenshots.sh     # iPad"
	;;
esac
