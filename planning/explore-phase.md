# Explore Phase — Video Archive Prototype

**Status:** Living source of truth
**Last reviewed:** 2026-10-22
**Decision boundary:** This document refines the problem and recommends a planning baseline. It does not authorize implementation or deployment.

## 1. Outcome

The prototype is feasible as a serverless AWS application. The recommended baseline is:

1. A scheduled `aws s3 sync` task on the Windows Server uses a unique IAM technical user only to assume a scoped uploader role, then moves completed recordings to a private Amazon S3 bucket over TLS. IAM Roles Anywhere is the credential roadmap; AWS DataSync remains a future scale option.
2. Completed S3 uploads emit events to Amazon EventBridge, which delivers them through Amazon SQS to an idempotent indexer Lambda.
3. The indexer parses camera/date/time from the object key, preserves the raw filename, and writes searchable metadata to Amazon DynamoDB.
4. A React/TypeScript/Material UI single-page application is served from a private S3 origin through Amazon CloudFront with Origin Access Control.
5. AWS WAF applies a fail-closed office-IP allowlist. Amazon Cognito authenticates individual users; IP allowlisting alone is insufficient for access attribution.
6. An authenticated API searches DynamoDB and issues short-lived S3 presigned download URLs only for authorized, currently retrievable objects.
7. The application records who requested each URL; AWS CloudTrail S3 data events record object-level GET activity. These are related but distinct audit facts.
8. Amazon S3 Lifecycle is parameterized, but the cold-storage class is not selected until retention and recovery-time requirements are confirmed.

## 2. Refined problem statement

Today, retrieval is manual and depends on infrastructure staff. The target outcome is a self-service catalog for a small authorized user population, likely HR and selected operational staff, while keeping video objects private and minimizing cost for infrequent retrieval.

The application is not a live camera viewer, video analytics platform, transcoder, or replacement VMS. It inventories completed files, searches metadata, initiates restoration when necessary, and authorizes downloads.

## 3. Scope for the customer prototype

### In scope

- Simulated or real Windows-origin upload of completed files to S3.
- Automatic metadata extraction from an agreed filename/key contract.
- Idempotent cataloging and visible handling of malformed filenames.
- Search by calendar date, time range, and camera; paginated results.
- User login and server-side authorization.
- Office egress-IP restriction on UI, API, and direct S3 downloads.
- Short-lived download URL generation.
- Audit of login, search where required, URL issuance, restore request, and object access.
- Lifecycle/restore behavior represented correctly in UI and API.
- AWS SAM templates, automated tests, OpenAPI documentation, architecture diagram, and setup/runbook documentation.

### Explicitly out of scope unless planning reopens it

- Live streaming, playback optimization, transcoding, thumbnails, AI/ML analysis, facial recognition, or motion detection.
- Direct Connect, site-to-site VPN, multi-region active/active, mobile application, and external customer tenancy.
- Production migration of historical recordings.
- Regulatory certification or a final production retention policy.
- Automatic deletion of source files before end-to-end upload verification.

## 4. Architecture hypothesis

### 4.1 Ingestion

The nightly batch decision and automatic indexing are compatible: upload can be scheduled nightly, while every completed object is cataloged event-by-event.

**Updated PoC baseline:** a scheduled `aws s3 sync` runs on the existing Windows recording server. A unique IAM technical user's access key is used only as a source credential to assume a one-hour uploader role. The user has no direct S3 access; the role can list/upload only under the configured prefix and cannot read/delete. The key is retired at pilot close. IAM Roles Anywhere is the preferred credential roadmap after the customer selects a PKI approach.

**Documented future/scale improvement — AWS DataSync from an SMB share:** stronger managed transfer, scheduling, checksum verification, bandwidth control, and operational reporting, at the cost of deploying and operating a DataSync agent VM. Revisit when volume/file count grows, or when the customer prefers zero uploader code and has the operational maturity to run the agent.

The prototype SHOULD include a synthetic uploader/test fixture and a stable object-key contract while the final source integration is confirmed. For the PoC, the IAM source user MUST have no direct S3 permissions and MUST only assume the exact uploader role. The access key MUST never appear in code/configuration and MUST be retired at pilot close. IAM Roles Anywhere SHOULD replace it before production or extended use.

