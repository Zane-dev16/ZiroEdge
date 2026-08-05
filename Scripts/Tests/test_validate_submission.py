"""Tests for validate-submission.py."""

import importlib.util
import io
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).parents[1] / "validate-submission.py"
spec = importlib.util.spec_from_file_location("submission_validator", SCRIPT)
if spec is None or spec.loader is None:
    raise RuntimeError(f"Could not load submission validator from {SCRIPT}")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class ValidateSubmissionTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]

    def test_validate_metadata_passes(self):
        path = self.root / "AppStore" / "listing-metadata.json"
        if not path.is_file():
            self.skipTest("listing-metadata.json not found")
        errors = validator.validate_metadata(path)
        self.assertEqual(errors, [], f"Metadata validation failed: {errors}")

    def test_validate_review_notes_passes(self):
        path = self.root / "AppStore" / "review-notes.md"
        if not path.is_file():
            self.skipTest("review-notes.md not found")
        errors = validator.validate_review_notes(path)
        self.assertEqual(errors, [], f"Review notes validation failed: {errors}")

    def test_validate_privacy_manifest_passes(self):
        path = self.root / "ZiroEdge" / "Resources" / "PrivacyInfo.xcprivacy"
        if not path.is_file():
            self.skipTest("PrivacyInfo.xcprivacy not found")
        errors = validator.validate_privacy_manifest(path)
        self.assertEqual(errors, [], f"Privacy manifest validation failed: {errors}")

    def test_validate_third_party_notices_passes(self):
        path = self.root / "ZiroEdge" / "Resources" / "THIRD_PARTY_NOTICES.md"
        if not path.is_file():
            self.skipTest("THIRD_PARTY_NOTICES.md not found")
        errors = validator.validate_third_party_notices(path)
        self.assertEqual(errors, [], f"Third party notices validation failed: {errors}")

    def test_validate_privacy_policy_passes_local(self):
        errors = validator.validate_privacy_policy(self.root)
        self.assertEqual(errors, [], f"Privacy policy validation failed: {errors}")

    def test_missing_metadata_reports_errors(self):
        errors = validator.validate_metadata(Path("/nonexistent/metadata.json"))
        self.assertGreater(len(errors), 0, "Missing metadata must produce errors")

    def test_missing_review_notes_reports_errors(self):
        errors = validator.validate_review_notes(Path("/nonexistent/review.md"))
        self.assertGreater(len(errors), 0, "Missing review notes must produce errors")

    def test_malformed_json_is_rejected(self):
        import tempfile

        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as tf:
            tf.write("{not valid json}")
            tf.flush()
            path = Path(tf.name)
        try:
            errors = validator.validate_metadata(path)
            self.assertGreater(len(errors), 0, "Malformed JSON must produce errors")
        finally:
            path.unlink(missing_ok=True)

    def test_passing_package_checks_do_not_claim_submission_ready(self):
        output = io.StringIO()
        validators = (
            "validate_metadata",
            "validate_review_notes",
            "validate_privacy_manifest",
            "validate_third_party_notices",
            "validate_privacy_policy",
            "validate_screenshot_assets",
        )
        patches = [
            patch.object(validator, name, return_value=[]) for name in validators
        ]
        for active_patch in patches:
            active_patch.start()
        try:
            with (
                patch("sys.argv", [str(SCRIPT), "--project-root", str(self.root)]),
                redirect_stdout(output),
            ):
                exit_code = validator.main()
        finally:
            for active_patch in reversed(patches):
                active_patch.stop()

        self.assertEqual(exit_code, 0)
        self.assertIn("Local App Store package checks passed", output.getvalue())
        self.assertIn("not a submission-ready verdict", output.getvalue())
        self.assertNotIn("submission is ready", output.getvalue().lower())


if __name__ == "__main__":
    unittest.main()
