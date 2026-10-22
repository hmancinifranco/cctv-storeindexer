"""Tests for download_core (T5.4): authorization + audit item excludes URL."""

from __future__ import annotations

import unittest

from backend.app.download_core import AuthzError, authorize, build_audit_item, is_retrievable


class AuthorizeTest(unittest.TestCase):
    def test_operator_allowed(self) -> None:
        authorize(groups=["Operators"], object_exists=True)  # no raise

    def test_missing_object(self) -> None:
        with self.assertRaises(AuthzError) as ctx:
            authorize(groups=["Operators"], object_exists=False)
        self.assertEqual(ctx.exception.code, "NOT_FOUND")

    def test_wrong_group(self) -> None:
        with self.assertRaises(AuthzError) as ctx:
            authorize(groups=["Viewers"], object_exists=True)
        self.assertEqual(ctx.exception.code, "FORBIDDEN")

    def test_wrong_group_cannot_enumerate_missing_object(self) -> None:
        with self.assertRaises(AuthzError) as ctx:
            authorize(groups=["Viewers"], object_exists=False)
        self.assertEqual(ctx.exception.code, "FORBIDDEN")

    def test_no_groups(self) -> None:
        with self.assertRaises(AuthzError):
            authorize(groups=None, object_exists=True)


class AuditItemTest(unittest.TestCase):
    def test_excludes_url_and_has_fields(self) -> None:
        item = build_audit_item(
            stable_id="abc",
            object_key="videos/x.mp4",
            cognito_sub="sub-1",
            display_name="hugo",
            source_ip="1.2.3.4",
            request_id="req-1",
            outcome="OK",
            url_expiry_seconds=120,
            at_utc="2026-09-24T12:00:00+00:00",
        )
        serialized = str(item).lower()
        self.assertNotIn("x-amz-signature", serialized)
        self.assertNotIn("https://", serialized)
        self.assertEqual(item["PK"], "OBJ#abc")
        self.assertEqual(item["action"], "DOWNLOAD_URL_ISSUED")
        self.assertEqual(item["cognitoSub"], "sub-1")


class RetrievableTest(unittest.TestCase):
    def test_immediate_classes_retrievable(self) -> None:
        self.assertTrue(is_retrievable("STANDARD"))
        self.assertTrue(is_retrievable("STANDARD_IA"))
        self.assertTrue(is_retrievable("GLACIER_IR"))
        self.assertTrue(is_retrievable(None))

    def test_archive_requires_completed_restore(self) -> None:
        self.assertFalse(is_retrievable("GLACIER"))
        self.assertFalse(is_retrievable("DEEP_ARCHIVE"))
        self.assertFalse(is_retrievable("GLACIER", 'ongoing-request="true"'))
        self.assertTrue(
            is_retrievable(
                "GLACIER",
                'ongoing-request="false", expiry-date="Thu, 29 Oct 2026 00:00:00 GMT"',
            )
        )


if __name__ == "__main__":
    unittest.main()
