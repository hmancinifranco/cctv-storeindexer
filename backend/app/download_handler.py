"""Download-authorization Lambda — POST /v1/videos/{videoId}/download (design §9).

Authorizes the caller (Cognito group), re-checks live S3 state (HeadObject),
issues a short-lived presigned URL, and writes a DOWNLOAD_URL_ISSUED audit item
that never contains the URL (R4, R8).
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from typing import Any

from .download_core import AuthzError, authorize, build_audit_item, is_retrievable


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _claims(event: dict[str, Any]) -> tuple[str, str, list[str]]:
    """Extract Cognito subject, display name, and groups from the authorizer."""
    claims = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("claims", {})
    )
    sub = claims.get("sub", "unknown")
    name = claims.get("email") or claims.get("cognito:username") or sub
    raw_groups = claims.get("cognito:groups", "")
    groups = raw_groups.split(",") if isinstance(raw_groups, str) else list(raw_groups or [])
    return sub, name, [g for g in groups if g]


def handler(event: dict[str, Any], _context: Any = None) -> dict:
    import boto3

    video_id = (event.get("pathParameters") or {}).get("videoId")
    if not video_id:
        return _response(400, {"code": "INVALID_QUERY", "message": "missing videoId"})

    sub, display_name, groups = _claims(event)
    bucket = os.environ["VIDEO_BUCKET"]
    ttl = int(os.environ.get("PRESIGN_TTL_SECONDS", "120"))
    request_id = event.get("requestContext", {}).get("requestId", "unknown")
    source_ip = (
        event.get("requestContext", {}).get("identity", {}).get("sourceIp", "unknown")
    )

    dynamodb = boto3.resource("dynamodb")
    catalog = dynamodb.Table(os.environ["CATALOG_TABLE"])
    audit = dynamodb.Table(os.environ["AUDIT_TABLE"])
    s3 = boto3.client("s3")

    # Resolve the object AUTHORITATIVELY from the catalog by videoId (stableId).
    # The client never supplies the S3 key, so a caller cannot presign an
    # arbitrary object — only a real cataloged one (R4, security).
    resolved = catalog.query(
        IndexName="by-object",
        KeyConditionExpression="GSI2PK = :oid",
        ExpressionAttributeValues={":oid": f"OBJ#{video_id}"},
        Limit=1,
    )
    catalog_items = resolved.get("Items", [])
    catalog_item = catalog_items[0] if catalog_items else {}
    object_key = catalog_item.get("objectKey")
    is_deleted = catalog_item.get("deleted", False) or catalog_item.get(
        "lifecycleState"
    ) == "DELETED"

    try:
        authorize(groups=groups, object_exists=bool(object_key) and not is_deleted)
    except AuthzError as err:
        status = 403 if err.code == "FORBIDDEN" else 404
        return _response(status, {"code": err.code, "message": err.message})

    # Live S3 state recheck (never trust client/UI state).
    try:
        head = s3.head_object(Bucket=bucket, Key=object_key)
    except Exception:  # noqa: BLE001
        return _response(404, {"code": "NOT_FOUND", "message": "object not in bucket"})

    storage_class = head.get("StorageClass", "STANDARD")
    if not is_retrievable(storage_class, head.get("Restore")):
        return _response(
            409, {"code": "RESTORE_REQUIRED", "message": "object requires restoration"}
        )

    url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": object_key},
        ExpiresIn=ttl,
    )

    now = datetime.now(timezone.utc).isoformat()
    audit.put_item(
        Item=build_audit_item(
            stable_id=video_id,
            object_key=object_key,
            cognito_sub=sub,
            display_name=display_name,
            source_ip=source_ip,
            request_id=request_id,
            outcome="OK",
            url_expiry_seconds=ttl,
            at_utc=now,
        )
    )
    return _response(200, {"url": url, "expiresInSeconds": ttl})
