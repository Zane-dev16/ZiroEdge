"""Tests for the fail-closed screenshot verifier."""

import importlib.util
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "verify-screenshots.py"
spec = importlib.util.spec_from_file_location("screenshot_validator", SCRIPT)
if spec is None or spec.loader is None:
    raise RuntimeError(f"Could not load screenshot validator from {SCRIPT}")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data))
    )


def write_rgb_png(path: Path, width: int, height: int, pixel) -> None:
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(pixel(x, y))
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(rows))
        + png_chunk(b"IEND", b"")
    )


class ScreenshotVerificationTests(unittest.TestCase):
    def test_near_blank_capture_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "blank.png"
            write_rgb_png(path, 64, 64, lambda _x, _y: (250, 250, 250))
            values, _ = validator.visual_signature(path)
            self.assertTrue(validator.is_near_blank(values))

    def test_structurally_identical_capture_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.png"
            second = Path(directory) / "second.png"
            pattern = (
                lambda x, y: (20, 20, 20) if (x // 8 + y // 8) % 2 else (240, 240, 240)
            )
            write_rgb_png(first, 64, 64, pattern)
            write_rgb_png(second, 64, 64, pattern)
            self.assertTrue(
                validator.structurally_identical(
                    validator.visual_signature(first),
                    validator.visual_signature(second),
                )
            )

    def test_distinct_nonblank_captures_pass_similarity_check(self):
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.png"
            second = Path(directory) / "second.png"
            write_rgb_png(first, 64, 64, lambda x, _y: (x * 4, 30, 30))
            write_rgb_png(second, 64, 64, lambda _x, y: (30, y * 4, 30))
            first_signature = validator.visual_signature(first)
            second_signature = validator.visual_signature(second)
            self.assertFalse(validator.is_near_blank(first_signature[0]))
            self.assertFalse(validator.is_near_blank(second_signature[0]))
            self.assertFalse(
                validator.structurally_identical(first_signature, second_signature)
            )


if __name__ == "__main__":
    unittest.main()
