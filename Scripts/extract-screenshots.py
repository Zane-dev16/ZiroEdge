#!/usr/bin/env python3
"""Extract screenshots from an .xcresult bundle.

Usage: python3 extract-screenshots.py <xcresult_path> <output_dir>

Uses xcresulttool to export attachments, then renames PNGs using the
suggested human-readable names from the export manifest.
"""

import json
import os
import subprocess
import sys


def extract_attachments(xcresult_path: str, output_dir: str):
    """Extract image attachments from xcresult, renaming to clean names."""
    os.makedirs(output_dir, exist_ok=True)

    # Use xcresulttool export attachments (Xcode 16+)
    r = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "export",
            "attachments",
            "--path",
            xcresult_path,
            "--output-path",
            output_dir,
        ],
        capture_output=True,
        text=True,
    )

    if r.returncode != 0 and "Exported" not in (r.stdout + r.stderr):
        # Fallback: bulk directory export
        _bulk_export(xcresult_path, output_dir)
        return

    # Read the manifest that xcresulttool wrote alongside the attachments
    manifest_path = os.path.join(output_dir, "manifest.json")
    rename_map = {}
    if os.path.isfile(manifest_path):
        try:
            with open(manifest_path, "r") as fh:
                manifest = json.load(fh)
            for entry in manifest:
                if not isinstance(entry, dict):
                    continue
                test_id = entry.get("testIdentifier", "unknown")
                class_name = test_id.split("/")[0] if "/" in test_id else "Screenshot"
                for att in entry.get("attachments", []):
                    exported = att.get("exportedFileName", "")
                    suggested = att.get("suggestedHumanReadableName", "")
                    if exported and suggested:
                        rename_map[exported] = suggested
        except (json.JSONDecodeError, OSError):
            pass

    count = 0
    for exported_name, clean_name in sorted(rename_map.items()):
        exported_path = os.path.join(output_dir, exported_name)
        clean_path = os.path.join(output_dir, clean_name)
        if os.path.isfile(exported_path):
            os.rename(exported_path, clean_path)
            count += 1

    # Remove the manifest (it referenced the UUID names, now stale)
    if os.path.isfile(manifest_path):
        os.remove(manifest_path)

    if count > 0:
        print(f"Extracted {count} screenshots to {output_dir}")
        for f in sorted(os.listdir(output_dir)):
            if f.endswith(".png"):
                fpath = os.path.join(output_dir, f)
                size = os.path.getsize(fpath)
                print(f"  {f} ({size:,} bytes)")
    else:
        # Maybe the files already have clean names (bulk export fallback)
        pngs = sorted(f for f in os.listdir(output_dir) if f.endswith(".png"))
        if pngs:
            print(f"Extracted {len(pngs)} screenshots to {output_dir}")
            for f in pngs:
                fpath = os.path.join(output_dir, f)
                size = os.path.getsize(fpath)
                print(f"  {f} ({size:,} bytes)")
        else:
            print("No screenshots extracted", file=sys.stderr)


def _bulk_export(xcresult: str, output_dir: str):
    """Last resort: export all test attachments as directory tree."""
    try:
        r = subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "export",
                "--type",
                "directory",
                "--path",
                xcresult,
                "--output-path",
                output_dir,
            ],
            capture_output=True,
            text=True,
        )
        if r.returncode == 0:
            # Walk the exported tree for PNGs
            pngs = []
            for root, _dirs, files in os.walk(output_dir):
                for f in files:
                    if f.endswith(".png"):
                        pngs.append(os.path.join(root, f))
            if pngs:
                # Move all PNGs to the top-level output dir with clean names
                for i, png_path in enumerate(sorted(pngs)):
                    clean = os.path.join(output_dir, f"screenshot_{i + 1:02d}.png")
                    os.rename(png_path, clean)
                print(f"Bulk exported {len(pngs)} screenshots to {output_dir}")
            else:
                print("Bulk export produced no PNGs", file=sys.stderr)
    except Exception as e:
        print(f"Bulk export failed: {e}", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <xcresult_path> <output_dir>", file=sys.stderr)
        sys.exit(1)
    extract_attachments(sys.argv[1], sys.argv[2])
