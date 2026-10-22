"""Parser tests, driven by the synthetic fixture manifest (T3.2).

Every fixture entry's expected_status must match what the real parser produces —
this cross-checks the generator (T2.3) and the parser against one source of truth.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from backend.app.filename_parser import FilenameParser

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST = json.loads((REPO_ROOT / "uploader" / "synthetic" / "manifest.json").read_text())


class ParserVsManifestTest(unittest.TestCase):
    def setUp(self) -> None:
        self.parser = FilenameParser()

    def test_every_manifest_entry_matches(self) -> None:
        for entry in MANIFEST["entries"]:
            result = self.parser.parse(entry["filename"])
            self.assertEqual(
                result.status,
                entry["expected_status"],
                f"{entry['filename']}: expected {entry['expected_status']}, got "
                f"{result.status} ({result.reason})",
            )
            if entry["expected_status"] == "OK":
                self.assertEqual(result.camera_id, entry["camera_id"])
                self.assertEqual(result.recorded_at_utc, entry["recorded_at_utc"])


class ParserUnitTest(unittest.TestCase):
    def setUp(self) -> None:
        self.parser = FilenameParser()

    def test_utc_derivation(self) -> None:
        # 14:25:30 local UTC-3 -> 17:25:30 UTC
        r = self.parser.parse("CAM07_20260923_142530-142959.mp4")
        self.assertEqual(r.status, "OK")
        self.assertEqual(r.recorded_at_utc, "2026-09-23T17:25:30+00:00")
        self.assertEqual(r.local_day, "2026-09-23")

    def test_cross_midnight_end_rolls_forward(self) -> None:
        r = self.parser.parse("CAM03_20260923_235000-001000.mp4")
        self.assertEqual(r.status, "OK")
        assert r.ends_at_utc is not None
        assert r.recorded_at_utc is not None
        self.assertGreater(r.ends_at_utc, r.recorded_at_utc)

    def test_malformed_has_reason(self) -> None:
        r = self.parser.parse("not-a-valid-name.mp4")
        self.assertEqual(r.status, "INVALID_METADATA")
        self.assertTrue(r.reason)

    def test_configurable_grammar(self) -> None:
        # A different client grammar: DVR<id>-YYYYMMDD.mp4
        grammar = {
            "version": "client-x",
            "pattern": r"^DVR(?P<camera>\d+)-(?P<date>\d{8})_(?P<start>\d{6})\.(?P<ext>mp4)$",
            "allowed_extensions": ["mp4"],
            "utc_offset_hours": -3,
        }
        p = FilenameParser(grammar=grammar)
        self.assertEqual(p.parse("DVR9-20260923_120000.mp4").status, "OK")
        self.assertEqual(p.parse("CAM07_20260923_142530.mp4").status, "INVALID_METADATA")


if __name__ == "__main__":
    unittest.main()
