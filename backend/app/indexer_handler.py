"""Indexer Lambda for S3 object creation and lifecycle state changes.

Consumes SQS messages delivered by EventBridge, writes new catalog entries, and
updates archive/restore/deletion state. Conditional writes make duplicate and
out-of-order delivery a no-op; poison messages retain SQS partial-batch retry
behavior and eventually reach the DLQ.
"""

from __future__ import annotations

import json
import os
from typing import Any

from .indexer_core import build_catalog_write, is_malformed, stable_object_id
from .lifecycle_core import (
    SUPPORTED_LIFECYCLE_EVENTS,
    build_lifecycle_update,
    event_object_identity,
)


def _emit_invalid_metric() -> None:
    """Structured log line; CloudWatch metric filter turns it into InvalidFilename."""
    print(json.dumps({"metric": "InvalidFilename", "value": 1}))  # noqa: T201


def _is_conditional_noop(exc: Exception) -> bool:
    return type(exc).__name__ == "ConditionalCheckFailedException"


def _index_created(table: Any, envelope: dict[str, Any], detail: dict[str, Any]) -> None:
    bucket, key, version_id = event_object_identity(detail)
    obj = detail["object"]
    write = build_catalog_write(
        bucket=bucket,
        key=key,
        size_bytes=obj.get("size", 0),
        etag=obj.get("etag") or obj.get("eTag", ""),
        sequencer=obj.get("sequencer", "0"),
        version_id=version_id,
        event_time=envelope.get("time", ""),
    )
    if is_malformed(write):
        _emit_invalid_metric()
    try:
        table.put_item(**write)
    except Exception as exc:  # noqa: BLE001
        if _is_conditional_noop(exc):
            return
        raise


def _update_lifecycle(table: Any, envelope: dict[str, Any], detail: dict[str, Any]) -> None:
    bucket, key, version_id = event_object_identity(detail)
    stable_id = stable_object_id(bucket, key, version_id)
    resolved = table.query(
        IndexName="by-object",
        KeyConditionExpression="GSI2PK = :oid",
        ExpressionAttributeValues={":oid": f"OBJ#{stable_id}"},
        ProjectionExpression="PK, SK",
        Limit=1,
    )
    items = resolved.get("Items", [])
    if not items:
        # Creation and lifecycle notifications can arrive out of order. Raising
        # lets SQS retry after the creation event has populated the catalog.
        raise LookupError(f"catalog item not found for object {stable_id}")

    update = build_lifecycle_update(
        detail_type=envelope["detail-type"],
        detail=detail,
        event_time=envelope["time"],
        event_id=envelope["id"],
        tombstone_retention_days=int(
            os.environ.get("CATALOG_TOMBSTONE_RETENTION_DAYS", "365")
        ),
    )
    try:
        table.update_item(Key={"PK": items[0]["PK"], "SK": items[0]["SK"]}, **update)
    except Exception as exc:  # noqa: BLE001
        if _is_conditional_noop(exc):
            return
        raise


def handler(event: dict[str, Any], _context: Any = None) -> dict[str, Any]:
    """SQS-triggered entry point with partial-batch failure reporting."""
    import boto3

    table = boto3.resource("dynamodb").Table(os.environ["CATALOG_TABLE"])
    failures: list[dict[str, str]] = []

    for record in event.get("Records", []):
        try:
            envelope = json.loads(record["body"])
            detail = envelope.get("detail", envelope)
            detail_type = envelope.get("detail-type", "Object Created")
            if detail_type == "Object Created":
                _index_created(table, envelope, detail)
            elif detail_type in SUPPORTED_LIFECYCLE_EVENTS:
                _update_lifecycle(table, envelope, detail)
            else:
                raise ValueError(f"unsupported S3 event: {detail_type}")
        except Exception:  # noqa: BLE001
            failures.append({"itemIdentifier": record.get("messageId", "")})

    return {"batchItemFailures": failures}
