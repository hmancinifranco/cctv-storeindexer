#!/usr/bin/env bash
# Plan-first teardown for the Video Archive PoC.
# Default/--plan: read-only. Destructive modes require --confirm <stack-name>.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MODE="plan"
CONFIRM=""
SOURCE_MANIFEST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) MODE="plan"; shift ;;
    --retain-data) MODE="retain"; shift ;;
    --purge-data) MODE="purge"; shift ;;
    --purge-retained) MODE="purge-retained"; SOURCE_MANIFEST="${2:-}"; shift 2 ;;
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Uso:
  scripts/teardown.sh --plan
  scripts/teardown.sh --retain-data --confirm <stack-name>
  scripts/teardown.sh --purge-data --confirm <stack-name>
  scripts/teardown.sh --purge-retained <manifest.txt> --confirm <stack-name>

retain-data elimina aplicación/identidad y conserva VideoBucket, Catalog y Audit.
purge-data elimina también videos, catálogo y auditoría de forma permanente.
purge-retained elimina los recursos conservados por una ejecución retain-data.
EOF
      exit 0 ;;
    *) echo "ERROR: opción desconocida: $1" >&2; exit 2 ;;
  esac
done

load_deploy_env
ONPREM_STACK="${PROJECT_NAME_VALUE}-${ENVIRONMENT_VALUE}-onprem"
OLD_ONPREM_STACK="${PROJECT_NAME_VALUE}-${ENVIRONMENT_VALUE}-onprem-ec2"
CERT_PARAM="/${PROJECT_NAME_VALUE}/${ENVIRONMENT_VALUE}/ra/client-cert"
KEY_PARAM="/${PROJECT_NAME_VALUE}/${ENVIRONMENT_VALUE}/ra/client-key"

stack_exists() {
  aws cloudformation describe-stacks --stack-name "$1" "${AWS_ARGS[@]}" >/dev/null 2>&1
}

if [[ "${MODE}" == "purge-retained" ]]; then
  [[ -f "${SOURCE_MANIFEST}" ]] || {
    echo "ERROR: manifiesto no encontrado: ${SOURCE_MANIFEST}" >&2
    exit 2
  }
  manifest_value() { awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "${SOURCE_MANIFEST}"; }
  MANIFEST_STACK="$(manifest_value stack_name)"
  RETAINED_VIDEO_BUCKET="$(manifest_value video_bucket)"
  RETAINED_CATALOG_TABLE="$(manifest_value catalog_table)"
  RETAINED_AUDIT_TABLE="$(manifest_value audit_table)"
  [[ -n "${MANIFEST_STACK}" && "${CONFIRM}" == "${MANIFEST_STACK}" ]] || {
    echo "ERROR: confirme con --confirm ${MANIFEST_STACK:-<stack-del-manifiesto>}" >&2
    exit 2
  }
  echo "PURGE RETAINED: eliminación permanente según ${SOURCE_MANIFEST}"
  echo "  Bucket: ${RETAINED_VIDEO_BUCKET}"
  echo "  Tablas: ${RETAINED_CATALOG_TABLE}, ${RETAINED_AUDIT_TABLE}"
  if aws s3api head-bucket --bucket "${RETAINED_VIDEO_BUCKET}" "${AWS_ARGS[@]}" >/dev/null 2>&1; then
    aws s3 rm "s3://${RETAINED_VIDEO_BUCKET}/" --recursive "${AWS_ARGS[@]}"
    aws s3api delete-bucket --bucket "${RETAINED_VIDEO_BUCKET}" "${AWS_ARGS[@]}"
  fi
  for table in "${RETAINED_CATALOG_TABLE}" "${RETAINED_AUDIT_TABLE}"; do
    if aws dynamodb describe-table --table-name "${table}" "${AWS_ARGS[@]}" >/dev/null 2>&1; then
      aws dynamodb delete-table --table-name "${table}" "${AWS_ARGS[@]}" >/dev/null
      aws dynamodb wait table-not-exists --table-name "${table}" "${AWS_ARGS[@]}"
    fi
  done
  echo "Recursos retenidos eliminados."
  exit 0
fi

if ! stack_exists "${STACK_NAME_VALUE}"; then
  echo "ERROR: no existe el stack ${STACK_NAME_VALUE}." >&2
  exit 1
fi

VIDEO_BUCKET="$(stack_output VideoBucketName)"
SPA_BUCKET="$(stack_output SpaBucketName)"
CATALOG_TABLE="$(stack_output CatalogTableName)"
AUDIT_TABLE="$(stack_output AuditTableName)"

