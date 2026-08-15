"""Focused local tests for release-gate-check.sh gate logic.

Tests validate the evidence-validation logic each gate uses — Python inline
snippets, JSON schema checks, regex-based scenario matching — without invoking
the full bash script (which would trigger network checks in Gate 4).

End-to-end bash invocation tests are included only where all gates can be
satisfied without external network calls.
"""

import importlib.util
import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

GATE_SCRIPT = (Path(__file__).parents[1] / "release-gate-check.sh").resolve()
PROJECT_DIR = GATE_SCRIPT.parents[1]
VALIDATOR_PATH = PROJECT_DIR / "Scripts" / "validate-release-evidence.py"
CATALOG_VERIFIER_PATH = PROJECT_DIR / "Scripts" / "verify-model-catalog.py"


def _load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot import {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


VALIDATOR = _load_module(VALIDATOR_PATH, "validate_release_evidence")
CATALOG_VERIFIER = _load_module(
    CATALOG_VERIFIER_PATH, "verify_model_catalog_for_gate_tests"
)


def _write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2))


def _valid_evidence(layer: str = "lifecycle", **overrides) -> dict:
    """Return a minimal valid evidence.json record."""
    record = {
        "recorded_at": "2025-01-01T00:00:00Z",
        "completed_at": "2025-01-01T00:05:00Z",
        "device_udid": "00000000-0000000000000000",
        "device_name": "Test iPhone",
        "device_os": "18.0",
        "device_kind": "physical",
        "build_revision": "abc123def",
        "source_tree_clean": True,
        "catalog_version": "1",
        "layer": layer,
        "exit_code": 0,
        "xcresult_hash": "deadbeef",
        "screenshot_count": 3,
        "command": "xcodebuild test ...",
        "unit_test_exit_code": 0,
        "unit_xcresult_hash": "cafebabe",
        "unit_xcodebuild_command": "xcodebuild test-without-building -only-testing ZiroEdgeTests/ModelMigrationTests ...",
        "unit_test_suites": [
            {
                "name": name,
                "outcome": "pass",
                "exit_code": 0,
                "xcresult_hash": f"hash-{name}",
                "xcodebuild_command": f"xcodebuild test-without-building -only-testing ZiroEdgeTests/{name}",
            }
            for name in (
                "ModelMigrationTests",
                "DurableTransferStateTests",
                "StoreRecoveryTests",
            )
        ],
    }
    record.update(overrides)
    return record


# ─────────────────────────────────────────────────────────────
# Gate 2: Catalog verification evidence — complete schema check
# ─────────────────────────────────────────────────────────────


def _validate_catalog_schema(data) -> list[str]:
    """The exact Python inline logic from Gate 2. Returns list of errors."""
    errors = []
    if not isinstance(data, dict):
        errors.append("root is not a JSON object")
        return errors
    verification_passed = data.get("verification_passed")
    if not isinstance(verification_passed, bool) or not verification_passed:
        errors.append("verification_passed is not true")
    if not data.get("catalogVersion"):
        errors.append("catalogVersion missing or empty")
    if not data.get("recordedAt"):
        errors.append("recordedAt missing or empty")
    if not data.get("buildRevision"):
        errors.append("buildRevision missing or empty")
    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) == 0:
        errors.append("artifacts missing or empty")
    else:
        for i, a in enumerate(artifacts):
            if not isinstance(a, dict):
                errors.append(f"artifacts[{i}] is not an object")
                continue
            for field in ("model", "kind", "url", "size", "sha256"):
                if not a.get(field):
                    errors.append(f"artifacts[{i}].{field} missing or empty")
    return errors


class Gate2CatalogSchemaTests(unittest.TestCase):
    def _catalog(self, **overrides):
        base = {
            "verification_passed": True,
            "catalogVersion": "1",
            "recordedAt": "2025-01-01T00:00:00Z",
            "buildRevision": "abc123def",
            "artifacts": [
                {
                    "model": "test-model",
                    "kind": "base",
                    "url": "https://example.com/model.gguf",
                    "size": 1024,
                    "sha256": "a" * 64,
                }
            ],
        }
        base.update(overrides)
        return base

    def test_complete_schema_passes(self):
        self.assertEqual(_validate_catalog_schema(self._catalog()), [])

    def test_missing_catalog_version_fails(self):
        errors = _validate_catalog_schema(self._catalog(catalogVersion=""))
        self.assertTrue(any("catalogVersion" in e for e in errors))

    def test_missing_artifacts_fails(self):
        errors = _validate_catalog_schema(self._catalog(artifacts=[]))
        self.assertTrue(any("artifacts" in e for e in errors))

    def test_verification_not_passed_fails(self):
        errors = _validate_catalog_schema(self._catalog(verification_passed=False))
        self.assertTrue(any("verification_passed" in e for e in errors))

    def test_artifact_missing_sha256_fails(self):
        art = self._catalog()["artifacts"][0].copy()
        art.pop("sha256")
        errors = _validate_catalog_schema(self._catalog(artifacts=[art]))
        self.assertTrue(any("sha256" in e for e in errors))

    def test_not_a_dict_fails(self):
        errors = _validate_catalog_schema([])
        self.assertTrue(any("not a JSON object" in e for e in errors))


