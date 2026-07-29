#!/usr/bin/env python3
"""Fail closed unless App Store screenshot sets have the required PNG sizes/counts."""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

EXPECTED = {
    "iphone-67": (1290, 2796),
    "iphone-61": (1179, 2556),
    "ipad-13": (2048, 2732),
    "ipad-11": (1668, 2388),
}


def png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as stream:
        header = stream.read(24)
    if (
        len(header) != 24
        or header[:8] != b"\x89PNG\r\n\x1a\n"
        or header[12:16] != b"IHDR"
    ):
        raise ValueError("not a valid PNG")
    return struct.unpack(">II", header[16:24])


def verify(root: Path, minimum_count: int) -> list[str]:
    errors: list[str] = []
    for directory, expected_size in EXPECTED.items():
        screenshot_dir = root / directory
        files = sorted(screenshot_dir.glob("*.png")) if screenshot_dir.is_dir() else []
        if len(files) < minimum_count:
            errors.append(
                f"{directory}: expected at least {minimum_count} real UI PNGs, found {len(files)}"
            )
        for path in files:
            try:
                actual_size = png_size(path)
            except (OSError, ValueError) as error:
                errors.append(f"{path}: {error}")
                continue
            if actual_size != expected_size:
                errors.append(
                    f"{path}: expected {expected_size[0]}x{expected_size[1]}, "
                    f"found {actual_size[0]}x{actual_size[1]}"
                )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "root",
        nargs="?",
        type=Path,
        default=Path("ziroedge-docs/app-store-screenshots"),
    )
    parser.add_argument("--minimum-count", type=int, default=3)
    args = parser.parse_args()

    errors = verify(args.root, args.minimum_count)
    if errors:
        print("Screenshot verification failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"Screenshot verification passed: {args.root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
