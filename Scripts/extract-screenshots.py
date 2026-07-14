#!/usr/bin/env python3
"""Extract screenshots from an .xcresult bundle.

Usage: python3 extract-screenshots.py <xcresult_path> <output_dir>

Parses the xcresult JSON, finds XCTAttachment image data, and writes PNGs
to output_dir named as {test}_{step}_{name}.png.
"""

import json
import os
import subprocess
import sys
from pathlib import Path


def xcresult_json(xcresult_path: str) -> dict:
    """Get structured test results as JSON."""
    r = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary",
         "--path", xcresult_path, "--format", "json"],
        capture_output=True, text=True
    )
    if r.returncode != 0:
        # Try older xcresulttool API
        r = subprocess.run(
            ["xcrun", "xcresulttool", "get", "--path", xcresult_path, "--format", "json"],
            capture_output=True, text=True
        )
    return json.loads(r.stdout) if r.stdout else {}


def extract_attachments(xcresult_path: str, output_dir: str):
    """Extract image attachments from xcresult."""
    os.makedirs(output_dir, exist_ok=True)

    # Get list of actions/attachments via xcresulttool
    try:
        data = xcresult_json(xcresult_path)
    except (json.JSONDecodeError, FileNotFoundError):
        print("Could not parse xcresult JSON", file=sys.stderr)
        return

    # Try to extract all attachments using xcresulttool export
    # This works on Xcode 15+ with the test-results summary API
    try:
        r = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "summary",
             "--path", xcresult_path, "--format", "json"],
            capture_output=True, text=True
        )
        summary = json.loads(r.stdout)

        # Walk test nodes looking for attachments
        count = 0
        for test_node in _walk_tests(summary):
            for attachment in test_node.get("attachments", []):
                _export_attachment(xcresult_path, attachment, output_dir, count)
                count += 1

        print(f"Extracted {count} screenshots to {output_dir}")

    except Exception as e:
        print(f"Extraction fallback: {e}", file=sys.stderr)
        # Fallback: try to export all attachments at once
        _bulk_export(xcresult_path, output_dir)


def _walk_tests(data: dict):
    """Recursively walk test result tree yielding test nodes."""
    if "node" in data:
        yield data["node"]
    for child in data.get("children", []):
        yield from _walk_tests(child)
    # Direct node with attachments
    if "attachments" in data:
        yield data


def _export_attachment(xcresult: str, attachment: dict, output_dir: str, index: int):
    """Export a single attachment to PNG."""
    name = attachment.get("name", f"screenshot_{index}")
    payload_ref = attachment.get("payloadRef", {})
    if not payload_ref:
        return

    output_path = os.path.join(output_dir, f"{name}.png")
    subprocess.run(
        ["xcrun", "xcresulttool", "get", "object",
         "--path", xcresult, "--id", payload_ref.get("id", ""),
         "--output-path", output_path],
        capture_output=True
    )


def _bulk_export(xcresult: str, output_dir: str):
    """Last resort: export all test attachments."""
    try:
        r = subprocess.run(
            ["xcrun", "xcresulttool", "export", "--type", "directory",
             "--path", xcresult, "--output-path", output_dir],
            capture_output=True, text=True
        )
        if r.returncode == 0:
            print(f"Bulk exported to {output_dir}")
    except Exception as e:
        print(f"Bulk export failed: {e}", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <xcresult_path> <output_dir>", file=sys.stderr)
        sys.exit(1)
    extract_attachments(sys.argv[1], sys.argv[2])
