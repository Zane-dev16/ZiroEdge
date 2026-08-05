#!/usr/bin/env python3
"""Fail closed unless App Store screenshot sets are valid and visually distinct."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from collections import Counter
from pathlib import Path

EXPECTED = {
    "iphone-67": (1290, 2796),
    "iphone-61": (1179, 2556),
    "ipad-13": (2048, 2732),
    "ipad-11": (1668, 2388),
}
SAMPLE_SIZE = 32


def png_metadata(path: Path) -> tuple[int, int, int]:
    data = path.read_bytes()
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a valid PNG")
    if data[12:16] != b"IHDR":
        raise ValueError("PNG does not start with IHDR")
    width, height, depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", data[16:29]
    )
    if depth != 8 or color_type not in (2, 6):
        raise ValueError("PNG must use 8-bit RGB or RGBA color")
    if compression != 0 or filtering != 0 or interlace != 0:
        raise ValueError(
            "PNG must be non-interlaced with standard compression/filtering"
        )
    return width, height, color_type


def read_png(path: Path) -> tuple[int, int, list[bytearray]]:
    """Decode a non-interlaced 8-bit RGB/RGBA PNG using only the standard library."""
    data = path.read_bytes()
    width, height, color_type = png_metadata(path)

    compressed = bytearray()
    offset = 8
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_end = offset + 12 + length
        if chunk_end > len(data):
            raise ValueError("truncated PNG chunk")
        if chunk_type == b"IDAT":
            compressed.extend(data[offset + 8 : offset + 8 + length])
        offset = chunk_end
    try:
        raw = zlib.decompress(compressed)
    except zlib.error as error:
        raise ValueError(f"invalid PNG image data: {error}") from error

    channels = 3 if color_type == 2 else 4
    stride = width * channels
    expected_length = height * (stride + 1)
    if len(raw) != expected_length:
        raise ValueError("unexpected decompressed PNG length")

    rows: list[bytearray] = []
    previous = bytearray(stride)
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        cursor += 1
        row = bytearray(raw[cursor : cursor + stride])
        cursor += stride
        if filter_type > 4:
            raise ValueError(f"unsupported PNG filter {filter_type}")
        for index in range(stride):
            left = row[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                estimate = left + above - upper_left
                distances = (
                    abs(estimate - left),
                    abs(estimate - above),
                    abs(estimate - upper_left),
                )
                predictor = (left, above, upper_left)[distances.index(min(distances))]
            else:
                predictor = 0
            row[index] = (row[index] + predictor) & 0xFF
        rows.append(row)
        previous = row
    return width, height, rows


def visual_signature(path: Path) -> tuple[tuple[int, ...], tuple[bool, ...]]:
    signature_path = path
    temporary_directory: tempfile.TemporaryDirectory[str] | None = None
    sips = shutil.which("sips")
    if sips is not None:
        temporary_directory = tempfile.TemporaryDirectory(
            prefix="screenshot-signature-"
        )
        signature_path = Path(temporary_directory.name) / "sample.png"
        result = subprocess.run(
            [
                sips,
                "-z",
                str(SAMPLE_SIZE),
                str(SAMPLE_SIZE),
                str(path),
                "--out",
                str(signature_path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            temporary_directory.cleanup()
            raise ValueError(f"PNG decode/resize failed: {result.stderr.strip()}")

    width, height, rows = read_png(signature_path)
    channels = len(rows[0]) // width
    values: list[int] = []
    for sample_y in range(SAMPLE_SIZE):
        y = min(height - 1, ((2 * sample_y + 1) * height) // (2 * SAMPLE_SIZE))
        for sample_x in range(SAMPLE_SIZE):
            x = min(width - 1, ((2 * sample_x + 1) * width) // (2 * SAMPLE_SIZE))
            offset = x * channels
            red, green, blue = rows[y][offset : offset + 3]
            values.append((299 * red + 587 * green + 114 * blue) // 1000)
    mean = sum(values) / len(values)
    if temporary_directory is not None:
        temporary_directory.cleanup()
    return tuple(values), tuple(value >= mean for value in values)


def is_near_blank(values: tuple[int, ...]) -> bool:
    # Quantization tolerates antialiasing while detecting a mostly uniform screen.
    buckets = Counter(value // 8 for value in values)
    dominant_fraction = buckets.most_common(1)[0][1] / len(values)
    meaningful_range = max(values) - min(values)
    return dominant_fraction >= 0.96 or meaningful_range < 12


def structurally_identical(
    first: tuple[tuple[int, ...], tuple[bool, ...]],
    second: tuple[tuple[int, ...], tuple[bool, ...]],
) -> bool:
    first_values, first_hash = first
    second_values, second_hash = second
    hamming = sum(left != right for left, right in zip(first_hash, second_hash))
    mean_error = sum(
        abs(left - right) for left, right in zip(first_values, second_values)
    ) / len(first_values)
    # Require agreement from both the threshold structure and luminance error.
    # Modal screens can share a large background/layout while containing
    # materially different reviewable content.
    return hamming <= 8 and mean_error <= 1.5


def verify(root: Path, minimum_count: int) -> list[str]:
    errors: list[str] = []
    for directory, expected_size in EXPECTED.items():
        screenshot_dir = root / directory
        files = sorted(screenshot_dir.glob("*.png")) if screenshot_dir.is_dir() else []
        if len(files) < minimum_count:
            errors.append(
                f"{directory}: expected at least {minimum_count} real UI PNGs, found {len(files)}"
            )

        signatures: dict[Path, tuple[tuple[int, ...], tuple[bool, ...]]] = {}
        digests: dict[str, Path] = {}
        for path in files:
            try:
                width, height, _ = png_metadata(path)
                if (width, height) != expected_size:
                    errors.append(
                        f"{path}: expected {expected_size[0]}x{expected_size[1]}, "
                        f"found {width}x{height}"
                    )
                    continue
                signature = visual_signature(path)
                signatures[path] = signature
                if is_near_blank(signature[0]):
                    errors.append(f"{path}: capture is near-blank and not reviewable")
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                if digest in digests:
                    errors.append(f"{path}: exact duplicate of {digests[digest]}")
                else:
                    digests[digest] = path
            except (OSError, ValueError) as error:
                errors.append(f"{path}: {error}")

        paths = sorted(signatures)
        for index, first_path in enumerate(paths):
            for second_path in paths[index + 1 :]:
                if structurally_identical(
                    signatures[first_path], signatures[second_path]
                ):
                    errors.append(
                        f"{second_path}: structurally identical to {first_path}"
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
