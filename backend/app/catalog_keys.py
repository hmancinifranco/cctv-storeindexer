"""DynamoDB catalog key construction and query building (design §5).

Pure, dependency-free helpers so they unit-test without AWS. The Lambdas
(indexer T3.3, search T5.3) import these to build items and Query params — no
table Scan is ever produced (R3).

Key model:
  Catalog  PK = DAY#<YYYY-MM-DD>          SK = TS#<utc>#CAM#<camId>#OBJ#<stableId>
  by-camera GSI1PK = CAM#<camId>          GSI1SK = <utc>#<stableId>
"""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass


@dataclass(frozen=True)
class CatalogKey:
    pk: str
    sk: str
    gsi1pk: str
    gsi1sk: str


def build_catalog_key(
    *, local_day: str, recorded_at_utc: str, camera_id: str, stable_id: str
) -> CatalogKey:
    """Build the primary + GSI keys for a catalog item.

    local_day: YYYY-MM-DD (local recording day)
    recorded_at_utc: ISO-8601 UTC timestamp
    """
    return CatalogKey(
        pk=f"DAY#{local_day}",
        sk=f"TS#{recorded_at_utc}#CAM#{camera_id}#OBJ#{stable_id}",
        gsi1pk=f"CAM#{camera_id}",
        gsi1sk=f"{recorded_at_utc}#{stable_id}",
    )


def encode_cursor(last_evaluated_key: dict | None) -> str | None:
    """Opaque base64 cursor wrapping a DynamoDB LastEvaluatedKey."""
    if not last_evaluated_key:
        return None
    raw = json.dumps(last_evaluated_key, separators=(",", ":"), sort_keys=True)
    return base64.urlsafe_b64encode(raw.encode()).decode()


@dataclass(frozen=True)
class CursorError(ValueError):
    message: str = "cursor is invalid"


def decode_cursor(cursor: str | None) -> dict | None:
    """Decode and validate an opaque DynamoDB cursor.

    A malformed or tampered cursor is a client error, never an instruction to
    restart pagination and never an unhandled server exception.
    """
    if not cursor:
        return None
    try:
        raw = base64.b64decode(cursor.encode(), altchars=b"-_", validate=True).decode()
        decoded = json.loads(raw)
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CursorError() from exc
    if not isinstance(decoded, dict) or not decoded:
        raise CursorError()
    if not all(isinstance(key, str) and isinstance(value, str) for key, value in decoded.items()):
        raise CursorError()
    return decoded


def build_day_query(
    *, local_day: str, from_utc: str | None = None, to_utc: str | None = None
) -> dict:
    """Query params for one local day, optionally bounded by a UTC time range.

    Uses KeyConditionExpression only (no FilterExpression Scan). The SK begins
    with TS#<utc>, so a lexical range on the UTC segment bounds the time window.
    """
    params: dict = {
        "KeyConditionExpression": "#pk = :pk",
        "ExpressionAttributeNames": {"#pk": "PK"},
        "ExpressionAttributeValues": {":pk": f"DAY#{local_day}"},
    }
    if from_utc and to_utc:
        params["KeyConditionExpression"] += " AND #sk BETWEEN :lo AND :hi"
        params["ExpressionAttributeNames"]["#sk"] = "SK"
        params["ExpressionAttributeValues"][":lo"] = f"TS#{from_utc}"
        params["ExpressionAttributeValues"][":hi"] = f"TS#{to_utc}~"
    return params


def build_camera_query(*, camera_id: str, from_utc: str, to_utc: str) -> dict:
    """Query params for a camera over a UTC range, via the by-camera GSI."""
    return {
        "IndexName": "by-camera",
        "KeyConditionExpression": "#pk = :pk AND #sk BETWEEN :lo AND :hi",
        "ExpressionAttributeNames": {"#pk": "GSI1PK", "#sk": "GSI1SK"},
        "ExpressionAttributeValues": {
            ":pk": f"CAM#{camera_id}",
            ":lo": from_utc,
            ":hi": f"{to_utc}~",
        },
    }
