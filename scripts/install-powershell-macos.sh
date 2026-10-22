#!/usr/bin/env bash
# Install a project-local PowerShell LTS runtime without sudo or global changes.
set -euo pipefail

VERSION="7.6.6"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET="${REPO_ROOT}/.tools/powershell/${VERSION}"
PWSH="${TARGET}/pwsh"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: este instalador local es únicamente para macOS." >&2
  exit 1
fi

case "$(uname -m)" in
  arm64) ARCH="arm64" ;;
  x86_64) ARCH="x64" ;;
  *) echo "ERROR: arquitectura no soportada: $(uname -m)" >&2; exit 1 ;;
esac

if [[ -x "${PWSH}" && "$("${PWSH}" -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')" == "${VERSION}" ]]; then
  echo "PowerShell ${VERSION} ya está instalado en ${PWSH}."
  exit 0
fi

mkdir -p "${TARGET}"
ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/powershell-${VERSION}.XXXXXX.tar.gz")"
URL="https://github.com/PowerShell/PowerShell/releases/download/v${VERSION}/powershell-${VERSION}-osx-${ARCH}.tar.gz"

echo "Descargando PowerShell ${VERSION} LTS para macOS ${ARCH}..."
curl -fL "${URL}" -o "${ARCHIVE}"
tar -xzf "${ARCHIVE}" -C "${TARGET}"
chmod 755 "${PWSH}"

DETECTED="$("${PWSH}" -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
[[ "${DETECTED}" == "${VERSION}" ]] || {
  echo "ERROR: versión inesperada: ${DETECTED}" >&2
  exit 1
}

echo "OK: PowerShell ${DETECTED} instalado localmente en ${PWSH}."
echo "Valide scripts con: make powershell-validate"
