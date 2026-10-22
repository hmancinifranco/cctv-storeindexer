"""Indexer handler tests for lifecycle updates without AWS dependencies."""

from __future__ import annotations

from unittest.mock import patch

import pytest
from backend.app.indexer_core import stable_object_id
from backend.app.indexer_handler import _required_message_id, _update_lifecycle, handler


class FakeTable:
    def __init__(self, items: list[dict]) -> None:
        self.items = items
        self.query_request: dict | None = None
        self.update_request: dict | None = None

    def query(self, **request: object) -> dict:
        self.query_request = request
        return {"Items": self.items}

    def update_item(self, **request: object) -> None:
        self.update_request = request


def _event() -> tuple[dict, dict]:
    detail = {
        "bucket": {"name": "bucket"},
        "object": {"key": "videos/CAM01_20261022_100000.avi", "sequencer": "002"},
        "reason": "Lifecycle Expiration",
        "deletion-type": "Permanently Deleted",
    }
    envelope = {
        "id": "event-1",
        "time": "2026-10-22T13:00:00Z",
        "detail-type": "Object Deleted",
    }
    return envelope, detail


def test_lifecycle_update_resolves_by_object_index_without_scan() -> None:
    table = FakeTable([{"PK": "DAY#2026-10-22", "SK": "TS#value"}])
    envelope, detail = _event()

    with patch.dict("os.environ", {"CATALOG_TOMBSTONE_RETENTION_DAYS": "365"}):
        _update_lifecycle(table, envelope, detail)

    assert table.query_request is not None
    assert table.query_request["IndexName"] == "by-object"
    expected_id = stable_object_id("bucket", detail["object"]["key"], None)
    assert table.query_request["ExpressionAttributeValues"] == {":oid": f"OBJ#{expected_id}"}
    assert table.update_request is not None
    assert table.update_request["Key"] == {
        "PK": "DAY#2026-10-22",
        "SK": "TS#value",
    }


def test_missing_catalog_item_is_retried() -> None:
    table = FakeTable([])
    envelope, detail = _event()
    with pytest.raises(LookupError, match="catalog item not found"):
        _update_lifecycle(table, envelope, detail)


def test_required_message_id_accepts_non_empty_value() -> None:
    assert _required_message_id({"messageId": "message-1"}) == "message-1"


def test_missing_message_id_fails_complete_invocation_before_boto3() -> None:
    with pytest.raises(ValueError, match="missing messageId"):
        handler({"Records": [{"body": "{}"}]})


def test_empty_message_id_fails_complete_invocation_before_boto3() -> None:
    with pytest.raises(ValueError, match="missing messageId"):
        handler({"Records": [{"messageId": "", "body": "{}"}]})
