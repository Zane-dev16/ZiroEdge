#!/usr/bin/env python3
"""Verify ZiroEdge's colour tokens against the WCAG contrast contract.

This is the guard rail for the design system. `DesignSystem.swift` and the
asset catalog are the single source of truth; this script reads them and
re-proves every foreground/background pairing the spec promises, in BOTH
appearances. It never invents values — it checks what is actually shipped.

    python3 app/Scripts/verify-design-tokens.py           # check, exit 1 on failure
    python3 app/Scripts/verify-design-tokens.py --table   # emit the markdown table for DESIGN-SPEC.md §4

Floors (repo a11y standard): 4.5:1 for text, 3.0:1 for icons / large text.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DESIGN_SYSTEM = REPO / "app/ZiroEdge/Views/DesignSystem.swift"
ASSETS = REPO / "app/ZiroEdge/Resources/Assets.xcassets"

TEXT_FLOOR = 4.5
ICON_FLOOR = 3.0

# `static let name = ziroColor(light: 0xRRGGBB, dark: 0xRRGGBB)`
TOKEN_RE = re.compile(
    r"static\s+let\s+(\w+)\s*=\s*ziroColor\(\s*light:\s*0x([0-9A-Fa-f]{6})\s*,\s*dark:\s*0x([0-9A-Fa-f]{6})\s*\)"
)

# Alias tokens resolve to another token rather than a literal.
ALIAS_RE = re.compile(r"static\s+let\s+(\w+)\s*=\s*(\w+)\s*$", re.MULTILINE)


# --------------------------------------------------------------------------
# WCAG relative luminance / contrast
# --------------------------------------------------------------------------
def _channel(value: int) -> float:
    srgb = value / 255.0
    return srgb / 12.92 if srgb <= 0.04045 else ((srgb + 0.055) / 1.055) ** 2.4


def luminance(hex_colour: str) -> float:
    raw = hex_colour.lstrip("#")
    r, g, b = (int(raw[i : i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * _channel(r) + 0.7152 * _channel(g) + 0.0722 * _channel(b)


def contrast(a: str, b: str) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# --------------------------------------------------------------------------
# Load tokens from the real sources
# --------------------------------------------------------------------------
def load_swift_tokens(
    extra: dict[str, dict[str, str]] | None = None,
) -> dict[str, dict[str, str]]:
    """Read colour tokens, resolving aliases (including chains) to literals.

    `extra` supplies tokens defined outside the Swift file (the asset-backed
    `accent` / `accentForeground`), so aliases like `infoText = accent`
    resolve against the real shipped value.
    """
    source = DESIGN_SYSTEM.read_text()
    tokens: dict[str, dict[str, str]] = {}

    for name, light, dark in TOKEN_RE.findall(source):
        tokens[name] = {"light": f"#{light.upper()}", "dark": f"#{dark.upper()}"}

    # Resolve aliases to a fixed point: `purpleContainer = neutralContainer`
    # where `neutralContainer = wellBackground` needs two passes.
    aliases = [(a, t) for a, t in ALIAS_RE.findall(source) if a != t]
    for _ in range(len(aliases) + 1):
        gained = False
        for alias, target in aliases:
            if alias in tokens:
                continue
            resolved = tokens.get(target) or (extra or {}).get(target)
            if resolved is not None:
                tokens[alias] = dict(resolved)
                gained = True
        if not gained:
            break

    return tokens


class TokenError(SystemExit):
    """A token source could not be read. Fail loudly, never silently."""


def load_colorset(name: str) -> dict[str, str]:
    """Read a .colorset, returning {'light': #RRGGBB, 'dark': #RRGGBB}."""
    path = ASSETS / f"{name}.colorset/Contents.json"
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        raise TokenError(f"cannot read colorset {name} at {path}: {exc}") from exc

    out: dict[str, str] = {}
    for entry in data.get("colors", []):
        appearances = {
            a["appearance"]: a["value"] for a in entry.get("appearances", []) or []
        }
        # Skip Increased Contrast variants — this script checks the defaults.
        if appearances.get("contrast") == "high":
            continue
        components = entry.get("color", {}).get("components")
        if not components:
            continue
        try:
            channels = tuple(
                round(float(components[c]) * 255) for c in ("red", "green", "blue")
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise TokenError(
                f"malformed components in colorset {name} at {path}: {exc}"
            ) from exc
        out["dark" if appearances.get("luminosity") == "dark" else "light"] = (
            "#%02X%02X%02X" % channels
        )

    if "light" not in out and "dark" not in out:
        raise TokenError(f"colorset {name} defines no default-appearance colour")
    for key in ("light", "dark"):
        out.setdefault(key, out.get("light") or out.get("dark", "#000000"))
    return out


# --------------------------------------------------------------------------
# The contract
# --------------------------------------------------------------------------
SURFACES = ("pageBackground", "raisedBackground", "wellBackground", "overlayBackground")

# Foreground tokens checked against every surface they may sit on.
ON_SURFACE = (
    "primaryText",
    "secondaryText",
    "tertiaryText",
    "accent",
    "positiveText",
    "warningText",
    "dangerText",
    "infoText",
)

# `text` is checked on `container`.
ON_CONTAINER = (
    ("accent", "accentContainer", TEXT_FLOOR),
    ("positiveText", "positiveContainer", TEXT_FLOOR),
    ("warningText", "warningContainer", TEXT_FLOOR),
    ("dangerText", "dangerContainer", TEXT_FLOOR),
    ("infoText", "infoContainer", TEXT_FLOOR),
    ("secondaryText", "wellBackground", TEXT_FLOOR),
)


def check(
    tokens: dict[str, dict[str, str]], assets: dict[str, dict[str, str]]
) -> list[str]:
    failures: list[str] = []
    appearances = ("light", "dark")

    def value(token: str, appearance: str) -> str | None:
        if token in tokens:
            return tokens[token][appearance]
        if token in assets:
            return assets[token][appearance]
        return None

    for appearance in appearances:
        for fg in ON_SURFACE:
            fg_value = value(fg, appearance)
            if fg_value is None:
                failures.append(f"MISSING token: {fg}")
                continue
            for surface in SURFACES:
                bg_value = value(surface, appearance)
                if bg_value is None:
                    failures.append(f"MISSING token: {surface}")
                    continue
                ratio = contrast(fg_value, bg_value)
                if ratio < TEXT_FLOOR:
                    failures.append(
                        f"{appearance}: {fg} {fg_value} on {surface} {bg_value} "
                        f"= {ratio:.2f} (needs {TEXT_FLOOR})"
                    )

        for fg, container, floor in ON_CONTAINER:
            fg_value, bg_value = value(fg, appearance), value(container, appearance)
            if fg_value is None or bg_value is None:
                failures.append(f"MISSING token: {fg} or {container}")
                continue
            ratio = contrast(fg_value, bg_value)
            if ratio < floor:
                failures.append(
                    f"{appearance}: {fg} {fg_value} on {container} {bg_value} "
                    f"= {ratio:.2f} (needs {floor})"
                )

        # On-accent fills: accentForeground must be readable on the accent.
        accent = value("accent", appearance)
        on_accent = value("accentForeground", appearance)
        if accent and on_accent:
            ratio = contrast(accent, on_accent)
            if ratio < TEXT_FLOOR:
                failures.append(
                    f"{appearance}: accentForeground {on_accent} on accent {accent} "
                    f"= {ratio:.2f} (needs {TEXT_FLOOR})"
                )

    return failures


def emit_table(
    tokens: dict[str, dict[str, str]], assets: dict[str, dict[str, str]]
) -> str:
    def value(token: str, appearance: str) -> str:
        return tokens.get(token, assets.get(token, {})).get(appearance, "?")

    lines = [
        "**Text hierarchy (floor 4.5:1)**",
        "",
        "| Token | Light page/raised/well | Dark page/raised/well |",
        "| --- | --- | --- |",
    ]
    for token in ("primaryText", "secondaryText", "tertiaryText"):
        cells = []
        for appearance in ("light", "dark"):
            cells.append(
                " / ".join(
                    f"{contrast(value(token, appearance), value(s, appearance)):.2f}"
                    for s in ("pageBackground", "raisedBackground", "wellBackground")
                )
            )
        lines.append(f"| `{token}` | {cells[0]} | {cells[1]} |")

    lines += [
        "",
        "**Accent & semantics on page/raised/well**",
        "",
        "| Token | Light | Dark |",
        "| --- | --- | --- |",
    ]
    for token in ("accent", "positiveText", "warningText", "dangerText", "infoText"):
        cells = []
        for appearance in ("light", "dark"):
            cells.append(
                " / ".join(
                    f"{contrast(value(token, appearance), value(s, appearance)):.2f}"
                    for s in ("pageBackground", "raisedBackground", "wellBackground")
                )
            )
        lines.append(f"| `{token}` | {cells[0]} | {cells[1]} |")

    lines += [
        "",
        "**Text on its own tinted container (floor 4.5:1)**",
        "",
        "| Pair | Light | Dark |",
        "| --- | --- | --- |",
    ]
    for fg, container, _ in ON_CONTAINER:
        cells = [
            f"{contrast(value(fg, a), value(container, a)):.2f}"
            for a in ("light", "dark")
        ]
        lines.append(f"| `{fg}` on `{container}` | {cells[0]} | {cells[1]} |")
    cells = [
        f"{contrast(value('accentForeground', a), value('accent', a)):.2f}"
        for a in ("light", "dark")
    ]
    lines.append(f"| `accentForeground` on `accent` | {cells[0]} | {cells[1]} |")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--table",
        action="store_true",
        help="print the markdown table for DESIGN-SPEC.md §4",
    )
    args = parser.parse_args()

    if not DESIGN_SYSTEM.exists():
        raise TokenError(f"missing design system at {DESIGN_SYSTEM}")

    assets = {
        "accent": load_colorset("AccentColor"),
        "accentForeground": load_colorset("AccentForeground"),
    }
    tokens = load_swift_tokens(extra=assets)

    if args.table:
        print(emit_table(tokens, assets))
        return 0

    failures = check(tokens, assets)

    print(
        f"Design tokens: {len(tokens)} from DesignSystem.swift, {len(assets)} from the asset catalog"
    )
    for appearance in ("light", "dark"):
        print(
            f"  {appearance:5s}  accent={assets['accent'][appearance]}  "
            f"accentForeground={assets['accentForeground'][appearance]}  "
            f"page={tokens['pageBackground'][appearance]}"
        )

    if failures:
        print(f"\nFAIL — {len(failures)} pairing(s) below floor:")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print(
        "\nPASS — every documented pairing clears its WCAG floor in both appearances."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
