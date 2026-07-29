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
            with self.subTest(url=url), self.assertRaisesRegex(ValueError, "non-canonical URL"):
                validator.validate_metadata(artifact(url=url))

    def test_nonpositive_sizes_are_rejected(self):
        for size in (0, -1):
            with self.subTest(size=size), self.assertRaisesRegex(ValueError, "non-positive size"):
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


if __name__ == "__main__":
    unittest.main()
