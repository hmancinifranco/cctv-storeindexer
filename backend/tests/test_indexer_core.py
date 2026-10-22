"""Indexer core tests (T3.3): item shape, idempotency condition, malformed path."""

from __future__ import annotations

import unittest
from typing import Any

from backend.app.indexer_core import build_catalog_write, is_malformed, stable_object_id


class StableIdTest(unittest.TestCase):
    def test_deterministic(self) -> None:
        a = stable_object_id("b", "videos/x.mp4", None)
        b = stable_object_id("b", "videos/x.mp4", None)
        self.assertEqual(a, b)

    def test_version_changes_id(self) -> None:
        self.assertNotEqual(
            stable_object_id("b", "videos/x.mp4", "v1"),
            stable_object_id("b", "videos/x.mp4", "v2"),
        )


class ValidWriteTest(unittest.TestCase):
    def _write(self, seq: str = "001") -> dict[str, Any]:
        return build_catalog_write(
            bucket="b",
            key="videos/CAM07_20260923_142530-142959.mp4",
            size_bytes=123,
            etag="etag",
            sequencer=seq,
        )

    def test_item_keys_and_status(self) -> None:
        w = self._write()
        self.assertEqual(w["Item"]["catalogStatus"], "OK")
        self.assertEqual(w["Item"]["lifecycleState"], "AVAILABLE")
        self.assertEqual(w["Item"]["restoreStatus"], "NOT_REQUIRED")
        self.assertFalse(w["Item"]["deleted"])
        self.assertEqual(w["Item"]["PK"], "DAY#2026-09-23")
        self.assertEqual(w["Item"]["cameraId"], "07")
        self.assertEqual(w["Item"]["recordedAtUtc"], "2026-09-23T17:25:30+00:00")
        self.assertEqual(w["Item"]["GSI1PK"], "CAM#07")

    def test_idempotent_condition_present(self) -> None:
        w = self._write()
        self.assertIn("attribute_not_exists(PK)", w["ConditionExpression"])
        self.assertIn("#seq < :seq", w["ConditionExpression"])
        self.assertEqual(w["ExpressionAttributeValues"][":seq"], "001")

    def test_same_object_same_key_across_events(self) -> None:
        # Duplicate/out-of-order events for the same object target the same PK/SK,
        # so the conditional write collapses them to one logical item.
        self.assertEqual(self._write("001")["Item"]["SK"], self._write("002")["Item"]["SK"])


class MalformedWriteTest(unittest.TestCase):
    def test_malformed_quarantined_not_dropped(self) -> None:
        w = build_catalog_write(
            bucket="b",
            key="videos/not-valid.mp4",
            size_bytes=10,
            etag="e",
            sequencer="001",
        )
        self.assertTrue(is_malformed(w))
        self.assertEqual(w["Item"]["PK"], "INVALID")
        self.assertTrue(w["Item"]["invalidReason"])
        self.assertEqual(w["Item"]["rawFilename"], "not-valid.mp4")


if __name__ == "__main__":
    unittest.main()
