#!/usr/bin/env bash
# ==============================================================================
# download-ventoy.sh - Download and fully extract necessary Ventoy components
# ==============================================================================
set -Eeuo pipefail

VERSION=$(curl -s https://api.github.com/repos/ventoy/Ventoy/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
URL="https://github.com/ventoy/Ventoy/releases/download/v${VERSION}/ventoy-${VERSION}-linux.tar.gz"
INSTALL_DIR="$(dirname "$0")/../ventoy"

echo "Downloading Ventoy ${VERSION}..."
TMP_WORK=$(mktemp -d)
trap 'rm -rf "${TMP_WORK}"' EXIT

wget -qO- "${URL}" | tar -xz -C "${TMP_WORK}"

# Find the nested ventoy directory
EXTRACTED=$(find "${TMP_WORK}" -maxdepth 1 -type d -name "ventoy-*")

echo "Installing to ${INSTALL_DIR}..."
rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
# Copy Ventoy2Disk.sh and core directories
cp "${EXTRACTED}/Ventoy2Disk.sh" "${INSTALL_DIR}/"
cp -r "${EXTRACTED}/ventoy" "${INSTALL_DIR}/"
cp -r "${EXTRACTED}/boot" "${INSTALL_DIR}/"
cp -r "${EXTRACTED}/tool" "${INSTALL_DIR}/"

chmod +x "${INSTALL_DIR}/Ventoy2Disk.sh"
echo "Ventoy binaries prepared successfully in ${INSTALL_DIR}"