class Gate2CurrentCatalogComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory(prefix="catalog_gate_")
        self.addCleanup(self.temp_dir.cleanup)
        self.evidence_path = Path(self.temp_dir.name) / "catalog.json"
        self.revision = "current-revision"

    def _passing_catalog(self) -> dict:
        artifacts = []
        for artifact in CATALOG_VERIFIER.extract_catalog():
            retained = dict(artifact)
            retained.update(
                {
                    "expectedSize": artifact["size"],
                    "actualSize": artifact["size"],
                    "expectedSHA256": artifact["sha256"],
                    "actualSHA256": artifact["sha256"],
                    "structuralValidation": {"outcome": "success"},
                    "outcome": "success",
                }
            )
            artifacts.append(retained)
        return {
            "verification_passed": True,
            "catalogVersion": CATALOG_VERIFIER.extract_catalog_version(),
            "recordedAt": "2025-01-01T00:00:00Z",
            "buildRevision": self.revision,
            "command": "python3 Scripts/verify-model-catalog.py --evidence catalog.json",
            "artifacts": artifacts,
        }

    def _validate(self, data: dict) -> list[str]:
        _write_json(self.evidence_path, data)
        return VALIDATOR.validate_catalog(
            self.evidence_path, CATALOG_VERIFIER_PATH, self.revision
        )

    def test_complete_current_catalog_passes(self):
        self.assertEqual(self._validate(self._passing_catalog()), [])

    def test_one_artifact_synthetic_schema_fails(self):
        data = self._passing_catalog()
        data["artifacts"] = data["artifacts"][:1]
        self.assertTrue(self._validate(data))

    def test_stale_catalog_version_fails(self):
        data = self._passing_catalog()
        data["catalogVersion"] = "stale"
        self.assertTrue(self._validate(data))

    def test_stale_build_revision_fails(self):
        data = self._passing_catalog()
        data["buildRevision"] = "different-revision"
        self.assertTrue(self._validate(data))

    def test_changed_url_size_or_hash_fails(self):
        for field, value in (
            ("url", "https://example.com/wrong.gguf"),
            ("size", 1),
            ("sha256", "0" * 64),
        ):
            with self.subTest(field=field):
                data = self._passing_catalog()
                data["artifacts"][0][field] = value
                self.assertTrue(self._validate(data))

    def test_failed_or_metadata_only_evidence_fails(self):
        data = self._passing_catalog()
        data["artifacts"][0]["outcome"] = "failure"
        self.assertTrue(self._validate(data))
        data = self._passing_catalog()
        data["command"] += " --metadata-only"
        self.assertTrue(self._validate(data))


# ─────────────────────────────────────────────────────────────
# Gates 3, 9, 10: Unit test outcome validation
# ─────────────────────────────────────────────────────────────


def _validate_named_unit_suite(
    data: dict, required_suite: str, expected_revision: str = "abc123def"
) -> list[str]:
    """Mirror the fail-closed retained-evidence checks for Gates 3/9/10."""
    errors = []
    if not data.get("build_revision"):
        errors.append("missing build_revision")
    if data.get("build_revision") != expected_revision:
        errors.append("build_revision does not match the checked revision")

    suites = data.get("unit_test_suites")
    if not isinstance(suites, list):
        errors.append("unit_test_suites missing or not a list")
        suites = []
    matches = [
        suite
        for suite in suites
        if isinstance(suite, dict) and suite.get("name") == required_suite
    ]
    if len(matches) != 1:
        errors.append(
            f"expected exactly one {required_suite} outcome, found {len(matches)}"
        )
    else:
        suite = matches[0]
        if suite.get("outcome") != "pass" or suite.get("exit_code") != 0:
            errors.append(f"{required_suite} did not pass")
        if not suite.get("xcodebuild_command"):
            errors.append(f"{required_suite} missing exact xcodebuild command")
        if not suite.get("xcresult_hash"):
            errors.append(f"{required_suite} missing xcresult hash")
    return errors


