#!/usr/bin/env bash
# ==============================================================================
# bootstrap.sh - One-line installer for immutable-live
# ==============================================================================
set -e

REPO_URL="https://github.com/i3ycuk/immutable-live.git"
INSTALL_DIR="immutable-live"

echo "Checking dependencies..."
for dep in git whiptail parted cryptsetup mkfs.ext4 wget curl; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "Error: Required dependency '$dep' is missing. Please install it."
        exit 1
    fi
done

if [ ! -d "$INSTALL_DIR" ]; then
    echo "Cloning repository..."
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"
echo "Starting installer..."
sudo ./install.sh
