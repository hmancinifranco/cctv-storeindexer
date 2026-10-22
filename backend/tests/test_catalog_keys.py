"""Tests for catalog key construction, opaque cursor, and no-Scan queries (T4.2)."""

from __future__ import annotations

import unittest

from backend.app.catalog_keys import (
    build_camera_query,
    build_catalog_key,
    build_day_query,
    decode_cursor,
    encode_cursor,
)


class CatalogKeyTest(unittest.TestCase):
    def test_key_shape(self) -> None:
        k = build_catalog_key(
            local_day="2026-09-23",
            recorded_at_utc="2026-09-23T17:25:30+00:00",
            camera_id="07",
            stable_id="abc123",
        )
        self.assertEqual(k.pk, "DAY#2026-09-23")
        self.assertTrue(k.sk.startswith("TS#2026-09-23T17:25:30+00:00#CAM#07#OBJ#abc123"))
        self.assertEqual(k.gsi1pk, "CAM#07")
        self.assertTrue(k.gsi1sk.startswith("2026-09-23T17:25:30+00:00#abc123"))


class CursorTest(unittest.TestCase):
    def test_round_trip(self) -> None:
        key = {"PK": "DAY#2026-09-23", "SK": "TS#...#OBJ#x"}
        self.assertEqual(decode_cursor(encode_cursor(key)), key)

    def test_empty(self) -> None:
        self.assertIsNone(encode_cursor(None))
        self.assertIsNone(decode_cursor(None))


class QueryTest(unittest.TestCase):
    def test_day_query_no_scan(self) -> None:
        q = build_day_query(local_day="2026-09-23")
        self.assertIn("KeyConditionExpression", q)
        self.assertNotIn("FilterExpression", q)
        self.assertEqual(q["ExpressionAttributeValues"][":pk"], "DAY#2026-09-23")

    def test_day_query_time_range(self) -> None:
        q = build_day_query(
            local_day="2026-09-23",
            from_utc="2026-09-23T00:00:00+00:00",
            to_utc="2026-09-23T12:00:00+00:00",
        )
        self.assertIn("BETWEEN", q["KeyConditionExpression"])

    def test_camera_query_uses_gsi(self) -> None:
        q = build_camera_query(
            camera_id="07",
            from_utc="2026-09-23T00:00:00+00:00",
            to_utc="2026-09-23T23:59:59+00:00",
        )
        self.assertEqual(q["IndexName"], "by-camera")
        self.assertNotIn("FilterExpression", q)
        self.assertEqual(q["ExpressionAttributeValues"][":pk"], "CAM#07")


if __name__ == "__main__":
    unittest.main()
