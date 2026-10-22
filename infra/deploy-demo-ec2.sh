#!/usr/bin/env bash
#
# deploy-demo-ec2.sh — deploy the simulated on-prem recording server (EC2).
# Puts the RA client cert/key into SSM Parameter Store (SecureString so the key
# is never in logs or UserData), discovers a default-VPC subnet, and deploys the
# standalone demo stack. Reads config + RA_* ARNs from .env.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
CERTS="${REPO_ROOT}/uploader/roles-anywhere/certs"

read_env() { grep -E "^[[:space:]]*$1=" "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

PROFILE="$(read_env AWS_PROFILE)"; REGION="$(read_env AWS_REGION)"
PROJECT="$(read_env PROJECT_NAME)"; ENVIRONMENT="$(read_env ENVIRONMENT)"
BUCKET="$(read_env VIDEO_BUCKET_RESOLVED)"; PREFIX="$(read_env INGEST_PREFIX)"
TA="$(read_env RA_TRUST_ANCHOR_ARN)"; PR="$(read_env RA_PROFILE_ARN)"; RO="$(read_env RA_ROLE_ARN)"
AWSP=(--profile "${PROFILE}" --region "${REGION}")
STACK="${PROJECT}-${ENVIRONMENT}-onprem"
CERT_PARAM="/${PROJECT}/${ENVIRONMENT}/ra/client-cert"
KEY_PARAM="/${PROJECT}/${ENVIRONMENT}/ra/client-key"

for v in PROFILE REGION BUCKET TA PR RO; do
  [[ -n "${!v}" ]] || { echo "ERROR: ${v} empty in .env (run RA setup first)." >&2; exit 1; }
done
[[ -f "${CERTS}/client.crt" ]] || { echo "ERROR: ${CERTS}/client.crt missing (run setup_ca.sh)." >&2; exit 1; }

echo "Storing RA client cert/key in SSM (SecureString for the key)…"
aws ssm put-parameter "${AWSP[@]}" --name "${CERT_PARAM}" --type String --overwrite \
  --value "$(cat "${CERTS}/client.crt")" >/dev/null
aws ssm put-parameter "${AWSP[@]}" --name "${KEY_PARAM}" --type SecureString --overwrite \
  --value "$(cat "${CERTS}/client.key")" >/dev/null

echo "Deploying stack ${STACK} (self-contained VPC)…"
aws cloudformation deploy "${AWSP[@]}" \
  --stack-name "${STACK}" \
  --template-file "${SCRIPT_DIR}/demo-onprem-ec2.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ProjectName="${PROJECT}" Environment="${ENVIRONMENT}" \
    VideoBucketName="${BUCKET}" IngestPrefix="${PREFIX:-videos}" \
    RaTrustAnchorArn="${TA}" RaProfileArn="${PR}" RaRoleArn="${RO}" \
    ClientCertParam="${CERT_PARAM}" ClientKeyParam="${KEY_PARAM}"

INSTANCE=$(aws cloudformation describe-stacks "${AWSP[@]}" --stack-name "${STACK}" --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
echo
echo "Instance: ${INSTANCE}"
echo "Connect : aws ssm start-session --target ${INSTANCE} ${AWSP[*]}"
echo "Scripts on the box: /opt/cctv/upload-via-instance-profile.sh  and  /opt/cctv/upload-via-rolesanywhere.sh"