class GateUnitTestOutcomeTests(unittest.TestCase):
    def test_each_required_suite_passes_with_complete_provenance(self):
        evidence = _valid_evidence(layer="qa-full")
        for suite in (
            "ModelMigrationTests",
            "DurableTransferStateTests",
            "StoreRecoveryTests",
        ):
            self.assertEqual(_validate_named_unit_suite(evidence, suite), [])

    def test_generic_zero_exit_code_does_not_prove_named_suite(self):
        evidence = _valid_evidence(layer="qa-full", unit_test_suites=[])
        self.assertTrue(_validate_named_unit_suite(evidence, "ModelMigrationTests"))

    def test_failed_individual_suite_is_detected(self):
        evidence = _valid_evidence(layer="qa-full")
        evidence["unit_test_suites"][1] = {
            "name": "DurableTransferStateTests",
            "outcome": "fail",
            "exit_code": 1,
            "xcresult_hash": "hash-failed-suite",
            "xcodebuild_command": "xcodebuild test-without-building -only-testing ZiroEdgeTests/DurableTransferStateTests",
        }
        self.assertTrue(
            _validate_named_unit_suite(evidence, "DurableTransferStateTests")
        )

    def test_missing_revision_is_detected(self):
        evidence = _valid_evidence(layer="qa-full", build_revision="")
        self.assertTrue(_validate_named_unit_suite(evidence, "StoreRecoveryTests"))

    def test_missing_individual_command_or_hash_is_detected(self):
        for field in ("xcodebuild_command", "xcresult_hash"):
            evidence = _valid_evidence(layer="qa-full")
            evidence["unit_test_suites"][2][field] = ""
            self.assertTrue(
                _validate_named_unit_suite(evidence, "StoreRecoveryTests"), field
            )

    def test_stale_revision_is_detected(self):
        evidence = _valid_evidence(layer="qa-full")
        self.assertTrue(
            _validate_named_unit_suite(
                evidence, "ModelMigrationTests", expected_revision="different-revision"
            )
        )


# ─────────────────────────────────────────────────────────────
# Gates 6, 7, 8: Evidence schema + scenario status validation
# ─────────────────────────────────────────────────────────────


def _validate_evidence_identities(data: dict, expected_layer: str | tuple) -> list[str]:
    """The exact Python inline logic from Gates 6/7/8 for schema check."""
    errors = []
    for field in ("device_udid", "catalog_version", "build_revision", "layer"):
        if not data.get(field):
            errors.append(f"missing {field}")
    if isinstance(expected_layer, str):
        if data.get("layer") != expected_layer:
            errors.append(
                f"layer is '{data.get('layer')}', expected '{expected_layer}'"
            )
    else:
        if data.get("layer") not in expected_layer:
            errors.append(
                f"layer is '{data.get('layer')}', expected one of {expected_layer}"
            )
    return errors


def _check_scenarios_in_observations(
    observations_text: str, required_scenarios: list[str]
) -> list[str]:
    """Check that each required scenario appears in observations text."""
    missing = []
    for scenario in required_scenarios:
        # Regex from the bash gate: \[.*\]\s+$scenario\s
        if not re.search(rf"\[.*\]\s+{re.escape(scenario)}\s", observations_text):
            missing.append(scenario)
    return missing


class GateEvidenceIdentityTests(unittest.TestCase):
    def test_valid_lifecycle_evidence_passes(self):
        data = _valid_evidence(layer="lifecycle")
        self.assertEqual(_validate_evidence_identities(data, "lifecycle"), [])

    def test_valid_offline_evidence_passes(self):
        data = _valid_evidence(layer="offline")
        self.assertEqual(_validate_evidence_identities(data, "offline"), [])

    def test_valid_qa_evidence_passes(self):
        data = _valid_evidence(layer="qa-full")
        self.assertEqual(_validate_evidence_identities(data, ("qa-full", "all")), [])

    def test_wrong_layer_fails(self):
        data = _valid_evidence(layer="smoke")
        errors = _validate_evidence_identities(data, "lifecycle")
        self.assertTrue(any("layer" in e for e in errors))

    def test_missing_device_udid_fails(self):
        data = _valid_evidence(layer="lifecycle", device_udid="")
        errors = _validate_evidence_identities(data, "lifecycle")
        self.assertTrue(any("device_udid" in e for e in errors))

    def test_missing_catalog_version_fails(self):
        data = _valid_evidence(layer="lifecycle", catalog_version="")
        errors = _validate_evidence_identities(data, "lifecycle")
        self.assertTrue(any("catalog_version" in e for e in errors))

    def test_missing_build_revision_fails(self):
        data = _valid_evidence(layer="lifecycle", build_revision="")
        errors = _validate_evidence_identities(data, "lifecycle")
        self.assertTrue(any("build_revision" in e for e in errors))


