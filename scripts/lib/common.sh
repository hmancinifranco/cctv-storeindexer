#!/usr/bin/env bash
# Shared helpers for customer deployment scripts. This file is sourced.
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"

read_env() {
  local key="$1"
  [[ -f "${ENV_FILE}" ]] || return 0
  awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "${ENV_FILE}" |
    sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: falta '$1'. ${2:-Instálelo y vuelva a ejecutar.}" >&2
    return 1
  }
}

require_value() {
  local label="$1" value="$2"
  [[ -n "${value}" && "${value}" != "<"* ]] || {
    echo "ERROR: ${label} no está configurado en ${ENV_FILE}." >&2
    return 1
  }
}

load_deploy_env() {
  [[ -f "${ENV_FILE}" ]] || {
    echo "ERROR: no existe ${ENV_FILE}. Copie .env.example a .env y complételo." >&2
    return 1
  }

  AWS_PROFILE_VALUE="$(read_env AWS_PROFILE)"
  AWS_REGION_VALUE="$(read_env AWS_REGION)"
  STACK_NAME_VALUE="$(read_env STACK_NAME)"
  PROJECT_NAME_VALUE="$(read_env PROJECT_NAME)"
  ENVIRONMENT_VALUE="$(read_env ENVIRONMENT)"
  RETENTION_MODE_VALUE="$(read_env RETENTION_MODE)"
  RETENTION_DAYS_VALUE="$(read_env RETENTION_DAYS)"
  IP_ALLOWLIST_MODE_VALUE="$(read_env IP_ALLOWLIST_MODE)"
  OFFICE_ALLOWED_CIDRS_VALUE="$(read_env OFFICE_ALLOWED_CIDRS)"
  INGEST_PREFIX_VALUE="$(read_env INGEST_PREFIX)"
  ROLES_ANYWHERE_ENABLED_VALUE="$(read_env ROLES_ANYWHERE_ENABLED)"
  RA_PROFILE_ARN_VALUE="$(read_env RA_PROFILE_ARN)"
  UPLOADER_IAM_USER_NAME_VALUE="$(read_env UPLOADER_IAM_USER_NAME)"

  require_value AWS_PROFILE "${AWS_PROFILE_VALUE}"
  require_value AWS_REGION "${AWS_REGION_VALUE}"
  require_value STACK_NAME "${STACK_NAME_VALUE}"
  require_value PROJECT_NAME "${PROJECT_NAME_VALUE}"
  require_value ENVIRONMENT "${ENVIRONMENT_VALUE}"

  AWS_ARGS=(--profile "${AWS_PROFILE_VALUE}" --region "${AWS_REGION_VALUE}")
}

stack_output() {
  local key="$1"
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME_VALUE}" "${AWS_ARGS[@]}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue | [0]" \
    --output text
}

upsert_env_values() {
  local path="$1"
  shift
  python3 - "${path}" "$@" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
updates = dict(arg.split("=", 1) for arg in sys.argv[2:])
lines = path.read_text().splitlines() if path.exists() else []
seen = set()
out = []
for line in lines:
    if "=" in line and not line.lstrip().startswith("#"):
        key = line.split("=", 1)[0]
        if key in updates:
            out.append(f"{key}={updates[key]}")
            seen.add(key)
            continue
    out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f"{key}={value}")
path.write_text("\n".join(out) + "\n")
PY
}
