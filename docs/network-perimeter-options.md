# Network Perimeter Options — IP allowlist with and without WAF

**Last reviewed:** 2026-09-23
**Traceability:** Supports `requirements.md` R6 and `design.md` §8 / ADR-006.

The prototype restricts access to approved office source CIDRs. This document
records the chosen approach (WAF) and the documented alternative (no WAF), so
the decision can be revisited for cost or operability.

## The core rule (applies to BOTH options)

The IP allowlist must be enforced on **three independent paths**, because they
do not share a choke point:

1. **SPA** — served via CloudFront.
2. **API** — API Gateway REST API; its default `execute-api` endpoint is public and does **not** traverse CloudFront.
3. **Direct download** — S3 presigned URL goes **straight to S3**, bypassing CloudFront and WAF.

Enforcing IP on only one path (e.g. CloudFront) leaves the other two open. This
is the most common and most dangerous mistake.

## Option A — WAF (chosen, default)

| Path | Control |
|------|---------|
| SPA | CloudFront + **global WAF** WebACL IP set (default block) |
| API | **Regional WAF** on the REST API stage |
| Download | S3 bucket policy `aws:SourceIp` condition |

**Pros:** managed IP sets (update without redeploy), centralized WAF logging of
blocked requests, rate limiting and managed rule groups available, easy IPv6 and
large lists.
**Cons:** ~$13/month fixed floor (2 WebACLs) regardless of traffic.

## Option B — No WAF (documented alternative)

| Path | Control |
|------|---------|
| SPA | **CloudFront Function** reading `CloudFront-Viewer-Address`, returns 403 if the client IP is not in the CIDR list |
| API | **API Gateway resource policy** with `aws:SourceIp` condition (native, no extra cost) |
| Download | S3 bucket policy `aws:SourceIp` condition (identical to Option A) |

**Pros:** removes the ~$13/month WAF floor; all three paths still enforce IP.
**Cons:**
- CIDR list lives **in the CloudFront Function code** → changing it needs a function redeploy (vs a managed WAF IP set).
- **No centralized logging/metrics** of blocked requests like WAF provides.
- **No rate limiting / managed L7 rules** (OWASP, bots).
- IPv6 and large lists are more awkward to maintain by hand.

### Notes / gotchas

- CloudFront **geo-restriction** filters by **country only**, not IP/CIDR — not a substitute for an office allowlist.
- `CloudFront-Viewer-Address` is the TCP peer as seen by CloudFront (trustworthy), not a spoofable `X-Forwarded-For`.
- Whichever option is used, **Cognito authentication and server-side
  authorization still apply** — IP allowlisting is a network control, never identity (R7).

## Recommendation

- **Prototype / cost-sensitive:** Option B is reasonable **provided all three
  paths are covered**. It saves the WAF floor.
- **Production / growth:** Option A (WAF) pays for itself with managed lists,
  logging, and L7 defense.

Switching between options is a deployment choice; the S3 bucket-policy layer is
identical in both, so only the SPA and API layers change.
