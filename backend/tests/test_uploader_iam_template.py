"""Security invariants for the simplified PoC uploader IAM design."""

from __future__ import annotations

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = (REPO_ROOT / "infra" / "template.yaml").read_text()
PROFILE_SCRIPT = (REPO_ROOT / "uploader" / "iam-user" / "configure-profile.ps1").read_text()
UPLOAD_SCRIPT = (REPO_ROOT / "uploader" / "iam-user" / "upload-videos.ps1").read_text()
REGISTER_TASK_SCRIPT = (REPO_ROOT / "uploader" / "iam-user" / "register-task.ps1").read_text()
REMOVE_TASK_SCRIPT = (REPO_ROOT / "uploader" / "iam-user" / "remove-task.ps1").read_text()


class UploaderIamTemplateTest(unittest.TestCase):
    def setUp(self) -> None:
        start = TEMPLATE.index("  RaUploadRole:")
        end = TEMPLATE.index("  RaProfile:", start)
        self.role_section = TEMPLATE[start:end]

    def test_stack_never_creates_access_keys(self) -> None:
        self.assertNotIn("AWS::IAM::AccessKey", TEMPLATE)
        self.assertNotIn("iam:CreateAccessKey", TEMPLATE)
        self.assertIn("UploaderMechanismRequired", TEMPLATE)
        self.assertNotIn("AccessKeyId:", TEMPLATE)
        self.assertNotIn("SecretAccessKey:", TEMPLATE)

    def test_source_user_can_assume_only_the_uploader_role(self) -> None:
        self.assertIn("UploaderUserAssumeRolePolicy", TEMPLATE)
        self.assertIn('Action: "sts:AssumeRole"', TEMPLATE)
        self.assertIn("Resource: !GetAtt RaUploadRole.Arn", TEMPLATE)
        self.assertNotIn('Action: "sts:*"', TEMPLATE)

    def test_role_trusts_exact_configured_user_not_account_root(self) -> None:
        self.assertIn("user/${UploaderIamUserName}", self.role_section)
        self.assertNotIn(":root", self.role_section)
        self.assertNotIn('AWS: "*"', self.role_section)

    def test_uploader_role_is_write_only_to_ingest_prefix(self) -> None:
        self.assertIn('"s3:PutObject"', self.role_section)
        self.assertIn('"s3:AbortMultipartUpload"', self.role_section)
        self.assertIn("${VideoBucket.Arn}/${IngestPrefix}/*", self.role_section)
        self.assertNotIn('"s3:GetObject"', self.role_section)
        self.assertNotIn('"s3:DeleteObject"', self.role_section)
        self.assertNotIn('"s3:*"', self.role_section)

    def test_windows_script_uses_source_and_role_profiles(self) -> None:
        self.assertIn("source_profile", PROFILE_SCRIPT)
        self.assertIn("role_arn", PROFILE_SCRIPT)
        secret_field = "aws_" + "secret_access_key"
        self.assertNotIn("aws_access_key_id", PROFILE_SCRIPT.lower())
        self.assertNotIn(secret_field, PROFILE_SCRIPT.lower())

    def test_sync_never_deletes_destination_or_source(self) -> None:
        self.assertNotIn("'--delete'", UPLOAD_SCRIPT)
        self.assertIn("'--no-follow-symlinks'", UPLOAD_SCRIPT)
        self.assertIn("'--include', '*.avi'", UPLOAD_SCRIPT)
        self.assertIn("[System.IO.FileShare]::None", UPLOAD_SCRIPT)

    def test_sync_has_overlap_retry_and_backlog_controls(self) -> None:
        self.assertIn("upload.lock", UPLOAD_SCRIPT)
        self.assertIn("AWS_RETRY_MODE", UPLOAD_SCRIPT)
        self.assertIn("AWS_MAX_ATTEMPTS", UPLOAD_SCRIPT)
        self.assertIn("DEFERRED_INCOMPLETE_FILES", UPLOAD_SCRIPT)
        self.assertIn("SYNC_FAILED", UPLOAD_SCRIPT)

    def test_scheduled_task_does_not_embed_credentials(self) -> None:
        self.assertIn("#Requires -RunAsAdministrator", REGISTER_TASK_SCRIPT)
        self.assertIn("Get-Credential", REGISTER_TASK_SCRIPT)
        self.assertIn("Copy-Item", REGISTER_TASK_SCRIPT)
        self.assertIn("CctvUploader\\bin", REGISTER_TASK_SCRIPT)
        self.assertIn("CctvUploader\\logs", REGISTER_TASK_SCRIPT)
        self.assertIn("icacls.exe", REGISTER_TASK_SCRIPT)
        self.assertIn("MultipleInstances IgnoreNew", REGISTER_TASK_SCRIPT)
        self.assertIn("StartWhenAvailable", REGISTER_TASK_SCRIPT)
        self.assertNotIn("ExecutionPolicy Bypass", REGISTER_TASK_SCRIPT)
        secret_field = "aws_" + "secret_access_key"
        self.assertNotIn(secret_field, REGISTER_TASK_SCRIPT.lower())

    def test_task_removal_requires_powershell_confirmation(self) -> None:
        self.assertIn("SupportsShouldProcess", REMOVE_TASK_SCRIPT)
        self.assertIn("ConfirmImpact = 'High'", REMOVE_TASK_SCRIPT)
        self.assertIn("Disable-ScheduledTask", REMOVE_TASK_SCRIPT)
        self.assertIn("Unregister-ScheduledTask", REMOVE_TASK_SCRIPT)


if __name__ == "__main__":
    unittest.main()
