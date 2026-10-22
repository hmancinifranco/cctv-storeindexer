#!/usr/bin/env bash
# Delete only the known CAM92 synthetic fixture and verify S3 -> EventBridge ->
# SQS -> Lambda -> DynamoDB. This script is intentionally demo-specific.
set -euo pipefail
export PATH="${PATH}:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

EXPECTED_STACK="cctv-storeindexer-demo"
EXPECTED_KEY="videos/CAM92_20261022_101500.avi"
EXPECTED_SIZE_BYTES="256"
CONFIRMATION="BORRAR-CAM92"
MAX_ATTEMPTS=12
POLL_SECONDS=5

usage() {
  cat <<'EOF'
Uso:
  ./scripts/test-physical-delete.sh

El script elimina únicamente el fixture sintético CAM92 del stack demo, espera
el evento Object Deleted y valida el tombstone, la búsqueda normal y la DLQ.
EOF
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) echo "ERROR: argumento desconocido: $1" >&2; usage >&2; exit 2 ;;
esac

require_command aws "Instale AWS CLI v2."
require_command python3
load_deploy_env

if [[ "${STACK_NAME_VALUE}" != "${EXPECTED_STACK}" ]]; then
  echo "ERROR: este ensayo solo admite STACK_NAME=${EXPECTED_STACK}." >&2
  echo "Actual: ${STACK_NAME_VALUE}" >&2
  exit 1
fi

CALLER_ACCOUNT="$(aws sts get-caller-identity "${AWS_ARGS[@]}" --query Account --output text)"
STACK_ID="$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME_VALUE}" "${AWS_ARGS[@]}" \
  --query 'Stacks[0].StackId' --output text)"
STACK_ACCOUNT="$(printf '%s' "${STACK_ID}" | cut -d: -f5)"

if [[ -z "${CALLER_ACCOUNT}" || "${CALLER_ACCOUNT}" != "${STACK_ACCOUNT}" ]]; then
  echo "ERROR: la cuenta del perfil no coincide con la cuenta propietaria del stack." >&2
  echo "Perfil=${AWS_PROFILE_VALUE}; caller=${CALLER_ACCOUNT}; stack=${STACK_ACCOUNT}" >&2
  exit 1
fi

VIDEO_BUCKET="$(stack_output VideoBucketName)"
CATALOG_TABLE="$(stack_output CatalogTableName)"
QUEUE_URL="$(aws cloudformation describe-stack-resource \
  --stack-name "${STACK_NAME_VALUE}" --logical-resource-id IndexerQueue \
  "${AWS_ARGS[@]}" --query 'StackResourceDetail.PhysicalResourceId' --output text)"
DLQ_URL="$(aws cloudformation describe-stack-resource \
  --stack-name "${STACK_NAME_VALUE}" --logical-resource-id IndexerDLQ \
  "${AWS_ARGS[@]}" --query 'StackResourceDetail.PhysicalResourceId' --output text)"

OBJECT_ID="$(python3 - "${VIDEO_BUCKET}" "${EXPECTED_KEY}" <<'PY'
import hashlib
import sys
bucket, key = sys.argv[1:]
print(hashlib.sha256(f"{bucket}/{key}/".encode()).hexdigest()[:16])
PY
)"

OBJECT_SIZE="$(aws s3api head-object \
  --bucket "${VIDEO_BUCKET}" --key "${EXPECTED_KEY}" "${AWS_ARGS[@]}" \
  --query ContentLength --output text)"
if [[ "${OBJECT_SIZE}" != "${EXPECTED_SIZE_BYTES}" ]]; then
  echo "ERROR: el objeto objetivo no tiene los ${EXPECTED_SIZE_BYTES} bytes esperados." >&2
  echo "No se borró nada. Tamaño observado: ${OBJECT_SIZE}" >&2
  exit 1
fi

cat <<EOF
Ensayo destructivo acotado
  Perfil : ${AWS_PROFILE_VALUE}
  Cuenta : ${CALLER_ACCOUNT}
  Región : ${AWS_REGION_VALUE}
  Stack  : ${STACK_NAME_VALUE}
  Objeto : s3://${VIDEO_BUCKET}/${EXPECTED_KEY}
  Tamaño : ${OBJECT_SIZE} bytes (fixture sintético)
EOF

printf 'Escribí %s para confirmar: ' "${CONFIRMATION}"
read -r REPLY
if [[ "${REPLY}" != "${CONFIRMATION}" ]]; then
  echo "Cancelado: no se eliminó nada."
  exit 1
fi

aws s3api delete-object \
  --bucket "${VIDEO_BUCKET}" --key "${EXPECTED_KEY}" "${AWS_ARGS[@]}" >/dev/null

