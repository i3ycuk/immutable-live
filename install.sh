#!/usr/bin/env bash
# ==============================================================================
# install.sh - Robust Unified Installer
# ==============================================================================
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then echo "Root required."; exit 1; fi
DIALOG=${DIALOG:-whiptail}
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
VENTOY_DISK_SCRIPT="${BASE_DIR}/tools/ventoy/Ventoy2Disk.sh"

select_drive() {
    drives=$(lsblk -dno NAME,SIZE,MODEL | grep -v 'loop\|sr\|zd')
    [[ -z "$drives" ]] && { echo "No drives found."; exit 1; }
    local menu_args=()
    while read -r name size model; do menu_args+=("/dev/$name" "$size $model"); done <<< "$drives"
    $DIALOG --title "Select Drive" --menu "Select USB:" 15 60 10 "${menu_args[@]}" 3>&1 1>&2 2>&3
}

configure_env() {
    local target_mnt=$1
    local config_dir="${target_mnt}/etc/immutable-live/config"
    mkdir -p "$config_dir"
    cat > "${config_dir}/.env" <<EOF
HOSTNAME=${HOSTNAME}
USER_NAME=${USER_NAME}
USER_PASSWORD_HASH='${USER_HASH}'
LOCALE=ru_RU.UTF-8
LANGUAGE=ru_RU:ru
KEYBOARD_LAYOUT=us,ru
KEYBOARD_OPTIONS=grp:alt_shift_toggle
AUTOLOGIN=true
HIDE_USER=true
DISABLE_LIVE_USER=true
SWAP_ENABLE=false
SWAP_SIZE=${SWAP_SIZE}
SWAPPINESS=60
EOF
    log_info ".env configured"
}

# 1. Drive Selection
DRIVE=$(select_drive) || exit 1

# 2. Input Configuration
VENTOY_SIZE="2048"
PERSISTENCE_SIZE=$($DIALOG --title "Persistence" --inputbox "MiB for Persistence partition:" 10 60 "2048" 3>&1 1>&2 2>&3)
LUKS_PASS=$($DIALOG --title "Security" --passwordbox "Enter LUKS password (Empty = No Encryption):" 10 60 3>&1 1>&2 2>&3)
HOSTNAME=$($DIALOG --title "System" --inputbox "Hostname:" 10 60 "Stealth" 3>&1 1>&2 2>&3)
USER_NAME=$($DIALOG --title "User" --inputbox "Username:" 10 60 "live_user" 3>&1 1>&2 2>&3)
USER_PASS=$($DIALOG --title "User Password" --passwordbox "User Password:" 10 60 3>&1 1>&2 2>&3)
USER_HASH=$(openssl passwd -6 "$USER_PASS")
SWAP_SIZE=$($DIALOG --title "Swap" --inputbox "Swap size in MB:" 10 60 "2048" 3>&1 1>&2 2>&3)

$DIALOG --title "Final Confirmation" --yesno "WARNING: All data on $DRIVE will be erased. Proceed?" 10 60 || exit 1

# 3. Execution
umount "${DRIVE}"* 2>/dev/null || true

# Ventoy Install
bash "${VENTOY_DISK_SCRIPT}" -I -r "${VENTOY_SIZE}" "${DRIVE}"

# Partitioning
partprobe "${DRIVE}"
sleep 3
# Create persistence partition in reserved space
parted -s "${DRIVE}" -- mkpart primary ext4 "${VENTOY_SIZE}MiB" "$((VENTOY_SIZE + PERSISTENCE_SIZE))MiB"
partprobe "${DRIVE}"
sleep 3
PARTITION="${DRIVE}3"

# Encryption / FS
DEV="${PARTITION}"
if [[ -n "$LUKS_PASS" ]]; then
    echo "$LUKS_PASS" | cryptsetup luksFormat --batch-mode "${PARTITION}" -
    echo "$LUKS_PASS" | cryptsetup luksOpen "${PARTITION}" persistence
    DEV="/dev/mapper/persistence"
fi
mkfs.ext4 -L persistence "${DEV}"

# Mount & Copy
MNT=$(mktemp -d)
mount "${DEV}" "${MNT}"
configure_env "${MNT}"
cp -r "${BASE_DIR}/disk/persistence/"* "${MNT}/"
umount "${MNT}"
[[ -n "$LUKS_PASS" ]] && cryptsetup luksClose persistence

$DIALOG --msgbox "SUCCESS: System prepared." 10 60
