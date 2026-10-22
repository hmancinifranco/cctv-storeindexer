# Kiro SDD Kickoff Prompt

**Last reviewed:** 2026-09-23

## How to start

1. Open the repository root as the project workspace.
2. Start a **new Spec session** (not Vibe/Quick Spec) so requirements, design, and tasks each have an approval checkpoint.
3. Paste the instruction below exactly.
4. Answer the agent's discovery questions with customer evidence. When an answer is unknown, require an explicit assumption plus impact; do not let the agent silently invent it.
5. Approve `requirements.md` first, then `design.md`, then `tasks.md`. Do not authorize implementation or deployment in this session.

Kiro CLI fallback, if Spec mode is unavailable: use the documented PDD SOP from `/prompts` with `@agent-sops:pdd`, provide this file and `planning/explore-phase.md` as inputs, and stop after implementation planning.

## Copy/paste instruction

```text
Create a Spec-Driven Development plan for the Video Archive Prototype. This session is PLANNING ONLY: do not implement application code, install dependencies, deploy AWS resources, create production credentials, or use customer production data.

Read these project sources before asking questions:
- planning/explore-phase.md
- .kiro/steering/engineering-documentation-standards.md
- architecture/conceptual-architecture.drawio
- architecture/client-proposal-aws-icons.drawio
- .env.example
- README.md

Treat the Explore document as a researched hypothesis, not an immutable design. Validate assumptions and keep design documents as source-controlled, living artifacts.

Deployment and configuration contract:
- The prototype is demonstrated in a developer-owned AWS demo account, NOT the customer's account. The AWS named profile and all account-specific values are provided through a local, git-ignored .env file (committed template: .env.example). The repository must never contain account IDs, ARNs, regions, office CIDRs, bucket names, domains, or credentials.
- SAM/CloudFormation must read environment, account, region, and the office CIDR allowlist as parameters sourced from .env, with no permissive defaults and fail-closed behavior when the allowlist is empty. Deploy the demo with the AWS profile referenced by .env.

Goal:
Design a customer-deliverable AWS prototype that uploads completed video-surveillance files from an on-premises Windows Server to private Amazon S3 over the internet; automatically inventories each completed upload by parsing camera/date/time metadata from its filename; provides an IP-restricted and individually authenticated web interface to search by date, time, and camera; enables authorized download through a short-lived URL generated on demand; handles archived objects correctly; and records auditable access events.

Required process:
1. First perform structured requirements clarification. Ask one focused question at a time and record each answer. Prioritize the blocking items listed in planning/explore-phase.md: exact VMS/version and integration capability; 20 sanitized filename examples; timezone; files/day, GB/day and file-size distribution; retention; retrieval SLA; users/roles; required meaning of “who accessed”; stable office IPv4/IPv6 CIDRs; upload bandwidth/backlog; source-file completeness/deletion semantics; identity/MFA; compliance/data residency/legal hold; and target AWS account/region classification.
2. Do not infer answers from the meeting estimate. If information remains unavailable, recommend a safe prototype assumption, label it ASSUMPTION, state impact and validation owner, and place it in an open-decisions table.
3. Research only when a decision still lacks evidence. Use AWS documentation MCP for AWS behavior, Builder/internal search for reusable Amazon patterns, MUI documentation MCP for UI decisions, and SAM/CloudFormation documentation for deployable resources. Cite exact URLs. Do not rely on blog claims when an AWS service guide provides the authoritative behavior.
4. Generate 10–15 clear, testable MVP requirements in EARS style. Include functional, security, audit, operability, performance, cost-guardrail, documentation, and cleanup requirements. Explicitly state non-goals.
5. Pause for human review and approval of requirements. Do not generate design until requirements are approved.
6. Generate a detailed design that includes:
   - context, component, ingestion, indexing, search, download, archive-restore, authentication, authorization, and audit flows;
   - ingestion baseline for the PoC: scheduled `aws s3 sync` on the existing Windows Server using a unique IAM technical user only to assume a scoped, write-only uploader role; CloudFormation never creates the access key; document retirement at pilot close; keep IAM Roles Anywhere as the preferred credential roadmap and AWS DataSync as the evaluated future/scale improvement;
   - fail-closed IP controls for CloudFront UI, the API Gateway REST API stage and its default execute-api endpoint, and the direct S3 presigned download path;
   - Cognito User Pool authentication and server-side role authorization;
   - WAF logging/redaction rules that prevent authorization headers, cookies, tokens, or presigned query strings from being captured, with request sampling disabled unless proven safe;
   - S3 ObjectCreated -> EventBridge -> SQS/DLQ -> idempotent Lambda indexing, including duplicates, out-of-order events, poison messages, replay, and malformed filenames;
   - versioned filename grammar and parser error strategy;
   - DynamoDB keys validated against every access pattern without Scan, pagination cursor design, conditional writes, capacity mode, backup/PITR decision, and representative items;
   - versioned OpenAPI contract for search, download authorization, restore initiation, and restore status, including typed errors;
   - exact audit semantics separating URL issuance from observed S3 GET, CloudTrail data events, log retention, and the bearer-URL limitation;
   - S3 lifecycle decision based on measured retention/object size/retrieval inputs, including minimum-duration charges, small-object overhead, and restore UX;
   - encryption, least-privilege IAM, CORS, secrets, data classification, threat model, abuse cases, and cleanup;
   - IAM Roles Anywhere as a documented roadmap: preserve the validated trust-anchor/profile/helper runbook, but do not require certificates or a CA for the initial PoC;
   - AWS SAM stack boundaries, parameters, environments, outputs, local testing, CI/CD gates, observability, alarms, and cost model;
   - rollback and prototype teardown plan.
7. For the frontend, create 2–3 genuinely distinct low-cost mockups before choosing components or coding. Use React + TypeScript + Material UI as the target. Each option must cover search, loading, empty, malformed metadata, ready, archived, restore-pending, denied, and error states. Recommend one but wait for human selection; the chosen mockup becomes the visual specification. Plan tests around accessible roles and labels rather than MUI internals.
8. Update architecture/conceptual-architecture.drawio and architecture/client-proposal-aws-icons.drawio if the approved design differs from the Explore hypothesis. Record non-obvious decisions as ADRs, including rejected alternatives and consequences.
9. Pause for human review and approval of design. Do not generate tasks until design is approved.
10. Generate tasks sized for one focused agent session each. Every task must identify requirement traceability, files/resources affected, dependencies, security considerations, documentation updates, tests, validation commands, and acceptance evidence. Separate infrastructure, backend, frontend, the scheduled `aws s3 sync` uploader with IAM-user-to-role setup, the IAM Roles Anywhere roadmap, integration/E2E, security, documentation, cost validation, customer demo, and teardown work.
11. Pause after tasks are approved. Summarize unresolved decisions, risks, and recommended implementation order. Do not begin implementation.

Mandatory constraints:
- Apply every rule in .kiro/steering/engineering-documentation-standards.md.
- Use AWS SAM/CloudFormation for infrastructure and generate OpenAPI documentation from the contract.
- Keep all S3 buckets private; use CloudFront OAC for static assets.
- Do not treat office IP allowlisting as user identity.
- Do not claim that an S3 presigned URL proves which human performed the GET.
- Do not issue a download URL for a Flexible Retrieval/Deep Archive object until restore is complete.
- Do not choose a Glacier class before validating minimum storage duration, object-size distribution, retention, recovery SLA, and retrieval cost.
- Do not assume S3 events are exactly-once or ordered.
- Do not silently discard filenames that fail parsing.
- Do not expose presigned URLs, tokens, credentials, or video contents in logs.
- Do not use DynamoDB Scan for user search paths.
- Do not hardcode CIDRs, account IDs, regions, bucket names, domains, retention days, or URL TTLs.
- Keep non-pushable configuration (AWS profile, account, region, office CIDRs, ARNs) in a git-ignored .env; commit only .env.example. Deploy the demo with the AWS profile referenced by .env.

Planning exit criteria:
Requirements, design, tasks, ADRs, threat model, OpenAPI outline, data model examples, UI mockup choice, test strategy, cost assumptions, and unresolved-decision register are internally consistent, source-controlled, and explicitly approved. Stop there.
```