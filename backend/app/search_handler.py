"""Search Lambda handler — GET /v1/videos (design §6, R3).

Validates query params, runs a no-Scan DynamoDB Query, returns a page plus an
opaque cursor. boto3 imported inside the handler so the core stays testable.
"""

from __future__ import annotations

import json
import os
from decimal import Decimal
from typing import Any

from .catalog_keys import decode_cursor, encode_cursor
from .search_core import SearchError, build_search


def _json_default(value: Any) -> Any:
    """Make DynamoDB Decimal values JSON-serializable (int if integral, else float)."""
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError(f"not JSON serializable: {type(value)}")


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=_json_default),
    }


def handler(event: dict[str, Any], _context: Any = None) -> dict:
    # /health is served by this same function (Auth NONE) — answer it directly
    # instead of treating it as a search with no criteria.
    path = event.get("resource") or event.get("path") or ""
    if path.endswith("/health"):
        return _response(200, {"status": "ok"})

    import boto3

    params = event.get("queryStringParameters") or {}
    try:
        query = build_search(params)
    except SearchError as err:
        return _response(400, {"code": err.code, "message": err.message})

    cursor = decode_cursor(params.get("cursor"))
    if cursor:
        query["ExclusiveStartKey"] = cursor

    table = boto3.resource("dynamodb").Table(os.environ["CATALOG_TABLE"])
    result = table.query(**query)

    items = [
        {
            "objectKey": it.get("objectKey"),
            "cameraId": it.get("cameraId"),
            "recordedAtUtc": it.get("recordedAtUtc"),
            "recordedAtLocal": it.get("recordedAtLocal"),
            "sizeBytes": it.get("sizeBytes"),
            "catalogStatus": it.get("catalogStatus"),
            "storageClass": it.get("storageClass"),
            "accessTier": it.get("accessTier"),
            "lifecycleState": it.get("lifecycleState", "AVAILABLE"),
            "restoreStatus": it.get("restoreStatus", "NOT_REQUIRED"),
            "stateChangedAt": it.get("stateChangedAt"),
            "storageClassChangedAt": it.get("storageClassChangedAt"),
            "accessTierChangedAt": it.get("accessTierChangedAt"),
            "archivedAt": it.get("archivedAt"),
            "restoreRequestedAt": it.get("restoreRequestedAt"),
            "restoredAt": it.get("restoredAt"),
            "restoreExpiresAt": it.get("restoreExpiresAt"),
            "restoreExpiredAt": it.get("restoreExpiredAt"),
            "deleted": it.get("deleted", False),
            "deletedAt": it.get("deletedAt"),
            "deletionReason": it.get("deletionReason"),
            "stableId": it.get("stableId"),
        }
        for it in result.get("Items", [])
    ]
    return _response(
        200,
        {"items": items, "cursor": encode_cursor(result.get("LastEvaluatedKey"))},
    )