active_uploader_key_count() {
  if [[ -z "${UPLOADER_IAM_USER_NAME_VALUE}" ]]; then
    echo "0"
    return
  fi
  local count
  count="$(aws iam list-access-keys \
    --user-name "${UPLOADER_IAM_USER_NAME_VALUE}" \
    --profile "${AWS_PROFILE_VALUE}" \
    --query 'length(AccessKeyMetadata[?Status==`Active`])' \
    --output text 2>/dev/null || true)"
  [[ "${count}" =~ ^[0-9]+$ ]] && echo "${count}" || echo "unknown"
}

count_bucket() {
  local response
  response="$(aws s3api list-objects-v2 --bucket "$1" --max-keys 1000 --no-paginate \
    "${AWS_ARGS[@]}" --output json 2>/dev/null || true)"
  if [[ -z "${response}" ]]; then
    echo "desconocido"
    return
  fi
  python3 -c '
import json, sys
d = json.load(sys.stdin)
items = d.get("Contents", [])
count = len(items)
size = sum(item.get("Size", 0) for item in items)
suffix = "+ (muestra truncada)" if d.get("IsTruncated") else ""
print(f"{count}{suffix} objetos; {size} bytes en la muestra")
' <<<"${response}"
}

print_plan() {
  echo "== Plan de teardown (solo lectura) =="
  echo "Cuenta/perfil : ${AWS_PROFILE_VALUE}"
  echo "Región        : ${AWS_REGION_VALUE}"
  echo "Stack         : ${STACK_NAME_VALUE}"
  echo "Video bucket  : ${VIDEO_BUCKET} (objetos/bytes: $(count_bucket "${VIDEO_BUCKET}"))"
  echo "SPA bucket    : ${SPA_BUCKET} (objetos/bytes: $(count_bucket "${SPA_BUCKET}"))"
  echo "Catálogo      : ${CATALOG_TABLE}"
  echo "Auditoría     : ${AUDIT_TABLE}"
  if [[ -n "${UPLOADER_IAM_USER_NAME_VALUE}" ]]; then
    echo "Usuario uploader: ${UPLOADER_IAM_USER_NAME_VALUE} (keys activas: $(active_uploader_key_count); no administradas por el stack)"
  else
    echo "Usuario uploader: no configurado (Roles Anywhere o stack legado)"
  fi
  for stack in "${ONPREM_STACK}" "${OLD_ONPREM_STACK}"; do
    if stack_exists "${stack}"; then
      status="$(aws cloudformation describe-stacks --stack-name "${stack}" "${AWS_ARGS[@]}" --query 'Stacks[0].StackStatus' --output text)"
      echo "Stack auxiliar: ${stack} (${status})"
    fi
  done
  echo "Modo retain   : elimina app/usuarios; conserva videos, catálogo y auditoría."
  echo "Modo purge    : elimina permanentemente todos los datos y recursos PoC."
}

print_plan
[[ "${MODE}" == "plan" ]] && exit 0

if [[ "${CONFIRM}" != "${STACK_NAME_VALUE}" ]]; then
  echo "ERROR: confirme con --confirm ${STACK_NAME_VALUE}" >&2
  exit 2
fi

if [[ -n "${UPLOADER_IAM_USER_NAME_VALUE}" ]]; then
  ACTIVE_UPLOADER_KEYS="$(active_uploader_key_count)"
  if [[ "${ACTIVE_UPLOADER_KEYS}" == "unknown" ]]; then
    echo "ERROR: no se pudo verificar el estado de access keys de ${UPLOADER_IAM_USER_NAME_VALUE}." >&2
    echo "       El teardown se detiene para evitar uploads concurrentes." >&2
    exit 1
  fi
  if ((ACTIVE_UPLOADER_KEYS > 0)); then
    echo "ERROR: ${UPLOADER_IAM_USER_NAME_VALUE} todavía tiene ${ACTIVE_UPLOADER_KEYS} access key(s) activa(s)." >&2
    echo "       Deshabilítelas en IAM y repita el teardown." >&2
    exit 1
  fi
fi

OUTPUT_DIR="${REPO_ROOT}/teardown-output"
mkdir -p "${OUTPUT_DIR}"
MANIFEST="${OUTPUT_DIR}/${STACK_NAME_VALUE}-$(date -u +%Y%m%dT%H%M%SZ).txt"
cat > "${MANIFEST}" <<EOF
stack_name=${STACK_NAME_VALUE}
mode=${MODE}
video_bucket=${VIDEO_BUCKET}
spa_bucket=${SPA_BUCKET}
catalog_table=${CATALOG_TABLE}
audit_table=${AUDIT_TABLE}
region=${AWS_REGION_VALUE}
EOF
chmod 600 "${MANIFEST}"
echo "Manifiesto local: ${MANIFEST}"

