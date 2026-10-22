#!/usr/bin/env bash
# Validate tools, target identity and safety choices before deployment.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ALLOW_COGNITO_ONLY=false
ALLOW_EXPIRATION=false
for arg in "$@"; do
  case "$arg" in
    --allow-cognito-only) ALLOW_COGNITO_ONLY=true ;;
    --allow-expiration) ALLOW_EXPIRATION=true ;;
    -h|--help)
      echo "Uso: $0 [--allow-cognito-only] [--allow-expiration]"
      exit 0 ;;
    *) echo "ERROR: opción desconocida: $arg" >&2; exit 2 ;;
  esac
done

load_deploy_env
errors=0

check_command() {
  if require_command "$1" "$2"; then printf "  OK  %s\n" "$1"; else errors=$((errors + 1)); fi
}

check_aws_cli_v2() {
  if ! require_command aws "Instale AWS CLI v2."; then
    errors=$((errors + 1))
    return
  fi
  local version major minor
  version="$(aws --version 2>&1)"
  if [[ "${version}" =~ ^aws-cli/([0-9]+)\.([0-9]+)\. ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
  else
    major="0"
    minor="0"
  fi
  if ((major == 2)); then
    printf "  OK  aws (%s)\n" "${version%% *}"
    if ((minor < 32)); then
      echo "  AVISO: aws login requiere AWS CLI 2.32.0+; actualice si usará credenciales de consola."
    fi
  else
    echo "  ERROR: se requiere AWS CLI v2; detectado: ${version}" >&2
    errors=$((errors + 1))
  fi
}

check_node_20_or_later() {
  if ! require_command node "Instale Node.js 20 LTS o posterior."; then
    errors=$((errors + 1))
    return
  fi
  local version major
  version="$(node --version)"
  major="${version#v}"
  major="${major%%.*}"
  if [[ "${major}" =~ ^[0-9]+$ ]] && ((major >= 20)); then
    printf "  OK  node (%s)\n" "${version}"
  else
    echo "  ERROR: se requiere Node.js 20 o posterior; detectado: ${version}" >&2
    errors=$((errors + 1))
  fi
}

check_python_3_12_or_later() {
  if ! require_command python3 "Instale Python 3.12 o posterior."; then
    errors=$((errors + 1))
    return
  fi
  local version supported
  version="$(python3 --version 2>&1)"
  supported="$(python3 -c 'import sys; print("yes" if sys.version_info >= (3, 12) else "no")')"
  if [[ "${supported}" == "yes" ]]; then
    printf "  OK  python3 (%s)\n" "${version#Python }"
  else
    echo "  ERROR: se requiere Python 3.12 o posterior; detectado: ${version}" >&2
    errors=$((errors + 1))
  fi
}

echo "== Herramientas =="
check_aws_cli_v2
check_command sam "Instale AWS SAM CLI."
check_node_20_or_later
check_command npm "Instale npm junto con Node.js."
check_python_3_12_or_later
if [[ "${ROLES_ANYWHERE_ENABLED_VALUE}" == "true" || -n "${RA_PROFILE_ARN_VALUE}" ]]; then
  check_command openssl "Instale OpenSSL para IAM Roles Anywhere."
else
  echo "  OMIT openssl (solo requerido por el roadmap IAM Roles Anywhere)"
fi
check_command git "Instale Git o use un paquete entregado fuera de Git."

if [[ "${errors}" -eq 0 ]]; then
  echo
  echo "== Cuenta de destino =="
  identity_json="$(aws sts get-caller-identity "${AWS_ARGS[@]}")" || {
    echo "ERROR: no fue posible autenticar el perfil ${AWS_PROFILE_VALUE}." >&2
    echo "  Si usa aws login: aws login --profile ${AWS_PROFILE_VALUE}" >&2
    echo "  Si usa IAM Identity Center: aws sso login --profile ${AWS_PROFILE_VALUE}" >&2
    echo "  Si usa access keys: aws configure --profile ${AWS_PROFILE_VALUE}" >&2
    echo "  Luego verifique: aws sts get-caller-identity --profile ${AWS_PROFILE_VALUE} --region ${AWS_REGION_VALUE}" >&2
    errors=$((errors + 1))
    identity_json=""
  }
  if [[ -n "${identity_json}" ]]; then
    account="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])' <<<"${identity_json}")"
    arn="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Arn"])' <<<"${identity_json}")"
    echo "  Perfil : ${AWS_PROFILE_VALUE}"
    echo "  Cuenta : ${account}"
    echo "  Rol    : ${arn}"
    echo "  Región : ${AWS_REGION_VALUE}"
    echo "  Stack  : ${STACK_NAME_VALUE}"
  fi
