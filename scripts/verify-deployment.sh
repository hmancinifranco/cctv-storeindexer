#!/usr/bin/env bash
# Read-only verification of the deployed customer stack.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_deploy_env

failures=0
pass() { echo "  OK    $*"; }
fail() { echo "  ERROR $*" >&2; failures=$((failures + 1)); }
warn() { echo "  AVISO $*"; }

STACK_STATUS="$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME_VALUE}" "${AWS_ARGS[@]}" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
[[ "${STACK_STATUS}" == *_COMPLETE ]] && pass "stack ${STACK_NAME_VALUE}: ${STACK_STATUS}" || fail "stack: ${STACK_STATUS:-no encontrado}"

VIDEO_BUCKET="$(stack_output VideoBucketName)"
SPA_BUCKET="$(stack_output SpaBucketName)"
CATALOG_TABLE="$(stack_output CatalogTableName)"
AUDIT_TABLE="$(stack_output AuditTableName)"
CLOUDFRONT_URL="$(stack_output CloudFrontUrl)"

for bucket in "${VIDEO_BUCKET}" "${SPA_BUCKET}"; do
  bpa="$(aws s3api get-public-access-block --bucket "${bucket}" "${AWS_ARGS[@]}" \
    --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
    --output text 2>/dev/null || true)"
  [[ "${bpa}" == $'True\tTrue\tTrue\tTrue' ]] && pass "S3 ${bucket}: Block Public Access completo" || fail "S3 ${bucket}: Block Public Access=${bpa}"

  encryption="$(aws s3api get-bucket-encryption --bucket "${bucket}" "${AWS_ARGS[@]}" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
    --output text 2>/dev/null || true)"
  [[ -n "${encryption}" && "${encryption}" != "None" ]] && pass "S3 ${bucket}: cifrado ${encryption}" || fail "S3 ${bucket}: cifrado no verificado"
done

for table in "${CATALOG_TABLE}" "${AUDIT_TABLE}"; do
  status="$(aws dynamodb describe-table --table-name "${table}" "${AWS_ARGS[@]}" \
    --query 'Table.TableStatus' --output text 2>/dev/null || true)"
  [[ "${status}" == "ACTIVE" ]] && pass "DynamoDB ${table}: ACTIVE" || fail "DynamoDB ${table}: ${status:-no encontrada}"
done

root_code="$(curl -sS -o /dev/null -w '%{http_code}' "${CLOUDFRONT_URL}/" || true)"
[[ "${root_code}" == "200" ]] && pass "CloudFront SPA: HTTP 200" || fail "CloudFront SPA: HTTP ${root_code}"

health_code="$(curl -sS -o /dev/null -w '%{http_code}' "${CLOUDFRONT_URL}/v1/health" || true)"
[[ "${health_code}" == "200" ]] && pass "API health vía CloudFront: HTTP 200" || fail "API health: HTTP ${health_code}"

unauth_code="$(curl -sS -o /dev/null -w '%{http_code}' "${CLOUDFRONT_URL}/v1/videos?date=2026-01-01" || true)"
[[ "${unauth_code}" == "401" || "${unauth_code}" == "403" ]] && pass "API sin sesión rechazada: HTTP ${unauth_code}" || fail "API sin sesión respondió HTTP ${unauth_code}"

if [[ "${IP_ALLOWLIST_MODE_VALUE}" == "disabled" ]]; then
  warn "allowlist de IP deshabilitada; acceso protegido solo por Cognito."
else
  warn "el modo enforce requiere validación desde una IP permitida y otra no permitida."
fi

if [[ "${RETENTION_MODE_VALUE}" == "keep" ]]; then
  pass "retención: keep (sin borrado automático)"
else
  warn "retención: expire/${RETENTION_DAYS_VALUE}; confirme aprobación del cliente."
fi

if [[ "${failures}" -ne 0 ]]; then
  echo "Verificación FALLÓ: ${failures} control(es)." >&2
  exit 1
fi

echo "Verificación básica OK. Falta el E2E autenticado con carga/búsqueda/descarga."
