#!/usr/bin/env python3
"""Verify the privacy policy page is locally correct and publicly reachable.

Checks:
1. The local privacy.html exists and contains every required policy section.
2. The app and AppStore/listing-metadata.json use the canonical URL.
3. Live verification receives a successful HTTP response (fail-closed).

Usage:
  python3 Scripts/verify-privacy-policy.py              # full check (needs network)
  python3 Scripts/verify-privacy-policy.py --local-only  # skip live reachability
  python3 Scripts/verify-privacy-policy.py --url URL     # override canonical URL

Exit 0 when the policy is ready; exit 1 with details when something is missing.
"""

from __future__ import annotations

import argparse
import json
import re
import urllib.error
from pathlib import Path
from typing import Sequence
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]

CANONICAL_URL = "https://zane-dev16.github.io/ZiroEdge/privacy.html"

REQUIRED_SECTIONS: tuple[tuple[str, str], ...] = (
    ("Data Collection", "does not collect"),
    ("On-Device Processing", "on your device"),
    ("Conversation Storage", "locally"),
    ("Model Downloads", "choose to download"),
    ("Third-Party Services", "Hugging Face"),
    ("Your Rights", "control"),
    ("Children's Privacy", "under 13"),
    ("Changes to This Policy", "may be updated"),
)


def local_page_path() -> Path:
    return ROOT / "docs" / "privacy.html"


def listing_metadata_path() -> Path:
    return ROOT / "AppStore" / "listing-metadata.json"


def settings_source_paths() -> Sequence[Path]:
    """Swift source files known to reference the privacy policy URL."""
    return (ROOT / "ZiroEdge" / "ZiroEdgeApp.swift",)


def check_local_page(page_path: Path) -> list[str]:
    errors: list[str] = []
    if not page_path.is_file():
        return [f"Local privacy page not found: {page_path}"]

    try:
        text = page_path.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"Cannot read {page_path}: {exc}"]

    if "<!DOCTYPE html>" not in text and "<!doctype html>" not in text:
        errors.append("Local privacy page is not valid HTML (missing DOCTYPE)")

    if '<meta name="viewport"' not in text:
        errors.append("Local privacy page is missing a mobile viewport meta tag")

    lower = text.lower()
    for section_name, keyword in REQUIRED_SECTIONS:
        if keyword.lower() not in lower:
            errors.append(
                f"Local privacy page missing required section content: "
                f"'{section_name}' (expected keyword: '{keyword}')"
            )

    return errors


def check_listing_metadata(listing_path: Path, canonical_url: str) -> list[str]:
    errors: list[str] = []
    if not listing_path.is_file():
        return [f"Listing metadata not found: {listing_path}"]

    try:
        data = json.loads(listing_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        return [f"Cannot parse listing metadata: {exc}"]

    privacy = data.get("privacy", {})
    policy_url = privacy.get("policyURL", "")
    if policy_url != canonical_url:
        errors.append(
            f"listing-metadata.json policyURL is {policy_url!r}, "
            f"expected {canonical_url!r}"
        )
    return errors


def check_settings_source(paths: Sequence[Path], canonical_url: str) -> list[str]:
    errors: list[str] = []
    url_pattern = re.compile(r'"https?://[^"]*privacy[^"]*"')

    for path in paths:
        if not path.is_file():
            errors.append(f"Settings source not found: {path}")
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            errors.append(f"Cannot read {path}: {exc}")
            continue

        found = url_pattern.findall(text)
        if not found:
            errors.append(f"{path.name}: no privacy URL found")
            continue

        for match in found:
            url = match.strip('"')
            if url != canonical_url:
                errors.append(
                    f"{path.name}: contains non-canonical privacy URL {url!r}, "
                    f"expected {canonical_url!r}"
                )
    return errors


def check_live_reachability(canonical_url: str, timeout: int) -> list[str]:
    """Fail-closed: any non-2xx response or network error is a blocking failure."""
    errors: list[str] = []
    request = Request(
        canonical_url,
        headers={"User-Agent": "ZiroEdge-privacy-release-check/1"},
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            status = response.status
            if 200 <= status < 300:
                return []  # success
            body_preview = response.read(4096).decode("utf-8", errors="replace")
            # GitHub Pages 404 often returns 200 with a "not found" page.
            if (
                "github.com/404" in body_preview
                or "There isn't a GitHub Pages site here" in body_preview
            ):
                errors.append(
                    f"Live privacy page returned {status} but content indicates "
                    f"GitHub Pages is not deployed: {canonical_url}"
                )
            else:
                errors.append(
                    f"Live privacy page returned HTTP {status}: {canonical_url}"
                )
    except urllib.error.HTTPError as exc:
        errors.append(f"Live privacy page returned HTTP {exc.code}: {canonical_url}")
    except urllib.error.URLError as exc:
        errors.append(
            f"Live privacy page is unreachable: {canonical_url} — {exc.reason}"
        )
    except OSError as exc:
        errors.append(f"Live privacy page connection failed: {canonical_url} — {exc}")
    return errors


def verify_all(
    canonical_url: str = CANONICAL_URL,
    *,
    local_only: bool = False,
    timeout: int = 30,
) -> list[str]:
    errors: list[str] = []

    errors += check_local_page(local_page_path())
    errors += check_listing_metadata(listing_metadata_path(), canonical_url)
    errors += check_settings_source(settings_source_paths(), canonical_url)

    if not local_only:
        errors += check_live_reachability(canonical_url, timeout)

    return errors


def verify_local_only(canonical_url: str = CANONICAL_URL) -> list[str]:
    return verify_all(canonical_url, local_only=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--local-only",
        action="store_true",
        help="Skip live reachability check",
    )
    parser.add_argument(
        "--url",
        type=str,
        default=CANONICAL_URL,
        help=f"Canonical privacy policy URL (default: {CANONICAL_URL})",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=30,
        help="HTTP timeout in seconds (default: 30)",
    )
    args = parser.parse_args()

    errors = verify_all(
        canonical_url=args.url,
        local_only=args.local_only,
        timeout=args.timeout,
    )

    if errors:
        print("❌ Privacy policy verification failed:")
        for err in errors:
            print(f"  • {err}")
        return 1

    mode = "local" if args.local_only else "full"
    print(f"✅ Privacy policy verification passed ({mode}).")
    if args.local_only:
        print(
            "   Live reachability was skipped; re-run without --local-only to verify."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
