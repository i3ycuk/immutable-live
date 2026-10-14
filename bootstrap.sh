#!/usr/bin/env bash
# ==============================================================================
# bootstrap.sh - Temporary one-line installer for immutable-live
# ==============================================================================
set -Eeuo pipefail

REPO_URL="https://github.com/i3ycuk/immutable-live.git"
WORK_DIR=""

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" && "${WORK_DIR}" == "${TMPDIR:-/tmp}"/immutable-live-bootstrap.* ]]; then
        rm -rf -- "${WORK_DIR}" 2>/dev/null || true
        if [[ -e "${WORK_DIR}" ]]; then
            sudo rm -rf -- "${WORK_DIR}" 2>/dev/null || true
        fi
        if [[ -e "${WORK_DIR}" ]]; then
            echo "Warning: Could not remove temporary files at ${WORK_DIR}. Remove them manually." >&2
            (( status == 0 )) && status=1
        fi
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Checking dependencies..."
for dep in git mkfs.ext4 lsblk findmnt blockdev mount umount openssl awk sed cp head tar; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "Error: Required dependency '$dep' is missing. Please install it."
        exit 1
    fi
done

if ! command -v whiptail >/dev/null 2>&1 && ! command -v dialog >/dev/null 2>&1; then
    echo "Error: whiptail or dialog is missing. Please install either whiptail or dialog."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "Error: curl or wget is missing. Please install curl or wget."
    exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: sudo is required to install immutable-live."
    exit 1
fi

if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    echo "Error: An interactive terminal is required. Run this command from a terminal session."
    exit 1
fi

if ! command -v parted >/dev/null 2>&1 && ! command -v sfdisk >/dev/null 2>&1 && ! command -v fdisk >/dev/null 2>&1; then
    echo "Error: parted, sfdisk, or fdisk is required to create the persistence partition."
    exit 1
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/immutable-live-bootstrap.XXXXXXXX")
REPO_DIR="${WORK_DIR}/source"

echo "Downloading a fresh copy of immutable-live into temporary storage..."
git clone --depth 1 "$REPO_URL" "$REPO_DIR" </dev/null

echo "Starting installer from temporary storage..."
sudo bash "${REPO_DIR}/install.sh" </dev/tty

echo "Installer finished. Temporary files will now be removed."
