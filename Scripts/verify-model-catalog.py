#!/usr/bin/env python3
"""Download every production catalog artifact into a clean temp file and verify it."""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
import tempfile
from pathlib import Path
from typing import TypedDict
from urllib.parse import urlparse
from urllib.request import Request, urlopen


class CatalogArtifact(TypedDict):
    model: str
    kind: str
    url: str
    size: int
    sha256: str


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "ZiroEdge" / "Models" / "AIModel.swift"
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")


def parse_size(match: re.Match[str], label: str) -> int:
    try:
        return int(match.group(1).replace("_", ""))
    except ValueError as error:
        raise ValueError(f"invalid byte length for {label}") from error


def extract_catalog() -> list[CatalogArtifact]:
    source = CATALOG.read_text(encoding="utf-8")
    # Reference entries are intentionally not production catalog entries.
    source = source.split("/* Reference:", 1)[0]
    models: list[CatalogArtifact] = []
    pattern = re.compile(r"static let\s+\w+\s*=\s*AIModel\((.*?)\n    \)", re.DOTALL)

    for block in pattern.findall(source):
        model_id = re.search(r'id:\s*"([^"]+)"', block)
        model_type = re.search(r"modelType:\s*\.(\w+)", block)
        base_url = re.search(r'baseURL:\s*URL\(string:\s*"([^"]+)"\)', block)
        base_size = re.search(r"baseFileSizeBytes:\s*([0-9_]+)", block)
        base_hash = re.search(r'baseSHA256:\s*"([^"]+)"', block)
        if (
            model_id is None
            or model_type is None
            or base_url is None
            or base_size is None
            or base_hash is None
        ):
            raise ValueError(
                "Could not parse a complete base artifact from AIModel.swift"
            )

        artifacts: list[CatalogArtifact] = [
            {
                "model": model_id.group(1),
                "kind": "base",
                "url": base_url.group(1),
                "size": parse_size(base_size, f"{model_id.group(1)} base"),
                "sha256": base_hash.group(1),
            }
        ]

        if model_type.group(1) == "vision":
            projector_url = re.search(r'mmprojURL:\s*URL\(string:\s*"([^"]+)"\)', block)
            projector_size = re.search(r"mmprojFileSizeBytes:\s*([0-9_]+)", block)
            projector_hash = re.search(r'mmprojSHA256:\s*"([^"]+)"', block)
            if (
                projector_url is None
                or projector_size is None
                or projector_hash is None
            ):
                raise ValueError(
                    f"{model_id.group(1)} is missing complete projector metadata"
                )
            artifacts.append(
                {
                    "model": model_id.group(1),
                    "kind": "mmproj",
                    "url": projector_url.group(1),
                    "size": parse_size(projector_size, f"{model_id.group(1)} mmproj"),
                    "sha256": projector_hash.group(1),
                }
            )

        models.extend(artifacts)

    if not models:
        raise ValueError("No production catalog artifacts found")
    return models


def validate_metadata(artifacts: list[CatalogArtifact]) -> None:
    destinations: set[str] = set()
    for artifact in artifacts:
        url = str(artifact["url"])
        parsed = urlparse(url)
        if (
            parsed.scheme != "https"
            or not parsed.netloc
            or not parsed.path
            or not parsed.path.lower().endswith(".gguf")
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError(
                f"non-canonical URL for {artifact['model']} {artifact['kind']}: {url}"
            )

        size = artifact["size"]
        if size <= 0:
            raise ValueError(
                f"non-positive size for {artifact['model']} {artifact['kind']}"
            )

        digest = str(artifact["sha256"])
        if not SHA256_RE.fullmatch(digest):
            raise ValueError(
                f"invalid SHA-256 for {artifact['model']} {artifact['kind']}"
            )

        suffix = "-mmproj.gguf" if artifact["kind"] == "mmproj" else ".gguf"
        destination = f"{artifact['model']}{suffix}"
        if destination in destinations:
            raise ValueError(f"duplicate destination: {destination}")
        destinations.add(destination)


def verify_download(artifact: CatalogArtifact) -> None:
    request = Request(
        str(artifact["url"]),
        headers={"User-Agent": "ZiroEdge-catalog-release-check/1"},
    )
    expected_size = artifact["size"]
    expected_hash = str(artifact["sha256"]).lower()
    actual_size = 0
    digest = hashlib.sha256()

    with tempfile.NamedTemporaryFile(
        prefix="ziroedge-catalog-", suffix=".gguf"
    ) as clean_file:
        with urlopen(request, timeout=120) as response:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                clean_file.write(chunk)
                digest.update(chunk)
                actual_size += len(chunk)
        clean_file.flush()

        actual_hash = digest.hexdigest()
        label = f"{artifact['model']} {artifact['kind']}"
        if actual_size != expected_size:
            raise ValueError(
                f"{label}: expected {expected_size} bytes, downloaded {actual_size}"
            )
        if actual_hash != expected_hash:
            raise ValueError(
                f"{label}: expected {expected_hash}, downloaded {actual_hash}"
            )
        print(f"verified {label}: {actual_size} bytes, {actual_hash}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model",
        action="append",
        help="verify only this model ID (repeatable); default is every production artifact",
    )
    args = parser.parse_args()

    try:
        artifacts = extract_catalog()
        validate_metadata(artifacts)
        selected = (
            [artifact for artifact in artifacts if artifact["model"] in args.model]
            if args.model
            else artifacts
        )
        if args.model and not selected:
            raise ValueError(
                "none of the requested model IDs exist in the production catalog"
            )
        for artifact in selected:
            verify_download(artifact)
    except Exception as error:  # noqa: BLE001 - release check should report one concise failure
        print(f"catalog verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
