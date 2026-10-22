# Engineering and Documentation Standards

**Last reviewed:** 2026-10-22

These rules apply to every requirement, design, task, implementation, review, and deployment in this project.

## Clean code

- You MUST use consistent, descriptive naming conventions. Avoid abbreviations unless they are widely understood in the project domain.
- You MUST keep functions, classes, components, and Lambda handlers small and focused on one responsibility.
- You MUST apply DRY deliberately, but MUST NOT introduce abstractions before a repeated concept is stable.
- You MUST use established design patterns only when they reduce coupling or clarify ownership. Document why a non-obvious pattern is used.
- You MUST remove dead code, unused variables, commented-out code, and obsolete feature flags.
- You MUST use automated formatting, linting, and static type checking.
- Comments MUST explain intent, constraints, or trade-offs; they MUST NOT restate self-explanatory code.
- Errors MUST be typed or categorized, logged with actionable context, and translated to safe client responses.

## Testing and validation

- You MUST write unit tests for filename parsing, key construction, authorization decisions, idempotency, lifecycle-state transitions, and API validation.
- You MUST write integration tests for S3 event to catalog flow, search pagination, download authorization/audit, and archive restore behavior.
- Frontend tests MUST query user-visible roles and labels rather than Material UI implementation details.
- You MUST test success, malformed input, duplicate/out-of-order event, unauthorized, forbidden-IP, missing object, archived object, restore-pending, throttling, and dependency-failure scenarios.
- Every task MUST define its validation command and acceptance evidence before implementation begins.
- You MUST NOT weaken or delete a test merely to make a build pass; fix the behavior or update the approved specification.

## Documentation structure

- `README.md` MUST summarize functionality, prerequisites, setup, dependencies, local development, deployment, usage examples, and troubleshooting.
- `docs/architecture/` or `architecture/` MUST contain the current architecture diagram and architecture decision records.
- Public API contracts MUST be generated from an OpenAPI definition and MUST include authentication, authorization scopes, inputs, outputs, examples, pagination, versioning, and error responses.
- Complex algorithms and data models MUST document why the approach was selected, its constraints, and its edge cases.
- Documentation MUST be concise but complete, versioned with code, and updated in the same change as behavior.
- Outdated documentation MUST be removed or clearly superseded.
- Every document MUST declare a last-review date before customer handoff. Public assets SHOULD NOT require a named personal owner; repository maintainers and CODEOWNERS MAY carry maintenance responsibility.

## Automated documentation

- The OpenAPI contract MUST be validated in CI and used as the source for rendered API documentation.
- Code documentation SHOULD use the ecosystem-standard mechanism selected in design (for example, TypeDoc/JSDoc for TypeScript and docstrings plus an approved generator for Python).
- Documentation links and examples MUST be tested where practical.
- CI MUST run formatting, linting, type checking, unit tests, template validation, API-contract validation, and documentation checks.

## AWS architecture and security

- Infrastructure MUST be defined as code with AWS SAM/CloudFormation. Console-only configuration is not acceptable for the deliverable.
- All Amazon S3 buckets MUST block public access, require TLS, and use encryption at rest. Static frontend access MUST use CloudFront Origin Access Control.
- IP allowlisting is a network control, not user authentication. Protected APIs MUST also authenticate users with Amazon Cognito and authorize actions server-side.
- Office CIDRs MUST be explicit deployment parameters with no permissive default. Empty allowlists MUST fail deployment closed.
- Direct video download bypasses CloudFront/WAF when using an S3 presigned URL; therefore the video bucket policy MUST independently enforce approved source CIDRs, and URLs MUST have a short expiration.
- The API MUST record the authenticated user who requested a download URL. CloudTrail S3 data events MUST record object-level access. Documentation MUST distinguish URL issuance from proof of actual download.
- On-premises workloads SHOULD use temporary credentials through IAM Roles Anywhere. Long-lived access keys MUST NOT be embedded in code, scripts, or configuration files.
- Large-file transfer MUST use multipart upload with bounded concurrency, retry/backoff, and a documented resumability strategy. The video bucket MUST abort incomplete multipart uploads after an approved interval.
- IAM permissions MUST follow least privilege and separate uploader, indexer, query, restore, and audit responsibilities.
- S3 event consumers MUST be idempotent because notifications are delivered at least once and can arrive out of order.
- Invalid filenames MUST NOT be silently dropped. They MUST be quarantined or cataloged with a parse-error status and observable alarm.
- Archived objects MUST NOT receive a download URL until restore completion is verified. Restore-completion events MAY update catalog state, but the presigning path MUST recheck current S3 state.
- WAF logs MUST redact authorization headers, cookies, tokens, and query strings that can contain presigned credentials. Request sampling MUST be disabled unless the design proves sensitive fields cannot be captured.
- Logs MUST NOT contain presigned URLs, access tokens, credentials, or video content.
- CORS MUST allow only the approved frontend origin; credentialed wildcard origins are forbidden.
- Production-like resource changes, public exposure changes, and deletion/retention changes require explicit human approval.

## Frontend and accessibility

- Visual implementation MUST begin only after 2–3 distinct mockups are reviewed and one is selected as the visual specification.
- The frontend MUST use React, TypeScript, and Material UI with a centralized theme. It MUST NOT hardcode colors that bypass the theme.
- Search controls MUST have explicit labels, validation, and keyboard navigation.
- Results MUST expose recording date/time, camera, filename, size, storage/restore status, and available action.
- Loading, empty, invalid-query, archived, restore-pending, access-denied, and service-error states MUST be designed explicitly.
- Alerts MUST not steal focus; essential messages MUST not disappear automatically; color MUST not be the only status indicator.
- User-facing text MUST use plain language suitable for non-technical users.

## Maintainability and review

- Design decisions MUST be recorded before implementation and revisited when requirements change.
- Specs and design documents are living source-of-truth artifacts and MUST be reviewed like code.
- Tasks MUST be small enough to complete and validate in one focused agent session.
- Dependencies MUST be documented and locked reproducibly by the package lockfile.
- Before customer handoff, a maintainer MUST review documentation freshness, operational runbooks, alarms, backup/retention policy, and cost assumptions.