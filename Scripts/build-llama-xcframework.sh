#!/bin/bash
# build-llama-xcframework.sh — rebuild the pinned llama.cpp iOS XCFramework.
#
# The app never consumes a hand-assembled binary. This script is the only
# supported path: it checks out the pinned upstream tag, runs upstream's own
# build-xcframework.sh for the two slices the app needs, and installs the
# result into the Swift package. The tag is part of the runtime contract —
# bump it here, then run the full device verification lane.
#
#   ./Scripts/build-llama-xcframework.sh            # pin from LLAMA_TAG
#   LLAMA_TAG=b12435 ./Scripts/build-llama-xcframework.sh
#   LLAMA_KEEP_SRC=1 ./Scripts/build-llama-xcframework.sh   # reuse the clone
#
# Requirements: cmake 3.28+, Xcode command line tools, network access for the
# clone. The build takes roughly 15–25 minutes on an 8-core Mac.
#
# Two environment traps this script handles:
#   1. Homebrew toolchain exports (CC=/opt/homebrew/bin/gcc-14) make CMake's
#      Xcode generator fail with "The C compiler identification is unknown".
#      Both are unset for the build.
#   2. Upstream publishes some tags with a device-only XCFramework. Building
#      both slices here keeps the simulator test target working regardless of
#      what the release asset contains.

set -euo pipefail

LLAMA_TAG="${LLAMA_TAG:-b12000}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/Packages/swift-llama-cpp/llama.xcframework"
WORK_DIR="${LLAMA_BUILD_DIR:-/tmp/ziroedge-llama-$LLAMA_TAG}"
SRC_DIR="$WORK_DIR/llama.cpp"

echo ">> pinned tag: $LLAMA_TAG"
echo ">> work dir:   $WORK_DIR"

mkdir -p "$WORK_DIR"
if [ ! -d "$SRC_DIR/.git" ]; then
	rm -rf "$SRC_DIR"
	git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp.git "$SRC_DIR"
else
	CURRENT_TAG="$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null || echo unknown)"
	if [ "$CURRENT_TAG" != "$LLAMA_TAG" ]; then
		echo ">> checkout is $CURRENT_TAG, not $LLAMA_TAG; re-cloning"
		rm -rf "$SRC_DIR"
		git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp.git "$SRC_DIR"
	else
		echo ">> reusing $SRC_DIR ($CURRENT_TAG)"
	fi
fi

if [ ! -x "$SRC_DIR/build-xcframework.sh" ]; then
	echo "!! $LLAMA_TAG has no build-xcframework.sh; it cannot be built as an XCFramework" >&2
	exit 1
fi

echo ">> building ios-sim + ios-device (this is the long step)"
(
	cd "$SRC_DIR"
	env -u CC -u CXX ./build-xcframework.sh ios-sim ios-device
)

BUILT="$SRC_DIR/build-apple/llama.xcframework"
[ -d "$BUILT" ] || { echo "!! build produced no XCFramework at $BUILT" >&2; exit 1; }

if [ -d "$TARGET" ]; then
	BACKUP="$WORK_DIR/llama-previous.xcframework"
	rm -rf "$BACKUP"
	mv "$TARGET" "$BACKUP"
	echo ">> previous framework moved to $BACKUP"
fi
cp -R "$BUILT" "$TARGET"

echo ""
echo ">> installed $TARGET"
python3 - "$TARGET" "$LLAMA_TAG" <<'PY'
import plistlib, sys
path, tag = sys.argv[1:3]
with open(path + "/Info.plist", "rb") as handle:
    info = plistlib.load(handle)
for entry in info["AvailableLibraries"]:
    variant = entry.get("SupportedPlatformVariant", "")
    print(f"   {entry['LibraryIdentifier']}  {entry['SupportedPlatform']} {variant}")
print(f"   tag {tag}")
PY

if [ "${LLAMA_KEEP_SRC:-0}" != "1" ]; then
	# Build products are multi-gigabyte; the source tree is cheap to re-clone.
	rm -rf "$SRC_DIR/build-ios-sim" "$SRC_DIR/build-ios-device"
fi

echo ""
echo ">> next: xcodebuild build-for-testing (simulator) and a device launch, then"
echo ">>       re-verify every catalog row on hardware. The runtime backs everything."
