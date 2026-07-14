#!/usr/bin/env python3
"""Generate HTML + Markdown test report from screenshots and xcresult.

Usage: python3 generate-report.py <output_dir> <layer> <exit_code>

Reads screenshots from output_dir/screenshots/ and produces:
  - output_dir/report.html
  - output_dir/report.md
"""

import glob
import os
import sys
from datetime import datetime
from pathlib import Path


def gather_screenshots(screenshots_dir: str) -> list[str]:
    """Get sorted list of screenshot filenames."""
    pngs = sorted(glob.glob(os.path.join(screenshots_dir, "*.png")))
    return [os.path.basename(p) for p in pngs]


def parse_screenshot_name(name: str) -> dict:
    """Parse ClassName_NN_description.png into parts."""
    stem = Path(name).stem
    parts = stem.split("_", 2)
    if len(parts) >= 3:
        return {"class": parts[0], "step": parts[1], "description": parts[2]}
    return {"class": "?", "step": "?", "description": stem}


def generate_html(screenshots: list[str], layer: str, exit_code: int, output_dir: str):
    """Write report.html."""
    status = "PASS" if exit_code == 0 else "FAIL"
    status_color = "#4ade80" if exit_code == 0 else "#f87171"
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    groups: dict[str, list[str]] = {}
    for s in screenshots:
        info = parse_screenshot_name(s)
        groups.setdefault(info["class"], []).append(s)

    html = f"""<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>ZiroEdge Test Report — {status}</title>
<style>
  body {{ font-family: -apple-system, sans-serif; background: #1a1a2e; color: #e0e0e0; margin: 0; padding: 20px; }}
  .header {{ display: flex; align-items: center; gap: 16px; margin-bottom: 24px; }}
  .badge {{ background: {status_color}; color: #000; padding: 6px 16px; border-radius: 8px; font-weight: bold; font-size: 18px; }}
  .meta {{ color: #888; font-size: 14px; }}
  h1 {{ margin: 0; }}
  h2 {{ color: #a78bfa; border-bottom: 1px solid #333; padding-bottom: 8px; margin-top: 32px; }}
  .screenshots {{ display: flex; flex-wrap: wrap; gap: 12px; }}
  .screenshot {{ background: #16213e; border-radius: 8px; padding: 8px; max-width: 320px; }}
  .screenshot img {{ width: 100%; border-radius: 4px; }}
  .screenshot .caption {{ font-size: 12px; color: #aaa; margin-top: 4px; text-align: center; }}
</style>
</head><body>
<div class="header">
  <h1>ZiroEdge Device Test Report</h1>
  <span class="badge">{status}</span>
</div>
<div class="meta">
  Layer: <strong>{layer}</strong> &bull; Generated: {now} &bull;
  Screenshots: {len(screenshots)} &bull; Exit code: {exit_code}
</div>
"""

    for cls, files in groups.items():
        html += f"<h2>{cls}</h2>\n<div class='screenshots'>\n"
        for f in files:
            info = parse_screenshot_name(f)
            html += f"""<div class="screenshot">
  <img src="screenshots/{f}" alt="{info['description']}">
  <div class="caption">{info['step']}. {info['description'].replace('_', ' ')}</div>
</div>\n"""
        html += "</div>\n"

    html += "</body></html>"

    with open(os.path.join(output_dir, "report.html"), "w") as fh:
        fh.write(html)


def generate_markdown(screenshots: list[str], layer: str, exit_code: int, output_dir: str):
    """Write report.md."""
    status = "PASS" if exit_code == 0 else "FAIL"
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    groups: dict[str, list[str]] = {}
    for s in screenshots:
        info = parse_screenshot_name(s)
        groups.setdefault(info["class"], []).append(s)

    md = f"""# ZiroEdge Device Test Report — {status}

Layer: **{layer}** | Generated: {now} | Screenshots: {len(screenshots)} | Exit code: {exit_code}

"""
    for cls, files in groups.items():
        md += f"## {cls}\n\n"
        for f in files:
            info = parse_screenshot_name(f)
            md += f"- [{info['step']}. {info['description'].replace('_', ' ')}](screenshots/{f})\n"
        md += "\n"

    with open(os.path.join(output_dir, "report.md"), "w") as fh:
        fh.write(md)


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <output_dir> <layer> <exit_code>", file=sys.stderr)
        sys.exit(1)

    output_dir = sys.argv[1]
    layer = sys.argv[2]
    exit_code = int(sys.argv[3])
    screenshots_dir = os.path.join(output_dir, "screenshots")

    screenshots = gather_screenshots(screenshots_dir)
    generate_html(screenshots, layer, exit_code, output_dir)
    generate_markdown(screenshots, layer, exit_code, output_dir)
    print(f"Reports written to {output_dir}/report.html and report.md")


if __name__ == "__main__":
    main()
