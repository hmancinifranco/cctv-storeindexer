"""Download-authorization core (design §9, §10; R4, R8). Pure/unit-testable.

Decides whether a caller may receive a presigned URL, and builds the audit item
recorded when a URL is issued. The audit item NEVER contains the presigned URL,
tokens, or credentials (R8) — only who requested it, for which object, when, and
from where.
"""

from __future__ import annotations

from dataclasses import dataclass

REQUIRED_GROUP = "Operators"


@dataclass(frozen=True)
class AuthzError(Exception):
    code: str  # "FORBIDDEN" | "NOT_FOUND"
    message: str


def authorize(*, groups: list[str] | None, object_exists: bool) -> None:
    """Raise AuthzError if the caller may not download the object."""
    if not object_exists:
        raise AuthzError("NOT_FOUND", "object not found in catalog")
    if not groups or REQUIRED_GROUP not in groups:
        raise AuthzError("FORBIDDEN", f"caller must be in {REQUIRED_GROUP}")


def build_audit_item(
    *,
    stable_id: str,
    object_key: str,
    cognito_sub: str,
    display_name: str,
    source_ip: str,
    request_id: str,
    outcome: str,
    url_expiry_seconds: int,
    at_utc: str,
) -> dict:
    """Build the DynamoDB Audit item for a URL-issuance event.

    Deliberately excludes the presigned URL and any token/credential (R8).
    """
    return {
        "PK": f"OBJ#{stable_id}",
        "SK": f"AT#{at_utc}#DOWNLOAD_URL_ISSUED#{request_id}",
        "action": "DOWNLOAD_URL_ISSUED",
        "objectKey": object_key,
        "cognitoSub": cognito_sub,
        "displayName": display_name,
        "sourceIp": source_ip,
        "requestId": request_id,
        "outcome": outcome,
        "urlExpirySeconds": url_expiry_seconds,
        "at": at_utc,
    }


def is_retrievable(storage_class: str | None, restore_header: str | None = None) -> bool:
    """Return whether S3 can serve the object without initiating a restore.

    Glacier Instant Retrieval is immediately available. Flexible Retrieval and
    Deep Archive require a completed temporary restore, represented by S3's
    ``ongoing-request=\"false\"`` HeadObject header.
    """
    immediate_classes = {
        None,
        "",
        "STANDARD",
        "STANDARD_IA",
        "ONEZONE_IA",
        "INTELLIGENT_TIERING",
        "GLACIER_IR",
        "EXPRESS_ONEZONE",
    }
    if storage_class in immediate_classes:
        return True
    if storage_class in {"GLACIER", "DEEP_ARCHIVE"}:
        return bool(restore_header and 'ongoing-request="false"' in restore_header)
    return False
