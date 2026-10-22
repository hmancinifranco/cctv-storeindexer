#!/usr/bin/env bash
# Install the validated IAM Roles Anywhere credential helper for the current user.
set -euo pipefail

VERSION="1.8.5"
INSTALL_DIR="${HOME}/.local/bin"
DESTINATION="${INSTALL_DIR}/aws_signing_helper"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: este instalador es únicamente para macOS." >&2
  exit 1
fi

case "$(uname -m)" in
  arm64) ARCH="Aarch64" ;;
  x86_64) ARCH="X86_64" ;;
  *) echo "ERROR: arquitectura no soportada: $(uname -m)" >&2; exit 1 ;;
esac

URL="https://rolesanywhere.amazonaws.com/releases/${VERSION}/${ARCH}/MacOS/Sonoma/aws_signing_helper"
TEMP_FILE="$(mktemp "${TMPDIR:-/tmp}/aws-signing-helper.XXXXXX")"
cleanup() { rm -f "${TEMP_FILE}"; }
trap cleanup EXIT

mkdir -p "${INSTALL_DIR}"
echo "Descargando aws_signing_helper ${VERSION} desde AWS..."
curl -fL "${URL}" -o "${TEMP_FILE}"
chmod 755 "${TEMP_FILE}"

DETECTED_VERSION="$("${TEMP_FILE}" version)"
if [[ "${DETECTED_VERSION}" != "${VERSION}" ]]; then
  echo "ERROR: versión inesperada: ${DETECTED_VERSION}" >&2
  exit 1
fi

install -m 755 "${TEMP_FILE}" "${DESTINATION}"
echo "OK: instalado ${DESTINATION} (${DETECTED_VERSION}, $(uname -m))."
echo "Ejecute: ./scripts/test-roles-anywhere-local.sh"
