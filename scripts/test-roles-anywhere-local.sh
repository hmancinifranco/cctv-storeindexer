#!/usr/bin/env bash
# Validate IAM Roles Anywhere from this workstation without modifying ~/.aws.
# Uses an isolated temporary AWS config and performs read-only identity/prefix checks.
set -euo pipefail
export PATH="${HOME}/.local/bin:${PATH}:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_deploy_env

CERTIFICATE="${REPO_ROOT}/uploader/roles-anywhere/certs/client.crt"
PRIVATE_KEY="${REPO_ROOT}/uploader/roles-anywhere/certs/client.key"
HELPER="${AWS_SIGNING_HELPER:-$(command -v aws_signing_helper || true)}"
TRUST_ANCHOR_ARN="$(read_env RA_TRUST_ANCHOR_ARN)"
ROLES_ANYWHERE_PROFILE_ARN="$(read_env RA_PROFILE_ARN)"
ROLE_ARN="$(read_env RA_ROLE_ARN)"
VIDEO_BUCKET="$(stack_output VideoBucketName)"
LOCAL_PROFILE="cctv-ra-local-test"
UPLOAD_FIXTURE=false
MAX_ATTEMPTS=12
POLL_SECONDS=5

usage() {
  cat <<'EOF'
Uso:
  ./scripts/test-roles-anywhere-local.sh
  ./scripts/test-roles-anywhere-local.sh --upload-fixture

Sin flags valida credenciales temporales y acceso acotado sin escribir en S3.
Con --upload-fixture sube un AVI sintético único usando Roles Anywhere y valida
S3 -> EventBridge -> SQS -> Lambda -> DynamoDB con el perfil de deployment.
EOF
}

case "${1:-}" in
  "") ;;
  --upload-fixture) UPLOAD_FIXTURE=true ;;
  -h|--help) usage; exit 0 ;;
  *) echo "ERROR: argumento desconocido: $1" >&2; usage >&2; exit 2 ;;
esac

require_value RA_TRUST_ANCHOR_ARN "${TRUST_ANCHOR_ARN}"
require_value RA_PROFILE_ARN "${ROLES_ANYWHERE_PROFILE_ARN}"
require_value RA_ROLE_ARN "${ROLE_ARN}"
[[ -f "${CERTIFICATE}" ]] || { echo "ERROR: falta ${CERTIFICATE}." >&2; exit 1; }
[[ -f "${PRIVATE_KEY}" ]] || { echo "ERROR: falta ${PRIVATE_KEY}." >&2; exit 1; }
[[ -n "${HELPER}" && -x "${HELPER}" ]] || {
  echo "ERROR: aws_signing_helper no está instalado." >&2
  echo "Consulte docs/implementation-manual.md, sección IAM Roles Anywhere." >&2
  exit 1
}

openssl x509 -in "${CERTIFICATE}" -noout -checkend 0 >/dev/null || {
  echo "ERROR: el certificado de cliente está vencido o todavía no es válido." >&2
  exit 1
}

if [[ "$(uname -s)" == "Darwin" ]]; then
  KEY_MODE="$(stat -f '%Lp' "${PRIVATE_KEY}")"
else
  KEY_MODE="$(stat -c '%a' "${PRIVATE_KEY}")"
fi
[[ "${KEY_MODE}" == "600" ]] || {
  echo "ERROR: la clave privada debe tener permisos 600; actual=${KEY_MODE}." >&2
  exit 1
}

EXPECTED_ACCOUNT="$(printf '%s' "${ROLE_ARN}" | cut -d: -f5)"
TEMP_CONFIG="$(mktemp "${TMPDIR:-/tmp}/cctv-ra-config.XXXXXX")"
cleanup() {
  chmod 600 "${TEMP_CONFIG}" 2>/dev/null || true
  rm -f "${TEMP_CONFIG}"
}
trap cleanup EXIT
chmod 600 "${TEMP_CONFIG}"

cat >"${TEMP_CONFIG}" <<EOF
[profile ${LOCAL_PROFILE}]
credential_process = ${HELPER} credential-process --certificate ${CERTIFICATE} --private-key ${PRIVATE_KEY} --trust-anchor-arn ${TRUST_ANCHOR_ARN} --profile-arn ${ROLES_ANYWHERE_PROFILE_ARN} --role-arn ${ROLE_ARN}
region = ${AWS_REGION_VALUE}
output = json
EOF

run_with_roles_anywhere() {
  AWS_CONFIG_FILE="${TEMP_CONFIG}" \
  AWS_SHARED_CREDENTIALS_FILE="/dev/null" \
  aws "$@" --profile "${LOCAL_PROFILE}" --region "${AWS_REGION_VALUE}"
}

IDENTITY="$(run_with_roles_anywhere sts get-caller-identity --output json)"
ACTUAL_ACCOUNT="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])' <<<"${IDENTITY}")"
ACTUAL_ARN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Arn"])' <<<"${IDENTITY}")"

[[ "${ACTUAL_ACCOUNT}" == "${EXPECTED_ACCOUNT}" ]] || {
  echo "ERROR: Roles Anywhere devolvió la cuenta ${ACTUAL_ACCOUNT}; se esperaba ${EXPECTED_ACCOUNT}." >&2
  exit 1
}
[[ "${ACTUAL_ARN}" == *":assumed-role/${ROLE_ARN##*/}/"* ]] || {
  echo "ERROR: identidad inesperada: ${ACTUAL_ARN}" >&2
  exit 1
}

