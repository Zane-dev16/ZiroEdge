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
# clone. The build takes roughly 25–35 minutes on an 8-core Mac.
#
# Three environment traps this script handles:
#   1. Homebrew toolchain exports (CC=/opt/homebrew/bin/gcc-14) make CMake's
#      Xcode generator fail with "The C compiler identification is unknown".
#      Both are unset for the build.
#   2. Upstream publishes some tags with a device-only XCFramework. Building
#      both slices here keeps the simulator test target working regardless of
#      what the release asset contains.
#   3. Upstream's release asset (and its default build script) sets
#      LLAMA_BUILD_COMMON=OFF, so it carries only the heuristic
#      `llama_chat_apply_template`. That formatter cannot take template kwargs,
#      which means it cannot honor `enable_thinking`, and it cannot split a
#      reply into `reasoning_content`. ZiroEdge therefore builds the runtime
#      with upstream's jinja engine (`common/chat.cpp`) linked in, plus the
#      `Native/ZiroChat.cpp` shim declared in `docs/llama-runtime.md`.
#
# The three divergences below are applied to the checkout, never to the app:
#   - LLAMA_BUILD_COMMON=ON
#   - libllama-common{,-base}.a and libcpp-httplib.a added to the framework link
#   - ZiroChat.cpp added to the llama-common target, ZiroChat.h copied to Headers

set -euo pipefail

LLAMA_TAG="${LLAMA_TAG:-b12000}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/Packages/swift-llama-cpp"
TARGET="$PACKAGE_DIR/llama.xcframework"
SHIM_DIR="$PACKAGE_DIR/Native"
# A cache, not a scratch dir: the checkout is pinned, reusable across tags, and
# the source of the include paths the editor needs for Native/ZiroChat.cpp.
WORK_DIR="${LLAMA_BUILD_DIR:-$HOME/Library/Caches/ziroedge-llama/$LLAMA_TAG}"
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

# --- Divergence 1+2: build the jinja chat engine into the framework ---------
# Idempotent: a re-run on the same checkout must not double-apply.
echo ">> patching upstream build for the jinja chat engine"
python3 - "$SRC_DIR" "$SHIM_DIR" <<'PY'
import pathlib, shutil, sys

src = pathlib.Path(sys.argv[1])
shim = pathlib.Path(sys.argv[2])

script = src / "build-xcframework.sh"
text = script.read_text()
if "LLAMA_BUILD_COMMON=ON" not in text:
    if "LLAMA_BUILD_COMMON=OFF" not in text:
        sys.exit("upstream CMake default moved; update this patch")
    text = text.replace("LLAMA_BUILD_COMMON=OFF", "LLAMA_BUILD_COMMON=ON", 1)

# Each addition is guarded on its own marker. A single combined guard silently
# skipped the httplib entry on the second run of a retained checkout and cost a
# full rebuild to discover at link time.
anchor = '        "${base_dir}/${build_dir}/vendor/hash/${release_dir}/libvendor-hash.a"\n'
if anchor not in text:
    sys.exit("upstream link list moved; update this patch")
additions = [
    '        "${base_dir}/${build_dir}/common/${release_dir}/libllama-common.a"\n',
    '        "${base_dir}/${build_dir}/common/${release_dir}/libllama-common-base.a"\n',
    # llama-common links cpp-httplib PRIVATE, so those objects are not inside
    # libllama-common.a and the framework link fails without this archive.
    '        "${base_dir}/${build_dir}/vendor/cpp-httplib/${release_dir}/libcpp-httplib.a"\n',
]
missing = [line for line in additions if line not in text]
if missing:
    text = text.replace(anchor, anchor + "".join(missing), 1)
script.write_text(text)

for marker in ["LLAMA_BUILD_COMMON=ON", "libllama-common.a", "libcpp-httplib.a"]:
    if marker not in text:
        sys.exit(f"patch incomplete: {marker} missing")

cmake = src / "common" / "CMakeLists.txt"
text = cmake.read_text()
if "ZiroChat.cpp" not in text:
    anchor = "    jinja/caps.cpp\n"
    if anchor not in text:
        sys.exit("upstream llama-common sources moved; update this patch")
    text = text.replace(anchor, anchor + "    ZiroChat.cpp\n", 1)
