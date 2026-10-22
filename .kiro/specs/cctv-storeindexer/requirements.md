# Requirements — Video Archive Prototype

**Spec:** cctv-storeindexer
**Status:** APPROVED — lifecycle-state amendment deployed 2026-10-22
**Last reviewed:** 2026-10-22
**Phase:** Living source of truth; implementation evidence is tracked in `tasks.md`.

---

## 1. Purpose

Deliver a customer-demonstrable AWS prototype that ingests completed video-surveillance files from an on-premises Windows recording server into private Amazon S3, automatically catalogs each file by parsing camera/date/time from its filename, lets an authenticated and IP-restricted user search by date/time/camera, and authorizes controlled download through a short-lived presigned URL, while recording auditable access events.

The prototype SHALL be portable to a customer-owned AWS account. The customer confirmed that the proposed flow matches the intended process and requested a phased pilot with a limited number of cameras and retention days before scaling. The PoC ingestion baseline is a scheduled `aws s3 sync` on the Windows server using an IAM technical user's access key only to assume a scoped, write-only uploader role. IAM Roles Anywhere is the preferred roadmap mechanism to remove that long-lived source credential; the pilot SHALL measure whether `s3 sync` is sufficient before AWS DataSync is selected for larger scale.

## 2. Actors

- **Operator** — authorized customer user (initially HR/operations) who searches, requests restore, and downloads.
- **Uploader** — the scheduled process on the Windows server that transfers completed recordings to S3.
- **Indexer** — backend process that catalogs uploaded objects.
- **Auditor** — role that reviews access/audit records (may be the same person as Operator in the prototype).
- **Operator/SA (us)** — deploys and operates the demo.

## 3. Customer evidence and pilot register

The customer validated the proposed end-to-end flow on 2026-10-21. The following evidence replaces the earlier 500 GB/month placeholder for the complete estate. Unknown values remain explicit and SHALL be measured during the pilot.

| ID | Evidence / pilot decision | Design impact | Validation owner |
|----|---------------------------|---------------|------------------|
| A1 | Filename grammar remains pending. Files are confirmed as many small `.avi` objects; proceed with the configurable default grammar only for synthetic testing until 10–20 sanitized real names are supplied. Default timezone remains `America/Argentina/Buenos_Aires`. | Parser, local-time search, DynamoDB keys | Customer |
| A2 | Target cloud retention discussed is approximately **3 months (90 days)**. The exact pilot and rollout retention must be confirmed before deployment. Customer deployment SHALL default to `keep` until lifecycle expiration is explicitly approved. | Lifecycle, recovery UX, teardown, cost | Customer / compliance |
| A3 | Pilot starts in **S3 Standard** for simplicity. For a 90-day rollout, compare: Standard for all 90 days; Standard → Standard-IA at day 30; direct placement in Glacier Instant Retrieval for immediate access; and direct placement in Glacier Flexible Retrieval only if restore delays are acceptable. Deep Archive does not fit a 90-day target because its minimum is 180 days. | Cost and retrieval UX | Customer + SA |
| A4 | Customer currently manages approximately **90 TB across the complete camera estate**, but this is not a confirmed cloud-upload volume. Selected cameras, cloud GB/day, total camera count, file count, AVI size distribution, server count, peak upload rate and transfer window remain unknown. Pilot planning range remains **250–500 GB total**, 3–5 representative cameras and approximately 7 days, subject to confirmation. | Network, transfer mechanism, event rate, DynamoDB partitioning, SLOs, cost | Customer + SA pilot measurements |
| A5 | Single Cognito role `Operator` for the pilot (search+download). MFA remains required before production use. | Authorization | Customer |
| A6 | IP allowlist controlled by `.env`: `enforce` requires approved office CIDRs and full enforcement on CloudFront, API, and direct S3 download; `disabled` is allowed only for an explicitly approved pilot. CIDRs are still pending. | Network perimeter | Customer |
| A7 | Downloads are irregular: they may occur more than once in a week or not occur for several weeks. Audit semantics remain URL issuance plus observed S3 GET, not proof of the human who used the bearer URL. | Egress scenarios and audit wording | Customer / SA |
| A8 | Target is now a customer-owned AWS account. Account access method, region, stack name, first operator email, and data-residency requirements must be confirmed in preflight. `us-east-1` remains the tested reference region. | Deployment | Customer + SA |
| A9 | No archive state in the pilot; S3 Standard is immediately retrievable. Archive/recovery remains roadmap. | Retrieval UX | SA |