# Read-only authorization check. The uploader role may list only the ingest prefix.
KEY_COUNT="$(run_with_roles_anywhere s3api list-objects-v2 \
  --bucket "${VIDEO_BUCKET}" --prefix "${INGEST_PREFIX_VALUE}/" --max-keys 1 \
  --query KeyCount --output text)"

echo "OK: IAM Roles Anywhere emitió credenciales temporales válidas."
echo "Cuenta : ${ACTUAL_ACCOUNT}"
echo "Rol    : ${ACTUAL_ARN}"
echo "Sesión : el helper renueva credenciales mediante credential_process."
echo "S3     : acceso de listado acotado al prefijo aprobado (KeyCount=${KEY_COUNT})."

if [[ "${UPLOAD_FIXTURE}" != true ]]; then
  echo "No se modificó ~/.aws/config, no se imprimieron credenciales y no se escribió en S3."
  exit 0
fi

SOURCE_FIXTURE="${REPO_ROOT}/uploader/synthetic/out/CAM02_20260921_142530-142959.avi"
[[ -f "${SOURCE_FIXTURE}" ]] || {
  echo "ERROR: falta el fixture ${SOURCE_FIXTURE}." >&2
  echo "Genérelo con uploader/synthetic/generate_fixtures.py." >&2
  exit 1
}

make_test_key() {
  local local_timestamp
  local_timestamp="$(TZ=America/Argentina/Buenos_Aires date +%Y%m%d_%H%M%S)"
  printf '%s/CAM93_%s.avi' "${INGEST_PREFIX_VALUE}" "${local_timestamp}"
}

TEST_KEY="$(make_test_key)"
if aws s3api head-object --bucket "${VIDEO_BUCKET}" --key "${TEST_KEY}" \
  "${AWS_ARGS[@]}" >/dev/null 2>&1; then
  sleep 1
  TEST_KEY="$(make_test_key)"
fi

echo "Subiendo fixture con Roles Anywhere: s3://${VIDEO_BUCKET}/${TEST_KEY}"
run_with_roles_anywhere s3 cp "${SOURCE_FIXTURE}" \
  "s3://${VIDEO_BUCKET}/${TEST_KEY}" \
  --content-type video/x-msvideo --only-show-errors

# Least privilege: the uploader can PUT/list but must not read video contents.
if run_with_roles_anywhere s3api head-object \
  --bucket "${VIDEO_BUCKET}" --key "${TEST_KEY}" >/dev/null 2>&1; then
  echo "ERROR: el rol uploader pudo leer metadata del objeto; revise mínimo privilegio." >&2
  exit 1
else
  echo "OK: el rol uploader no puede leer el objeto que cargó."
fi

HEAD="$(aws s3api head-object --bucket "${VIDEO_BUCKET}" --key "${TEST_KEY}" \
  "${AWS_ARGS[@]}" --query '{Size:ContentLength,Encryption:ServerSideEncryption}' \
  --output json)"
OBJECT_ID="$(python3 - "${VIDEO_BUCKET}" "${TEST_KEY}" <<'PY'
import hashlib
import sys
bucket, key = sys.argv[1:]
print(hashlib.sha256(f"{bucket}/{key}/".encode()).hexdigest()[:16])
PY
)"

CATALOG_TABLE="$(stack_output CatalogTableName)"
CATALOG_STATUS=""
LIFECYCLE_STATE=""
for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
  ITEM="$(aws dynamodb query --table-name "${CATALOG_TABLE}" \
    --index-name by-object --key-condition-expression 'GSI2PK = :oid' \
    --expression-attribute-values "{\":oid\":{\"S\":\"OBJ#${OBJECT_ID}\"}}" \
    "${AWS_ARGS[@]}" --output json)"
  CATALOG_STATUS="$(python3 -c 'import json,sys; items=json.load(sys.stdin)["Items"]; print(items[0].get("catalogStatus",{}).get("S","") if items else "")' <<<"${ITEM}")"
  LIFECYCLE_STATE="$(python3 -c 'import json,sys; items=json.load(sys.stdin)["Items"]; print(items[0].get("lifecycleState",{}).get("S","") if items else "")' <<<"${ITEM}")"
  [[ "${CATALOG_STATUS}" == "OK" && "${LIFECYCLE_STATE}" == "AVAILABLE" ]] && break
  printf 'Esperando indexación (%d/%d)...\n' "${attempt}" "${MAX_ATTEMPTS}"
  sleep "${POLL_SECONDS}"
done

if [[ "${CATALOG_STATUS}" != "OK" || "${LIFECYCLE_STATE}" != "AVAILABLE" ]]; then
  echo "ERROR: el fixture se cargó, pero no llegó a OK/AVAILABLE." >&2
  echo "Objeto conservado para diagnóstico: s3://${VIDEO_BUCKET}/${TEST_KEY}" >&2
  exit 1
fi

printf 'S3=%s\n' "${HEAD}"
echo "OK: carga con Roles Anywhere e indexación E2E completadas."
echo "Catálogo: ${CATALOG_STATUS}/${LIFECYCLE_STATE}"
echo "Objeto conservado para la demo: s3://${VIDEO_BUCKET}/${TEST_KEY}"
echo "No se modificó ~/.aws/config ni se imprimieron credenciales."