if aws s3api head-object \
  --bucket "${VIDEO_BUCKET}" --key "${EXPECTED_KEY}" "${AWS_ARGS[@]}" \
  >/dev/null 2>&1; then
  echo "ERROR: el objeto todavía existe en S3." >&2
  exit 1
fi
echo "OK: el fixture ya no existe en S3."

STATE=""
for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
  STATE="$(aws dynamodb query \
    --table-name "${CATALOG_TABLE}" --index-name by-object \
    --key-condition-expression 'GSI2PK = :oid' \
    --expression-attribute-values "{\":oid\":{\"S\":\"OBJ#${OBJECT_ID}\"}}" \
    "${AWS_ARGS[@]}" --query 'Items[0].lifecycleState.S' --output text)"
  [[ "${STATE}" == "DELETED" ]] && break
  printf 'Esperando el tombstone (%d/%d)...\n' "${attempt}" "${MAX_ATTEMPTS}"
  sleep "${POLL_SECONDS}"
done

if [[ "${STATE}" != "DELETED" ]]; then
  echo "ERROR: S3 eliminó el fixture, pero el catálogo no llegó a DELETED." >&2
  exit 1
fi

ITEM_JSON="$(aws dynamodb query \
  --table-name "${CATALOG_TABLE}" --index-name by-object \
  --key-condition-expression 'GSI2PK = :oid' \
  --expression-attribute-values "{\":oid\":{\"S\":\"OBJ#${OBJECT_ID}\"}}" \
  --projection-expression \
    'objectKey, lifecycleState, deleted, deletedAt, deletionReason, deletionType, catalogExpiresAt, lastLifecycleEventType' \
  "${AWS_ARGS[@]}" --output json)"

DELETION_REASON="$(python3 -c \
  'import json,sys; print(json.load(sys.stdin)["Items"][0]["deletionReason"]["S"])' \
  <<<"${ITEM_JSON}")"
if [[ "${DELETION_REASON}" != "DELETE_OBJECT" ]]; then
  echo "ERROR: deletionReason inesperado: ${DELETION_REASON}" >&2
  exit 1
fi

ACTIVE_MATCHES="$(aws dynamodb query \
  --table-name "${CATALOG_TABLE}" \
  --key-condition-expression 'PK = :pk' \
  --filter-expression '(attribute_not_exists(#deleted) OR #deleted = :false) AND objectKey = :key' \
  --expression-attribute-names '{"#deleted":"deleted"}' \
  --expression-attribute-values \
    "{\":pk\":{\"S\":\"DAY#2026-10-22\"},\":false\":{\"BOOL\":false},\":key\":{\"S\":\"${EXPECTED_KEY}\"}}" \
  "${AWS_ARGS[@]}" --select COUNT --query Count --output text)"
ALL_MATCHES="$(aws dynamodb query \
  --table-name "${CATALOG_TABLE}" \
  --key-condition-expression 'PK = :pk' \
  --filter-expression 'objectKey = :key' \
  --expression-attribute-values \
    "{\":pk\":{\"S\":\"DAY#2026-10-22\"},\":key\":{\"S\":\"${EXPECTED_KEY}\"}}" \
  "${AWS_ARGS[@]}" --select COUNT --query Count --output text)"

if [[ "${ACTIVE_MATCHES}" != "0" || "${ALL_MATCHES}" != "1" ]]; then
  echo "ERROR: filtros inesperados: normal=${ACTIVE_MATCHES}, con borrados=${ALL_MATCHES}." >&2
  exit 1
fi

for queue_name in IndexerQueue IndexerDLQ; do
  queue_url="${QUEUE_URL}"
  [[ "${queue_name}" == "IndexerDLQ" ]] && queue_url="${DLQ_URL}"
  visible="$(aws sqs get-queue-attributes \
    --queue-url "${queue_url}" --attribute-names ApproximateNumberOfMessages \
    "${AWS_ARGS[@]}" --query 'Attributes.ApproximateNumberOfMessages' --output text)"
  in_flight="$(aws sqs get-queue-attributes \
    --queue-url "${queue_url}" --attribute-names ApproximateNumberOfMessagesNotVisible \
    "${AWS_ARGS[@]}" --query 'Attributes.ApproximateNumberOfMessagesNotVisible' --output text)"
  if [[ "${visible}" != "0" || "${in_flight}" != "0" ]]; then
    echo "ERROR: ${queue_name} no quedó vacía: visible=${visible}, procesando=${in_flight}." >&2
    exit 1
  fi
done

printf '%s\n' "${ITEM_JSON}"
echo "OK: borrado físico E2E validado."
echo "OK: búsqueda normal oculta el objeto y la vista con borrados conserva el tombstone."
echo "OK: cola y DLQ están vacías."