---

## 4. Requirements (EARS)

### R1 — Ingestion (baseline uploader)

The system SHALL ingest completed recordings from the Windows server into a private S3 video bucket using a scheduled `aws s3 sync` over TLS. For the PoC, a unique IAM technical user MAY provide the long-lived source credential only when it has no direct S3 access and can assume exactly one scoped uploader role that vends temporary credentials.

- WHEN the scheduled task runs, the uploader SHALL transfer only new or changed **completed** objects, SHALL prevent overlapping executions, and SHALL use multipart upload with automatic retry where applicable.
- The uploader role SHALL allow only listing the configured ingest prefix plus upload/multipart actions under that prefix; object read, delete and access outside the prefix SHALL be denied by omission.
- The stack SHALL NOT create, output, log, or store an IAM access key. Key creation and secure delivery remain an explicit customer-administrator action.
- The source user SHALL be unique to this workload, SHALL NOT have console access or broad managed policies, and its key SHALL be disabled or deleted at pilot close.
- IAM Roles Anywhere SHOULD replace the source access key before production or extended operation.
- The pilot SHALL record per-camera GB/day, files/day, average/p95/max object size, elapsed upload time, effective Mbps, failed/retried files, and backlog recovery after an interruption.
- The source contract SHALL use a completed-file export folder, temporary-extension rename, or a configurable stability interval; a file still being written SHALL NOT become downloadable from the archive.
- Acceptance: the source user can assume only the uploader role; the role can upload only to the configured prefix and cannot read/delete; a scheduled run copies completed files to S3; re-running copies nothing unchanged; an in-progress file is excluded; transfer uses TLS; an interrupted transfer resumes without duplicate catalog entries; no key appears in IaC, logs, outputs, or Git.

### R2 — Automatic idempotent indexing (incl. malformed filenames)

WHEN an object is created in the video bucket, the system SHALL catalog it exactly once into DynamoDB via `S3 ObjectCreated → EventBridge → SQS(+DLQ) → indexer Lambda`.

- The indexer SHALL be idempotent: duplicate or out-of-order S3 events for the same object SHALL NOT create duplicate or regressed catalog entries (conditional write keyed on stable object id + `sequencer`).
- IF a filename fails the parser, THEN the system SHALL persist a catalog entry with status `INVALID_METADATA` (or route to a quarantine entity), retain the raw key, and emit a metric — it SHALL NOT silently drop the object.
- WHEN repeated delivery fails, the message SHALL land in the DLQ without blocking the queue.
- WHEN S3 reports deletion, storage-class transition, access-tier transition, restore initiation, restore completion, or restore expiry, THEN the system SHALL update the existing catalog item idempotently without a table Scan.
- A storage transition SHALL NOT be treated as deletion. The catalog SHALL distinguish `AVAILABLE`, `ARCHIVED`, `RESTORE_PENDING`, `RESTORED`, and `DELETED` and record the corresponding transition timestamps.
- A deletion SHALL retain a tombstone containing `deletedAt`, whether the cause was `DELETE_OBJECT` or `LIFECYCLE_EXPIRATION`, and the S3 deletion type. Normal searches SHALL exclude tombstones; an explicit administrative query MAY include them.
- Tombstones SHALL expire through configurable DynamoDB TTL after the approved audit period so catalog growth is bounded.
- The filename grammar SHALL be an externalized, versioned configuration (not hardcoded); documentation SHALL explain how to adapt it per customer deployment (see A1).
- Acceptance: valid file → searchable entry; duplicate event → single entry; malformed name → `INVALID_METADATA` + metric; poison message → DLQ; the grammar can be changed via configuration without code edits.

### R3 — Search by date, time, and camera

WHEN an authenticated Operator submits a search by calendar date, time range, and/or camera, the system SHALL return matching catalog entries with server-side pagination and SHALL NOT perform a DynamoDB table Scan.

