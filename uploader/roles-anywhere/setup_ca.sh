#!/usr/bin/env bash
#
# setup_ca.sh — generate a demo Certificate Authority + a client certificate for
# IAM Roles Anywhere. The CA cert becomes the trust anchor; the client cert +
# private key live on the Windows recording server and are exchanged (by the
# aws_signing_helper credential-process) for short-lived AWS credentials.
#
# DEMO/PROTOTYPE ONLY. For production the customer uses their own CA (or AWS
# Private CA) and follows the runbook (README.md) in their account.
#
# Output (in ./certs, git-ignored):
#   ca.key       CA private key (KEEP OFFLINE / SECRET)
#   ca.crt       CA certificate  -> upload as the Roles Anywhere trust anchor
#   client.key   client private key (goes on the Windows server)
#   client.crt   client certificate signed by the CA
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS="${SCRIPT_DIR}/certs"
DAYS_CA="${DAYS_CA:-1825}"     # CA valid 5 years
DAYS_CLIENT="${DAYS_CLIENT:-90}"  # client cert 90 days — rotate before expiry
CN_CLIENT="${CN_CLIENT:-cctv-uploader}"

mkdir -p "${CERTS}"
cd "${CERTS}"

if [[ -f ca.crt && "${1:-}" != "--force" ]]; then
  echo "CA already exists in ${CERTS} (use --force to regenerate). Skipping CA."
else
  echo "Generating CA (valid ${DAYS_CA} days)…"
  openssl genrsa -out ca.key 4096
  openssl req -x509 -new -nodes -key ca.key -sha256 -days "${DAYS_CA}" \
    -out ca.crt -subj "/CN=cctv-storeindexer-demo-ca/O=Prototype" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
fi

echo "Generating client certificate '${CN_CLIENT}' (valid ${DAYS_CLIENT} days)…"
openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr -subj "/CN=${CN_CLIENT}/O=Prototype"
# End-entity cert MUST carry CA:FALSE, keyUsage=digitalSignature and
# extendedKeyUsage=clientAuth. Select an explicit extension section; OpenSSL can
# silently omit bare -extfile directives when no section is selected.
CLIENT_EXTENSIONS="$(mktemp "${TMPDIR:-/tmp}/cctv-client-ext.XXXXXX")"
cat >"${CLIENT_EXTENSIONS}" <<'EOF'
[v3_client]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
EOF
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days "${DAYS_CLIENT}" -sha256 \
  -extfile "${CLIENT_EXTENSIONS}" -extensions v3_client
rm -f "${CLIENT_EXTENSIONS}" client.csr

echo
echo "Done. Files in ${CERTS}:"
ls -1 "${CERTS}"
echo
echo "Next: deploy with the CA trust anchor —"
echo "  ROLESANYWHERE_CA_FILE=${CERTS}/ca.crt ./infra/deploy.sh"
echo "Then configure the Windows server with client.crt + client.key (see README.md)."