fi


echo
echo "== Credenciales del uploader =="
if [[ -n "${UPLOADER_IAM_USER_NAME_VALUE}" ]]; then
  if aws iam get-user --user-name "${UPLOADER_IAM_USER_NAME_VALUE}" \
      --profile "${AWS_PROFILE_VALUE}" >/dev/null 2>&1; then
    echo "  OK: usuario IAM técnico existente: ${UPLOADER_IAM_USER_NAME_VALUE}"
    echo "  OK: el stack le concederá únicamente sts:AssumeRole sobre el uploader role."
  else
    echo "  ERROR: no existe o no puede verificarse el usuario IAM ${UPLOADER_IAM_USER_NAME_VALUE}." >&2
    errors=$((errors + 1))
  fi
elif [[ "${ROLES_ANYWHERE_ENABLED_VALUE}" == "true" || -n "${RA_PROFILE_ARN_VALUE}" ]]; then
  echo "  OK: IAM Roles Anywhere habilitado como mecanismo uploader."
else
  echo "  ERROR: configure UPLOADER_IAM_USER_NAME para la PoC o habilite Roles Anywhere." >&2
  errors=$((errors + 1))
fi

if [[ "${ROLES_ANYWHERE_ENABLED_VALUE}" == "true" && -n "${UPLOADER_IAM_USER_NAME_VALUE}" ]]; then
  echo "  AVISO: ambos mecanismos estarán habilitados sobre el mismo role acotado."
fi

echo
echo "== Controles de seguridad =="
if [[ "${IP_ALLOWLIST_MODE_VALUE}" == "enforce" ]]; then
  if [[ -z "${OFFICE_ALLOWED_CIDRS_VALUE}" ]]; then
    echo "  ERROR: OFFICE_ALLOWED_CIDRS está vacío en modo enforce." >&2
    errors=$((errors + 1))
  else
    echo "  ERROR: el template actual aún no crea WAF para CloudFront/API." >&2
    echo "         El modo enforce no puede desplegarse hasta completar ese control." >&2
    errors=$((errors + 1))
  fi
elif [[ "${IP_ALLOWLIST_MODE_VALUE}" == "disabled" ]]; then
  if [[ "${ALLOW_COGNITO_ONLY}" != true ]]; then
    echo "  ERROR: el acceso por IP está deshabilitado." >&2
    echo "         Para una prueba aceptada con solo Cognito, repita con --allow-cognito-only." >&2
    errors=$((errors + 1))
  else
    echo "  ADVERTENCIA: acceso por IP deshabilitado; Cognito sigue siendo obligatorio."
  fi
else
  echo "  ERROR: IP_ALLOWLIST_MODE debe ser enforce o disabled." >&2
  errors=$((errors + 1))
fi

if [[ "${RETENTION_MODE_VALUE}" == "expire" ]]; then
  if [[ "${ALLOW_EXPIRATION}" != true ]]; then
    echo "  ERROR: la expiración automática está activa (${RETENTION_DAYS_VALUE} días)." >&2
    echo "         Use RETENTION_MODE=keep o confirme la prueba con --allow-expiration." >&2
    errors=$((errors + 1))
  else
    echo "  ADVERTENCIA: objetos configurados para expirar a los ${RETENTION_DAYS_VALUE} días."
  fi
elif [[ "${RETENTION_MODE_VALUE}" == "keep" ]]; then
  echo "  OK: sin borrado automático de videos."
else
  echo "  ERROR: RETENTION_MODE debe ser keep o expire." >&2
  errors=$((errors + 1))
fi

if [[ "${errors}" -ne 0 ]]; then
  echo
  echo "Preflight FALLÓ con ${errors} problema(s). No despliegue." >&2
  exit 1
fi

echo
echo "Preflight OK. Revise cuenta, región y advertencias antes de continuar."