- Each result SHALL expose recording date/time (local + UTC), camera, filename, size, storage/restore status, and the available action.
- WHERE a query is invalid (e.g. `from` > `to`, a camera-only range lacks full timezone-aware ISO timestamps, or a cursor is malformed/tampered), the system SHALL return a typed `INVALID_QUERY` 400, not empty success or an unhandled 500.
- Acceptance: date-range and camera queries return correct pages via an opaque cursor; no Scan in query paths; invalid range → typed 4xx.

### R4 — Download authorization and short-lived URL

WHEN an authorized Operator requests a download for a retrievable object, the system SHALL re-check current S3 object/storage state and SHALL return a presigned URL with a short expiration (proposed 60–300 s, parameterized).

- The system SHALL authorize the request server-side (identity, role, object, source network) before issuing any URL.
- The system SHALL NOT trust client/UI state for retrievability; it SHALL read live S3 state before presigning (keeps the path forward-compatible if colder/archive classes are added later).
- Acceptance: authorized+retrievable → short-lived URL issued and audited; unauthorized → 403 and no URL; TTL matches the configured parameter.

### R5 — Retention lifecycle (configurable at deploy)

The system SHALL apply an S3 retention lifecycle driven by deploy-time configuration in `.env`: WHERE `RETENTION_MODE=expire`, objects SHALL be deleted `RETENTION_DAYS` after creation; WHERE `RETENTION_MODE=keep`, no automatic deletion SHALL be configured.

- A customer-account deployment SHALL default to `RETENTION_MODE=keep` until the customer explicitly approves automatic expiration.
- The pilot SHALL use an agreed retention period appropriate to the selected cameras and test duration; the current on-premises reference is 30 days.
- Objects SHALL remain in S3 Standard for the pilot; no automatic Standard-IA/Glacier transition SHALL be configured.
- Changing retention SHALL require only a configuration change and redeploy — no code edit.
- Acceptance: with `keep` no expiration rule exists; with explicitly approved `expire`/N the bucket expires objects after N days; the selected value is displayed during preflight and recorded in deployment evidence.

### R6 — Network perimeter (fail-closed by default, explicit opt-out)

WHERE `IP_ALLOWLIST_MODE=enforce` (default), the system SHALL restrict access to approved office source CIDRs across every path: CloudFront+WAF for the SPA, a regional WAF/IP restriction on the API Gateway REST API stage (so the default execute-api endpoint cannot bypass the allowlist), and an independent S3 bucket-policy source-IP condition for direct presigned `GetObject`.

- IF `IP_ALLOWLIST_MODE=enforce` AND `OFFICE_ALLOWED_CIDRS` is empty at deploy, THEN deployment SHALL fail closed (no allow-all default).
- WHERE `IP_ALLOWLIST_MODE=disabled` (explicit opt-out for the demo when office CIDRs are unknown), the system SHALL skip IP restriction but SHALL still enforce Cognito authentication and server-side authorization (R7); this mode MUST be set deliberately and logged — it is never the default and never reached by an empty variable.
- WAF is the chosen enforcement (ADR-002/ADR-006); the no-WAF alternative (CloudFront Function + API Gateway resource policy + S3 bucket policy) and its trade-offs are documented.
- Acceptance: with `enforce`+CIDR, allowed CIDR succeeds and non-allowed is denied on UI/API/download; with `enforce`+empty, deploy is blocked; with `disabled`, access is open at the network layer but still requires a valid Cognito identity.

### R7 — Individual authentication and server-side authorization

The system SHALL authenticate individual users with Amazon Cognito and SHALL authorize actions server-side; IP allowlisting SHALL NOT be treated as user identity.

- Unauthenticated API requests SHALL be rejected by the Cognito User Pool authorizer.
- Acceptance: no/invalid token → 401/403; valid token without the required role → 403; valid Operator → authorized.

### R8 — Auditable access events

The system SHALL record auditable events for URL issuance, restore requests, and (via CloudTrail S3 data events) object-level GET, with precise semantics.

