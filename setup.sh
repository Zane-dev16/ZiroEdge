#!/bin/bash
# setup.sh — ZiroEdge project setup
# Downloads the llama.cpp xcframework binary for the swift-llama-cpp package.
set -euo pipefail

XCFRAMEWORK_URL="https://github.com/ggml-org/llama.cpp/releases/download/b9821/llama-b9821-xcframework.zip"
TARGET_DIR="Packages/swift-llama-cpp"
XCFRAMEWORK_DIR="$TARGET_DIR/llama.xcframework"

if [ -d "$XCFRAMEWORK_DIR" ]; then
    echo "✓ llama.xcframework already exists at $XCFRAMEWORK_DIR"
    exit 0
fi

echo "Downloading llama.cpp xcframework (b9821)..."
TMPFILE=$(mktemp /tmp/llama-xcframework.XXXXXX.zip)
curl -L --connect-timeout 30 -o "$TMPFILE" "$XCFRAMEWORK_URL"

echo "Extracting to $TARGET_DIR..."
unzip -o "$TMPFILE" -d /tmp/llama-xcextract > /dev/null
cp -R /tmp/llama-xcextract/build-apple/llama.xcframework "$XCFRAMEWORK_DIR"
rm -f "$TMPFILE"
rm -rf /tmp/llama-xcextract

echo "✓ llama.xcframework installed at $XCFRAMEWORK_DIR"
echo ""
echo "Open ZiroEdge.xcodeproj in Xcode and build."
