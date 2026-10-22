"""Lifecycle-state tests: archive, restore, deletion, expiry and ordering."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from backend.app.lifecycle_core import build_lifecycle_update, event_object_identity


def _values(detail_type: str, detail: dict | None = None) -> dict:
    request = build_lifecycle_update(
        detail_type=detail_type,
        detail=detail or {},
        event_time="2026-10-22T13:00:00Z",
        event_id="event-1",
        tombstone_retention_days=365,
    )
    return request["ExpressionAttributeValues"]


def test_event_identity_accepts_official_hyphenated_version_id() -> None:
    detail = {
        "bucket": {"name": "bucket"},
        "object": {"key": "videos/a.avi", "version-id": "v1"},
    }
    assert event_object_identity(detail) == ("bucket", "videos/a.avi", "v1")


def test_lifecycle_expiration_creates_retained_tombstone() -> None:
    values = _values(
        "Object Deleted",
        {"reason": "Lifecycle Expiration", "deletion-type": "Permanently Deleted"},
    )
    assert values[":lifecycleState"] == "DELETED"
    assert values[":deleted"] is True
    assert values[":deletionReason"] == "LIFECYCLE_EXPIRATION"
    expected = int(datetime(2027, 10, 22, 13, tzinfo=timezone.utc).timestamp())
    assert values[":catalogExpiresAt"] == expected


def test_manual_deletion_has_distinct_reason() -> None:
    values = _values("Object Deleted", {"reason": "DeleteObject"})
    assert values[":deletionReason"] == "DELETE_OBJECT"


@pytest.mark.parametrize(
    ("storage_class", "state", "restore_status"),
    [
        ("GLACIER", "ARCHIVED", "NOT_REQUESTED"),
        ("DEEP_ARCHIVE", "ARCHIVED", "NOT_REQUESTED"),
        ("GLACIER_IR", "AVAILABLE", "NOT_REQUIRED"),
        ("STANDARD_IA", "AVAILABLE", "NOT_REQUIRED"),
    ],
)
def test_storage_transition_models_retrieval_behavior(
    storage_class: str, state: str, restore_status: str
) -> None:
    values = _values(
        "Object Storage Class Changed",
        {"destination-storage-class": storage_class},
    )
    assert values[":storageClass"] == storage_class
    assert values[":lifecycleState"] == state
    assert values[":restoreStatus"] == restore_status


def test_restore_lifecycle_records_dates() -> None:
    pending = _values(
        "Object Restore Initiated", {"source-storage-class": "GLACIER"}
    )
    assert pending[":lifecycleState"] == "RESTORE_PENDING"
    assert pending[":restoreRequestedAt"] == "2026-10-22T13:00:00Z"

    restored = _values(
        "Object Restore Completed",
        {
            "source-storage-class": "GLACIER",
            "restore-expiry-time": "2026-10-29T13:00:00Z",
        },
    )
    assert restored[":lifecycleState"] == "RESTORED"
    assert restored[":restoreExpiresAt"] == "2026-10-29T13:00:00Z"

    expired = _values("Object Restore Expired")
    assert expired[":lifecycleState"] == "ARCHIVED"
    assert expired[":restoreStatus"] == "EXPIRED"


def test_update_rejects_duplicate_and_older_events() -> None:
    request = build_lifecycle_update(
        detail_type="Object Deleted",
        detail={"reason": "DeleteObject"},
        event_time="2026-10-22T13:00:00Z",
        event_id="event-1",
        tombstone_retention_days=365,
    )
    assert "#lastLifecycleEventOrder < :lastLifecycleEventOrder" in request[
        "ConditionExpression"
    ]
    assert request["ExpressionAttributeValues"][":lastLifecycleEventOrder"].endswith(
        "#90#event-1"
    )


def test_non_delete_event_cannot_revive_tombstone() -> None:
    request = build_lifecycle_update(
        detail_type="Object Restore Completed",
        detail={
            "source-storage-class": "GLACIER",
            "restore-expiry-time": "2026-10-29T13:00:00Z",
        },
        event_time="2026-10-23T13:00:00Z",
        event_id="event-after-delete",
        tombstone_retention_days=365,
    )
    assert "attribute_not_exists(#deleted) OR #deleted = :notDeleted" in request[
        "ConditionExpression"
    ]
    assert request["ExpressionAttributeValues"][":notDeleted"] is False


def test_rejects_unknown_event() -> None:
    with pytest.raises(ValueError, match="unsupported lifecycle event"):
        _values("Object Created")
