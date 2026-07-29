#!/usr/bin/env python3
"""Download every production catalog artifact into a clean temp file and verify it."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tempfile
from datetime import datetime, timezone
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
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def parse_size(match: re.Match[str], label: str) -> int:
    try:
        return int(match.group(1).replace("_", ""))
    except ValueError as error:
        raise ValueError(f"invalid byte length for {label}") from error


def extract_catalog() -> list[CatalogArtifact]:
    source = CATALOG.read_text(encoding="utf-8")
    # Reference and DEBUG calibration identities are not production catalog entries.
    source = source.split("/* Reference:", 1)[0]
    source = re.sub(r"#if DEBUG.*?#endif", "", source, flags=re.DOTALL)
    models: list[CatalogArtifact] = []
    symbols: dict[str, CatalogArtifact] = {}
    seen_artifacts: set[tuple[str, int, str, str]] = set()
    pattern = re.compile(r"static let\s+(\w+)\s*=\s*AIModel\((.*?)\n    \)", re.DOTALL)

    reference_patterns = {
        "baseURL": re.compile(r"baseURL:\s*(\w+)\.baseURL"),
        "baseSHA256": re.compile(r"baseSHA256:\s*(\w+)\.baseSHA256"),
    }

    def resolve_string(block, field, literal_pattern):
        literal = literal_pattern.search(block)
        if literal:
            return literal.group(1)
        reference = reference_patterns[field].search(block)
        if reference and reference.group(1) in symbols:
            return symbols[reference.group(1)][
                {"baseURL": "url", "baseSHA256": "sha256"}[field]
            ]
        raise ValueError(f"Could not resolve {field} from AIModel.swift")

    def resolve_size(block):
        literal = re.search(r"baseFileSizeBytes:\s*([0-9_]+)", block)
        if literal:
            return parse_size(literal, "base artifact")
        reference = re.search(r"baseFileSizeBytes:\s*(\w+)\.baseFileSizeBytes", block)
        if reference and reference.group(1) in symbols:
            return symbols[reference.group(1)]["size"]
        raise ValueError("Could not resolve baseFileSizeBytes from AIModel.swift")

    for symbol, block in pattern.findall(source):
        model_id = re.search(r'id:\s*"([^"]+)"', block)
        model_type = re.search(r"modelType:\s*\.(\w+)", block)
        if model_id is None or model_type is None:
            raise ValueError("Could not parse a production AIModel identity")
        base_artifact: CatalogArtifact = {
            "model": model_id.group(1),
            "kind": "base",
            "url": resolve_string(
                block,
                "baseURL",
                re.compile(r'baseURL:\s*URL\(string:\s*"([^"]+)"\)'),
            ),
            "size": resolve_size(block),
            "sha256": resolve_string(
                block, "baseSHA256", re.compile(r'baseSHA256:\s*"([^"]*)"')
            ),
        }
        symbols[symbol] = base_artifact
        artifacts: list[CatalogArtifact] = [base_artifact]

        if model_type.group(1) == "vision":
            projector_url = re.search(r'mmprojURL:\s*URL\(string:\s*"([^"]+)"\)', block)
            projector_size = re.search(r"mmprojFileSizeBytes:\s*([0-9_]+)", block)
            projector_hash = re.search(r'mmprojSHA256:\s*"([^"]*)"', block)
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

        for artifact in artifacts:
            identity = (
                artifact["kind"],
                artifact["size"],
                artifact["sha256"],
                artifact["url"],
            )
            if identity not in seen_artifacts:
                seen_artifacts.add(identity)
                models.append(artifact)

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
                f"invalid SHA-256 for {artifact['model']} {artifact['kind']} sha256"
            )

        suffix = "-mmproj.gguf" if artifact["kind"] == "mmproj" else ".gguf"
        destination = f"{artifact['model']}{suffix}"
        if destination in destinations:
            raise ValueError(f"duplicate destination: {destination}")
        destinations.add(destination)


def sanitize_provenance(url: str) -> str:
    parsed = urlparse(url)
    host = parsed.hostname or "unknown-host"
    authority = f"{host}:{parsed.port}" if parsed.port else host
    return f"{parsed.scheme}://{authority}{parsed.path}"


def verify_download(artifact: CatalogArtifact, timeout: int) -> dict[str, object]:
    expected_size = artifact["size"]
    expected_hash = str(artifact["sha256"]).lower()
    actual_size = 0
    digest = hashlib.sha256()
    request_chunk_size = 64 * 1024 * 1024
    final_provenance = str(artifact["url"])

    with tempfile.NamedTemporaryFile(
        prefix="ziroedge-catalog-", suffix=".gguf"
    ) as clean_file:
        while actual_size < expected_size:
            range_end = min(actual_size + request_chunk_size, expected_size) - 1
            request = Request(
                str(artifact["url"]),
                headers={
                    "User-Agent": "ZiroEdge-catalog-release-check/1",
                    "Range": f"bytes={actual_size}-{range_end}",
                },
            )
            received_this_request = 0
            with urlopen(request, timeout=timeout) as response:
                final_provenance = sanitize_provenance(response.geturl())
                if actual_size > 0 and response.status != 206:
                    raise ValueError("server stopped honoring ranged verification")
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    clean_file.write(chunk)
                    digest.update(chunk)
                    actual_size += len(chunk)
                    received_this_request += len(chunk)
            if received_this_request == 0:
                raise ValueError("server returned an empty ranged response")
            if actual_size > expected_size:
                raise ValueError("server returned bytes beyond catalog size")
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
        return {
            "model": artifact["model"],
            "kind": artifact["kind"],
            "canonicalSource": artifact["url"],
            "finalProvenance": final_provenance,
            "size": actual_size,
            "sha256": actual_hash,
            "verifiedAt": datetime.now(timezone.utc).isoformat(),
            "command": "python3 Scripts/verify-model-catalog.py",
        }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--timeout",
        type=int,
        default=900,
        help="per-socket operation timeout in seconds (default: 900)",
    )
    parser.add_argument(
        "--model",
        action="append",
        help="verify only this model ID (repeatable); default is every production artifact",
    )
    parser.add_argument(
        "--evidence",
        type=Path,
        help="write sanitized JSON release evidence to this path",
    )
    parser.add_argument(
        "--metadata-only",
        action="store_true",
        help="validate catalog metadata without downloading artifacts",
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
        evidence = []
        if not args.metadata_only:
            for artifact in selected:
                evidence.append(verify_download(artifact, args.timeout))
        if args.evidence:
            args.evidence.parent.mkdir(parents=True, exist_ok=True)
            args.evidence.write_text(
                json.dumps({"artifacts": evidence}, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
    except Exception as error:  # noqa: BLE001 - release check should report one concise failure
        print(f"catalog verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
