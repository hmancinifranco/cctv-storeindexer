#!/usr/bin/env bash
#
# scan_secrets.sh — fail the build if credentials, private keys, or presigned
# URLs appear in tracked source. Steering: logs/code MUST NOT contain presigned
# URLs, tokens, credentials, or video content.
#
# Scans all paths intended for source control, including documentation. Local
# `.env`, certificates and generated build artifacts are excluded by path.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# Paths that can be committed/shared. Local secrets and generated artifacts are
# excluded explicitly below rather than silently narrowing the scan to code.
SCAN_PATHS=(
  README.md LICENSE Makefile pyproject.toml .env.example .github .kiro architecture
  backend docs frontend infra planning scripts uploader
)

# Patterns that must never be committed or shared with the customer.
PATTERNS=(
  'AKIA[0-9A-Z]{16}'                    # AWS access key id
  'aws_secret_access_key[[:space:]]*='  # secret key assignment
  '-----BEGIN [A-Z ]*PRIVATE KEY-----' # private key material
  'X-Amz-Signature='                    # presigned URL
  'w\.amazon\.com|amazon\.dev|a2z\.com|amazon\.work|corp\.amazon' # internal URLs
  '/Users/[^/]+/Documents/Repo|[[:alnum:]_.-]+\+demos' # personal path/profile
)

found=0
for path in "${SCAN_PATHS[@]}"; do
  [[ -e "${path}" ]] || continue
  for pat in "${PATTERNS[@]}"; do
    if grep -REn \
      --exclude=scan_secrets.sh --exclude=.env.local --exclude=.env.production \
      --exclude-dir=certs --exclude-dir=out --exclude-dir=node_modules \
      --exclude-dir=dist --exclude-dir=build --exclude-dir=.aws-sam \
      --binary-files=without-match -- "${pat}" "${path}" \
      2>/dev/null; then
      echo "SECRET-SCAN: forbidden pattern '${pat}' found in ${path}" >&2
      found=1
    fi
  done
done

if [[ "${found}" -ne 0 ]]; then
  echo "SECRET-SCAN: FAILED — remove the material above." >&2
  exit 1
fi
echo "SECRET-SCAN: clean"