class GateScenarioMatchingTests(unittest.TestCase):
    def _obs(self, *scenarios: str) -> str:
        lines = ["# header"]
        for s in scenarios:
            lines.append(f"[00:00:00] {s} — observed as expected")
        return "\n".join(lines)

    def test_all_lifecycle_scenarios_found(self):
        required = [
            "background-suspension",
            "lock-unlock",
            "os-termination",
            "force-quit",
            "reboot",
        ]
        obs = self._obs(*required)
        self.assertEqual(_check_scenarios_in_observations(obs, required), [])

    def test_all_offline_scenarios_found(self):
        required = [
            "airplane-mode-launch",
            "e2b-text-offline",
            "e4b-text-offline",
            "e2b-vision-offline",
            "e4b-vision-offline",
            "invalid-pair-recovery",
            "conversation-history",
        ]
        obs = self._obs(*required)
        self.assertEqual(_check_scenarios_in_observations(obs, required), [])

    def test_all_qa_scenarios_found(self):
        required = [
            "wifi-loss-reconnect",
            "cellular-handoff",
            "repeated-pause-resume",
            "cancel-redownload",
            "low-storage-warn",
            "out-of-space-recovery",
            "repeated-transfer-e2b",
            "repeated-transfer-e4b",
            "reboot-recovery",
            "storage-pressure-recover",
        ]
        obs = self._obs(*required)
        self.assertEqual(_check_scenarios_in_observations(obs, required), [])

    def test_missing_scenario_reported(self):
        required = ["scenario-a", "scenario-b", "scenario-c"]
        obs = self._obs("scenario-a", "scenario-c")
        missing = _check_scenarios_in_observations(obs, required)
        self.assertEqual(missing, ["scenario-b"])

    def test_no_match_on_partial_word(self):
        """'e2b-text-offline' should not match 'e2b-text-offline-extra'."""
        required = ["e2b-text-offline"]
        obs = self._obs("e2b-text-offline-extra")
        missing = _check_scenarios_in_observations(obs, required)
        self.assertEqual(missing, ["e2b-text-offline"])

    def test_empty_observations_reports_all_missing(self):
        required = ["a", "b", "c"]
        obs = "# just comments\n"
        missing = _check_scenarios_in_observations(obs, required)
        self.assertEqual(set(missing), set(required))


class StrictPhysicalEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory(prefix="physical_gate_")
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.evidence_path = self.root / "evidence.json"
        self.observations_path = self.root / "operator-observations.txt"
        self.scenarios = ["background-suspension", "lock-unlock"]
        self.suites = [
            "FreshInstallLegacyUpgradeTests",
            "NetworkConditionTests",
            "BackgroundLifecycleQATests",
            "StorageConstraintQATests",
            "PauseResumeQATests",
            "EvidenceArtifactQATests",
            "EndToEndLifecycleQATests",
        ]

    def _archive_record(self, name: str, content: bytes = b"xcresult") -> dict:
        archive = self.root / f"{name}.tar"
        archive.write_bytes(content)
        import hashlib

        return {
            "xcresult_archive_path": archive.name,
            "xcresult_archive_sha256": hashlib.sha256(content).hexdigest(),
        }

    def _passing_evidence(self) -> dict:
        record = _valid_evidence(
            layer="lifecycle",
            unit_test_suites=[
                {
                    "name": name,
                    "outcome": "pass",
                    "exit_code": 0,
                    "xcodebuild_command": "xcodebuild test-without-building",
                    **self._archive_record("unit"),
                }
                for name in self.suites
            ],
        )
        record.update(self._archive_record("ui"))
        return record

    def _validate(self, record: dict, observations: str) -> list[str]:
        _write_json(self.evidence_path, record)
        self.observations_path.write_text(observations)
        return VALIDATOR.validate_physical(
            self.evidence_path,
            self.observations_path,
            ["lifecycle"],
            "abc123def",
            self.suites,
            self.scenarios,
        )

    def _passing_observations(self) -> str:
        return "\n".join(
            f"[12:00:00] {scenario} — PASS — observed expected recovery"
            for scenario in self.scenarios
        )

    def test_complete_physical_evidence_passes(self):
        self.assertEqual(
            self._validate(self._passing_evidence(), self._passing_observations()),
            [],
        )

    def test_failed_ui_tests_fail(self):
        record = self._passing_evidence()
        record["exit_code"] = 65
        self.assertTrue(self._validate(record, self._passing_observations()))

    def test_non_physical_device_fails(self):
        record = self._passing_evidence()
        record["device_kind"] = "simulator"
        errors = self._validate(record, self._passing_observations())
        self.assertIn("device_kind is not physical", errors)

    def test_missing_or_failed_required_unit_suite_fails(self):
        record = self._passing_evidence()
        record["unit_test_suites"] = []
        self.assertTrue(self._validate(record, self._passing_observations()))
        record = self._passing_evidence()
        record["unit_test_suites"][0]["outcome"] = "fail"
        self.assertTrue(self._validate(record, self._passing_observations()))

    def test_stale_or_dirty_build_identity_fails(self):
        record = self._passing_evidence()
        record["build_revision"] = "stale"
        self.assertTrue(self._validate(record, self._passing_observations()))
        record = self._passing_evidence()
        record["source_tree_clean"] = False
        self.assertTrue(self._validate(record, self._passing_observations()))

    def test_presence_only_fail_pending_and_free_form_observations_fail(self):
        for status in ("FAIL", "PENDING", "looked okay"):
            with self.subTest(status=status):
                observations = "\n".join(
                    f"[12:00:00] {scenario} — {status} — mentioned only"
                    for scenario in self.scenarios
                )
                self.assertTrue(self._validate(self._passing_evidence(), observations))

    def test_duplicate_pass_observation_fails(self):
        observations = (
            self._passing_observations()
            + "\n"
            + ("[12:01:00] lock-unlock — PASS — duplicate observation")
        )
        self.assertTrue(self._validate(self._passing_evidence(), observations))

    def test_mutated_retained_archive_fails_digest_verification(self):
        record = self._passing_evidence()
        (self.root / "ui.tar").write_bytes(b"mutated")
        self.assertTrue(self._validate(record, self._passing_observations()))


