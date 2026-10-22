"""Validate the synthetic fixture manifest (proves the test toolchain works).

This is a real, in-scope check: it guards the fixture consumed by later indexer
tests (T3.3) so a malformed manifest is caught early. Uses only the stdlib so it
runs with or without pytest installed.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / "uploader" / "synthetic" / "manifest.json"

VALID_STATUSES = {"OK", "INVALID_METADATA"}
VALID_CATEGORIES = {"valid", "edge", "invalid"}


class FixtureManifestTest(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(MANIFEST.exists(), f"missing fixture manifest: {MANIFEST}")
        self.manifest = json.loads(MANIFEST.read_text())

    def test_top_level_keys(self) -> None:
        for key in ("grammar", "parser_version", "timezone", "entries", "counts"):
            self.assertIn(key, self.manifest)

    def test_counts_match_entries(self) -> None:
        entries = self.manifest["entries"]
        counts = self.manifest["counts"]
        self.assertEqual(counts["total"], len(entries))
        for category in VALID_CATEGORIES:
            actual = sum(1 for e in entries if e["category"] == category)
            self.assertEqual(counts[category], actual, f"count mismatch for {category}")

    def test_entries_are_well_formed(self) -> None:
        for entry in self.manifest["entries"]:
            self.assertIn(entry["expected_status"], VALID_STATUSES)
            self.assertIn(entry["category"], VALID_CATEGORIES)
            self.assertTrue(entry["filename"], "empty filename")
            if entry["expected_status"] == "OK":
                self.assertTrue(entry["camera_id"], "valid entry needs camera_id")
                self.assertTrue(entry["recorded_at_utc"], "valid entry needs UTC")
            else:
                self.assertTrue(entry["reason"], "invalid entry needs a reason")

    def test_has_each_category(self) -> None:
        # The fixture must exercise valid, edge, and malformed cases.
        self.assertGreater(self.manifest["counts"]["valid"], 0)
        self.assertGreater(self.manifest["counts"]["edge"], 0)
        self.assertGreater(self.manifest["counts"]["invalid"], 0)


if __name__ == "__main__":
    unittest.main()
