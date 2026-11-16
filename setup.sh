#!/bin/bash
# setup.sh — ZiroEdge project setup
#
# The llama.cpp XCFramework is built from the pinned upstream tag by the
# in-repo recipe. Nothing is hand-assembled: see Scripts/build-llama-xcframework.sh
# and docs/llama-runtime.md for the tag, the slices, and the upgrade checklist.
set -euo pipefail

TARGET_DIR="Packages/swift-llama-cpp"
XCFRAMEWORK_DIR="$TARGET_DIR/llama.xcframework"

if [ -d "$XCFRAMEWORK_DIR" ]; then
    echo "✓ llama.xcframework already exists at $XCFRAMEWORK_DIR"
    exit 0
fi

bash Scripts/build-llama-xcframework.sh

echo ""
echo "Open ZiroEdge.xcodeproj in Xcode and build."