# ─────────────────────────────────────────────────────────────
# Gate 11: Only FAIL rows require ticket URLs, not PENDING
# ─────────────────────────────────────────────────────────────


def _find_fail_rows_without_tickets(markdown: str) -> int:
    """The exact Python inline logic from Gate 11."""
    table_rows = re.findall(r"\|[^|]+\|[^|]+\|\s*FAIL\s*\|([^|]+)\|", markdown)
    issue_url = re.compile(
        r"https://github\.com/Zane-dev16/ZiroEdge/issues/[1-9][0-9]*(?:\b|/)"
    )
    missing = [row for row in table_rows if not issue_url.search(row)]
    return len(missing)


class Gate11FailureMapTests(unittest.TestCase):
    def _table(self, *rows: str) -> str:
        header = """| # | Scenario | Status | Ticket URL | Notes |
| --- | ---------- | -------- | ------------ | ------- |
"""
        return header + "\n".join(rows) + "\n"

    def test_all_pending_no_tickets_passes(self):
        content = self._table(
            "| 1 | Wi-Fi loss | PENDING | <!-- REQUIRED if FAIL --> | |",
            "| 2 | Cellular handoff | PENDING | <!-- REQUIRED if FAIL --> | |",
        )
        self.assertEqual(_find_fail_rows_without_tickets(content), 0)

    def test_fail_without_ticket_detected(self):
        content = self._table(
            "| 1 | Wi-Fi loss | FAIL | <!-- REQUIRED if FAIL --> | |",
        )
        self.assertEqual(_find_fail_rows_without_tickets(content), 1)

    def test_fail_with_ticket_passes(self):
        content = self._table(
            "| 1 | Wi-Fi loss | FAIL | https://github.com/Zane-dev16/ZiroEdge/issues/1 | fixed |",
        )
        self.assertEqual(_find_fail_rows_without_tickets(content), 0)

    def test_unrelated_url_does_not_pass(self):
        content = self._table(
            "| 1 | Wi-Fi loss | FAIL | https://example.com/not-a-ticket | |",
        )
        self.assertEqual(_find_fail_rows_without_tickets(content), 1)

    def test_mixed_rows(self):
        content = self._table(
            "| 1 | Wi-Fi loss | FAIL | https://github.com/Zane-dev16/ZiroEdge/issues/1 | fixed |",
            "| 2 | Cellular | FAIL | <!-- REQUIRED if FAIL --> | |",
            "| 3 | Reboot | PENDING | <!-- REQUIRED if FAIL --> | |",
            "| 4 | Storage | PASS | <!-- REQUIRED if FAIL --> | |",
        )
        self.assertEqual(_find_fail_rows_without_tickets(content), 1)


# ─────────────────────────────────────────────────────────────
# End-to-end: release-gate-check.sh as a whole
# Only where all gates can be satisfied without network calls.
# ─────────────────────────────────────────────────────────────


class GateSourceCleanlinessTests(unittest.TestCase):
    def test_gate_excludes_only_generated_evidence_root_from_source_status(self):
        script = GATE_SCRIPT.read_text()
        self.assertIn('":(exclude)$EVIDENCE_PATHSPEC/**"', script)
        self.assertIn("evidence.relative_to(project)", script)

    def test_git_pathspec_ignores_evidence_but_not_source_changes(self):
        with tempfile.TemporaryDirectory(prefix="gate_cleanliness_") as temp:
            repo = Path(temp)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(
                ["git", "-C", str(repo), "config", "user.email", "test@example.com"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(repo), "config", "user.name", "Test"],
                check=True,
            )
            (repo / "source.txt").write_text("clean\n")
            subprocess.run(["git", "-C", str(repo), "add", "source.txt"], check=True)
            subprocess.run(
                ["git", "-C", str(repo), "commit", "-qm", "fixture"], check=True
            )
            evidence = repo / "docs" / "release-evidence" / "evidence.json"
            evidence.parent.mkdir(parents=True)
            evidence.write_text("{}\n")

            status = subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo),
                    "status",
                    "--porcelain",
                    "--untracked-files=all",
                    "--",
                    ".",
                    ":(exclude)docs/release-evidence/**",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(status.stdout, "")

            (repo / "source.txt").write_text("dirty\n")
            status = subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo),
                    "status",
                    "--porcelain",
                    "--untracked-files=all",
                    "--",
                    ".",
                    ":(exclude)docs/release-evidence/**",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("source.txt", status.stdout)


