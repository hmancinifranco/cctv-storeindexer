"""Tests for search_handler behavior that needs no AWS: health + Decimal JSON."""

from __future__ import annotations

import json
import unittest
from decimal import Decimal

from backend.app.search_handler import _json_default, _response, handler


class HealthRouteTest(unittest.TestCase):
    def test_health_returns_ok_without_boto3(self) -> None:
        resp = handler({"resource": "/health", "path": "/health"})
        self.assertEqual(resp["statusCode"], 200)
        self.assertEqual(json.loads(resp["body"]), {"status": "ok"})


class DecimalJsonTest(unittest.TestCase):
    def test_integral_decimal_to_int(self) -> None:
        self.assertEqual(_json_default(Decimal("123")), 123)
        self.assertIsInstance(_json_default(Decimal("123")), int)

    def test_fractional_decimal_to_float(self) -> None:
        self.assertEqual(_json_default(Decimal("1.5")), 1.5)

    def test_response_serializes_decimal(self) -> None:
        # A body carrying a Decimal (as DynamoDB returns sizeBytes) must not raise.
        resp = _response(200, {"items": [{"sizeBytes": Decimal("2048")}]})
        self.assertEqual(json.loads(resp["body"])["items"][0]["sizeBytes"], 2048)

    def test_unknown_type_raises(self) -> None:
        with self.assertRaises(TypeError):
            _json_default(object())


class InvalidCursorRouteTest(unittest.TestCase):
    def test_invalid_cursor_returns_typed_400_before_boto3(self) -> None:
        response = handler(
            {
                "path": "/videos",
                "queryStringParameters": {
                    "date": "2026-09-23",
                    "cursor": "not valid base64!!!",
                },
            }
        )
        self.assertEqual(response["statusCode"], 400)
        self.assertEqual(json.loads(response["body"])["code"], "INVALID_QUERY")


if __name__ == "__main__":
    unittest.main()
