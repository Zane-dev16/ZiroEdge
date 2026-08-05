"""Tests for verify-privacy-policy.py."""

import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "verify-privacy-policy.py"
spec = importlib.util.spec_from_file_location("privacy_checker", SCRIPT)
if spec is None or spec.loader is None:
    raise RuntimeError(f"Could not load privacy checker from {SCRIPT}")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class PrivacyPolicyLocalTests(unittest.TestCase):
    """Tests that exercise local checks without network access."""

    def test_local_page_passes_all_required_sections(self):
        errors = checker.check_local_page(checker.local_page_path())
        self.assertEqual(errors, [], f"Local page check failed: {errors}")

    def test_listing_metadata_uses_canonical_url(self):
        errors = checker.check_listing_metadata(
            checker.listing_metadata_path(), checker.CANONICAL_URL
        )
        self.assertEqual(errors, [], f"Listing metadata check failed: {errors}")

    def test_settings_source_uses_canonical_url(self):
        errors = checker.check_settings_source(
            checker.settings_source_paths(), checker.CANONICAL_URL
        )
        self.assertEqual(errors, [], f"Settings source check failed: {errors}")

    def test_verify_local_only_passes(self):
        errors = checker.verify_local_only(checker.CANONICAL_URL)
        self.assertEqual(errors, [], f"Local-only verification failed: {errors}")

    def test_mismatched_url_in_listing_metadata_is_rejected(self):
        errors = checker.check_listing_metadata(
            checker.listing_metadata_path(),
            "https://example.com/wrong.html",
        )
        self.assertGreater(len(errors), 0, "Mismatched URL must produce an error")

    def test_mismatched_url_in_settings_source_is_rejected(self):
        errors = checker.check_settings_source(
            checker.settings_source_paths(),
            "https://example.com/wrong.html",
        )
        self.assertGreater(len(errors), 0, "Mismatched URL must produce an error")

    def test_missing_page_is_reported(self):
        errors = checker.check_local_page(Path("/nonexistent/privacy.html"))
        self.assertGreater(len(errors), 0, "Missing page must produce an error")
        self.assertIn("not found", errors[0])

    def test_incomplete_content_is_rejected(self):
        import tempfile

        with tempfile.NamedTemporaryFile(mode="w", suffix=".html", delete=False) as tf:
            tf.write("<!DOCTYPE html><html><body>Empty</body></html>")
            tf.flush()
            path = Path(tf.name)
        try:
            errors = checker.check_local_page(path)
            # Missing viewport and all required section keywords
            self.assertGreater(len(errors), 0, "Incomplete page must produce errors")
        finally:
            path.unlink(missing_ok=True)


class PrivacyPolicyURLChecks(unittest.TestCase):
    """Tests that verify URL canonicality."""

    def test_canonical_url_is_https(self):
        self.assertTrue(
            checker.CANONICAL_URL.startswith("https://"),
            "Canonical URL must use HTTPS",
        )

    def test_canonical_url_is_not_empty(self):
        self.assertTrue(len(checker.CANONICAL_URL) > 0)


if __name__ == "__main__":
    unittest.main()
