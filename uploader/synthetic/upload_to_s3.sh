#!/usr/bin/env bash
#
# upload_to_s3.sh — push the synthetic fixture set to the demo S3 video bucket.
#
# Mirrors the production ingestion baseline (a scheduled `aws s3 sync`, design
# §2), but sources the synthetic set instead of real recordings so the pipeline
# can be demonstrated end-to-end. All account-specific values come from the
# git-ignored .env at the repo root — nothing is hardcoded.
#
# Usage:
#   ./upload_to_s3.sh [--dry-run] [--prefix videos]
#
# Requires: awscli v2, python3 (to (re)generate fixtures if missing).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
OUT_DIR="${SCRIPT_DIR}/out"

DRY_RUN=""
PREFIX_OVERRIDE=""

usage() { sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="--dryrun"; shift ;;
    --prefix)  PREFIX_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- Read a single KEY=value from .env without executing the file ---
read_env() {
  local key="$1"
  [[ -f "${ENV_FILE}" ]] || return 0
  grep -E "^[[:space:]]*${key}=" "${ENV_FILE}" | tail -n1 | cut -d= -f2- | \
    sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Copy .env.example to .env and fill it." >&2
  exit 1
fi

AWS_PROFILE_VAL="$(read_env AWS_PROFILE)"
AWS_REGION_VAL="$(read_env AWS_REGION)"
# Prefer the resolved bucket from deploy outputs; fall back to the naming param.
BUCKET="$(read_env VIDEO_BUCKET_RESOLVED)"
[[ -z "${BUCKET}" ]] && BUCKET="$(read_env VIDEO_BUCKET_NAME)"
PREFIX="${PREFIX_OVERRIDE:-$(read_env INGEST_PREFIX)}"
PREFIX="${PREFIX:-videos}"

if [[ -z "${AWS_PROFILE_VAL}" ]]; then
  echo "ERROR: AWS_PROFILE is not set in ${ENV_FILE}." >&2
  exit 1
fi
if [[ -z "${BUCKET}" ]]; then
  echo "ERROR: VIDEO_BUCKET_NAME is empty in ${ENV_FILE}." >&2
  echo "       Deploy the storage stack first, then set the bucket name in .env." >&2
  exit 1
fi

# --- (Re)generate the fixture set if absent ---
if [[ ! -d "${OUT_DIR}" ]] || [[ -z "$(ls -A "${OUT_DIR}" 2>/dev/null)" ]]; then
  echo "Fixture set missing; generating..."
  python3 "${SCRIPT_DIR}/generate_fixtures.py"
fi

DEST="s3://${BUCKET}/${PREFIX}/"
echo "Profile : ${AWS_PROFILE_VAL}"
echo "Region  : ${AWS_REGION_VAL:-(default)}"
echo "Source  : ${OUT_DIR}"
echo "Dest    : ${DEST}"
[[ -n "${DRY_RUN}" ]] && echo "Mode    : DRY-RUN (no objects written)"

# --- Verify the bucket is reachable with the demo profile before syncing ---
if ! aws s3api head-bucket --bucket "${BUCKET}" \
      --profile "${AWS_PROFILE_VAL}" ${AWS_REGION_VAL:+--region "${AWS_REGION_VAL}"} 2>/dev/null; then
  echo "ERROR: cannot reach s3://${BUCKET} with profile '${AWS_PROFILE_VAL}'." >&2
  echo "       Check credentials (aws sso login) and that the bucket exists." >&2
  exit 1
fi

# --- Upload. `aws s3 sync` = the same mechanism as the real uploader ---
# shellcheck disable=SC2086
aws s3 sync "${OUT_DIR}/" "${DEST}" \
  --profile "${AWS_PROFILE_VAL}" \
  ${AWS_REGION_VAL:+--region "${AWS_REGION_VAL}"} \
  --exclude "*.md" \
  ${DRY_RUN}

echo "Done. Objects are under ${DEST}"
echo "Each PutObject triggers S3 -> EventBridge -> SQS -> indexer Lambda (design §3)."
