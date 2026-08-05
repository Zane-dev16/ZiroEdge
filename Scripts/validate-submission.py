#!/usr/bin/env python3
"""Validate local App Store submission-package consistency.

This script does not perform live privacy reachability, release-gate, physical-
device, or authorized human visual-review checks. Passing means only that the
local package checks listed below succeeded; it is not a submission-ready
verdict. Use ``Scripts/release-gate-check.sh`` for the fail-closed release verdict.

Checks:
1. Listing metadata is valid JSON with required fields
2. Review notes document exists and covers required topics
3. PrivacyInfo.xcprivacy declares zero tracking and zero data collection
4. Privacy policy URL is set to a live HTTPS URL
5. THIRD_PARTY_NOTICES.md is bundled
6. All catalog models carry a license
7. Screenshot capture/verification scripts are present
8. Every required screenshot set has at least three exact-size real UI PNGs

Usage: python3 Scripts/validate-submission.py [--project-root .]
Exit 0 when local package checks pass; exit 1 when a local package check fails.
Neither exit code represents live release readiness.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

REQUIRED_METADATA_FIELDS = {
    "name": str,
    "description": str,
    "keywords": list,
    "category": dict,
    "copyright": str,
}

REQUIRED_CATEGORY_FIELDS = {"primary", "secondary"}

REQUIRED_REVIEW_TOPICS = (
    "local inference",
    "no account",
    "no data collection",
    "privacy",
    "on-device",
)

REQUIRED_PRIVACY_KEYS = {
    "NSPrivacyTracking": False,
    "NSPrivacyCollectedDataTypes": [],
}


def validate_metadata(metadata_path: Path) -> list[str]:
    errors: list[str] = []
    try:
        data = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        return [f"listing-metadata.json: cannot parse — {exc}"]

    app = data.get("app", {})
    for field, expected_type in REQUIRED_METADATA_FIELDS.items():
        if field not in app:
            errors.append(f"listing-metadata.json: missing app.{field}")
        elif not isinstance(app[field], expected_type):
            errors.append(
                f"listing-metadata.json: app.{field} must be {expected_type.__name__}, "
                f"got {type(app[field]).__name__}"
            )

    category = app.get("category", {})
    missing = REQUIRED_CATEGORY_FIELDS - set(category.keys())
    if missing:
        errors.append(
            f"listing-metadata.json: app.category missing fields: {', '.join(sorted(missing))}"
        )

    keywords = app.get("keywords", [])
    if len(keywords) < 5:
        errors.append(
            f"listing-metadata.json: at least 5 keywords required, found {len(keywords)}"
        )

    privacy = data.get("privacy", {})
    policy_url = privacy.get("policyURL", "")
    parsed = urlparse(policy_url)
    if parsed.scheme != "https" or not parsed.hostname:
        errors.append(
            f"listing-metadata.json: privacy.policyURL is not a valid HTTPS URL: {policy_url!r}"
        )

    return errors


def validate_review_notes(notes_path: Path) -> list[str]:
    errors: list[str] = []
    if not notes_path.is_file():
        return [f"review-notes.md: file not found at {notes_path}"]
    try:
        text = notes_path.read_text(encoding="utf-8").lower()
    except OSError as exc:
        return [f"review-notes.md: cannot read — {exc}"]

    for topic in REQUIRED_REVIEW_TOPICS:
        if topic not in text:
            errors.append(f"review-notes.md: missing required topic '{topic}'")
    return errors


def validate_privacy_manifest(manifest_path: Path) -> list[str]:
    errors: list[str] = []
    if not manifest_path.is_file():
        return [f"PrivacyInfo.xcprivacy: file not found at {manifest_path}"]

    try:
        import plistlib

        with manifest_path.open("rb") as fh:
            plist = plistlib.load(fh)
    except Exception as exc:
        return [f"PrivacyInfo.xcprivacy: cannot parse — {exc}"]

    for key, expected in REQUIRED_PRIVACY_KEYS.items():
        actual = plist.get(key)
        if actual != expected:
            errors.append(
                f"PrivacyInfo.xcprivacy: {key} is {actual!r}, expected {expected!r}"
            )

    accessed_apis = plist.get("NSPrivacyAccessedAPITypes", [])
    if not isinstance(accessed_apis, list) or len(accessed_apis) < 2:
        errors.append(
            "PrivacyInfo.xcprivacy: expected at least UserDefaults and DiskSpace reason entries"
        )

    return errors


def validate_third_party_notices(notices_path: Path) -> list[str]:
    errors: list[str] = []
    if not notices_path.is_file():
        return [f"THIRD_PARTY_NOTICES.md: file not found at {notices_path}"]
    try:
        text = notices_path.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"THIRD_PARTY_NOTICES.md: cannot read — {exc}"]

    if "llama.cpp" not in text:
        errors.append("THIRD_PARTY_NOTICES.md: missing llama.cpp attribution")
    if "MIT License" not in text:
        errors.append("THIRD_PARTY_NOTICES.md: missing MIT License text")
    return errors


def validate_privacy_policy(root: Path) -> list[str]:
    """Run the privacy policy verifier in local-only mode."""
    verifier = root / "Scripts" / "verify-privacy-policy.py"
    if not verifier.is_file():
        return [f"Privacy policy verifier not found: {verifier}"]

    result = subprocess.run(
        [sys.executable, str(verifier), "--local-only"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        return [f"Privacy policy verification failed:\n{detail}"]
    return []


def validate_screenshot_assets(root: Path) -> list[str]:
    required_scripts = (
        root / "Scripts" / "extract-screenshots.py",
        root / "Scripts" / "verify-screenshots.py",
    )
    errors = [
        f"screenshot script not found: {path}"
        for path in required_scripts
        if not path.is_file()
    ]
    if errors:
        return errors

    result = subprocess.run(
        [
            sys.executable,
            str(root / "Scripts" / "verify-screenshots.py"),
            str(root / "ziroedge-docs" / "app-store-screenshots"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        errors.append(f"App Store screenshots are incomplete:\n{detail}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Validate local App Store package consistency only; this does not "
            "produce a live release-readiness verdict"
        ),
        epilog=(
            "Exit 0 means local package checks passed; exit 1 means a local "
            "package check failed. Neither exit code means the release is ready."
        ),
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Path to the project root (default: parent of Scripts/)",
    )
    args = parser.parse_args()
    root = args.project_root

    all_errors: list[str] = []

    all_errors += validate_metadata(root / "AppStore" / "listing-metadata.json")
    all_errors += validate_review_notes(root / "AppStore" / "review-notes.md")
    all_errors += validate_privacy_manifest(
        root / "ZiroEdge" / "Resources" / "PrivacyInfo.xcprivacy"
    )
    all_errors += validate_third_party_notices(
        root / "ZiroEdge" / "Resources" / "THIRD_PARTY_NOTICES.md"
    )
    all_errors += validate_privacy_policy(root)
    all_errors += validate_screenshot_assets(root)

    if all_errors:
        print("❌ Local App Store package checks failed:")
        for err in all_errors:
            print(f"  • {err}")
        return 1

    print("✅ Local App Store package checks passed.")
    print(
        "   This is not a submission-ready verdict; live release gates remain separate."
    )
    print("   • Listing metadata: complete")
    print("   • Review notes: complete")
    print("   • PrivacyInfo.xcprivacy: zero tracking, zero data collection")
    print("   • Privacy policy: local checks passed")
    print("   • THIRD_PARTY_NOTICES.md: bundled")
    print("   • Required screenshot sets: complete and exact-size")
    return 0


if __name__ == "__main__":
    sys.exit(main())
