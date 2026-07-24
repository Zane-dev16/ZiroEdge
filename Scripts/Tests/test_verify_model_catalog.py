import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "verify-model-catalog.py"
spec = importlib.util.spec_from_file_location("catalog_validator", SCRIPT)
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def artifact(digest):
    return [{"model": "fixture", "kind": "base", "url": "https://example.com/fixture.gguf", "size": 16, "sha256": digest}]


class CatalogMetadataTests(unittest.TestCase):
    def test_empty_digest_names_model_and_field(self):
        with self.assertRaisesRegex(ValueError, "fixture base sha256"):
            validator.validate_metadata(artifact(""))

    def test_uppercase_and_malformed_are_rejected(self):
        for digest in ("A" * 64, "g" * 64, "a" * 63):
            with self.subTest(digest=digest):
                with self.assertRaises(ValueError):
                    validator.validate_metadata(artifact(digest))

    def test_lowercase_digest_passes(self):
        validator.validate_metadata(artifact("a" * 64))


if __name__ == "__main__":
    unittest.main()
