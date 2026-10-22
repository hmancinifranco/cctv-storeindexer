# Design — Video Archive Prototype

**Spec:** cctv-storeindexer
**Status:** APPROVED — lifecycle-state amendment deployed 2026-10-22
**Last reviewed:** 2026-10-22
**Traceability:** Implements `requirements.md` R1–R15. Requirement IDs are cited per section.
**Phase:** Living source of truth; implementation evidence is tracked in `tasks.md`.

---

## 1. Overview

A serverless AWS prototype that ingests completed surveillance recordings from an on-premises Windows server into private Amazon S3, catalogs each object by parsing camera/date/time from its filename, and exposes an individually authenticated web app to search and download through short-lived presigned URLs, with auditable access. The design SHALL deploy reproducibly to a customer-owned AWS account and support a measured pilot before wider rollout.

Customer evidence corrected 2026-10-21: the proposed flow was accepted; the customer currently manages approximately 90 TB across the complete camera estate, but has not committed to uploading all 90 TB to AWS. Recordings are many small AVI files and downloads are irregular. Target retention discussed is approximately 3 months (90 days). Pilot target remains 3–5 representative cameras, approximately 7 days and 250–500 GB total, subject to confirmation.

Reference diagrams: `architecture/conceptual-architecture.drawio` (technical) and `architecture/client-proposal-aws-icons.drawio` (client).

### 1.1 Component inventory

| Plane | Components |
|-------|-----------|
| Ingestion | Windows Task Scheduler + `aws s3 sync`; IAM technical user → scoped STS uploader role for PoC; IAM Roles Anywhere roadmap |
| Storage | Private S3 video bucket (Standard), private S3 SPA bucket |
| Indexing | S3 EventBridge notifications → EventBridge rule → SQS (+DLQ) → Indexer Lambda → DynamoDB `Catalog` |
| API | CloudFront + global WAF (SPA), API Gateway REST API + regional WAF + Cognito authorizer, Query/Download Lambda |
| Data | DynamoDB `Catalog`, DynamoDB `Audit` |
| Identity | Amazon Cognito User Pool + `Operators` group |
| Audit/Obs | CloudTrail S3 data events, CloudWatch logs/metrics/alarms |

## 2. Ingestion design (R1, R12)

- **Mechanism:** `aws s3 sync <completed-folder> s3://<video-bucket>/<prefix>/` run by Windows Task Scheduler. It copies new/changed objects and supports multipart/retry where applicable. Task configuration prevents overlapping executions and records transfer metrics.
- **PoC credentials:** a unique IAM technical user stores one source access key and has no direct S3 permissions. It can assume only the stack-created uploader role. AWS CLI's `role_arn + source_profile` automatically uses one-hour STS sessions for uploads.
- **Roadmap credentials:** IAM Roles Anywhere replaces the source key. The server holds an X.509 client certificate and `aws_signing_helper` exchanges it for temporary credentials.
- **Key boundary:** CloudFormation never creates, outputs or stores the access key. The customer administrator creates it after the role exists, delivers it securely, and disables/deletes it at pilot close.
- **Upload role:** least privilege — list only the ingest prefix and upload/multipart actions only on `<video-bucket>/<prefix>/*`; no object read or delete.
- **Completeness contract:** preferred design is a VMS export/finalized folder. The PoC uploader additionally requires every AVI to be closed and older than a configurable stability interval before running `aws s3 sync`; if any AVI is not ready, the whole batch is deferred. This preserves one scalable sync invocation without constructing per-file include lists.
- **Scheduling and concurrency:** Task Scheduler runs every 15 minutes by default with `MultipleInstances=IgnoreNew`; the uploader also holds an exclusive lock file for defense in depth. Missed starts run when the server becomes available.
- **Failure/recovery:** AWS CLI standard retry mode uses five attempts. A failed run never deletes source files; the next scheduled run retries the unchanged backlog. Sync never uses `--delete`.
- **Observability:** daily JSONL logs retain 30 days and record eligible file/byte counts, upload operations, elapsed time, exit code, deferred incomplete files and failures.
- **Measured pilot:** capture files/day, GB/day per camera, average/p95/max AVI size, elapsed upload time, effective Mbps, retries, failures, and outage backlog recovery.
- **Capacity formula:** required average bandwidth is calculated from pilot-measured cloud-selected volume and transfer window: `Mbps ≈ GB/day × 8,000 ÷ window_seconds`, plus headroom for TLS/TCP overhead, retries and competing traffic. The pilot determines whether frequent incremental `s3 sync` meets the window. If it does not, evaluate parallel workers or AWS DataSync.
- **Cleanup:** the video bucket defines `AbortIncompleteMultipartUpload` after a configured interval.