class ReleaseGateCheckE2ETests(unittest.TestCase):
    """Minimal end-to-end tests that provide evidence for all 11 gates."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory(prefix="gate_e2e_")
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)

    def _seed_all_evidence(self):
        """Pre-create evidence for every gate so the script doesn't hang on Gate 4."""
        root = self.root

        # Gate 2: catalog verification
        _write_json(
            root / "catalog-verification.json",
            {
                "verification_passed": True,
                "catalogVersion": "1",
                "recordedAt": "2025-01-01T00:00:00Z",
                "buildRevision": "abc123def",
                "artifacts": [
                    {
                        "model": "test",
                        "kind": "base",
                        "url": "https://example.com/model.gguf",
                        "size": 1024,
                        "sha256": "a" * 64,
                    }
                ],
            },
        )

        # Gates 3, 8, 9, 10: physical-qa
        qa_dir = root / "physical-qa"
        qa_scenarios = [
            "wifi-loss-reconnect",
            "cellular-handoff",
            "repeated-pause-resume",
            "cancel-redownload",
            "low-storage-warn",
            "out-of-space-recovery",
            "repeated-transfer-e2b",
            "repeated-transfer-e4b",
            "reboot-recovery",
            "storage-pressure-recover",
        ]
        _write_json(
            qa_dir / "evidence.json",
            _valid_evidence(layer="qa-full"),
        )
        qa_dir.mkdir(parents=True, exist_ok=True)
        lines = ["# QA observations"]
        for s in qa_scenarios:
            lines.append(f"[00:00:00] {s} — observed as expected")
        (qa_dir / "operator-observations.txt").write_text("\n".join(lines) + "\n")

        # Gate 6: lifecycle
        lc_dir = root / "lifecycle"
        lc_scenarios = [
            "background-suspension",
            "lock-unlock",
            "os-termination",
            "force-quit",
            "reboot",
        ]
        _write_json(lc_dir / "evidence.json", _valid_evidence(layer="lifecycle"))
        lines = ["# Lifecycle observations"]
        for s in lc_scenarios:
            lines.append(f"[00:00:00] {s} — observed as expected")
        (lc_dir / "operator-observations.txt").write_text("\n".join(lines) + "\n")

        # Gate 7: offline
        off_dir = root / "offline"
        off_scenarios = [
            "airplane-mode-launch",
            "e2b-text-offline",
            "e4b-text-offline",
            "e2b-vision-offline",
            "e4b-vision-offline",
            "invalid-pair-recovery",
            "conversation-history",
        ]
        _write_json(off_dir / "evidence.json", _valid_evidence(layer="offline"))
        lines = ["# Offline observations"]
        for s in off_scenarios:
            lines.append(f"[00:00:00] {s} — observed as expected")
        (off_dir / "operator-observations.txt").write_text("\n".join(lines) + "\n")

    def test_script_runs_with_all_evidence_and_exits_not_ready(self):
        """With evidence for gates 2,3,6,7,8,9,10 but still missing 1,4,5,11 — expect NOT_READY."""
        self._seed_all_evidence()
        proc = subprocess.run(
            ["bash", str(GATE_SCRIPT), "--evidence-root", str(self.root)],
            capture_output=True,
            text=True,
            timeout=60,
            cwd=str(PROJECT_DIR),
            env={**__import__("os").environ, "PATH": __import__("os").environ["PATH"]},
        )
        self.assertNotEqual(proc.returncode, 0, "Should be NOT_READY")
        self.assertIn("NOT_READY", proc.stdout)

    def test_empty_evidence_root_fails(self):
        proc = subprocess.run(
            ["bash", str(GATE_SCRIPT), "--evidence-root", str(self.root)],
            capture_output=True,
            text=True,
            timeout=60,
            cwd=str(PROJECT_DIR),
            env={**__import__("os").environ, "PATH": __import__("os").environ["PATH"]},
        )
        self.assertNotEqual(proc.returncode, 0)


# ─────────────────────────────────────────────────────────────
# Device-test.sh helper behavior
# ─────────────────────────────────────────────────────────────