- Audit records SHALL include authenticated Cognito subject, action, object id, timestamp, trusted source IP, request id, outcome, and URL expiry — and SHALL NOT store the presigned URL, tokens, or credentials.
- Documentation SHALL state that URL issuance and observed GET are related but distinct facts and that a presigned URL is a bearer capability (no proof of which human performed the GET).
- Acceptance: issuing a URL writes an audit record without the URL value; CloudTrail records the GET; docs state the bearer-URL limitation.

### R9 — Observability and safe logging

The system SHALL emit structured logs, metrics, and alarms for upload failures, invalid filenames, indexing age, DLQ depth, API errors, denied requests, restore failures, and audit-write failures; and logs SHALL NOT contain presigned URLs, tokens, credentials, or video content.

- WHERE WAF logging is enabled, it SHALL redact authorization headers, cookies, tokens, and presigned query strings, and request sampling SHALL be disabled unless proven not to capture sensitive fields.
- Acceptance: alarms exist for the listed conditions; a log scan finds no secret material; WAF logs are redacted.

### R10 — Pilot performance and scalability measurements

The system SHALL meet prototype SLOs: a typical single-day search returns within 2 s p95, and a completed upload becomes searchable within 5 minutes under the measured pilot event rate.

- The pilot SHALL measure upload throughput and backlog recovery against the available customer uplink. Required bandwidth SHALL be calculated from the measured cloud-selected GB/day and allowed transfer window: `Mbps ≈ GB/day × 8,000 ÷ window_seconds`, plus operational headroom.
- The pilot SHALL load-test the indexing path at the measured peak files/second, not an assumed estate-wide rate. If the day partition approaches a hot-key limit, design SHALL introduce camera/hash sharding before wider rollout.
- Acceptance: search p95 ≤ 2 s; indexing latency ≤ 5 min p95 at pilot peak; upload metrics establish whether scheduled `aws s3 sync` can meet the target window or whether DataSync/parallel transfer must be evaluated.

### R11 — Cost guardrails and scenario model

The system SHALL define `AbortIncompleteMultipartUpload` cleanup, SHALL keep retention configurable, and SHALL provide P×Q scenarios based on the **selected cloud volume**, 90-day target retention, object count/size, retrieval SLA and downloaded GB. The current 90 TB estate SHALL be shown only as an optional sensitivity point, never as committed cloud scope.

- Pilot SHALL use S3 Standard. Rollout analysis SHALL compare:
  1. Standard for 90 days (immediate access, simplest operations).
  2. Standard for 30 days → Standard-IA for 60 days → expire at day 90 (immediate access; 30-day IA minimum satisfied).
  3. Direct Glacier Instant Retrieval placement for 90 days (immediate access; 90-day minimum aligned).
  4. Direct Glacier Flexible Retrieval placement for 90 days only if minutes-to-hours restore is acceptable and the restore workflow is implemented.
- A transition into a 90-day-minimum Glacier class at day 30 followed by expiration at day 90 SHALL show the extra minimum-duration charge; it SHALL NOT be presented as an optimized lifecycle.
- Deep Archive SHALL be excluded for a 90-day target because its minimum duration is 180 days.
- Cost inputs SHALL include stored GB by class/days, file-count request and transition charges, Glacier metadata overhead where applicable, restore/retrieval charges, indexing events, CloudTrail data events, downloaded GB, WAF and optional DataSync.
- Acceptance: the model supports camera/GB/day scenarios and lifecycle comparison; list prices and region/date are identified; no single 90 TB Standard total is presented as the proposed solution or a quote.

### R12 — Uploader credential roadmap

For the PoC, the system SHALL provide a customer-owned IAM-user-to-role bootstrap path with least privilege and explicit key retirement. IAM Roles Anywhere SHALL remain a documented and validated roadmap option for replacing the source access key with certificate-based temporary credentials.

- The PoC runbook SHALL cover unique technical-user creation, exact `sts:AssumeRole` scoping, two-profile AWS CLI configuration, local credential-file protection, role-session verification and key retirement.
- The Roles Anywhere roadmap SHALL cover certificate issuance/rotation, `aws_signing_helper` credential-process configuration, trust anchor/profile/role setup, per-server certificates and revocation.
- Acceptance: the technical user has no direct S3 access; the assumed uploader role can upload only to the configured prefix and cannot read/delete; no key appears in IaC/Git/output; Roles Anywhere migration is reproducible from its separate runbook.

