"""Search core logic (design §6, R3). Pure and unit-testable without AWS.

Validates search query parameters and builds a no-Scan DynamoDB Query using the
key helpers. Returns a typed error for invalid input (e.g. from > to) rather
than an empty success.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from .catalog_keys import build_camera_query, build_day_query

_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_TIME_RE = re.compile(r"^\d{2}:\d{2}(:\d{2})?$")
DEFAULT_LIMIT = 50
MAX_LIMIT = 200


@dataclass(frozen=True)
class SearchError(Exception):
    code: str
    message: str


def _validate_limit(raw: str | None) -> int:
    if raw is None or raw == "":
        return DEFAULT_LIMIT
    try:
        value = int(raw)
    except ValueError as exc:
        raise SearchError("INVALID_QUERY", "limit must be an integer") from exc
    if value < 1 or value > MAX_LIMIT:
        raise SearchError("INVALID_QUERY", f"limit must be 1..{MAX_LIMIT}")
    return value


def _to_utc_range(date: str, from_t: str | None, to_t: str | None) -> tuple[str, str] | None:
    """Build a UTC ISO range for a local day + optional HH:MM[:SS] bounds.

    Local time is UTC-3 (A1); we append the fixed offset so the range compares
    against the stored UTC timestamps.
    """
    if not from_t and not to_t:
        return None
    lo = from_t or "00:00:00"
    hi = to_t or "23:59:59"
    for t in (lo, hi):
        if not _TIME_RE.match(t):
            raise SearchError("INVALID_QUERY", f"invalid time: {t}")
    lo = lo if len(lo) == 8 else f"{lo}:00"
    hi = hi if len(hi) == 8 else f"{hi}:59"
    if lo > hi:
        raise SearchError("INVALID_QUERY", "from must be <= to")
    # Convert local wall-clock to the UTC instant used in stored SK (UTC-3).
    lo_utc = f"{date}T{lo}-03:00"
    hi_utc = f"{date}T{hi}-03:00"
    return lo_utc, hi_utc


def _validate_include_deleted(raw: str | None) -> bool:
    if raw in (None, "", "false"):
        return False
    if raw == "true":
        return True
    raise SearchError("INVALID_QUERY", "includeDeleted must be true or false")


def build_search(params: dict[str, str | None]) -> dict:
    """Validate params and return a DynamoDB Query dict (no Scan). Raises SearchError."""
    date = params.get("date")
    camera = params.get("camera")
    from_t = params.get("from")
    to_t = params.get("to")
    limit = _validate_limit(params.get("limit"))
    include_deleted = _validate_include_deleted(params.get("includeDeleted"))

    if camera and (from_t or to_t) and not date:
        # Camera + time range across days uses the GSI with UTC bounds.
        if not (from_t and to_t):
            raise SearchError("INVALID_QUERY", "camera time search needs both from and to")
        query = build_camera_query(camera_id=camera, from_utc=from_t, to_utc=to_t)
    elif date:
        if not _DATE_RE.match(date):
            raise SearchError("INVALID_QUERY", "date must be YYYY-MM-DD")
        rng = _to_utc_range(date, from_t, to_t)
        if rng:
            query = build_day_query(local_day=date, from_utc=rng[0], to_utc=rng[1])
        else:
            query = build_day_query(local_day=date)
    else:
        raise SearchError("INVALID_QUERY", "provide date, or camera with from/to")

    query["Limit"] = limit
    if not include_deleted:
        query["FilterExpression"] = "attribute_not_exists(#deleted) OR #deleted = :deletedFalse"
        query.setdefault("ExpressionAttributeNames", {})["#deleted"] = "deleted"
        query.setdefault("ExpressionAttributeValues", {})[":deletedFalse"] = False
    return query