For large recordings and unstable links, the managed or custom transfer path MUST use multipart upload with bounded concurrency, retry/backoff, and resumability appropriate to the selected client. The S3 bucket MUST define `AbortIncompleteMultipartUpload` cleanup so abandoned parts do not accumulate cost. Indexing starts only after multipart completion.

### 4.2 Event-driven catalog

Recommended path: `S3 Object Created -> EventBridge -> SQS + DLQ -> Indexer Lambda -> DynamoDB`.

SQS provides buffering and controlled retries. The indexer MUST be idempotent: S3 notifications are at-least-once, can be duplicated, and are not globally ordered. Store the S3 `sequencer`, object `versionId` when available, bucket/key, ETag, and a stable object identifier. Ignore duplicate or older events for the same object through a conditional DynamoDB write.

Malformed filenames are a business event, not a silent exception. Catalog them with `INVALID_METADATA` (or route to an explicit quarantine prefix/table), retain the raw key, emit a metric, and expose an operator remediation path.

### 4.3 Filename contract

No parser can be finalized without real samples. Planning MUST obtain at least 20 representative filenames across cameras, dates, midnight boundaries, re-recordings, and error cases. Define:

- timezone and daylight-saving behavior;
- camera identifier vocabulary;
- recording start and optional end/duration;
- extension and codec/container;
- collision behavior and whether files can be overwritten;
- treatment of spaces, accents, URL encoding, and vendor-specific suffixes.

The parser SHOULD be a versioned strategy with explicit regex/schema configuration, not scattered string splitting.

### 4.4 DynamoDB access model

Avoid table scans. Initial key hypothesis:

- Catalog PK: `DAY#YYYY-MM-DD`.
- Catalog SK: `TS#<UTC-ISO8601>#CAMERA#<camera-id>#OBJ#<stable-id>`.
- Camera GSI PK: `CAMERA#<camera-id>`.
- Camera GSI SK: `<UTC-ISO8601>#<stable-id>`.

A date-range query spanning multiple days performs bounded parallel queries per day and merges pages through an opaque cursor. This is appropriate for low-frequency human searches and distributes write load. Planning MUST validate expected files/day and cameras before accepting this model.

Suggested attributes: `objectKey`, `versionId`, `rawFilename`, `cameraId`, `recordedAtUtc`, `recordedAtLocal`, `timezone`, `sizeBytes`, `eTag`, `contentType`, `storageClass`, `catalogStatus`, `restoreStatus`, `restoreExpiry`, `sequencer`, `ingestedAt`, and parser version.

Use a separate audit table or clearly isolated audit entity type. Audit records SHOULD include authenticated Cognito subject, display identity, action, object ID, timestamp, source IP supplied by the trusted API boundary, request ID, outcome, and URL expiry—never the URL itself.

### 4.5 Web access perimeter

Recommended defense in depth:

- CloudFront + global WAF Web ACL/IP set for the SPA, default block.
- Private S3 frontend bucket with Block Public Access and CloudFront OAC.
- Cognito login plus an API Gateway REST API Cognito User Pool authorizer for individual identity.
- Regional WAF/IP restriction on the API Gateway REST API stage so the default execute-api endpoint cannot bypass the CloudFront allowlist.
- Private video bucket with an independent bucket-policy source-IP condition for direct S3 `GetObject`, because an S3 presigned URL bypasses CloudFront and its WAF.
- Short URL expiration, proposed 60–300 seconds, finalized in threat modeling.

The office must provide stable public egress CIDRs, including IPv4 and IPv6 behavior. A dynamic residential-style IP or split-tunnel VPN would make a strict allowlist unreliable. Deployment MUST fail closed when no CIDR is configured.

Cognito remains necessary: an IP identifies an office gateway, not a person. WAF should be treated as a location restriction and attack-control layer, not authorization.

### 4.6 Search and download API hypothesis

Versioned OpenAPI operations for planning:

- `GET /v1/videos?date=&from=&to=&camera=&cursor=&limit=`
- `POST /v1/videos/{videoId}/download`
- `POST /v1/videos/{videoId}/restore`
- `GET /v1/videos/{videoId}/restore-status`

Download behavior:

1. Validate JWT claims, role, requested object, and source network.
2. Read current object/storage state; do not trust stale UI state.
3. If immediately retrievable, write `DOWNLOAD_URL_ISSUED` audit and return a short-lived URL.
4. If archived, return a typed `RESTORE_REQUIRED` response or accept a restore request; do not issue a broken URL.
5. Consume S3 `Object Restore Completed` through EventBridge to update retrievability, while still verifying current S3 state before presigning.
6. Log S3 `GetObject` through CloudTrail data events.