### R13 — Infrastructure as code and configuration hygiene

The system SHALL be defined with AWS SAM/CloudFormation, and all account-specific/non-pushable values (AWS profile, account, region, office CIDRs, ARNs, bucket names) SHALL come from a git-ignored `.env` (template `.env.example`) or template parameters — never hardcoded or committed.

- All S3 buckets SHALL block public access, require TLS, and encrypt at rest; static assets SHALL be served via CloudFront OAC.
- Acceptance: `git` contains no account values or secrets; deploy uses the `.env` profile; buckets are private/encrypted; a linter/template validation passes in CI.

### R14 — Documentation

The system SHALL provide a customer-facing README and walkthroughs for prerequisites, deployment, Windows uploader setup, user creation, verification, operations, troubleshooting, cost estimation, and teardown. The OpenAPI contract SHALL remain versioned and validated, and non-obvious decisions SHALL be recorded as ADRs.

- Documentation SHALL use placeholders or generated outputs, never demo passwords, account IDs, ARNs, bucket names, tokens, or internal Amazon links.
- Acceptance: a minimally AWS-experienced reviewer can deploy from a clean checkout, configure one Windows uploader, create the first operator, verify an upload/search/download, and understand the remaining limitations using only the supplied documentation.

### R15 — Safe teardown and cleanup

The system SHALL provide a reproducible teardown with a read-only plan mode and two explicit outcomes: retain customer video/audit data or permanently purge all PoC data.

- Retain-data SHALL be the safe default for a customer account.
- Purge-data SHALL require explicit confirmation and SHALL remove non-empty buckets, stack resources, the CLI-created Roles Anywhere trust anchor, and any SSM certificate parameters.
- Acceptance: a clean-room rehearsal proves both the resource plan and complete purge on disposable data; post-teardown inventory shows no unintended billable resources, and retained resources are listed explicitly.

---

## 5. Non-goals

- Live streaming, playback optimization, transcoding, thumbnails, AI/ML analysis, facial recognition, motion detection.
- Direct Connect, site-to-site VPN, multi-region active/active, mobile app, external customer tenancy.
- Production migration of historical recordings; regulatory certification; final production retention policy.
- Automatic deletion of source files before end-to-end upload verification.
- Treating IP allowlisting as user authentication.

## 5.1 Roadmap (post-prototype)

Deliberately deferred. The prototype is designed to remain forward-compatible so these can be added without rework:

- **90-day storage optimization:** compare Standard, Standard→Standard-IA, Glacier Instant Retrieval and Glacier Flexible Retrieval using measured selected-cloud volume, object size and recovery SLA.
- **Archive + recovery flow:** if Glacier Flexible Retrieval is selected, implement typed `RESTORE_REQUIRED`, restore initiation, `Object Restore Completed`, restore status and user notifications before rollout.
- **Longer retention:** consider Deep Archive only if the policy extends beyond its 180-day minimum.
- **Mandatory MFA** before production access.

## 6. Traceability and exit

- Each requirement (R1–R15) MUST map to design components and tasks and carry acceptance evidence before implementation.
- Design MUST NOT begin until this document is approved. On approval, proceed to `design.md` per `planning/sdd-kickoff-prompt.md`.

## 7. Approval checkpoint

- [x] Customer confirmed the proposed end-to-end flow and phased-pilot approach on 2026-10-21.
- [x] Current-estate reference recorded: approximately 90 TB across all cameras, many small AVI files, irregular retrieval; cloud-selected volume remains unknown.
- [x] Target retention corrected to approximately 3 months (90 days); lifecycle/storage class remains a decision based on recovery SLA and measurements.
- [ ] Pilot camera count, pilot retention, region, office CIDRs, Windows source contract, real filename samples and restore SLA confirmed.
- [x] Requirements R1–R15 remain the approved MVP scope with this evidence amendment.
- [x] Non-goals confirmed.
