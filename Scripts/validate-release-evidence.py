#!/usr/bin/env python3
"""Fail-closed validation for retained release evidence."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import sys
from pathlib import Path

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
PASS_OBSERVATION_RE = re.compile(
    r"^\[[^]\r\n]+\]\s+(?P<scenario>[a-z0-9-]+)\s+—\s+PASS\s+—\s+(?P<detail>\S.*)$"
)


def load_json(path: Path) -> dict:
    try:
        text = path.read_text(encoding="utf-8")
        data = json.loads(text)
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read evidence JSON: {error}") from error
    if not isinstance(data, dict):
        raise ValueError("root is not a JSON object")
    return data


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_retained_artifact(evidence_path: Path, stored_path: object) -> Path:
    if not isinstance(stored_path, str) or not stored_path:
        raise ValueError("missing retained artifact path")
    path = Path(stored_path)
    return path if path.is_absolute() else evidence_path.parent / path


def validate_archive(
    evidence_path: Path, record: dict, prefix: str = "xcresult"
) -> list[str]:
    errors: list[str] = []
    expected = record.get(f"{prefix}_archive_sha256")
    if not isinstance(expected, str) or not SHA256_RE.fullmatch(expected):
        return [f"missing or invalid {prefix}_archive_sha256"]
    try:
        archive = resolve_retained_artifact(
            evidence_path, record.get(f"{prefix}_archive_path")
        )
    except ValueError as error:
        return [str(error).replace("artifact", prefix + " archive")]
    if not archive.is_file():
        errors.append(f"retained {prefix} archive does not exist: {archive}")
    elif file_sha256(archive) != expected:
        errors.append(f"retained {prefix} archive digest mismatch")
    return errors


def load_catalog_module(script_path: Path):
    spec = importlib.util.spec_from_file_location("verify_model_catalog", script_path)
    if spec is None or spec.loader is None:
        raise ValueError(f"cannot load catalog verifier: {script_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def normalized_artifact(artifact: dict) -> tuple[object, ...]:
    return tuple(
        artifact.get(field) for field in ("model", "kind", "url", "size", "sha256")
    )


def validate_catalog(
    evidence_path: Path, verifier_path: Path, revision: str
) -> list[str]:
    data = load_json(evidence_path)
    verifier = load_catalog_module(verifier_path)
    expected_artifacts = verifier.extract_catalog()
    verifier.validate_metadata(expected_artifacts)
    errors: list[str] = []
    verification_passed = data.get("verification_passed")
    if not isinstance(verification_passed, bool) or not verification_passed:
        errors.append("verification_passed is not true")
    if data.get("catalogVersion") != verifier.extract_catalog_version():
        errors.append("catalogVersion does not match the current production catalog")
    if data.get("buildRevision") != revision:
        errors.append("buildRevision does not match the checked revision")
    command = data.get("command")
    if not isinstance(command, str) or "--metadata-only" in command:
        errors.append("command is missing or is metadata-only")
    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list):
        errors.append("artifacts missing or not a list")
        artifacts = []
    expected = [normalized_artifact(artifact) for artifact in expected_artifacts]
    actual = [
        normalized_artifact(artifact)
        for artifact in artifacts
        if isinstance(artifact, dict)
    ]
    if len(actual) != len(artifacts) or actual != expected:
        errors.append(
            "artifact set does not exactly match current canonical URLs, sizes, and SHA-256 values"
        )
    for index, artifact in enumerate(artifacts):
        if not isinstance(artifact, dict):
            continue
        if artifact.get("outcome") != "success":
            errors.append(f"artifacts[{index}] outcome is not success")
        if artifact.get("actualSize") != artifact.get("size") or artifact.get(
            "expectedSize"
        ) != artifact.get("size"):
            errors.append(f"artifacts[{index}] byte counts do not match")
        if artifact.get("actualSHA256") != artifact.get("sha256") or artifact.get(
            "expectedSHA256"
        ) != artifact.get("sha256"):
            errors.append(f"artifacts[{index}] digests do not match")
        structural = artifact.get("structuralValidation")
        if not isinstance(structural, dict) or structural.get("outcome") != "success":
            errors.append(f"artifacts[{index}] structural validation did not pass")
    return errors


def validate_suite(evidence_path: Path, suite_name: str, revision: str) -> list[str]:
    data = load_json(evidence_path)
    errors: list[str] = []
    if data.get("build_revision") != revision:
        errors.append("build_revision does not match the checked revision")
    source_tree_clean = data.get("source_tree_clean")
    if not isinstance(source_tree_clean, bool) or not source_tree_clean:
        errors.append("source_tree_clean is not true")
    suites = data.get("unit_test_suites")
    if not isinstance(suites, list):
        return errors + ["unit_test_suites missing or not a list"]
    matches = [
        item
        for item in suites
        if isinstance(item, dict) and item.get("name") == suite_name
    ]
    if len(matches) != 1:
        return errors + [
            f"expected exactly one {suite_name} outcome, found {len(matches)}"
        ]
    suite = matches[0]
    if suite.get("outcome") != "pass" or suite.get("exit_code") != 0:
        errors.append(f"{suite_name} did not record outcome=pass and exit_code=0")
    if not suite.get("xcodebuild_command"):
        errors.append(f"{suite_name} missing exact xcodebuild command")
    errors.extend(validate_archive(evidence_path, suite))
    return errors


def validate_observations(path: Path, scenarios: list[str]) -> list[str]:
    found: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = PASS_OBSERVATION_RE.fullmatch(line.strip())
        if match:
            scenario = match.group("scenario")
            found[scenario] = found.get(scenario, 0) + 1
    return [scenario for scenario in scenarios if found.get(scenario) != 1]


def validate_physical(
    evidence_path: Path,
    observations_path: Path,
    layers: list[str],
    revision: str,
    suites: list[str],
    scenarios: list[str],
) -> list[str]:
    data = load_json(evidence_path)
    errors: list[str] = []
    for field in ("device_udid", "catalog_version", "build_revision", "layer"):
        if not data.get(field) or data.get(field) == "unknown":
            errors.append(f"missing {field}")
    if data.get("device_kind") != "physical":
        errors.append("device_kind is not physical")
    if data.get("layer") not in layers:
        errors.append(f"layer is not one of {layers}")
    if data.get("build_revision") != revision:
        errors.append("build_revision does not match the checked revision")
    source_tree_clean = data.get("source_tree_clean")
    if not isinstance(source_tree_clean, bool) or not source_tree_clean:
        errors.append("source_tree_clean is not true")
    if data.get("exit_code") != 0:
        errors.append("UI-test exit_code is not zero")
    if not data.get("command"):
        errors.append("missing UI-test command")
    errors.extend(validate_archive(evidence_path, data))
    recorded_suites = data.get("unit_test_suites")
    if not isinstance(recorded_suites, list):
        errors.append("unit_test_suites missing or not a list")
        recorded_suites = []
    names = [
        name
        for item in recorded_suites
        if isinstance(item, dict)
        for name in [item.get("name")]
        if isinstance(name, str)
    ]
    if sorted(names) != sorted(suites):
        errors.append(
            "recorded unit-test suite set does not match the required layer suites"
        )
    for name in suites:
        matches = [
            item
            for item in recorded_suites
            if isinstance(item, dict) and item.get("name") == name
        ]
        if len(matches) != 1:
            continue
        suite = matches[0]
        if suite.get("outcome") != "pass" or suite.get("exit_code") != 0:
            errors.append(f"{name} did not pass")
        if not suite.get("xcodebuild_command"):
            errors.append(f"{name} missing exact xcodebuild command")
        errors.extend(validate_archive(evidence_path, suite))
    if not observations_path.is_file():
        errors.append("operator observations file is missing")
    else:
        invalid = validate_observations(observations_path, scenarios)
        if invalid:
            errors.append(
                "required scenarios without exactly one explicit PASS record: "
                + ", ".join(invalid)
            )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)
    catalog = subparsers.add_parser("catalog")
    catalog.add_argument("--evidence", type=Path, required=True)
    catalog.add_argument("--verifier", type=Path, required=True)
    catalog.add_argument("--revision", required=True)
    suite = subparsers.add_parser("suite")
    suite.add_argument("--evidence", type=Path, required=True)
    suite.add_argument("--name", required=True)
    suite.add_argument("--revision", required=True)
    physical = subparsers.add_parser("physical")
    physical.add_argument("--evidence", type=Path, required=True)
    physical.add_argument("--observations", type=Path, required=True)
    physical.add_argument("--layers", required=True)
    physical.add_argument("--revision", required=True)
    physical.add_argument("--suites", required=True)
    physical.add_argument("--scenarios", required=True)
    args = parser.parse_args()
    try:
        if args.mode == "catalog":
            errors = validate_catalog(args.evidence, args.verifier, args.revision)
        elif args.mode == "suite":
            errors = validate_suite(args.evidence, args.name, args.revision)
        else:
            errors = validate_physical(
                args.evidence,
                args.observations,
                args.layers.split(","),
                args.revision,
                [item for item in args.suites.split(",") if item],
                [item for item in args.scenarios.split(",") if item],
            )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        errors = [str(error)]
    if errors:
        print("; ".join(errors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
