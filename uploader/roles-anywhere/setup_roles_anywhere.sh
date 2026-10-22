#!/usr/bin/env bash
#
# setup_roles_anywhere.sh — provision IAM Roles Anywhere end to end:
#   1. create (or reuse) the TRUST ANCHOR via CLI from the CA cert
#      (CLI reads the PEM file directly — avoids the multi-line SAM param issue),
#   2. deploy the upload ROLE + PROFILE via SAM (RolesAnywhereEnabled=true),
#   3. write RA_TRUST_ANCHOR_ARN / RA_PROFILE_ARN / RA_ROLE_ARN into .env.
#
# Reads AWS_PROFILE / AWS_REGION / PROJECT_NAME / ENVIRONMENT / STACK_NAME from
# .env. Run setup_ca.sh first to generate certs/ca.crt.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
CA_CERT="${SCRIPT_DIR}/certs/ca.crt"

read_env() { grep -E "^[[:space:]]*$1=" "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

PROFILE="$(read_env AWS_PROFILE)"; REGION="$(read_env AWS_REGION)"
PROJECT="$(read_env PROJECT_NAME)"; ENVIRONMENT="$(read_env ENVIRONMENT)"
STACK="$(read_env STACK_NAME)"
AWSP=(--profile "${PROFILE}" --region "${REGION}")
TA_NAME="${PROJECT}-${ENVIRONMENT}-trust-anchor"

[[ -f "${CA_CERT}" ]] || { echo "ERROR: ${CA_CERT} not found. Run setup_ca.sh first." >&2; exit 1; }

# 1) Trust anchor: reuse if one with this name already exists, else create it.
echo "Looking for existing trust anchor '${TA_NAME}'…"
TA_ARN=$(aws rolesanywhere list-trust-anchors "${AWSP[@]}" \
  --query "trustAnchors[?name=='${TA_NAME}'].trustAnchorArn | [0]" --output text 2>/dev/null || echo "None")

if [[ "${TA_ARN}" == "None" || -z "${TA_ARN}" ]]; then
  echo "Creating trust anchor from ${CA_CERT}…"
  TA_ARN=$(aws rolesanywhere create-trust-anchor "${AWSP[@]}" \
    --name "${TA_NAME}" --enabled \
    --source "sourceType=CERTIFICATE_BUNDLE,sourceData={x509CertificateData=$(cat "${CA_CERT}")}" \
    --query 'trustAnchor.trustAnchorArn' --output text)
  echo "Created: ${TA_ARN}"
else
  echo "Reusing: ${TA_ARN}"
fi

# 2) Deploy role + profile via SAM.
echo "Deploying upload role + profile (SAM)…"
ROLES_ANYWHERE_ENABLED=true "${REPO_ROOT}/infra/deploy.sh"

# 3) Read the role/profile ARNs from stack outputs and persist to .env.
PROFILE_ARN=$(aws cloudformation describe-stacks --stack-name "${STACK}" "${AWSP[@]}" \
  --query "Stacks[0].Outputs[?OutputKey=='RaProfileArn'].OutputValue" --output text)
ROLE_ARN=$(aws cloudformation describe-stacks --stack-name "${STACK}" "${AWSP[@]}" \
  --query "Stacks[0].Outputs[?OutputKey=='RaRoleArn'].OutputValue" --output text)

# Update the three RA_* lines in .env in place.
python3 - "$ENV_FILE" "$TA_ARN" "$PROFILE_ARN" "$ROLE_ARN" <<'PY'
import re, sys
path, ta, prof, role = sys.argv[1:5]
s = open(path).read()
for key, val in (("RA_TRUST_ANCHOR_ARN", ta), ("RA_PROFILE_ARN", prof), ("RA_ROLE_ARN", role)):
    if re.search(rf"^{key}=.*$", s, re.M):
        s = re.sub(rf"^{key}=.*$", f"{key}={val}", s, flags=re.M)
    else:
        s += f"\n{key}={val}\n"
open(path, "w").write(s)
print("Updated .env with RA_* ARNs")
PY

echo
echo "Trust anchor : ${TA_ARN}"
echo "Profile ARN  : ${PROFILE_ARN}"
echo "Role ARN     : ${ROLE_ARN}"
echo "Next: configure the Windows server (see README.md section B)."
