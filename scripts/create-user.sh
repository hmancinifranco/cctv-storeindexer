#!/usr/bin/env bash
# Create or reuse a Cognito user and ensure membership in Operators.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

EMAIL="${1:-}"
if [[ -z "${EMAIL}" || "${EMAIL}" != *@*.* ]]; then
  echo "Uso: $0 <email-del-operador>" >&2
  exit 2
fi

load_deploy_env
USER_POOL="$(stack_output UserPoolId)"
require_value UserPoolId "${USER_POOL}"

if aws cognito-idp admin-get-user \
  --user-pool-id "${USER_POOL}" --username "${EMAIL}" \
  "${AWS_ARGS[@]}" >/dev/null 2>&1; then
  echo "El usuario ${EMAIL} ya existe."
else
  echo "Creando ${EMAIL}; Cognito enviará la contraseña temporal por email."
  aws cognito-idp admin-create-user \
    --user-pool-id "${USER_POOL}" \
    --username "${EMAIL}" \
    --user-attributes "Name=email,Value=${EMAIL}" "Name=email_verified,Value=true" \
    --desired-delivery-mediums EMAIL \
    "${AWS_ARGS[@]}" >/dev/null
fi

aws cognito-idp admin-add-user-to-group \
  --user-pool-id "${USER_POOL}" \
  --username "${EMAIL}" \
  --group-name Operators \
  "${AWS_ARGS[@]}"

echo "Usuario listo en el grupo Operators: ${EMAIL}"
echo "En el primer login deberá establecer una contraseña permanente."
