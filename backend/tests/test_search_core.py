"""Tests for search_core (T5.3): validation + no-Scan query building."""

from __future__ import annotations

import unittest

from backend.app.search_core import DEFAULT_LIMIT, SearchError, build_search


class SearchCoreTest(unittest.TestCase):
    def test_day_only(self) -> None:
        q = build_search({"date": "2026-09-23"})
        self.assertEqual(q["ExpressionAttributeValues"][":pk"], "DAY#2026-09-23")
        self.assertIn("FilterExpression", q)
        self.assertEqual(q["ExpressionAttributeValues"][":deletedFalse"], False)
        self.assertEqual(q["Limit"], DEFAULT_LIMIT)

    def test_include_deleted_removes_filter(self) -> None:
        q = build_search({"date": "2026-09-23", "includeDeleted": "true"})
        self.assertNotIn("FilterExpression", q)

    def test_invalid_include_deleted_rejected(self) -> None:
        with self.assertRaises(SearchError):
            build_search({"date": "2026-09-23", "includeDeleted": "yes"})

    def test_day_with_time_range(self) -> None:
        q = build_search({"date": "2026-09-23", "from": "08:00", "to": "12:00"})
        self.assertIn("BETWEEN", q["KeyConditionExpression"])
        self.assertEqual(
            q["ExpressionAttributeValues"][":lo"],
            "TS#2026-09-23T11:00:00+00:00",
        )
        self.assertEqual(
            q["ExpressionAttributeValues"][":hi"],
            "TS#2026-09-23T15:00:59+00:00~",
        )

    def test_camera_range_uses_gsi(self) -> None:
        q = build_search(
            {
                "camera": "07",
                "from": "2026-09-23T00:00:00-03:00",
                "to": "2026-09-23T23:59:59-03:00",
            }
        )
        self.assertEqual(q["IndexName"], "by-camera")
        self.assertEqual(q["ExpressionAttributeValues"][":lo"], "2026-09-23T03:00:00+00:00")
        self.assertEqual(q["ExpressionAttributeValues"][":hi"], "2026-09-24T02:59:59+00:00~")

    def test_camera_range_rejects_wall_clock_without_date(self) -> None:
        with self.assertRaises(SearchError) as ctx:
            build_search({"camera": "07", "from": "08:00", "to": "12:00"})
        self.assertEqual(ctx.exception.code, "INVALID_QUERY")

    def test_camera_range_requires_timezone(self) -> None:
        with self.assertRaises(SearchError) as ctx:
            build_search(
                {
                    "camera": "07",
                    "from": "2026-09-23T08:00:00",
                    "to": "2026-09-23T12:00:00",
                }
            )
        self.assertIn("timezone", ctx.exception.message)

    def test_camera_range_rejects_reverse_instants(self) -> None:
        with self.assertRaises(SearchError) as ctx:
            build_search(
                {
                    "camera": "07",
                    "from": "2026-09-24T00:00:00Z",
                    "to": "2026-09-23T00:00:00Z",
                }
            )
        self.assertEqual(ctx.exception.message, "from must be <= to")

    def test_from_after_to_rejected(self) -> None:
        with self.assertRaises(SearchError) as ctx:
            build_search({"date": "2026-09-23", "from": "12:00", "to": "08:00"})
        self.assertEqual(ctx.exception.code, "INVALID_QUERY")

    def test_bad_date_rejected(self) -> None:
        with self.assertRaises(SearchError):
            build_search({"date": "23-09-2026"})

    def test_no_criteria_rejected(self) -> None:
        with self.assertRaises(SearchError):
            build_search({})

    def test_limit_bounds(self) -> None:
        with self.assertRaises(SearchError):
            build_search({"date": "2026-09-23", "limit": "9999"})


if __name__ == "__main__":
    unittest.main()