# Stop/delete optional simulated on-prem stacks first so they cannot upload.
for stack in "${ONPREM_STACK}" "${OLD_ONPREM_STACK}"; do
  if stack_exists "${stack}"; then
    echo "Eliminando stack auxiliar ${stack}…"
    aws cloudformation delete-stack --stack-name "${stack}" "${AWS_ARGS[@]}"
    aws cloudformation wait stack-delete-complete --stack-name "${stack}" "${AWS_ARGS[@]}"
  fi
done

# The SPA bucket is application code, not customer data; empty it so CFN can delete it.
echo "Vaciando bucket de aplicación ${SPA_BUCKET}…"
aws s3 rm "s3://${SPA_BUCKET}/" --recursive "${AWS_ARGS[@]}"

if [[ "${MODE}" == "purge" ]]; then
  echo "PURGE: vaciando videos permanentemente…"
  aws s3 rm "s3://${VIDEO_BUCKET}/" --recursive "${AWS_ARGS[@]}"
fi

echo "Eliminando stack principal ${STACK_NAME_VALUE}…"
aws cloudformation delete-stack --stack-name "${STACK_NAME_VALUE}" "${AWS_ARGS[@]}"
aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME_VALUE}" "${AWS_ARGS[@]}"

# Trust anchor and SSM cert parameters were created outside the main stack.
TA_ID="$(aws rolesanywhere list-trust-anchors "${AWS_ARGS[@]}" \
  --query "trustAnchors[?name=='${PROJECT_NAME_VALUE}-${ENVIRONMENT_VALUE}-trust-anchor'].trustAnchorId | [0]" \
  --output text 2>/dev/null || true)"
if [[ -n "${TA_ID}" && "${TA_ID}" != "None" ]]; then
  aws rolesanywhere disable-trust-anchor --trust-anchor-id "${TA_ID}" "${AWS_ARGS[@]}" >/dev/null 2>&1 || true
  aws rolesanywhere delete-trust-anchor --trust-anchor-id "${TA_ID}" "${AWS_ARGS[@]}"
fi
aws ssm delete-parameters --names "${CERT_PARAM}" "${KEY_PARAM}" "${AWS_ARGS[@]}" >/dev/null 2>&1 || true

if [[ "${MODE}" == "retain" ]]; then
  # Reapply security controls because the stack-owned bucket policy was removed.
  policy_file="$(mktemp)"
  python3 - "${VIDEO_BUCKET}" "${policy_file}" "${IP_ALLOWLIST_MODE_VALUE}" "${OFFICE_ALLOWED_CIDRS_VALUE}" <<'PY'
import json, sys
bucket, path, ip_mode, cidrs = sys.argv[1:]
statements = [{
  "Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*","Action":"s3:*",
  "Resource":[f"arn:aws:s3:::{bucket}",f"arn:aws:s3:::{bucket}/*"],
  "Condition":{"Bool":{"aws:SecureTransport":"false"}}
}]
if ip_mode == "enforce" and cidrs:
    statements.append({
      "Sid":"RestrictGetObjectToOfficeCidrs","Effect":"Deny","Principal":"*",
      "Action":"s3:GetObject","Resource":f"arn:aws:s3:::{bucket}/*",
      "Condition":{"NotIpAddress":{"aws:SourceIp":[x.strip() for x in cidrs.split(",") if x.strip()]}}
    })
policy = {"Version":"2012-10-17","Statement":statements}
open(path,"w").write(json.dumps(policy))
PY
  aws s3api put-bucket-policy --bucket "${VIDEO_BUCKET}" --policy "file://${policy_file}" "${AWS_ARGS[@]}"
  rm -f "${policy_file}"
  echo "Retenidos: ${VIDEO_BUCKET}, ${CATALOG_TABLE}, ${AUDIT_TABLE}."
else
  echo "PURGE: eliminando recursos retenidos…"
  aws s3api delete-bucket --bucket "${VIDEO_BUCKET}" "${AWS_ARGS[@]}"
  aws dynamodb delete-table --table-name "${CATALOG_TABLE}" "${AWS_ARGS[@]}" >/dev/null
  aws dynamodb delete-table --table-name "${AUDIT_TABLE}" "${AWS_ARGS[@]}" >/dev/null
fi

echo "Teardown ${MODE} completado. Revise el manifiesto ${MANIFEST}."