## 3. Event-driven indexing (R2)

Flow: `S3 object/lifecycle events → EventBridge → SQS (+DLQ) → Indexer Lambda → DynamoDB Catalog`.

- **Why EventBridge + SQS:** SQS buffers spikes and gives controlled retries; DLQ isolates poison messages; one EventBridge rule handles creation, deletion, storage-class/access-tier changes and restore events without adding a Lambda per transition.
- **Idempotency (R2):** S3 notifications are at-least-once and unordered. Creation uses stable object id + S3 `sequencer`. Lifecycle updates resolve the item through `by-object` and condition on a deterministic `event time + transition rank + event id`; duplicate/older events are no-ops.
- **Lifecycle state:** metadata quality remains in `catalogStatus`; physical availability uses `lifecycleState = AVAILABLE | ARCHIVED | RESTORE_PENDING | RESTORED | DELETED`. Transitions record their individual timestamps and official S3 reason/type.
- **Deletion:** normal search excludes tombstones. Deleted records are retained for a configurable audit period and bounded with DynamoDB TTL; the object itself is never recreated or retained by the catalog.
- **Malformed filenames (R2):** if the parser fails, the item is written with `catalogStatus = INVALID_METADATA`, raw key retained, and a `InvalidFilename` metric emitted (alarm in R9). Never dropped.
- **Failure handling:** a lifecycle event arriving before creation is retried; after `maxReceiveCount` the message moves to the DLQ and its alarm fires (R9).

## 4. Filename grammar & parser (R2, A1)

- **Confirmed input:** recordings are AVI files and are described as many small objects. Exact size distribution and vendor naming convention remain unknown.
- **Default synthetic grammar:** `CAM<id>_YYYYMMDD_HHMMSS[-HHMMSS].<ext>`, timezone `America/Argentina/Buenos_Aires`. It is only a test fixture until 10–20 sanitized real filenames are supplied.
- **Externalized config:** regex/field map, allowed extensions, IANA timezone, and parser version SHALL be deployment configuration, not source-code constants. `.avi` is enabled by default.
- **Output:** `cameraId`, `recordedAtLocal`, `recordedAtUtc`, optional `endsAtUtc`/`durationSec`, `extension`. UTC is derived once at index time and stored.
- **Errors:** unmatched names remain visible as `INVALID_METADATA`, with reason and remediation path; they are never discarded.

## 5. Data model — DynamoDB (R3)

Two tables (separation simplifies IAM and audit isolation; see ADR-005). On-demand capacity for the prototype; PITR enabled.

### 5.1 `Catalog` table

- PK: `DAY#<YYYY-MM-DD>` (local day of recording)
- SK: `TS#<UTC-ISO8601>#CAM#<cameraId>#OBJ#<stableId>`
- GSI `by-camera`: PK `CAM#<cameraId>`, SK `<UTC-ISO8601>#<stableId>`
- Attributes: `objectKey`, `versionId`, `rawFilename`, `cameraId`, `recordedAtUtc`, `recordedAtLocal`, `timezone`, `sizeBytes`, `eTag`, `contentType`, `storageClass`, `accessTier`, `catalogStatus`, `lifecycleState`, `restoreStatus`, `stateChangedAt`, `archivedAt`, `restoreRequestedAt`, `restoredAt`, `restoreExpiresAt`, `deleted`, `deletedAt`, `deletionReason`, `catalogExpiresAt`, `sequencer`, `ingestedAt`, `parserVersion`.

### 5.2 `Audit` table

- PK: `OBJ#<stableId>` (or `USER#<sub>` for user-centric queries)
- SK: `AT#<UTC-ISO8601>#<action>#<requestId>`
- Attributes: `cognitoSub`, `displayName`, `action`, `objectKey`, `sourceIp`, `requestId`, `outcome`, `urlExpirySeconds`. **Never** the presigned URL, tokens, or credentials (R8).

### 5.3 Access patterns (no Scan — R3)