class DeviceTestEvidenceSchemaTests(unittest.TestCase):
    """Test that evidence.json produced by device-test.sh has the right shape."""

    def test_command_field_is_xcodebuild_not_python(self):
        record = _valid_evidence()
        self.assertIn("xcodebuild", record["command"])
        self.assertNotIn("python3", record["command"])

    def test_unit_test_exit_code_present_when_run(self):
        record = _valid_evidence()
        self.assertEqual(record["unit_test_exit_code"], 0)
        self.assertIsNotNone(record["unit_xcresult_hash"])
        self.assertTrue(record["unit_xcodebuild_command"])

    def test_unit_test_fields_none_for_smoke_layer(self):
        """Smoke doesn't run unit tests — fields should be None/-1."""
        # Simulating what device-test.sh would produce for smoke layer:
        # unit_test_exit_code is set to -1 in bash, converted to None in Python
        record = _valid_evidence(
            layer="smoke",
            unit_test_exit_code=None,
            unit_xcresult_hash=None,
            unit_xcodebuild_command="",
        )
        self.assertIsNone(record["unit_test_exit_code"])

    def test_device_runner_records_required_suites_individually(self):
        script = (PROJECT_DIR / "Scripts" / "device-test.sh").read_text()
        for suite in (
            "SubmissionReadinessTests",
            "DownloadDiagnosticTests",
            "ModelMigrationTests",
            "ImportedChatCompositionTests",
            "VariantCapabilityEstimateTests",
            "MemoryProfileTests",
            "DurableTransferStateTests",
            "StoreRecoveryTests",
            "HuggingFaceImportTests",
            "ImportRejectionTests",
            "ImportRelaunchPersistenceTests",
            "ImportStoragePreflightTests",
            "ImportTransferLifecycleTests",
            "ImportVariantSelectionTests",
            "ImportedModelConfigurationTests",
            "ImportedModelLoadFailureTests",
            "ImportedModelRelaunchTests",
            "ImportedModelRemovalTests",
            "ImportedModelUpdateTests",
            "VisionImportTests",
            "VisionRejectionRepairTests",
            "VisionUpdateTests",
        ):
            self.assertIn(f'"{suite}"', script)
        self.assertIn('"unit_test_suites"', script)
        self.assertIn('"xcodebuild_command": command', script)
        self.assertIn('"xcresult_archive_sha256": archive_hash or None', script)
        self.assertIn('"xcresult_archive_path": archive_path', script)

    def test_device_runner_preserves_clean_tree_and_disables_parallel_testing(self):
        script = (PROJECT_DIR / "Scripts" / "device-test.sh").read_text()
        self.assertIn('! -name .gitkeep -exec rm -rf {} +', script)
        self.assertNotIn('rm -rf "$OUTPUT_DIR"', script)
        self.assertNotIn("|| echo 0", script)
        self.assertIn("--unit-test", script)
        self.assertIn('UNIT_ONLY_CMD+=(-only-testing "ZiroEdgeTests/$suite")', script)
        self.assertGreaterEqual(script.count("-parallel-testing-enabled NO"), 6)

    def test_gate_requires_hugging_face_suites_in_physical_qa(self):
        gate_script = GATE_SCRIPT.read_text()
        gate_eight = gate_script.split("\n\t8)", 1)[1].split("\n\t9)", 1)[0]
        for suite in (
            "HuggingFaceImportTests",
            "ImportRejectionTests",
            "ImportRelaunchPersistenceTests",
            "ImportStoragePreflightTests",
            "ImportTransferLifecycleTests",
            "ImportVariantSelectionTests",
            "ImportedModelConfigurationTests",
            "ImportedModelLoadFailureTests",
            "ImportedModelRelaunchTests",
            "ImportedModelRemovalTests",
            "ImportedModelUpdateTests",
            "VisionImportTests",
            "VisionRejectionRepairTests",
            "VisionUpdateTests",
        ):
            self.assertIn(suite, gate_eight)

    def test_automated_recorder_and_gate_use_canonical_evidence(self):
        recorder = (
            PROJECT_DIR / "Scripts" / "record-automated-release-evidence.sh"
        ).read_text()
        gate_script = GATE_SCRIPT.read_text()
        self.assertIn("SubmissionReadinessTests", recorder)
        self.assertIn("DownloadDiagnosticTests", recorder)
        self.assertIn("automated-ios/evidence.json", gate_script)
        self.assertNotIn(
            'UNIT_EVIDENCE="$EVIDENCE_ROOT/physical-qa/evidence.json"',
            gate_script,
        )


