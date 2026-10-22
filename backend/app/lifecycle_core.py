"""Pure S3 lifecycle-event mapping for catalog state updates.

S3 EventBridge notifications are at-least-once and can arrive out of order.
Each update therefore carries a deterministic event order and a DynamoDB
condition that rejects duplicates and older state transitions.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

ARCHIVE_STORAGE_CLASSES = {"GLACIER", "DEEP_ARCHIVE"}
ARCHIVE_ACCESS_TIERS = {"ARCHIVE_ACCESS", "DEEP_ARCHIVE_ACCESS"}
SUPPORTED_LIFECYCLE_EVENTS = {
    "Object Deleted",
    "Object Storage Class Changed",
    "Object Access Tier Changed",
    "Object Restore Initiated",
    "Object Restore Completed",
    "Object Restore Expired",
}

_EVENT_RANK = {
    "Object Storage Class Changed": 10,
    "Object Access Tier Changed": 10,
    "Object Restore Initiated": 20,
    "Object Restore Completed": 30,
    "Object Restore Expired": 40,
    "Object Deleted": 90,
}


def event_object_identity(detail: dict[str, Any]) -> tuple[str, str, str | None]:
    """Return bucket, key and optional version id from an S3 EventBridge detail."""
    obj = detail["object"]
    return (
        detail["bucket"]["name"],
        obj["key"],
        obj.get("version-id") or obj.get("versionId"),
    )


def _epoch_after(event_time: str, days: int) -> int:
    occurred_at = datetime.fromisoformat(event_time.replace("Z", "+00:00"))
    return int((occurred_at + timedelta(days=days)).astimezone(UTC).timestamp())


def build_lifecycle_update(
    *,
    detail_type: str,
    detail: dict[str, Any],
    event_time: str,
    event_id: str,
    tombstone_retention_days: int,
) -> dict[str, Any]:
    """Build an idempotent DynamoDB update for one S3 lifecycle event."""
    if detail_type not in SUPPORTED_LIFECYCLE_EVENTS:
        raise ValueError(f"unsupported lifecycle event: {detail_type}")
    if tombstone_retention_days < 1:
        raise ValueError("tombstone_retention_days must be positive")

    rank = _EVENT_RANK[detail_type]
    event_order = f"{event_time}#{rank:02d}#{event_id}"
    fields: dict[str, Any] = {
        "stateChangedAt": event_time,
        "lastLifecycleEventType": detail_type,
        "lastLifecycleEventId": event_id,
        "lastLifecycleEventOrder": event_order,
    }

    if detail_type == "Object Deleted":
        reason = detail.get("reason", "Unknown")
        fields.update(
            {
                "lifecycleState": "DELETED",
                "deleted": True,
                "deletedAt": event_time,
                "deletionReason": (
                    "LIFECYCLE_EXPIRATION"
                    if reason == "Lifecycle Expiration"
                    else "DELETE_OBJECT"
                    if reason == "DeleteObject"
                    else reason.upper().replace(" ", "_")
                ),
                "deletionType": detail.get("deletion-type", "Unknown"),
                "catalogExpiresAt": _epoch_after(event_time, tombstone_retention_days),
            }
        )
    elif detail_type == "Object Storage Class Changed":
        storage_class = detail["destination-storage-class"]
        fields.update(
            {
                "storageClass": storage_class,
                "storageClassChangedAt": event_time,
                "lifecycleState": (
                    "ARCHIVED" if storage_class in ARCHIVE_STORAGE_CLASSES else "AVAILABLE"
                ),
                "restoreStatus": (
                    "NOT_REQUESTED" if storage_class in ARCHIVE_STORAGE_CLASSES else "NOT_REQUIRED"
                ),
            }
        )
        if storage_class in ARCHIVE_STORAGE_CLASSES:
            fields["archivedAt"] = event_time
    elif detail_type == "Object Access Tier Changed":
        access_tier = detail["destination-access-tier"]
        fields.update(
            {
                "accessTier": access_tier,
                "accessTierChangedAt": event_time,
                "lifecycleState": (
                    "ARCHIVED" if access_tier in ARCHIVE_ACCESS_TIERS else "AVAILABLE"
                ),
                "restoreStatus": (
                    "NOT_REQUESTED" if access_tier in ARCHIVE_ACCESS_TIERS else "NOT_REQUIRED"
                ),
            }
        )
        if access_tier in ARCHIVE_ACCESS_TIERS:
            fields["archivedAt"] = event_time
    elif detail_type == "Object Restore Initiated":
        fields.update(
            {
                "storageClass": detail.get("source-storage-class", "GLACIER"),
                "lifecycleState": "RESTORE_PENDING",
                "restoreStatus": "PENDING",
                "restoreRequestedAt": event_time,
            }
        )
    elif detail_type == "Object Restore Completed":
        fields.update(
            {
                "storageClass": detail.get("source-storage-class", "GLACIER"),
                "lifecycleState": "RESTORED",
                "restoreStatus": "RESTORED",
                "restoredAt": event_time,
                "restoreExpiresAt": detail["restore-expiry-time"],
            }
        )
    else:  # Object Restore Expired
        fields.update(
            {
                "lifecycleState": "ARCHIVED",
                "restoreStatus": "EXPIRED",
                "restoreExpiredAt": event_time,
            }
        )

    names = {f"#{name}": name for name in fields}
    values = {f":{name}": value for name, value in fields.items()}
    set_expression = ", ".join(f"#{name} = :{name}" for name in fields)
    condition = (
        "attribute_not_exists(#lastLifecycleEventOrder) "
        "OR #lastLifecycleEventOrder < :lastLifecycleEventOrder"
    )
    if detail_type != "Object Deleted":
        names["#deleted"] = "deleted"
        values[":notDeleted"] = False
        condition = f"({condition}) AND (attribute_not_exists(#deleted) OR #deleted = :notDeleted)"
    return {
        "UpdateExpression": f"SET {set_expression}",
        "ConditionExpression": condition,
        "ExpressionAttributeNames": names,
        "ExpressionAttributeValues": values,
    }
