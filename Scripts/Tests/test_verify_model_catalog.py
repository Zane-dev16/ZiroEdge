import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "verify-model-catalog.py"
spec = importlib.util.spec_from_file_location("catalog_validator", SCRIPT)
if spec is None or spec.loader is None:
    raise RuntimeError(f"Could not load catalog validator from {SCRIPT}")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def artifact(digest="a" * 64, **overrides):
    value = {
        "model": "fixture",
        "kind": "base",
        "url": "https://example.com/fixture.gguf",
        "size": 16,
        "sha256": digest,
    }
    value.update(overrides)
    return [value]


class CatalogMetadataTests(unittest.TestCase):
    def test_production_catalog_contract_is_well_formed(self):
        artifacts = validator.extract_catalog()
        validator.validate_metadata(artifacts)
        self.assertGreater(len(artifacts), 0)

    def test_empty_digest_names_model_and_field(self):
        with self.assertRaisesRegex(ValueError, "fixture base sha256"):
            validator.validate_metadata(artifact(""))

    def test_uppercase_and_malformed_hashes_are_rejected(self):
        for digest in ("A" * 64, "g" * 64, "a" * 63):
            with self.subTest(digest=digest):
                with self.assertRaises(ValueError):
                    validator.validate_metadata(artifact(digest))

    def test_lowercase_digest_passes(self):
        validator.validate_metadata(artifact())

    def test_noncanonical_urls_are_rejected(self):
        urls = (
            "http://example.com/fixture.gguf",
            "https://example.com/fixture.bin",
            "https://example.com/fixture.gguf?token=secret",
            "https:///fixture.gguf",
        )
        for url in urls:
            with (
                self.subTest(url=url),
                self.assertRaisesRegex(ValueError, "non-canonical URL"),
            ):
                validator.validate_metadata(artifact(url=url))

    def test_nonpositive_sizes_are_rejected(self):
        for size in (0, -1):
            with (
                self.subTest(size=size),
                self.assertRaisesRegex(ValueError, "non-positive size"),
            ):
                validator.validate_metadata(artifact(size=size))

    def test_duplicate_destinations_are_rejected(self):
        duplicate = artifact()[0]
        with self.assertRaisesRegex(ValueError, "duplicate destination"):
            validator.validate_metadata([duplicate, dict(duplicate)])

    def test_redirect_provenance_removes_credentials_query_and_fragment(self):
        sanitized = validator.sanitize_provenance(
            "https://user:password@cdn.example.com/model.gguf?X-Amz-Signature=secret#token"
        )
        self.assertEqual(sanitized, "https://cdn.example.com/model.gguf")
        self.assertNotIn("secret", sanitized)


class CatalogVersionTests(unittest.TestCase):
    def test_catalog_version_is_non_empty(self):
        version = validator.extract_catalog_version()
        self.assertIsInstance(version, str)
        self.assertGreater(len(version), 0)
        self.assertEqual(version, "1")


class EvidenceFormatTests(unittest.TestCase):
    def test_success_evidence_includes_catalog_version(self):
        """Success evidence must carry catalog version and expected/actual.*"""
        art = artifact()[0]
        result = validator.verify_download(art, timeout=5, catalog_version="1")
        # With a fake URL, verify_download will fail and return failure evidence.
        self.assertIn("catalogVersion", result)
        self.assertEqual(result["catalogVersion"], "1")
        self.assertIn("expectedSize", result)
        self.assertIn("expectedSHA256", result)
        self.assertIn("canonicalSource", result)
        self.assertIn("command", result)
        self.assertIn("outcome", result)

    def test_sanitized_source_never_exposes_credentials(self):
        san = validator.sanitize_provenance(
            "https://huggingface.co/user/model/resolve/main/file.gguf?token=abc&signature=xyz#frag"
        )
        self.assertEqual(
            san, "https://huggingface.co/user/model/resolve/main/file.gguf"
        )
        self.assertNotIn("token", san)
        self.assertNotIn("signature", san)
        self.assertNotIn("frag", san)
        self.assertNotIn("abc", san)

    def test_sanitized_source_preserves_structure(self):
        san = validator.sanitize_provenance(
            "https://huggingface.co/zanish-labs/model/resolve/main/file.gguf"
        )
        self.assertTrue(san.startswith("https://"))
        self.assertTrue(san.endswith(".gguf"))
        self.assertIn("huggingface.co", san)

    def test_failure_evidence_is_reviewable(self):
        """Failure evidence must not expose credentials and must be structured."""
        art = artifact(url="https://example.com/fixture.gguf")[0]
        result = validator.verify_download(art, timeout=1, catalog_version="1")
        self.assertEqual(result["outcome"], "failure")
        self.assertIn("failureSummary", result)
        self.assertIn("expectedSize", result)
        self.assertIn("expectedSHA256", result)
        # Canonical source must be sanitized
        self.assertNotIn("token", str(result.get("canonicalSource", "")))
        self.assertNotIn("password", str(result.get("canonicalSource", "")))


if __name__ == "__main__":
    unittest.main()
