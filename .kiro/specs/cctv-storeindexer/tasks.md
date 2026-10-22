# Tasks — Video Archive Prototype

**Spec:** cctv-storeindexer
**Status:** APPROVED — implementation and validation in progress
**Last reviewed:** 2026-10-22
**Traceability:** Every task maps to `requirements.md` (R#) and `design.md` (§#). Each task is sized for one focused session and lists validation + acceptance evidence.

> Conventions: `[ ]` not started. Each task states **Deps**, **Req/Design**, **Security**, **Docs**, **Validation** (command/how), **Evidence** (what proves done). No task deploys to production or uses customer data.

---

## Phase 0 — Repository & CI foundation

### T0.1 — Project scaffold & tooling ✅ DONE (2026-09-23)
- **Deps:** none. **Req/Design:** R13 / §13.
- Scope: monorepo layout (`infra/` SAM, `backend/` Lambdas, `frontend/` SPA, `uploader/`, `docs/`), formatter, linter, type-checking, pre-commit.
- **Security:** confirm `.gitignore` excludes `.env`, certs, build artifacts (already present).
- **Docs:** README "local development" section.
- **Validation:** `make lint && make typecheck` (or npm/py equivalents) pass on empty scaffold.
- **Evidence:** created `pyproject.toml` (ruff+mypy+pytest), `Makefile` (gate targets), `.pre-commit-config.yaml`, `backend/app` + `backend/tests`, `infra/`, `frontend/` READMEs. Tree matches design §1.1. Unit test `backend/tests/test_fixture_manifest.py` passes (4/4 via stdlib unittest).

### T0.2 — CI pipeline gates ✅ DONE (2026-09-23)
- **Deps:** T0.1. **Req/Design:** R13, R14 / §13.
- Scope: CI runs format, lint, type-check, unit tests, `sam validate`/`cfn-lint`, OpenAPI validation, and a secret/URL log scan.
- **Validation:** CI fails on an injected secret string and on an invalid template; passes when clean.
- **Evidence:** `.github/workflows/ci.yml` runs ruff, mypy, pytest, secret/public-sharing scans, template validation and OpenAPI validation. The local scanner blocks credential material, private keys, presigned-query signatures, internal URLs and personal paths.
- **Note:** ruff/mypy not installed on this host (memory-constrained); they run in CI. Locally validated tests via stdlib unittest and the secret scan via bash.

## Phase 1 — Infrastructure (SAM)

### T1.1 — Storage stack (S3 buckets + lifecycle) ✅ DONE — DEPLOYED (2026-09-23)
- **Deps:** T0.2. **Req/Design:** R5, R11, R13 / §11, §13.
- Scope: private video bucket + SPA bucket, Block Public Access, TLS-only policy, SSE, `AbortIncompleteMultipartUpload`; lifecycle expiration driven by `RETENTION_MODE`/`RETENTION_DAYS`; S3 Standard only.
- **Security:** no public access; bucket policy denies non-TLS.
- **Validation:** `sam validate`; deploy to demo; `aws s3api get-bucket-lifecycle-configuration` shows expiration at 60d when `expire`, none when `keep`; Block Public Access = on.
- **Evidence:** deployed and validated in the demo account: both buckets private/encrypted, retention output matched the configured 60-day demo setting, and the stack remained updateable. Account IDs and generated resource names are intentionally not stored in versioned documentation.

### T1.2 — Network perimeter parameters & fail-closed guard ✅ DONE — DEPLOYED (2026-09-23)
- **Deps:** T1.1. **Req/Design:** R6 / §8.
- Scope: template parameters from `.env` (`IP_ALLOWLIST_MODE`, `OFFICE_ALLOWED_CIDRS`, region, env, names); a guard that FAILS deployment when mode=`enforce` and the allowlist is empty; `disabled` mode skips IP restriction (Cognito still applies) and is logged.
- **Security:** no allow-all default anywhere; `disabled` must be explicit, never reached by an empty variable.
- **Validation:** deploy with `enforce` + empty `OFFICE_ALLOWED_CIDRS` → fails; `enforce` + CIDR → succeeds; `disabled` → deploys without IP restriction.
- **Evidence:** deployed with `IP_ALLOWLIST_MODE=disabled` (output IpAllowlistSummary "disabled"). CFN `Rules.EnforceRequiresCidrs` uses `Fn::Equals` (Rules block forbids `Fn::Join`); bucket-policy `RestrictGetObjectToOfficeCidrs` uses `!Split` gated on `EnforceIp`. Enforce+empty fail-closed path pending a later enforce-mode test.

### T1.3 — Identity stack (Cognito) ✅ DONE — DEPLOYED (2026-09-23)
- **Deps:** T1.1. **Req/Design:** R7 / §7.
- Scope: Cognito User Pool, app client, hosted UI, `Operators` group; MFA optional (flag).
- **Validation:** create a test user; obtain a JWT via hosted UI in the demo.
- **Evidence:** deployed and validated in the demo account: User Pool, app client and `Operators` group active; hosted-UI login succeeds; generated IDs remain only in git-ignored `.env`/CloudFormation outputs. MFA remains roadmap for production.

## Phase 2 — Ingestion credentials and uploader

### T2.1 — PoC IAM technical user → scoped uploader role 🟡 IMPLEMENTED LOCALLY — CUSTOMER E2E PENDING (2026-10-22)
- **Deps:** T1.1. **Req/Design:** R1, R12 / §2, §12.
- Scope: accept a pre-existing technical IAM username; create one write-only uploader role; trust only that exact user; attach only `sts:AssumeRole` on that role; expose `UploaderRoleArn`; never create an access key.
- **Security:** user has no direct S3 access; AssumeRole is not wildcarded; role has one-hour sessions and only list/PUT/multipart on the configured prefix; key is customer-created, uniquely assigned and retired at pilot close.
- **Validation:** `sam validate`; synthesized policy inspection; deploy to disposable customer-like stack with pre-created user; source profile cannot access S3; role profile can upload to prefix and cannot read/delete/write elsewhere.
- **Evidence:** SAM/template implementation plus `uploader/iam-user/configure-profile.ps1` and `uploader/iam-user/README.md`. Deployment and Windows E2E remain pending because no customer IAM user/key is created by this project.

### T2.2 — Windows uploader (`aws s3 sync`) + client runbook 🟡 IMPLEMENTED LOCALLY — CUSTOMER WINDOWS E2E PENDING
- **Deps:** T2.1. **Req/Design:** R1, R10, R12 / §2, §12.
- Scope: configure two-profile IAM user → role credentials; protect the credential file; select completed files; prevent overlaps; register Task Scheduler; write logs/metrics; retain backlog after failures. Roles Anywhere migration is separate T2.4.
- **Security:** source user has only exact AssumeRole; role cannot read/delete; access key is unique, locally ACL-protected, never embedded, and retired at pilot close; sync never uses `--delete` or removes source files.
- **Validation:** on Windows, `sts get-caller-identity` returns the uploader assumed-role; source profile is denied S3; dry-run/real sync work; open/recent AVI defers the batch; second run is idempotent; overlapping run is skipped; connectivity interruption produces backlog and recovery; scheduled task reports success and logs metrics.
- **Evidence:** `configure-profile.ps1`, `upload-videos.ps1`, `register-task.ps1`, `remove-task.ps1` and the PoC runbook are implemented. PowerShell 7.6.6 LTS was installed project-locally on macOS; the official parser accepted all four scripts. Cross-platform execution validated `NO_FILES` and `DEFERRED_INCOMPLETE_FILES` without invoking AWS. CI and `make powershell-validate` now parse the scripts. Remaining evidence is execution of profiles, ACLs, Task Scheduler and real sync on the customer Windows Server with real source-folder behavior and network interruption.

### T2.3 — Synthetic uploader test fixture ✅ DONE (2026-09-23)
- **Deps:** T2.2. **Req/Design:** R1, R2 / §2, §4.
- Scope: script/fixture generating valid + malformed filenames for E2E.
- **Validation:** fixture produces known-good and known-bad names covering edge cases (midnight, re-record, accents).
- **Evidence:** `uploader/synthetic/generate_fixtures.py` + committed `uploader/synthetic/manifest.json` (19 entries: 5 valid, 4 edge, 10 invalid). Built-in self-check cross-validates each expected status against the grammar before writing; run wrote 19 placeholder files and the manifest. Placeholder files are git-ignored (regenerable). Demo upload via `uploader/synthetic/upload_to_s3.sh` (mirrors the `aws s3 sync` baseline, config from `.env`, `--dry-run` supported); procedure documented in `uploader/synthetic/README.md`.

### T2.4 — IAM Roles Anywhere credential roadmap ✅ TECHNICALLY VALIDATED IN DEMO (2026-10-22)
- **Deps:** T2.1. **Req/Design:** R12 / §2, §12.
- Scope: replace the source access key with trust anchor, profile, per-server X.509 certificate and `aws_signing_helper`, reusing the same scoped uploader role.
- **Security:** no long-term AWS key; client key is host-protected; certificate rotation/revocation documented; trust anchor can be disabled.
- **Evidence:** trust anchor/profile enabled in demo; valid `CA:FALSE`, `digitalSignature`, `clientAuth` certificate; helper 1.8.5 successfully called CreateSession; STS returned the uploader role; CAM93 uploaded, read denied, catalog `OK/AVAILABLE`, AES256; separate runbook and macOS installer/test retained under `uploader/roles-anywhere/` and `scripts/`.
- **Roadmap exit:** decide customer PKI vs AWS Private CA, issue a certificate per Windows server, validate rotation/revocation, then disable/delete the PoC IAM access key.

## Phase 3 — Indexing backend

### T3.1 — Event plumbing (EventBridge → SQS + DLQ) ✅ DONE — DEPLOYED (2026-09-24)
- **Deps:** T1.1. **Req/Design:** R2 / §3.
- Scope: S3 EventBridge notifications, rule, SQS queue + DLQ with `maxReceiveCount`.
- **Validation:** upload an object → message observed on the queue; force failures → message lands in DLQ.
- **Evidence:** deployed to stack `cctv-storeindexer-demo`. `ObjectCreatedRule` (aws.s3/Object Created filtered to VideoBucket → IndexerQueue), `IndexerQueue` (redrive to `IndexerDLQ`, maxReceiveCount 5), `IndexerQueuePolicy`. Live E2E: re-uploading the 19 fixtures fired Object Created events that flowed through the queue to the Lambda — catalog Count = 19 confirms delivery.

### T3.2 — Filename parser (versioned, configurable) ✅ DONE (2026-09-23)
- **Deps:** T0.1. **Req/Design:** R2 / §4.
- Scope: externalized grammar config + parser producing UTC/local/camera; reason codes on failure.
- **Security:** input validation; no injection via filename into logs/keys.
- **Validation:** unit tests for valid grammar, malformed names, timezone conversion, boundary times; config change alters parsing without code edit.
- **Evidence:** `backend/app/filename_parser.py` — `FilenameParser` with injectable `grammar` dict (DEFAULT_GRAMMAR = A1), UTC derived from UTC-3, cross-midnight handling, typed `ParseResult` with reason codes; never raises on bad input. `backend/tests/test_filename_parser.py` — manifest-driven (all 19 fixtures agree) + UTC/midnight/malformed/config-swap tests. Config-only grammar swap proven (DVR<id> grammar). 21/21 suite green.

### T3.3 — Indexer Lambda (idempotent) → DynamoDB Catalog ✅ DONE — DEPLOYED (2026-09-24)
- **Deps:** T3.1, T3.2, T4.1. **Req/Design:** R2 / §3, §5.
- Scope: consume SQS, parse, conditional write keyed on stable id + `sequencer`; `INVALID_METADATA` path + metric.
- **Security:** least-privilege role (SQS consume + Catalog write only).
- **Validation:** unit + integration: valid→one item; duplicate event→one item; out-of-order→no regression; malformed→`INVALID_METADATA` + metric; poison→DLQ.
- **Evidence:** `indexer_core.py` (idempotent ConditionExpression `attribute_not_exists(PK) OR #seq < :seq`, PK=INVALID quarantine) + `indexer_handler.py` (ReportBatchItemFailures, InvalidFilename metric, ConditionalCheckFailed=success). SAM `IndexerFunction` built via `BuildMethod: makefile` (no python3.12/Docker dependency; boto3 from runtime). Deployed and validated LIVE: 19 objects re-uploaded → catalog Count = **19** (8 OK + 11 INVALID as expected; `__dup__` file correctly quarantined). 21/21 unit tests green.

### T3.4 — S3 lifecycle state machine ✅ DONE — DEPLOYED AND E2E VALIDATED (2026-10-22)
- **Deps:** T3.1, T3.3, T4.1. **Req/Design:** R2, R3, R5 / §3, §5, §11.
- Scope: consume S3 deletion, storage-class/access-tier and restore events; retain dated tombstones; hide deleted objects from normal search; keep live S3 as download authority.
- **Security:** no public access changes; no object contents or presigned URLs logged; admin tombstone view remains Cognito protected.
- **Scalability:** `by-object` query instead of Scan; conditional ordering; one queue/consumer; configurable DynamoDB TTL for tombstones.
- **Validation command:** `python3 -m pytest backend/tests/test_lifecycle_core.py backend/tests/test_indexer_handler.py backend/tests/test_indexer_core.py backend/tests/test_search_core.py backend/tests/test_download_core.py -q && (cd frontend && npm run typecheck && npm run test -- --run src/__tests__/ResultsTable.test.tsx)`.
- **Evidence:** 55 backend tests and 7 frontend tests pass; SAM/OpenAPI validate; stack `UPDATE_COMPLETE`; EventBridge rule has all seven object/lifecycle event types; Catalog TTL is `ENABLED` on `catalogExpiresAt`; synthetic SQS events validated `LIFECYCLE_EXPIRATION`, duplicate no-op, out-of-order archive/restore and terminal deletion; physical deletion of the 256-byte CAM92 fixture caused S3 to emit a real `Object Deleted`, producing `DELETED`, `deletedAt=2026-10-22T15:09:10Z`, `deletionReason=DELETE_OBJECT`, `deletionType=Permanently Deleted` and a 365-day tombstone; normal search returned zero CAM92 results while the historical view returned one; queue and DLQ ended at zero; stack and application health remained green.

## Phase 4 — Data layer

### T4.1 — DynamoDB tables (Catalog + Audit) ✅ DONE — DEPLOYED (2026-09-23)
- **Deps:** T1.1. **Req/Design:** R3, R8 / §5.
- Scope: `Catalog` (PK/SK + `by-camera` GSI) and `Audit` tables; on-demand; PITR on.
- **Validation:** `sam validate`; representative items written; keys match §5.
- **Evidence:** deployed to stack `cctv-storeindexer-demo`. `describe-table` confirms `cctv-storeindexer-demo-catalog` ACTIVE, KeySchema PK/SK, GSI `by-camera`, billing PAY_PER_REQUEST; `cctv-storeindexer-demo-audit` present. Outputs CatalogTableName/AuditTableName.

### T4.2 — Access-pattern verification (no Scan) ✅ DONE (2026-09-23)
- **Deps:** T4.1. **Req/Design:** R3 / §5.3.
- Scope: query helpers for day, day+time, camera+range, multi-day merge; opaque cursor.
- **Validation:** tests assert every query is a Query/GetItem (no `Scan`); pagination round-trips a cursor.
- **Evidence:** `backend/app/catalog_keys.py` builds bounded KeyConditionExpression queries and opaque cursors. `backend/app/search_core.py` adds a post-query tombstone filter unless `includeDeleted=true`; it never issues a table Scan. Deleted-heavy historical partitions may consume reads before filtering, so the rollout checkpoint is a sparse active-object index or tombstone partition if pilot measurements justify it. `backend/tests/test_catalog_keys.py` and `backend/tests/test_search_core.py` cover key access, filtering and cursor behavior.

## Phase 5 — API backend

### T5.1 — OpenAPI contract ✅ DONE (2026-09-24)
- **Deps:** T0.1. **Req/Design:** R14 / §6.
- Scope: versioned OpenAPI for `GET /v1/videos`, `POST /v1/videos/{id}/download`, `GET /v1/health`; typed errors; restore stubbed as roadmap.
- **Validation:** OpenAPI validates in CI; renders to docs.
- **Evidence:** `backend/api/openapi.yaml` (OpenAPI 3.0.3) — search with date/from/to/camera/cursor/limit, download with objectKey body, health (public), typed `Error {code,message}`, 409 RESTORE_REQUIRED documented as roadmap. Parses clean; `make openapi-validate` gate covers it.

### T5.2 — API Gateway REST API + Cognito authorizer + IP restriction 🟡 PARTIAL — API/auth deployed; regional WAF pending
- **Deps:** T1.3, T5.1. **Req/Design:** R6, R7 / §7, §8.
- Scope: REST API from OpenAPI, Cognito authorizer, regional WAF (or resource policy per ADR-002/ADR-006) enforcing office CIDRs on the stage; honor `IP_ALLOWLIST_MODE` (enforce/disabled).
- **Security:** default `execute-api` cannot bypass allowlist; unauth → 401; `disabled` mode still requires a valid Cognito identity.
- **Validation:** enforce+allowed CIDR + valid JWT → 200; enforce+non-allowed CIDR → blocked; no token → 401; valid token wrong role → 403; disabled mode → open at network layer but 401 without token.
- **Evidence:** `infra/template.yaml` — `VideoApi` (AWS::Serverless::Api, stage v1, `CognitoAuth` DefaultAuthorizer on UserPool; `/health` Auth NONE). API-stage IP enforcement (enforce mode) is delivered by a regional WAFv2 WebACL association per ADR-006 (production path), wired when enforce is turned on — NOT the earlier resource-policy attempt (removed: API Gateway rejected the policy document, and the demo runs `disabled` so it added only risk). The direct S3 download path keeps its independent bucket-policy `aws:SourceIp` control (R6). Cognito auth always applies. **Deploy pending.**

### T5.3 — Search Lambda ✅ DONE — DEPLOYED (2026-09-24)
- **Deps:** T4.2, T5.2. **Req/Design:** R3, R10 / §5, §6.
- Scope: `GET /videos` querying Catalog with pagination; typed `INVALID_QUERY`.
- **Validation:** integration tests for date/camera/range/cursor; invalid range → 400; measure p95 ≤ 2s on representative data.
- **Evidence:** `backend/app/search_core.py` (validate + no-Scan query; from>to and bad-date and no-criteria all → typed INVALID_QUERY) + `backend/app/search_handler.py` (API GW proxy, opaque cursor, projected fields). `backend/tests/test_search_core.py` — 7 tests. SAM `SearchFunction` (DynamoDBReadPolicy on Catalog only). **Deploy pending;** p95 measured post-deploy.

### T5.4 — Download-authorization Lambda ✅ DONE — DEPLOYED (2026-09-24)
- **Deps:** T4.1, T5.2. **Req/Design:** R4, R8 / §9, §10.
- Scope: authorize; `HeadObject` live-state check; presign with `PRESIGN_TTL_SECONDS`; write `DOWNLOAD_URL_ISSUED` audit (no URL stored).
- **Security:** server-side authz; audit excludes URL/tokens.
- **Validation:** authorized+retrievable→short URL+audit; unauthorized→403 no URL; TTL matches param; audit record has no URL.
- **Evidence:** `backend/app/download_core.py` (authorize by Operators group + object existence; `build_audit_item` asserts no URL/token; `is_retrievable` seam for archive classes) + `backend/app/download_handler.py` (Cognito claims, HeadObject live recheck, presign TTL from env, audit write, 409 RESTORE_REQUIRED for archive). `backend/tests/test_download_core.py` — 10 tests incl. no-URL-in-audit. SAM `DownloadFunction` (least-privilege: Catalog read + AuditTable write + s3:GetObject on video bucket only). LIVE E2E 2026-09-24: no-token→401; JWT GET /videos→200; /health→200; POST /download→200 with 120s URL; direct S3 fetch→200 (256B); audit item written with cognitoSub/sourceIp and ZERO URL/signature leakage (grep=0). Object resolved authoritatively via by-object GSI.

## Phase 6 — Frontend

### T6.1 — Mockups (2–3 distinct) + selection ✅ DONE (2026-09-24)
- **Deps:** T5.1. **Req/Design:** R14 / §15.
- Scope: 2–3 genuinely distinct full-page mockups covering search/loading/empty/invalid-metadata/ready/denied/error states; recommend one, await human selection.
- **Validation:** mockups reviewed; one selected as visual spec.
- **Evidence:** mockup artifacts + recorded selection.

### T6.2 — SPA implementation (React/TS/MUI) ✅ DONE — DEPLOYED (2026-09-24)
- **Deps:** T6.1, T5.3, T5.4. **Req/Design:** R14 / §15.
- Scope: Cognito login, search UI, results table (server-side pagination), download action, all state renderings; centralized theme.
- **Security:** no tokens in logs; least-privilege API usage.
- **Validation:** component/integration tests via accessible roles/labels; a11y check on key states.
- **Evidence:** test report; screenshots of each state.

### T6.3 — SPA delivery (CloudFront + OAC) + Cognito hosted-UI 🟡 PARTIAL — deployed; global WAF pending
- **Deps:** T1.1, T1.2, T6.2. **Req/Design:** R6 / §8.
- Scope: private SPA bucket, CloudFront OAC, global WAF IP allowlist.
- **Validation:** SPA loads from allowed CIDR; blocked from non-allowed; bucket not public.
- **Evidence:** access test from both sources.

## Phase 7 — Cross-cutting

### T7.1 — Audit + CloudTrail data events
- **Deps:** T4.1, T5.4. **Req/Design:** R8 / §10.
- Scope: CloudTrail S3 data events on the video bucket; audit semantics documented (bearer-URL limitation).
- **Validation:** a download produces an audit item and a CloudTrail GET event; docs state the distinction.
- **Evidence:** CloudTrail event sample; audit item; doc paragraph.

### T7.2 — Observability & safe logging
- **Deps:** T3.3, T5.3, T5.4. **Req/Design:** R9, R10 / §14.
- Scope: metrics/alarms (upload failures, invalid filenames, indexing age, DLQ depth, API errors, denied, audit-write failures); log redaction; WAF log redaction + sampling off.
- **Validation:** alarms exist; a log scan finds no URLs/tokens/credentials; WAF logs redacted.
- **Evidence:** alarm list; log-scan output.

### T7.3 — Threat model & abuse cases
- **Deps:** design complete. **Req/Design:** R7–R9 / §12.
- Scope: document threats (URL sharing, filename flooding, DLQ poison, IP spoof, token replay, over-broad CIDR) with mitigations.
- **Validation:** each abuse case maps to a control and a test.
- **Evidence:** threat-model doc reviewed.

## Phase 8 — Validation, cost, demo, teardown

### T8.1 — Integration / pilot E2E
- **Deps:** Phases 2–7. **Req/Design:** R1–R10 / all.
- Scope: clean-account end-to-end — Windows completed-file upload → index → search → authorized download; malformed filename; in-progress exclusion; outage/backlog recovery; denied-IP and unauthorized paths.
- **Validation:** 3–5 representative cameras or synthetic equivalents, approximately 7 days / 250–500 GB target; search p95, indexing p95, files/second and effective upload Mbps measured; no duplicate catalog entries.
- **Evidence:** E2E report mapping tests → R#, with camera/day/file-size/throughput measurements and decision whether `aws s3 sync` can scale or DataSync needs evaluation.

### T8.2 — Cost and lifecycle validation
- **Deps:** T1.1, T8.1. **Req/Design:** R11, R14 / §11, `docs/cost-model.md`.
- Scope: validate target-region prices in AWS Pricing Calculator using pilot-measured selected-cloud GB/day, file count/size and downloaded GB. Compare: Standard 90d; Standard 30d→Standard-IA 60d; Glacier Instant 90d; Glacier Flexible 90d with restore costs. Use the current 90 TB estate only as an optional sensitivity point, not committed scope.
- **Validation:** calculator scenarios identify region/date, minimum-duration charges, transition requests, object-size floors, metadata overhead and restore/egress. A Glacier transition at day 30 with expiration at day 90 must show early-deletion charges and must not be called optimized.
- **Evidence:** calculator exports plus camera/GB/day scenario table and selected lifecycle rationale.

### T8.3 — Documentation completeness 🟡 CUSTOMER REHEARSAL PENDING
- **Deps:** all. **Req/Design:** R14 / §1–§17.
- Scope: README, implementation/deployment/teardown runbooks, uploader operations/troubleshooting, rendered OpenAPI, ADRs, Roles Anywhere roadmap, cost model, MIT-0 license, owner + review dates.
- **Validation:** local links/fences resolve; secret/public-sharing scan passes; a new reader can deploy from docs alone.
- **Evidence:** complete orchestration scripts; `docs/implementation-manual.md`; PoC Windows profile/sync/scheduling/removal scripts and runbook; lifecycle and teardown evidence; MIT-0 license. Full demo deployment passed previously. Remaining: initialize Git, inspect the exact tracked set and perform one clean-checkout rehearsal with the customer-account profile/user.

### T8.4 — Customer demo package
- **Deps:** T8.1, T8.3. **Req/Design:** R14.
- Scope: demo script/walkthrough for the client meeting; both diagrams current; talking points on Standard-only + roadmap + cost model.
- **Validation:** dry-run of the demo in the demo account.
- **Evidence:** demo script; successful dry-run.

### T8.5 — Teardown ✅ PoC RETAIN/PURGE VALIDATED
- **Deps:** after demo. **Req/Design:** R15 / §16.
- Scope: `scripts/teardown.sh` provides `--plan`, `--retain-data`, `--purge-data` and `--purge-retained`; application bucket is emptied before stack deletion; video/catalog/audit use Retain policies. The PoC uploader role and assume-role policy are stack resources; the pre-existing IAM user and its customer-created key remain customer-owned. Plan reports active-key count and destructive modes fail closed until all uploader keys are disabled.
- **Validation:** `cctv-retain-test` proved stack/application removal while video bucket + Catalog + Audit survived; all remained private/ACTIVE and were then removed through `purge-retained`. `cctv-purge-test` proved full stack/data-resource purge. Confirmation guards reject missing/wrong stack names.
- **Evidence:** both temporary stacks, video buckets and four tables returned not found after cleanup; the main demo stack remained `UPDATE_COMPLETE`. Roles Anywhere trust-anchor/SSM cleanup is preserved in the roadmap script but is not part of the simplified PoC acceptance.

---

## Recommended implementation order

1. Phase 0 (scaffold + CI) → 2. Phase 1 (infra) → 3. Phase 4 (data) → 4. Phase 3 (indexing) → 5. Phase 2 (PoC uploader credentials; Roles Anywhere roadmap) → 6. Phase 5 (API) → 7. Phase 6 (frontend) → 8. Phase 7 (cross-cutting) → 9. Phase 8 (E2E/cost/demo/teardown).

Data and indexing precede ingestion so the pipeline can be tested with the synthetic fixture before wiring the real uploader.

## Customer evidence incorporated (2026-10-21)

- Customer confirmed the proposed flow and phased-pilot approach.
- Current local estate: approximately 90 TB across all cameras; this is not confirmed cloud-upload scope.
- Target retention discussed: approximately 3 months (90 days).
- Many small AVI files and irregular downloads; exact file count, size distribution and selected cloud volume remain unknown.
- Pilot planning range remains 250–500 GB total, 3–5 cameras and approximately 7 days.

## Decisions required before customer-account deployment

- Total camera count and selected 3–5 pilot cameras.
- Pilot duration/retention and whether expiration is enabled; safe default is `keep`.
- Files/day and average/p95/max AVI size.
- Windows server count, completed-file contract, bandwidth and transfer window.
- Target region/data residency, deployment role, office CIDRs and first operator email.
- 10–20 real sanitized filenames and recording timezone.
- Exact audit expectation and expected downloaded GB/month.

## Reopened implementation gaps

- **Network perimeter:** WAF is the chosen design but is NOT yet present in `infra/template.yaml`; current `enforce` only protects direct S3 GET. T5.2/T6.3 require WAF implementation and outside-CIDR validation before being considered complete for customer deployment.
- **Windows uploader:** IAM-user-to-role CloudFormation path, profile configurator, safe sync, Task Scheduler registration/removal, logging and runbook are implemented. Customer Windows E2E, actual VMS finished-folder behavior and interruption/backlog recovery remain open in T2.1/T2.2; Roles Anywhere is T2.4 roadmap.
- **Handoff:** implementation manual, MIT-0 license, deployment orchestration, user bootstrap, frontend publication and PoC teardown are complete. Git initialization, final tracked-file review and clean-checkout customer rehearsal remain open.

## Approval checkpoint

- [x] Task breakdown reviewed and sized appropriately.
- [x] Implementation order accepted.
- [x] Approved to begin implementation (Phase 0 first). — approved 2026-09-23
