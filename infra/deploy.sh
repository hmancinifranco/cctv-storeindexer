#!/usr/bin/env bash
#
# deploy.sh — build and deploy the SAM stack to the configured AWS account.
# Reads all account-specific values from the repo-root .env (nothing hardcoded).
# Prefer scripts/deploy-customer.sh, which also publishes/verifies the frontend.
#
# Usage:
#   ./deploy.sh            # sam build + deploy
#   ./deploy.sh --guided   # first-time guided deploy
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
GUIDED=""
[[ "${1:-}" == "--guided" ]] && GUIDED="--guided"

read_env() {
  local key="$1"
  [[ -f "${ENV_FILE}" ]] || return 0
  { grep -E "^[[:space:]]*${key}=" "${ENV_FILE}" || true; } | tail -n1 | cut -d= -f2- | \
    sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: ${ENV_FILE} not found (copy .env.example)." >&2; exit 1; }

PROFILE="$(read_env AWS_PROFILE)"
REGION="$(read_env AWS_REGION)"
STACK="$(read_env STACK_NAME)"
PROJECT="$(read_env PROJECT_NAME)"
ENVIRONMENT="$(read_env ENVIRONMENT)"
VIDEO_BUCKET="$(read_env VIDEO_BUCKET_NAME)"
INGEST_PREFIX="$(read_env INGEST_PREFIX)"
RETENTION_MODE="$(read_env RETENTION_MODE)"
RETENTION_DAYS="$(read_env RETENTION_DAYS)"
CATALOG_TOMBSTONE_RETENTION_DAYS="$(read_env CATALOG_TOMBSTONE_RETENTION_DAYS)"
IP_MODE="$(read_env IP_ALLOWLIST_MODE)"
CIDRS="$(read_env OFFICE_ALLOWED_CIDRS)"
ROLES_ANYWHERE_ENABLED_VALUE="$(read_env ROLES_ANYWHERE_ENABLED)"
UPLOADER_IAM_USER_NAME="$(read_env UPLOADER_IAM_USER_NAME)"
RA_PROFILE_ARN_VALUE="$(read_env RA_PROFILE_ARN)"

[[ -n "${PROFILE}" ]] || { echo "ERROR: AWS_PROFILE not set in .env" >&2; exit 1; }
[[ -n "${STACK}" ]]   || { echo "ERROR: STACK_NAME not set in .env" >&2; exit 1; }

# Client-side echo of the fail-closed guard (the template also enforces it).
if [[ "${IP_MODE}" == "enforce" && -z "${CIDRS}" ]]; then
  echo "ERROR: IP_ALLOWLIST_MODE=enforce but OFFICE_ALLOWED_CIDRS is empty (fail-closed)." >&2
  echo "       Set CIDRs in .env or use IP_ALLOWLIST_MODE=disabled for the demo." >&2
  exit 1
fi

echo "Deploying stack '${STACK}' to profile '${PROFILE}' region '${REGION:-default}'"
echo "  retention=${RETENTION_MODE}/${RETENTION_DAYS}  ip_mode=${IP_MODE}"

sam build --template-file "${SCRIPT_DIR}/template.yaml"

# Build parameter overrides, OMITTING empty values (SAM rejects "Key="); the
# template defaults ("") then apply — e.g. empty VideoBucketName lets CFN
# auto-name, empty OfficeAllowedCidrs is valid when IpAllowlistMode=disabled.
PARAMS=(
  "ProjectName=${PROJECT:-cctv-storeindexer}"
  "Environment=${ENVIRONMENT:-demo}"
  "IngestPrefix=${INGEST_PREFIX:-videos}"
  "RetentionMode=${RETENTION_MODE:-expire}"
  "RetentionDays=${RETENTION_DAYS:-60}"
  "CatalogTombstoneRetentionDays=${CATALOG_TOMBSTONE_RETENTION_DAYS:-365}"
  "IpAllowlistMode=${IP_MODE:-enforce}"
)
[[ -n "${VIDEO_BUCKET}" ]] && PARAMS+=( "VideoBucketName=${VIDEO_BUCKET}" )
[[ -n "${CIDRS}" ]] && PARAMS+=( "OfficeAllowedCidrs=${CIDRS}" )
[[ -n "${UPLOADER_IAM_USER_NAME}" ]] && PARAMS+=( "UploaderIamUserName=${UPLOADER_IAM_USER_NAME}" )

# IAM Roles Anywhere upload role + profile are created in SAM when enabled.
# Preserve them on subsequent deploys when an existing profile ARN is recorded;
# otherwise a normal update would flip the condition to false and delete them.
if [[ "${ROLES_ANYWHERE_ENABLED:-${ROLES_ANYWHERE_ENABLED_VALUE:-false}}" == "true" || -n "${RA_PROFILE_ARN_VALUE}" ]]; then
  PARAMS+=( "RolesAnywhereEnabled=true" )
fi

# --resolve-s3 lets SAM manage the deploy artifact bucket on non-guided runs.
# --no-confirm-changeset avoids the interactive "Deploy this changeset? [y/N]"
# prompt (there is no TTY in automated runs).
RESOLVE_S3="--resolve-s3 --no-confirm-changeset"
[[ -n "${GUIDED}" ]] && RESOLVE_S3=""

# shellcheck disable=SC2086
sam deploy ${GUIDED} ${RESOLVE_S3} \
  --stack-name "${STACK}" \
  --profile "${PROFILE}" \
  ${REGION:+--region "${REGION}"} \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides "${PARAMS[@]}"

echo "Done. Fetch outputs with:"
echo "  aws cloudformation describe-stacks --stack-name ${STACK} --profile ${PROFILE} ${REGION:+--region ${REGION}} --query 'Stacks[0].Outputs'"