cmake.write_text(text)

shutil.copy(shim / "ZiroChat.cpp", src / "common" / "ZiroChat.cpp")
shutil.copy(shim / "ZiroChat.h", src / "common" / "ZiroChat.h")
print("   patched: LLAMA_BUILD_COMMON=ON, llama-common + httplib linked, ZiroChat.cpp compiled")
PY

echo ">> building ios-sim + ios-device with the chat engine (this is the long step)"
(
	cd "$SRC_DIR"
	env -u CC -u CXX ./build-xcframework.sh ios-sim ios-device
)

BUILT="$SRC_DIR/build-apple/llama.xcframework"
[ -d "$BUILT" ] || { echo "!! build produced no XCFramework at $BUILT" >&2; exit 1; }

# --- Divergence 3: publish the shim header next to llama.h ------------------
# Upstream's umbrella module map picks up every header in Headers/, so copying
# the declaration here is what makes `import llama` expose the chat surface.
for slice in "$BUILT"/*/; do
	headers="$slice/llama.framework/Headers"
	[ -d "$headers" ] || continue
	cp "$SHIM_DIR/ZiroChat.h" "$headers/ZiroChat.h"
done

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

# Prove the jinja surface actually made it into the binary. A missing symbol
# here means the app would fail to link the chat API at the next build, which
# is better learned now than on a device.
echo ">> checking the chat surface in each slice"
for slice in "$TARGET"/*/; do
	framework="$slice/llama.framework/llama"
	[ -f "$framework" ] || continue
	for symbol in ziro_chat_templates_create ziro_chat_session_create ziro_chat_session_feed; do
		if ! xcrun nm -gU "$framework" 2>/dev/null | grep -q " _${symbol}$"; then
			echo "!! $symbol missing from $(basename "$slice")" >&2
			exit 1
		fi
	done
	[ -f "$slice/llama.framework/Headers/ZiroChat.h" ] || {
		echo "!! ZiroChat.h missing from $(basename "$slice")/Headers" >&2
		exit 1
	}
	echo "   $(basename "$slice"): chat symbols + header present"
done

if [ "${LLAMA_KEEP_SRC:-1}" == "0" ]; then
	# Build products are multi-gigabyte; the source tree is cheap to re-clone.
	rm -rf "$SRC_DIR/build-ios-sim" "$SRC_DIR/build-ios-device"
else
	echo ">> keeping build trees in $WORK_DIR (LLAMA_KEEP_SRC=0 to drop them)"
fi

# Publish the include paths the shim needs into the machine-local compile
# database, so an editor resolves `llama.h` and `chat.h` in Native/ZiroChat.cpp.
# That file is built by this script, not by the Xcode project, so nothing else
# tells the editor where its headers are. Best-effort: a missing database or a
# missing module is not a build failure.
if [ -f "$REPO_ROOT/.compile" ]; then
	python3 - "$REPO_ROOT/.compile" "$REPO_ROOT/Packages/swift-llama-cpp/Native/ZiroChat.cpp" "$SRC_DIR/common" "$SRC_DIR" "$SRC_DIR/include" "$SRC_DIR/ggml/include" "$SRC_DIR/vendor" "$SRC_DIR/tools/mtmd" <<'PY'
import json, sys
path, source = sys.argv[1:3]
includes = sys.argv[3:]
database = json.load(open(path))
database = [entry for entry in database if not entry.get("file", "").endswith("ZiroChat.cpp")]
database.append({
    "directory": includes[1],
    "file": source,
    "arguments": [
        "clang++", "-std=c++17", "-fsyntax-only", "-x", "c++",
        *[f"-I{include}" for include in includes],
        source,
    ],
})
json.dump(database, open(path, "w"), indent="\t")
print(f">> editor include paths recorded in {path}")
PY
fi

echo ""
echo ">> next: xcodebuild build-for-testing (simulator) and a device launch, then"
echo ">>       re-verify every catalog row on hardware. The runtime backs everything."