| Pattern | Query |
|---------|-------|
| Videos for a specific day (+time range) | `Catalog` PK=`DAY#date`, SK `begins_with`/`between` on `TS#` |
| Videos for a camera over a time range | GSI `by-camera` PK=`CAM#id`, SK `between` UTC |
| Multi-day date range | Bounded parallel per-day queries, merged via opaque cursor |
| Audit trail for an object | `Audit` PK=`OBJ#id` |

Pagination uses an **opaque base64 cursor** wrapping DynamoDB `LastEvaluatedKey`. No table Scan appears in any path.

**Scale checkpoint:** the current `DAY#YYYY-MM-DD` partition is acceptable for the bounded pilot, but the full estate may generate tens or hundreds of thousands of small AVI files per day and may upload them in bursts. The pilot SHALL measure peak files/second. Before wider rollout, if a day partition approaches DynamoDB hot-key limits, change the primary key to `DAY#<date>#SHARD#<n>` (deterministic hash/camera shard) and merge bounded shard queries. This decision is based on measured peak event rate, not stored TB alone.

## 6. API design — versioned OpenAPI outline (R14, R3–R5)

Base path `/v1`. Auth: Cognito User Pool authorizer on every route. All errors are typed JSON `{ code, message }`.

| Method & path | Purpose | Key responses |
|---------------|---------|---------------|
| `GET /v1/videos?date&from&to&camera&cursor&limit` | Search catalog | 200 page+cursor; 400 `INVALID_QUERY`; 401/403 |
| `POST /v1/videos/{videoId}/download` | Authorize + issue short-lived URL | 200 `{url,expiresAt}`; 403 `FORBIDDEN`; 404 `NOT_FOUND`; 409 `NOT_RETRIEVABLE` (roadmap: `RESTORE_REQUIRED`) |
| `GET /v1/health` | Liveness | 200 |
| *(roadmap)* `POST /v1/videos/{id}/restore`, `GET /v1/videos/{id}/restore-status` | Archive recovery | deferred (5.1 Roadmap) |

The OpenAPI contract is the source for generated API docs and validated in CI (R14). Restore operations are stubbed as roadmap; the download path already returns a typed non-retrievable error so adding them later is additive.

## 7. Authentication & authorization (R7)

- **Cognito User Pool** with hosted UI; group `Operators`. MFA optional in demo, required for production (roadmap).
- **API Gateway** REST API uses the Cognito User Pool authorizer; missing/invalid JWT → 401.
- **Server-side authorization:** the Lambda validates the caller's group/claims and object ownership rules before any action. IP allowlisting is never treated as identity (R7).

## 8. Network perimeter — fail-closed by default (R6)

Controlled by `IP_ALLOWLIST_MODE` in `.env`:

- **`enforce` (default):** defense in depth, all sourced from `OFFICE_ALLOWED_CIDRS`:
  1. **SPA:** CloudFront + **global WAF** WebACL IP set (default block); private SPA bucket via OAC.
  2. **API:** **regional WAF** on the API Gateway REST API stage so the default `execute-api` endpoint cannot bypass the CloudFront allowlist.
  3. **Direct download:** video bucket policy with an **independent** `aws:SourceIp` condition, because a presigned URL bypasses CloudFront/WAF (R6, R8).
  4. **Fail-closed:** empty `OFFICE_ALLOWED_CIDRS` in `enforce` mode fails deployment (template guard). No allow-all default.
- **`disabled` (explicit demo opt-out):** IP restriction skipped when office CIDRs are unknown; Cognito auth + server-side authz still apply. Deliberate, logged, never the default, never triggered by an empty variable.

**WAF is the chosen enforcement.** The no-WAF alternative — CloudFront Function (viewer-address allowlist) + API Gateway resource policy (`aws:SourceIp`) + the same S3 bucket policy — is documented in `docs/network-perimeter-options.md` with its trade-offs (ADR-006).

## 9. Download flow (R4)

1. Validate JWT, role, `videoId`, and source network.
2. `HeadObject` to read **live** storage/retrievability state (never trust UI state).
3. If retrievable (always true for Standard), write `DOWNLOAD_URL_ISSUED` audit and return a presigned URL with TTL = `PRESIGN_TTL_SECONDS` (default 120, parameter).
4. If not retrievable (future archive classes), return typed `NOT_RETRIEVABLE`/`RESTORE_REQUIRED` (roadmap) — never a broken URL.