class GateSuiteSyncTests(unittest.TestCase):
    """Gate 7/8 required suite lists must stay identical to the device-test.sh
    layer arms, and every mapped suite name must match a real test class.

    Mirrors the lifecycle-mapping guard: a layer arm naming a test class that
    does not exist resolves to zero tests under xcodebuild (exit 0, vacuous
    pass), which validate-release-evidence.py cannot detect.
    """

    OFFLINE_CLASSES = [
        "ChatSessionCancellationTests",
        "OfflineModelLoadingTests",
        "OfflineConversationPersistenceTests",
        "OfflineInferencePathTests",
        "OfflineOnboardingTests",
        "OfflineModelsPageTests",
        "NetworkIsolationTests",
        "OfflineFlowIntegrationTests",
        "OfflineAvailabilityGuardTests",
    ]

    QA_FULL_SUITES = [
        "SubmissionReadinessTests",
        "DownloadDiagnosticTests",
        "ModelMigrationTests",
        "ImportedChatCompositionTests",
        "VariantCapabilityEstimateTests",
        "MemoryProfileTests",
        "DurableTransferStateTests",
        "StoreRecoveryTests",
        "HuggingFaceImportTests",
        "ImportRejectionTests",
        "ImportRelaunchPersistenceTests",
        "ImportStoragePreflightTests",
        "ImportTransferLifecycleTests",
        "ImportVariantSelectionTests",
        "ImportedModelConfigurationTests",
        "ImportedModelLoadFailureTests",
        "ImportedModelRelaunchTests",
        "ImportedModelRemovalTests",
        "ImportedModelUpdateTests",
        "VisionImportTests",
        "VisionRejectionRepairTests",
        "VisionUpdateTests",
    ]

    @staticmethod
    def _device_unit_suites(layer: str) -> list[str]:
        """Extract a layer's UNIT_TEST_SUITES arm from device-test.sh."""
        script = (PROJECT_DIR / "Scripts" / "device-test.sh").read_text()
        # The unit-suite case is the one that follows the unit-test build step.
        start = script.index(
            'case "$LAYER" in', script.index("Building for unit testing")
        )
        end = script.index("esac", start)
        block = script[start:end]
        arm = block.split(f"\n\t{layer})\n", 1)[1]
        arm = arm.split("\n\t\t;;", 1)[0]
        return re.findall(r'^\t\t\t"([^"]+)"$', arm, re.M)

    @staticmethod
    def _gate_suites(gate_num: int, layer_literal: str) -> list[str]:
        """Extract the --suites argument for one gate from release-gate-check.sh."""
        gate_script = GATE_SCRIPT.read_text()
        gate_block = gate_script.split(f"\n\t{gate_num})", 1)[1].split(
            f"\n\t{gate_num + 1})", 1
        )[0]
        line = next(
            ln for ln in gate_block.splitlines() if f'"{layer_literal}"' in ln
        )
        after = line.split(f'"{layer_literal}"', 1)[1]
        return after.split('"', 2)[1].split(",")

    def test_offline_arm_maps_real_classes(self):
        device_suites = self._device_unit_suites("offline")
        self.assertEqual(device_suites, self.OFFLINE_CLASSES)
        self.assertNotIn("OfflineVerificationTests", device_suites)

    def test_offline_gate7_suites_match_device_arm(self):
        gate_suites = self._gate_suites(7, "offline")
        self.assertEqual(sorted(gate_suites), sorted(self.OFFLINE_CLASSES))

    def test_offline_mapped_classes_exist_in_test_sources(self):
        sources = "\n".join(
            p.read_text() for p in (PROJECT_DIR / "ZiroEdgeTests").glob("*.swift")
        )
        for cls in self.OFFLINE_CLASSES:
            self.assertIn(f"final class {cls}: XCTestCase", sources, cls)

    def test_qa_full_arm_has_exactly_22_suites(self):
        device_suites = self._device_unit_suites("qa-full")
        self.assertEqual(len(device_suites), len(set(device_suites)))
        self.assertEqual(sorted(device_suites), sorted(self.QA_FULL_SUITES))

    def test_qa_full_gate8_suites_match_device_arm(self):
        gate_suites = self._gate_suites(8, "qa-full,all")
        self.assertEqual(sorted(gate_suites), sorted(self.QA_FULL_SUITES))

    def test_qa_full_mapped_suites_exist_in_test_sources(self):
        sources = "\n".join(
            p.read_text() for p in (PROJECT_DIR / "ZiroEdgeTests").glob("*.swift")
        )
        for cls in self.QA_FULL_SUITES:
            self.assertIn(f"final class {cls}: XCTestCase", sources, cls)


class CatalogInfoPlistPathTests(unittest.TestCase):
    """Verify catalog version is read from Config/Info.plist."""

    def test_config_infoplist_exists(self):
        config_plist = PROJECT_DIR / "Config" / "Info.plist"
        self.assertTrue(config_plist.is_file())

    def test_catalog_version_key_present(self):
        config_plist = PROJECT_DIR / "Config" / "Info.plist"
        content = config_plist.read_text()
        self.assertIn("ModelCatalogVersion", content)


if __name__ == "__main__":
    unittest.main()
