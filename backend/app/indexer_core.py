"""Indexer core logic (design §3, R2). Pure and unit-testable without AWS.

Turns an S3 ObjectCreated event into a DynamoDB catalog item plus the
conditional-write parameters that make indexing idempotent: S3 notifications are
at-least-once and unordered, so we only apply a write when the incoming
`sequencer` is greater than the stored one. Duplicate or older events are no-ops.

Malformed filenames are NOT dropped: they are cataloged with
catalogStatus=INVALID_METADATA so an operator can see and remediate them (R2).
"""

from __future__ import annotations

import hashlib
from typing import Any

from .catalog_keys import build_catalog_key
from .filename_parser import FilenameParser


def stable_object_id(bucket: str, key: str, version_id: str | None) -> str:
    """Deterministic id for an object (used in the SK / audit correlation)."""
    basis = f"{bucket}/{key}/{version_id or ''}"
    return hashlib.sha256(basis.encode()).hexdigest()[:16]


def build_catalog_write(
    *,
    bucket: str,
    key: str,
    size_bytes: int,
    etag: str,
    sequencer: str,
    version_id: str | None = None,
    event_time: str = "",
    parser: FilenameParser | None = None,
) -> dict[str, Any]:
    """Build a DynamoDB put_item request (Item + condition) for one object.

    Idempotent: the ConditionExpression accepts the write only if the item is new
    OR the incoming sequencer is lexically greater than the stored one (S3
    sequencers are monotonic hex strings safe to compare lexically).
    """
    parser = parser or FilenameParser()
    filename = key.rsplit("/", 1)[-1]
    stable_id = stable_object_id(bucket, key, version_id)
    result = parser.parse(filename)

    common = {
        "objectKey": key,
        "bucket": bucket,
        "versionId": version_id or "",
        "rawFilename": filename,
        "sizeBytes": size_bytes,
        "eTag": etag,
        "sequencer": sequencer,
        "stableId": stable_id,
        "GSI2PK": f"OBJ#{stable_id}",
        "parserVersion": result.parser_version,
        "storageClass": "STANDARD",
        "lifecycleState": "AVAILABLE",
        "restoreStatus": "NOT_REQUIRED",
        "deleted": False,
        "stateChangedAt": event_time,
    }

    if result.status == "OK":
        camera_id = result.camera_id or "UNKNOWN"
        keys = build_catalog_key(
            local_day=result.local_day or "0000-00-00",
            recorded_at_utc=result.recorded_at_utc or "",
            camera_id=camera_id,
            stable_id=stable_id,
        )
        item = {
            "PK": keys.pk,
            "SK": keys.sk,
            "GSI1PK": keys.gsi1pk,
            "GSI1SK": keys.gsi1sk,
            "catalogStatus": "OK",
            "cameraId": camera_id,
            "recordedAtUtc": result.recorded_at_utc,
            "recordedAtLocal": result.recorded_at_local,
            "endsAtUtc": result.ends_at_utc or "",
            **common,
        }
    else:
        # Quarantine partition keeps malformed items visible and queryable.
        item = {
            "PK": "INVALID",
            "SK": f"OBJ#{stable_id}",
            "catalogStatus": "INVALID_METADATA",
            "invalidReason": result.reason,
            **common,
        }

    return {
        "Item": item,
        "ConditionExpression": "attribute_not_exists(PK) OR #seq < :seq",
        "ExpressionAttributeNames": {"#seq": "sequencer"},
        "ExpressionAttributeValues": {":seq": sequencer},
    }


def is_malformed(write_request: dict[str, Any]) -> bool:
    """True if the built item is an INVALID_METADATA entry (drives the metric)."""
    return write_request["Item"].get("catalogStatus") == "INVALID_METADATA"