## 10. Audit design (R8)

- Every URL issuance and (roadmap) restore writes an `Audit` item with the fields in 5.2 — without the URL value.
- **CloudTrail S3 data events** on the video bucket record object-level GET.
- **Documented semantics:** URL issuance and observed GET are distinct facts; a presigned URL is a bearer capability, so the system can prove who *requested* it and that a GET occurred, but not cryptographically that the same human performed the GET (R8, ADR-004).

## 11. Storage lifecycle & cost (R5, R11)

- **Pilot class:** S3 Standard for simplicity and immediate retrieval; pilot data remains until explicit teardown/expiration approval.
- **Target retention:** approximately 90 days for a potential rollout. Customer-account deployment still defaults to `keep` until the lifecycle is approved.
- **Lifecycle candidates:**
  1. `Standard 0–90d → expire` — immediate access and simplest operations.
  2. `Standard 0–30d → Standard-IA 30–90d → expire` — immediate access; Standard-IA 30-day minimum is satisfied.
  3. `Glacier Instant Retrieval 0–90d → expire` — immediate access; 90-day minimum aligned; higher retrieval price must be modeled.
  4. `Glacier Flexible Retrieval 0–90d → expire` — minutes-to-hours restore; only valid if the customer accepts that SLA and the application restore workflow is implemented.
- **Rejected/misleading lifecycle:** `Standard 0–30d → Glacier 30–90d → expire` leaves only 60 days in a class with a 90-day minimum and therefore incurs additional minimum-duration charges. Deep Archive is excluded because its 180-day minimum exceeds the retention target.
- **Object-size constraint:** objects below 128 KB do not transition by default; Standard-IA and Glacier Instant Retrieval have a 128 KB minimum billable object size. The AVI distribution must be measured.
- **Cost model:** `docs/cost-model.md` compares lifecycle choices using selected cloud GB/day and 90-day retention. The current 90 TB estate is an optional sensitivity point, not the proposed upload scope. Include requests/transitions, metadata overhead, retrieval/restore, egress, WAF, CloudTrail and optional DataSync. Validate in AWS Pricing Calculator for the target region.

## 12. Security (R7, R12, R13)

- **Least-privilege IAM** separated by responsibility: the PoC source user can only assume the uploader role; the uploader role can only list/upload under the ingest prefix; indexer writes Catalog; query/download reads Catalog, writes Audit and presigns `s3:GetObject`; audit-reader reads Audit.
- **PoC credential containment:** the access key is customer-created, unique to one technical user, stored only in the Windows AWS CLI credential store with restricted ACLs, and retired at pilot close. The stack creates no credentials.
- **IAM Roles Anywhere roadmap (R12):** reuse the scoped uploader role with a trust anchor/profile and per-server X.509 certificates. The separate runbook covers helper installation, certificate issuance/rotation and revocation.
- **Data protection:** all buckets Block Public Access, TLS-only bucket policies, SSE at rest; CloudFront OAC for the SPA; CORS limited to the SPA origin; no secrets in code.
- **Threat model / abuse cases** to enumerate in tasks: presigned URL sharing, malformed filename flooding, DLQ poisoning, IP spoofing attempts, token replay, over-broad CIDR.

## 13. Infrastructure as code (R13)

- **AWS SAM/CloudFormation**, single app stack with nested/logical grouping (storage, ingestion-IAM, indexing, api, identity, observability).
- **Parameters sourced from `.env`:** `AWS_PROFILE`, `AWS_REGION`, `ENVIRONMENT`, `STACK_NAME`, `OFFICE_ALLOWED_CIDRS`, `VIDEO_BUCKET_NAME`, `RETENTION_MODE`, `RETENTION_DAYS`, `PRESIGN_TTL_SECONDS`, `UPLOADER_IAM_USER_NAME`, and `ROLES_ANYWHERE_ENABLED`. No account IDs/CIDRs/regions/credentials hardcoded (R13).
- **CI gates:** format, lint, type-check, unit tests, `sam validate`/`cfn-lint`, OpenAPI validation, and a secret/URL log scan.

## 14. Observability (R9, R10)