A presigned URL is a bearer capability and can be shared during its lifetime. Therefore the system can prove which authenticated user requested the URL and whether a matching object GET occurred, but cannot cryptographically prove that the same human performed the GET. If strict non-repudiation is required, planning must evaluate a different delivery mechanism or accept this documented limitation.

### 4.7 Storage lifecycle

The meeting assumption “Glacier is cheaper” is not yet a decision. If retention is only one or two months, Glacier can cost more or create unusable recovery behavior:

- S3 Standard-IA has a 30-day minimum and millisecond retrieval.
- S3 Glacier Instant Retrieval, Flexible Retrieval, and their early deletion charges use a 90-day minimum.
- S3 Glacier Deep Archive uses a 180-day minimum.
- Flexible Retrieval and Deep Archive are not real-time; restore is required before download.
- Flexible/Deep Archive add 40 KB metadata overhead per archived object, relevant when there are many small files.

Planning MUST model at least: object count/day, average and p95 file size, GB/day, retention, monthly retrieval GB, retrieval urgency, and restore-request frequency. Candidate outcomes:

- Retention <= 60 days: S3 Standard then Standard-IA/expiration is likely simpler; validate cost.
- Retention >= 90 days and immediate access required: evaluate Glacier Instant Retrieval.
- Retention >= 90 days and 3–5 hour recovery acceptable: evaluate Glacier Flexible Retrieval plus restore workflow.
- Retention >= 180 days and 12–48 hour recovery acceptable: evaluate Deep Archive.

### 4.8 Security and operations

Minimum controls for the prototype:

- Least-privilege roles, encryption at rest, TLS, S3 Block Public Access, secrets excluded from code, and no presigned URLs in logs.
- CloudWatch structured logs/metrics/alarms for upload failures, invalid filenames, indexing age, DLQ depth, API errors, denied requests, restore failures, and audit-write failures.
- WAF logging with sensitive fields redacted; request sampling MUST be disabled or proven not to capture authorization headers, cookies, tokens, or presigned query strings.
- CloudTrail data events for the video bucket.
- CORS restricted to the approved frontend origin.
- Retention/deletion controls require explicit approval and are not tested against customer data.
- Threat model before deployment.

GuardDuty Malware Protection for S3 can scan new uploads and tag results, but CCTV files originate from an appliance and scanning large daily volume adds cost. Treat it as a planning decision based on threat model and supported size/quota, not an automatic MVP requirement.

## 5. Frontend exploration

Use React + TypeScript + Material UI. Before implementation, produce 2–3 genuinely distinct full-page mockups and select one. The recommended information architecture is:

- login/status header with environment and signed-in user;
- primary filter panel: date, from/to time, camera, search/reset;
- paginated result table with date/time, camera, filename, size, storage state, and action;
- plain-language states for empty results, invalid metadata, archived, restore pending, ready, denied, and failed;
- confirmation/status feedback for restoration and download preparation.

Material UI `Table` is suitable for the prototype; use server-side pagination and an opaque cursor. Move to MUI X Data Grid only if planning establishes large interactive result sets or richer grid requirements. Tests should use accessible roles/labels, not MUI component internals.

## 6. Open questions — required before design approval

### Customer and compliance

1. Exact VMS/DVR/NVR product and version on each server? GeoVision is plausible but unconfirmed.
2. Does the installed product provide a supported export/API/S3 integration? Public search found GeoVision cloud and backup products, but no reliable evidence of native Amazon S3 export for the customer's installation.
3. Who can search, restore, and download? Are there roles beyond HR?
4. What constitutes sufficient audit evidence: URL requested, download started, or download completed?
5. Regulatory/privacy requirements, legal hold, deletion, data residency, and minimum/maximum retention?
6. Is MFA required? What identity source should Cognito federate with, if any?

### Data and network

7. Measured GB/day, files/day, average/p95/max file size, and peak nightly transfer window?
8. At least 20 real sanitized filenames and their expected parsed metadata?
9. Stable office public IPv4/IPv6 CIDRs and behavior over VPN/failover links?
10. Available upload bandwidth and maximum acceptable backlog after an outage?
11. Can the recording server run a scheduled task with outbound HTTPS (443) and an IAM Roles Anywhere certificate (baseline uploader)? Separately, for the future DataSync option only: can the customer host a DataSync agent and expose the recording location over SMB?
12. When can a recording be considered complete and safe to upload/delete locally?

