#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_DIR="${BASE_DIR}/tools/ventoy"

echo "Downloading Ventoy..."
if command -v curl >/dev/null 2>&1; then
	VERSION=$(curl -fsSL https://api.github.com/repos/ventoy/Ventoy/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^\"]+)".*/\1/')
elif command -v wget >/dev/null 2>&1; then
	VERSION=$(wget -qO- https://api.github.com/repos/ventoy/Ventoy/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^\"]+)".*/\1/')
else
	echo "Error: curl or wget is required to download Ventoy." >&2
	exit 1
fi
[[ -n "${VERSION}" ]] || { echo "Error: Could not determine the latest Ventoy version." >&2; exit 1; }
URL="https://github.com/ventoy/Ventoy/releases/download/v${VERSION}/ventoy-${VERSION}-linux.tar.gz"

TMP_WORK=$(mktemp -d)
trap 'rm -rf "${TMP_WORK}"' EXIT

if command -v curl >/dev/null 2>&1; then
	curl -fSL "${URL}" | tar -xz -C "${TMP_WORK}"
else
	wget -qO- "${URL}" | tar -xz -C "${TMP_WORK}"
fi

echo "Installing to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
# Находим файлы независимо от вложенности
find "${TMP_WORK}" -name "Ventoy2Disk.sh" -exec cp {} "${INSTALL_DIR}/" \;
# Копируем структуру (ventoy, boot, tool)
find "${TMP_WORK}" -type d \( -name "ventoy" -o -name "boot" -o -name "tool" \) -exec cp -r {} "${INSTALL_DIR}/" \;

chmod +x "${INSTALL_DIR}/Ventoy2Disk.sh"
[[ -f "${INSTALL_DIR}/tool/ventoy_lib.sh" && -f "${INSTALL_DIR}/boot/boot.img" ]] || {
	echo "Error: Ventoy archive did not contain the required tool/ and boot/ files." >&2
	exit 1
}
echo "Ventoy binaries prepared successfully in ${INSTALL_DIR}"