- **Metrics/alarms:** upload failures, `InvalidFilename`, indexing age, DLQ depth, API 4xx/5xx, denied requests, restore failures (roadmap), audit-write failures.
- **Logs:** structured JSON; a redaction guard ensures no presigned URLs, tokens, credentials, or video bytes are logged. WAF logging redacts auth headers/cookies/tokens/query strings; request sampling disabled unless proven safe (R9).
- **SLOs (R10):** search p95 ≤ 2 s; indexing latency ≤ 5 min p95 under A4 volume.

## 15. Frontend design (R14, requirements §5)

React + TypeScript + Material UI with a centralized theme. **Before coding, produce 2–3 distinct full-page mockups and select one** (this is a task, not yet done). Each mockup MUST cover states: search, loading, empty, invalid-metadata, ready, denied, service-error (archived/restore-pending are roadmap). MUI `Table` with server-side pagination + opaque cursor. Tests query accessible roles/labels, not MUI internals.

## 16. Rollback & teardown (R15)

- Stack changes are deployed per environment; rollback = CloudFormation rollback / previous change set.
- **Teardown:** documented script empties and removes demo buckets and deletes the stack; retained items (e.g. CloudTrail logs) are listed with purge steps. No orphaned billable resources.

## 17. Architecture Decision Records

- **ADR-001 PoC ingestion = scheduled `aws s3 sync` + technical IAM user assuming a scoped uploader role.** Accepted as a time-boxed simplification: the user has only `sts:AssumeRole`, the role is write-only to one prefix, the stack never creates keys, and the key is retired at pilot close. IAM Roles Anywhere is the preferred credential roadmap; DataSync remains a future scale option. Consequence: faster PoC setup at the cost of temporarily operating one long-lived source credential.
- **ADR-002 API Gateway REST API (not HTTP API).** AWS WAF associates directly to REST API stages. Consequence: use REST API + Cognito User Pool authorizer.
- **ADR-003 Pilot = S3 Standard; rollout lifecycle selected after measurements.** The pilot optimizes for simplicity. For a 90-day rollout, evaluate Standard, Standard→Standard-IA, Glacier Instant Retrieval, and Glacier Flexible Retrieval against recovery SLA, object size and downloaded GB. Do not assume all 90 TB moves to AWS. Consequence: archive recovery remains unavailable until a Glacier Flexible workflow is explicitly selected and implemented.
- **ADR-004 Audit is correlational, not non-repudiation.** Presigned URL is a bearer token. Consequence: documented limitation; stronger proof deferred.
- **ADR-005 Two DynamoDB tables (Catalog, Audit).** Simpler IAM separation and audit isolation for the prototype vs single-table. Consequence: two access roles; revisit if scale/patterns favor single table.
- **ADR-006 WAF chosen for IP enforcement; no-WAF alternative documented.** WAF gives managed IP sets, centralized logging, and L7 room to grow. Rejected for the prototype but documented: CloudFront Function + API Gateway resource policy + S3 bucket policy achieves the same IP allowlist without WAF's ~$13/mo floor, at the cost of code-managed CIDR lists and weaker logging/observability. See `docs/network-perimeter-options.md`. Consequence: WAF is default; teams optimizing cost can switch using the documented pattern.

## 18. Open decisions for the customer pilot

- Total camera count represented by the current 90 TB estate and selected 3–5 pilot cameras.
- Selected cloud GB/day; do not assume the complete 90 TB estate moves to AWS.
- Files/day plus average, p95 and maximum AVI size.
- Number of Windows recording servers and completed-file folder/rename behavior.
- Available upload bandwidth, permitted transfer window and acceptable outage backlog.
- Pilot retention and rollout target of approximately 90 days.
- Maximum acceptable retrieval time: immediate, minutes, hours or next day; this selects Standard/IA/Glacier and determines whether restore workflow is required.
- Target AWS account access model, region/data residency, stack name and first operator email.
- Office CIDRs and whether `IP_ALLOWLIST_MODE=enforce` must be active on day one.
- 10–20 real sanitized filenames and recording timezone.
- Exact audit expectation and expected downloaded GB/month.

## 19. Approval checkpoint

- [x] Customer confirmed the conceptual flow and phased pilot.
- [x] Current-estate reference (~90 TB) recorded without treating it as committed cloud volume.
- [x] Target retention corrected to approximately 3 months (90 days).
- [ ] Pilot scope, selected cloud volume, recovery SLA and remaining inputs confirmed before customer-account deployment.