### Retrieval and cost

13. Formal retention period and expected growth?
14. Maximum acceptable recovery time: milliseconds, minutes, hours, or days?
15. Retrieval frequency measured as requests/month and GB/month?
16. Must users stream/preview in browser, or is file download sufficient?

## 7. Acceptance gates for leaving Planning

Planning is approved only when:

- requirements contain 10–15 testable EARS-style MVP requirements;
- every open question is answered, explicitly assumed, or deferred with impact;
- filename grammar and examples are documented;
- access patterns validate the DynamoDB keys without scans;
- IP restriction covers UI, API, and direct download paths;
- the audit claim is precisely worded and testable;
- storage-class choice is backed by retention/retrieval inputs and cost modeling;
- archived-object UX/API behavior is defined;
- threat model and least-privilege boundaries are reviewed;
- 2–3 UI mockups are reviewed and one selected;
- SAM stacks, environments, tests, API contract, observability, documentation, and deployment/cleanup tasks are enumerated;
- no customer production data or production account is used for prototype validation.

## 8. Evidence consulted

### Official AWS

- S3 Event Notifications delivery semantics: https://docs.aws.amazon.com/AmazonS3/latest/userguide/EventNotifications.html
- Duplicate/order handling with sequencer: https://aws.amazon.com/blogs/storage/manage-event-ordering-and-duplicate-events-with-amazon-s3-event-notifications/
- CloudFront private S3 origin/OAC: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
- CloudFront content restriction with WAF IP control: https://repost.aws/knowledge-center/cloudfront-content-restriction
- Cognito User Pool authorizer for API Gateway REST APIs: https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html
- AWS WAF association with an API Gateway REST API stage: https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-control-access-aws-waf.html
- Presigned URL request identification: https://docs.aws.amazon.com/prescriptive-guidance/latest/presigned-url-best-practices/identifying-requests.html
- DynamoDB date-range queries: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/example_dynamodb_Scenario_DateTimeQueries_section.html
- Glacier storage-class comparison: https://docs.aws.amazon.com/AmazonS3/latest/userguide/glacier-storage-classes.html
- Lifecycle cost pitfalls and small-object overhead: https://docs.aws.amazon.com/AmazonS3/latest/userguide/troubleshoot-lifecycle.html
- Archived-object restore behavior: https://docs.aws.amazon.com/AmazonS3/latest/userguide/archival-storage.html
- IAM Roles Anywhere: https://docs.aws.amazon.com/help-panel/rolesanywhere/latest/console/hp-roles-anywhere.html
- DataSync SMB metadata behavior: https://docs.aws.amazon.com/datasync/latest/userguide/metadata-copied.html
- GuardDuty Malware Protection for S3: https://docs.aws.amazon.com/guardduty/latest/ug/s3-malware-protection-capability.html

### Framework references

- Material UI tables: https://llms.mui.com/material-ui/7.3.11/react-table.md
- Material UI testing: https://llms.mui.com/material-ui/7.3.11/guides/testing.md

## 9. Customer evidence update — 2026-10-21

The customer confirmed that the proposed flow matches the intended process and requested a gradual rollout through a bounded pilot.

- Current local estate: approximately **90 TB across all cameras**; this is a sizing reference, not confirmed cloud-upload scope.
- Target retention discussed: approximately **3 months (90 days)**.
- Recordings: many small `.avi` files; exact file count, size distribution and selected cloud GB/day remain unknown.
- Retrieval: irregular — multiple requests in some weeks and no downloads in others.
- Pilot intent: limited cameras and days to measure upload/download time, operational complexity and actual AWS cost before scaling.
- Recommended planning range: **3–5 representative cameras, approximately 7 days and 250–500 GB total**, subject to customer confirmation.

This evidence makes selected cloud GB/day, upload bandwidth, files/second, object-size distribution and recovery SLA first-class pilot metrics. It also reopens DataSync as a possible transfer option and Standard-IA/Glacier as lifecycle candidates for a 90-day rollout, based on measured access and restore requirements.

## 10. Explore conclusion

Proceed to a fresh Kiro **Spec** session using `planning/sdd-kickoff-prompt.md`. Do not start from a generic “build this app” request: the next session must first resolve or explicitly assume the blocking questions, then generate and review requirements, design, and tasks.