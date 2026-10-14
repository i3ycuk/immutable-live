#!/usr/bin/env bash
# ==============================================================================
# install.sh - Robust Unified Installer for immutable-live
# ==============================================================================
clear
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

if [[ $EUID -ne 0 ]]; then
    echo "Error: Root privileges are required. Please run with sudo." >&2
    exit 1
fi

DIALOG=""
if command -v whiptail >/dev/null 2>&1; then
    DIALOG=whiptail
elif command -v dialog >/dev/null 2>&1; then
    DIALOG=dialog
else
    echo "Error: Neither whiptail nor dialog is installed." >&2
    exit 1
fi

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
VENTOY_DISK_SCRIPT="${BASE_DIR}/tools/ventoy/Ventoy2Disk.sh"

# Load locale
source "${BASE_DIR}/locale/locale.sh"
MNT_P=""
MNT_V=""
LUKS_OPEN=false

cleanup() {
    local status=$?
    [[ -n "${MNT_V}" && -d "${MNT_V}" ]] && umount "${MNT_V}" 2>/dev/null || true
    [[ -n "${MNT_P}" && -d "${MNT_P}" ]] && umount "${MNT_P}" 2>/dev/null || true
    if [[ "${LUKS_OPEN}" == "true" ]]; then
        cryptsetup luksClose persistence 2>/dev/null || true
    fi
    [[ -n "${MNT_V}" && -d "${MNT_V}" ]] && rmdir "${MNT_V}" 2>/dev/null || true
    [[ -n "${MNT_P}" && -d "${MNT_P}" ]] && rmdir "${MNT_P}" 2>/dev/null || true
    return "$status"
}

on_error() {
    local status=$1 line=$2 command=$3
    trap - ERR
    log_error "ERR_COMMAND_FAILED" LINE "$line" STATUS "$status" CMD "$command"
}
trap cleanup EXIT
trap 'status=$?; if (( BASH_SUBSHELL == 0 )); then on_error "$status" "$LINENO" "$BASH_COMMAND"; fi' ERR

localized_message() {
    local key=$1
    shift
    if [[ -n "${MSG[$key]:-}" ]]; then
        t "$key" "$@"
    else
        printf '%s\n' "$key${*:+ $*}"
    fi
}

log_info()  { printf '\033[32m[INFO]\033[0m  %s\n' "$(localized_message "$@")"; }
log_warn()  { printf '\033[33m[WARN]\033[0m  %s\n' "$(localized_message "$@")" >&2; }
log_error() { printf '\033[31m[ERROR]\033[0m  %s\n' "$(localized_message "$@")" >&2; }

dialog_cancelled() {
    local context=${1:-unknown dialog}
    log_error "ERR_DIALOG_CANCELLED" CONTEXT "$context"
    trap - ERR
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        log_error "ERR_COMMAND_MISSING" CMD "$1"
        exit 1
    }
}

for cmd in lsblk findmnt blockdev mount umount mkfs.ext4 openssl awk sed cp head; do
    require_command "$cmd"
done

if ! command -v parted >/dev/null 2>&1 && ! command -v sfdisk >/dev/null 2>&1 && ! command -v fdisk >/dev/null 2>&1; then
    log_error "ERR_PARTITION_TOOL_MISSING"
    exit 1
fi

# Auto-download Ventoy if missing
if [[ ! -f "${VENTOY_DISK_SCRIPT}" ]]; then
    log_info "INFO_DOWNLOADING_VENTOY"
    bash "${BASE_DIR}/tools/scripts/download-ventoy.sh"
fi

get_part_device() {
    local drive=$1
    local num=$2
    if [[ "${drive}" =~ [0-9]$ ]]; then
        echo "${drive}p${num}"
    else
        echo "${drive}${num}"
    fi
}

get_disk_size_mib() {
    local drive=$1
    local devname="${drive#/dev/}"
    local sectors=0
    if [[ -f "/sys/block/${devname}/size" ]]; then
        sectors=$(cat "/sys/block/${devname}/size" 2>/dev/null || echo 0)
    elif command -v blockdev >/dev/null 2>&1; then
        sectors=$(blockdev --getsz "${drive}" 2>/dev/null || echo 0)
    fi
    echo $(( sectors / 2048 ))
}

parse_size_to_mib() {
    local input=$1
    local total_mib=$2
    input=$(echo "$input" | tr -d '[:space:]')
    if [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)%$ ]]; then
        local pct="${BASH_REMATCH[1]}"
        awk -v t="$total_mib" -v p="$pct" 'BEGIN { printf "%.0f", (t * p / 100) }'
    elif [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)[tT][iI]?[bB]?$ ]]; then
        local tib="${BASH_REMATCH[1]}"
        awk -v t="$tib" 'BEGIN { printf "%.0f", (t * 1024 * 1024) }'
    elif [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)[gG][iI]?[bB]?$ ]]; then
        local gib="${BASH_REMATCH[1]}"
        awk -v g="$gib" 'BEGIN { printf "%.0f", (g * 1024) }'
    elif [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)[mM][iI]?[bB]?$ ]]; then
        local mib="${BASH_REMATCH[1]}"
        awk -v m="$mib" 'BEGIN { printf "%.0f", m }'
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
    else
        echo ""
    fi
}

format_swap_size() {
    local input=$1
    local total_mib=$2
    local mib
    mib=$(parse_size_to_mib "$input" "$total_mib")
    if [[ -z "$mib" || "$mib" -le 0 ]]; then
        echo "2G"
    elif (( mib >= 1024 && mib % 1024 == 0 )); then
        echo "$(( mib / 1024 ))G"
    else
        echo "${mib}M"
    fi
}

update_env_var() {
    local file=$1 key=$2 value=$3
    [[ -f "$file" ]] || return 0
    local tmp
    tmp=$(mktemp)
    if ! awk -v k="${key}" -v v="${value}" '
        BEGIN { found = 0 }
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            print k "=" v
            found = 1
            next
        }
        { print }
        END {
            if (found == 0) {
                print k "=" v
            }
        }
    ' "${file}" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    cat "${tmp}" > "${file}"
    rm -f "${tmp}"
}

select_drive() {
    local show_all=${1:-false}
    local root_src root_disk
    root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    root_disk=$(lsblk -no PKNAME "${root_src}" 2>/dev/null || true)
    [[ -z "$root_disk" && -n "$root_src" ]] && root_disk=$(echo "$root_src" | sed -E 's/[0-9]+$|p[0-9]+$//')
    root_disk="${root_disk#/dev/}"

    local raw_drives
    raw_drives=$(lsblk -dno NAME,SIZE,RM,TRAN,MODEL -P 2>/dev/null || true)
    if [[ -z "$raw_drives" ]]; then
        $DIALOG --title "$(t 'APP_TITLE')" --msgbox "$(t 'ERR_NO_DRIVES')" 10 60
        exit 1
    fi

    local menu_args=()
    local count_safe=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local NAME SIZE RM TRAN MODEL
        NAME=$(sed -n 's/.*NAME="\([^"]*\)".*/\1/p' <<< "$line")
        SIZE=$(sed -n 's/.*SIZE="\([^"]*\)".*/\1/p' <<< "$line")
        RM=$(sed -n 's/.*RM="\([^"]*\)".*/\1/p' <<< "$line")
        TRAN=$(sed -n 's/.*TRAN="\([^"]*\)".*/\1/p' <<< "$line")
        MODEL=$(sed -n 's/.*MODEL="\([^"]*\)".*/\1/p' <<< "$line")
        [[ "$NAME" =~ ^(loop|sr|zd|zram) ]] && continue

        local is_root=false
        local is_removable=false

        [[ "$NAME" == "$root_disk" ]] && is_root=true
        [[ "$RM" == "1" || "$TRAN" == "usb" ]] && is_removable=true

        local tag=""
        if [[ "$is_root" == "true" ]]; then
            tag="$(t 'DRIVE_TAG_SYSTEM')"
        elif [[ "$is_removable" == "false" ]]; then
            tag="$(t 'DRIVE_TAG_INTERNAL')"
        else
            tag="$(t 'DRIVE_TAG_USB')"
            count_safe=$((count_safe + 1))
        fi

        local desc="${SIZE} ${MODEL:-Disk} ${tag}"

        if [[ "$show_all" == "true" || ( "$is_removable" == "true" && "$is_root" == "false" ) ]]; then
            menu_args+=("/dev/${NAME}" "${desc}")
        fi
    done <<< "$raw_drives"

    if [[ "$show_all" == "false" ]]; then
        menu_args+=("SHOW_ALL" "$(t 'DRIVE_OPTION_SHOW_ALL')")
    fi

    local choice
    choice=$($DIALOG --title "$(t 'DIALOG_DRIVE_TITLE')" --menu \
        "$(t 'DIALOG_DRIVE_DESC')" \
        18 78 8 "${menu_args[@]}" 3>&1 1>&2 2>&3) || dialog_cancelled "drive selection menu"

    if [[ "$choice" == "SHOW_ALL" && "$count_safe" -eq 0 ]]; then
        if ! $DIALOG --title "$(t 'ERR_NO_USB')" --yesno "$(t 'ERR_NO_USB')" 12 70; then
            exit 1
        fi
        select_drive true
        return
    fi

    if [[ "$choice" == "SHOW_ALL" ]]; then
        if $DIALOG --title "$(t 'DIALOG_WARNING_ROOT_TITLE')" --yesno "$(t 'DIALOG_WARNING_ROOT_DESC')" 14 70; then
            select_drive true
        else
            select_drive false
        fi
        return
    fi

    local chosen_name="${choice#/dev/}"
    if [[ "$chosen_name" == "$root_disk" ]]; then
        if ! $DIALOG --title "$(t 'DIALOG_CRITICAL_TITLE')" --yesno "$(t 'DIALOG_CRITICAL_DESC' DRIVE "$choice")" 14 70; then
            select_drive true
            return
        fi
    fi

    SELECTED_DRIVE="$choice"
}

get_env_value() {
    local file=$1 key=$2 value
    value=$(sed -n "s/^[[:space:]]*${key}=[[:space:]]*//p" "$file" | head -n 1)
    value=${value#\'}
    value=${value%\'}
    printf '%s' "$value"
}

# Check .env.example exists
ENV_EXAMPLE="${BASE_DIR}/disk/persistence/link/etc/immutable-live/config/.env.example"
if [[ ! -f "${ENV_EXAMPLE}" ]]; then
    log_error "ERR_ENV_EXAMPLE_NOT_FOUND" PATH "${ENV_EXAMPLE}"
    exit 1
fi

# ==============================================================================
# 1. Выбор накопителя
# ==============================================================================
SELECTED_DRIVE=""
select_drive false
DRIVE=${SELECTED_DRIVE}

TOTAL_DISK_MIB=$(get_disk_size_mib "${DRIVE}")
TOTAL_DISK_GIB=$(awk -v m="$TOTAL_DISK_MIB" 'BEGIN { printf "%.1f", m/1024 }')
DISK_MODEL=$(lsblk -dno MODEL "${DRIVE}" 2>/dev/null | xargs || echo "Disk")

# ==============================================================================
# 2. Persistence size configuration
# ==============================================================================
while true; do
    PERSIST_DEFAULT="50%"
    if (( TOTAL_DISK_MIB > 0 && TOTAL_DISK_MIB * 50 / 100 > 16384 )); then
        PERSIST_DEFAULT="16384M"
    fi

    PERSIST_INPUT=$($DIALOG --title "$(t 'DIALOG_PERSIST_TITLE')" --inputbox \
        "$(t 'DIALOG_PERSIST_DESC' DRIVE "${DRIVE}" MODEL "${DISK_MODEL}" SIZE "${TOTAL_DISK_GIB} GiB / ${TOTAL_DISK_MIB} MiB")" \
        15 70 "${PERSIST_DEFAULT}" 3>&1 1>&2 2>&3) || dialog_cancelled "$(t 'DIALOG_PERSIST_TITLE')"
    PERSISTENCE_SIZE_MB=$(parse_size_to_mib "${PERSIST_INPUT}" "${TOTAL_DISK_MIB}")

    if [[ -z "${PERSISTENCE_SIZE_MB}" || "${PERSISTENCE_SIZE_MB}" -lt 512 ]]; then
        $DIALOG --msgbox "$(t 'ERR_PERSIST_TOO_SMALL')" 10 60
        continue
    fi
    if (( TOTAL_DISK_MIB > 0 && PERSISTENCE_SIZE_MB >= TOTAL_DISK_MIB - 512 )); then
        $DIALOG --msgbox "$(t 'ERR_PERSIST_TOO_LARGE')" 12 65
        continue
    fi
    break
done

# ==============================================================================
# 3. LUKS encryption
# ==============================================================================
LUKS_PASS=""
while true; do
    LUKS_PASS=$($DIALOG --title "$(t 'DIALOG_LUKS_TITLE')" --passwordbox \
        "$(t 'DIALOG_LUKS_DESC')" 12 65 3>&1 1>&2 2>&3) || dialog_cancelled "$(t 'DIALOG_LUKS_TITLE')"
    if [[ -n "${LUKS_PASS}" ]]; then
        LUKS_PASS_CONFIRM=$($DIALOG --title "$(t 'DIALOG_LUKS_CONFIRM_TITLE')" --passwordbox \
            "$(t 'DIALOG_LUKS_CONFIRM_DESC')" 10 65 3>&1 1>&2 2>&3) || dialog_cancelled "$(t 'DIALOG_LUKS_CONFIRM_TITLE')"
        if [[ "${LUKS_PASS}" != "${LUKS_PASS_CONFIRM}" ]]; then
            $DIALOG --msgbox "$(t 'ERR_LUKS_MISMATCH')" 10 60
            continue
        fi
    fi
    break
done
if [[ -n "${LUKS_PASS}" ]]; then
    require_command cryptsetup
fi

# ==============================================================================
# 4. Installer settings from .env.example
# ==============================================================================
HOSTNAME_DEFAULT=$(get_env_value "${ENV_EXAMPLE}" HOSTNAME)
USER_DEFAULT=$(get_env_value "${ENV_EXAMPLE}" USER_NAME)
SWAP_DEFAULT=$(get_env_value "${ENV_EXAMPLE}" SWAP_SIZE)

while true; do
    HOSTNAME=$($DIALOG --title "$(t 'DIALOG_HOSTNAME_TITLE')" --inputbox \
        "$(t 'DIALOG_HOSTNAME_DESC')" 10 65 "${HOSTNAME_DEFAULT:-immutable-live}" 3>&1 1>&2 2>&3) || dialog_cancelled "$(t 'DIALOG_HOSTNAME_TITLE')"
    if [[ "${HOSTNAME}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?$ && "${HOSTNAME}" != *..* ]]; then
        break
    fi
    $DIALOG --msgbox "$(t 'ERR_HOSTNAME_INVALID')" 10 65
done

while true; do
    USER_NAME=$($DIALOG --title "$(t 'DIALOG_USER_TITLE')" --inputbox \
        "$(t 'DIALOG_USER_DESC')" 10 65 "${USER_DEFAULT:-user}" 3>&1 1>&2 2>&3) || dialog_cancelled "$(t 'DIALOG_USER_TITLE')"
    if [[ "${USER_NAME}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        break
    fi
    $DIALOG --msgbox "$(t 'ERR_USER_INVALID')" 10 70
done

while true; do
    USER_PASS=$($DIALOG --title "$(t 'DIALOG_USERPASS_TITLE')" --passwordbox \
        "$(t 'DIALOG_USERPASS_DESC' USER "${USER_NAME}")" 10 65 3>&1 1>&2 2>&3) || dialog_cancelled "$(t 'DIALOG_USERPASS_TITLE')"
    if [[ -z "${USER_PASS}" ]]; then
        $DIALOG --msgbox "$(t 'ERR_USERPASS_EMPTY')" 10 60
        continue
    fi
    USER_PASS_CONFIRM=$($DIALOG --title "$(t 'DIALOG_USERPASS_CONFIRM_TITLE')" --passwordbox \
        "$(t 'DIALOG_USERPASS_CONFIRM_DESC')" 10 65 3>&1 1>&2 2>&3) || dialog_cancelled "$(t 'DIALOG_USERPASS_CONFIRM_TITLE')"
    if [[ "${USER_PASS}" == "${USER_PASS_CONFIRM}" ]]; then
        break
    fi
    $DIALOG --msgbox "$(t 'ERR_USERPASS_MISMATCH')" 10 60
done
USER_HASH=$(printf '%s' "${USER_PASS}" | openssl passwd -6 -stdin)
unset USER_PASS USER_PASS_CONFIRM

AUTOLOGIN="false"
if $DIALOG --title "$(t 'DIALOG_AUTOLOGIN_TITLE')" --yesno \
    "$(t 'DIALOG_AUTOLOGIN_DESC' USER "${USER_NAME}")" 10 65; then
    AUTOLOGIN="true"
fi

# ==============================================================================
# 5. Настройка Swap
# ==============================================================================
CONFIGURED_SWAP_ENABLE=$(get_env_value "${ENV_EXAMPLE}" SWAP_ENABLE)
CONFIGURED_SWAP_ENABLE=${CONFIGURED_SWAP_ENABLE:-false}
CONFIGURED_SWAP_SIZE=${SWAP_DEFAULT:-2G}

if $DIALOG --title "$(t 'DIALOG_SWAP_TITLE')" --yesno \
    "$(t 'DIALOG_SWAP_DESC')" 10 60; then
    CONFIGURED_SWAP_ENABLE="true"
    while true; do
        SWAP_INPUT=$($DIALOG --title "$(t 'DIALOG_SWAP_SIZE_TITLE')" --inputbox \
            "$(t 'DIALOG_SWAP_SIZE_DESC' SIZE "${TOTAL_DISK_GIB} GiB")" \
            12 60 "${CONFIGURED_SWAP_SIZE}" 3>&1 1>&2 2>&3) || dialog_cancelled "$(t 'DIALOG_SWAP_SIZE_TITLE')"

        SWAP_MIB=$(parse_size_to_mib "${SWAP_INPUT}" "${TOTAL_DISK_MIB}")
        if [[ -n "${SWAP_MIB}" && "${SWAP_MIB}" -gt 0 && \
              "${SWAP_MIB}" -lt "${PERSISTENCE_SIZE_MB}" ]]; then
            CONFIGURED_SWAP_SIZE=$(format_swap_size "${SWAP_INPUT}" "${TOTAL_DISK_MIB}")
            break
        else
            $DIALOG --msgbox "$(t 'ERR_SWAP_INVALID' MAX "${PERSISTENCE_SIZE_MB}")" 10 70
        fi
    done
else
    CONFIGURED_SWAP_ENABLE="false"
fi

# ==============================================================================
# 5. Итоговое подтверждение
# ==============================================================================
LUKS_STATUS="$(t 'LABEL_DISABLED')"
[[ -n "${LUKS_PASS}" ]] && LUKS_STATUS="$(t 'LABEL_ENABLED')"
SWAP_STATUS="$(t 'LABEL_DISABLED_SWAP')"
[[ "${CONFIGURED_SWAP_ENABLE}" == "true" ]] && SWAP_STATUS="$(t 'LABEL_ENABLED_SWAP' SIZE "${CONFIGURED_SWAP_SIZE}")"
AUTOLOGIN_STATUS="$(t 'LABEL_DISABLED_AUTOLOGIN')"
[[ "${AUTOLOGIN}" == "true" ]] && AUTOLOGIN_STATUS="$(t 'LABEL_ENABLED_AUTOLOGIN')"

SUMMARY=$(t 'DIALOG_SUMMARY' \
    DRIVE "${DRIVE}" MODEL "${DISK_MODEL}" SIZE "${TOTAL_DISK_GIB} GiB" \
    PERSIST_MiB "${PERSISTENCE_SIZE_MB}" PERSIST_INPUT "${PERSIST_INPUT}" \
    LUKS_STATUS "${LUKS_STATUS}" HOSTNAME "${HOSTNAME}" USER "${USER_NAME}" \
    AUTOLOGIN "${AUTOLOGIN_STATUS}" SWAP_STATUS "${SWAP_STATUS}")

$DIALOG --title "$(t 'DIALOG_FINAL_TITLE')" --yesno "${SUMMARY}" 18 75 || dialog_cancelled "$(t 'DIALOG_FINAL_TITLE')"

# ==============================================================================
# 6. Выполнение разметки и установки
# ==============================================================================
log_info "=================================================================="
log_info "Начало подготовки накопителя ${DRIVE}..."
log_info "=================================================================="

# 1. Размонтирование разделов
log_info "Размонтирование существующих разделов на ${DRIVE}..."
for p in "${DRIVE}"* /dev/mapper/persistence; do
    umount "$p" 2>/dev/null || true
done
if command -v cryptsetup >/dev/null 2>&1; then
    cryptsetup luksClose persistence 2>/dev/null || true
fi

# 2. Установка Ventoy с автоматическим подтверждением
log_info "Установка Ventoy (резервирование ${PERSISTENCE_SIZE_MB} MiB в конце диска)..."
VENTOY_ARGS=(-I -r "${PERSISTENCE_SIZE_MB}")
if (( TOTAL_DISK_MIB > 2 * 1024 * 1024 )); then
    log_info "Накопитель больше 2 TiB: включаю GPT для Ventoy."
    VENTOY_ARGS+=(-g)
fi
printf 'y\ny\n' | bash "${VENTOY_DISK_SCRIPT}" "${VENTOY_ARGS[@]}" "${DRIVE}"
if [[ ! -b "$(get_part_device "${DRIVE}" 1)" || ! -b "$(get_part_device "${DRIVE}" 2)" ]]; then
    log_error "ERR_VENTOY_FAILED"
    exit 1
fi

# Desktop automounters may mount Ventoy's new exFAT partition immediately.
for p in "${DRIVE}"*; do
    umount "$p" 2>/dev/null || true
done

# 3. Обновление таблицы разделов
partprobe "${DRIVE}" 2>/dev/null || true
sleep 2
command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || sleep 2

# 4. Создание раздела Persistence в зарезервированном пространстве
log_info "Создание раздела Persistence..."
PART2=$(get_part_device "${DRIVE}" 2)
p3_start_sector=""
if [[ -f "/sys/block/${DRIVE#/dev/}/${PART2#/dev/}/start" && -f "/sys/block/${DRIVE#/dev/}/${PART2#/dev/}/size" ]]; then
    p2_start=$(cat "/sys/block/${DRIVE#/dev/}/${PART2#/dev/}/start")
    p2_size=$(cat "/sys/block/${DRIVE#/dev/}/${PART2#/dev/}/size")
    p3_start_sector=$(( p2_start + p2_size ))
    p3_start_sector=$(( (p3_start_sector + 2047) / 2048 * 2048 ))
elif [[ -f "/sys/class/block/${PART2#/dev/}/start" && -f "/sys/class/block/${PART2#/dev/}/size" ]]; then
    p2_start=$(cat "/sys/class/block/${PART2#/dev/}/start")
    p2_size=$(cat "/sys/class/block/${PART2#/dev/}/size")
    p3_start_sector=$(( p2_start + p2_size ))
    p3_start_sector=$(( (p3_start_sector + 2047) / 2048 * 2048 ))
fi

if command -v parted >/dev/null 2>&1; then
    if [[ -n "${p3_start_sector}" && "${p3_start_sector}" -gt 0 ]]; then
        parted -s "${DRIVE}" -- mkpart primary ext4 "${p3_start_sector}s" 100%
    else
        parted -s "${DRIVE}" -- mkpart primary ext4 "$(( TOTAL_DISK_MIB - PERSISTENCE_SIZE_MB ))MiB" 100%
    fi
elif command -v sfdisk >/dev/null 2>&1; then
    echo ",," | sfdisk --no-reread -a "${DRIVE}"
elif command -v fdisk >/dev/null 2>&1; then
    printf 'n\n\n\n\nw\n' | fdisk "${DRIVE}"
fi

partprobe "${DRIVE}" 2>/dev/null || true
sleep 2
command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || sleep 2

PART_VTOY=$(get_part_device "${DRIVE}" 1)
PART_PERSISTENCE=$(get_part_device "${DRIVE}" 3)

for i in {1..10}; do
    [[ -b "${PART_PERSISTENCE}" ]] && break
    sleep 1
    partprobe "${DRIVE}" 2>/dev/null || true
done

# Fallback node creation if kernel registered partition in sysfs but not in /dev
if [[ ! -b "${PART_PERSISTENCE}" && -e "/sys/class/block/${PART_PERSISTENCE#/dev/}/dev" ]]; then
    MajorMinor=$(sed "s/:/ /" "/sys/class/block/${PART_PERSISTENCE#/dev/}/dev")
    mknod -m 0660 "${PART_PERSISTENCE}" b $MajorMinor 2>/dev/null || true
fi

if [[ ! -b "${PART_PERSISTENCE}" ]]; then
    log_error "ERR_PERSISTENCE_PARTITION" PART "${PART_PERSISTENCE}"
    exit 1
fi
log_info "Раздел Persistence успешно создан: ${PART_PERSISTENCE}"

# 5. Шифрование LUKS / Форматирование ext4 (label=persistence)
DEV="${PART_PERSISTENCE}"
if [[ -n "${LUKS_PASS}" ]]; then
    log_info "Настройка шифрования LUKS1 на ${PART_PERSISTENCE}..."
    printf '%s' "${LUKS_PASS}" | cryptsetup luksFormat --type luks1 --batch-mode --key-file=- "${PART_PERSISTENCE}"
    printf '%s' "${LUKS_PASS}" | cryptsetup luksOpen --key-file=- "${PART_PERSISTENCE}" persistence
    LUKS_OPEN=true
    DEV="/dev/mapper/persistence"
fi

log_info "Форматирование файловой системы ext4 (label=persistence) на ${DEV}..."
mkfs.ext4 -F -L persistence "${DEV}"

# 6. Развертывание структуры persistence и создание .env из .env.example
log_info "Развертывание файлов конфигурации persistence..."
MNT_P=$(mktemp -d)
mount "${DEV}" "${MNT_P}"

# Копируем всё дерево persistence
cp -a "${BASE_DIR}/disk/persistence/"* "${MNT_P}/"

# Создаём .env на основе .env.example и обновляем значения из установки
TARGET_ENV="${MNT_P}/link/etc/immutable-live/config/.env"
mkdir -p "$(dirname "${TARGET_ENV}")"

# Копируем .env.example как .env
cp -a "${ENV_EXAMPLE}" "${TARGET_ENV}"

# Сохраняем шаблон и меняем только значения, заданные пользователем
update_env_var "${TARGET_ENV}" "HOSTNAME" "${HOSTNAME}"
update_env_var "${TARGET_ENV}" "USER_NAME" "${USER_NAME}"
update_env_var "${TARGET_ENV}" "USER_PASSWORD_HASH" "'${USER_HASH}'"
update_env_var "${TARGET_ENV}" "AUTOLOGIN" "${AUTOLOGIN}"
update_env_var "${TARGET_ENV}" "SWAP_ENABLE" "${CONFIGURED_SWAP_ENABLE}"
update_env_var "${TARGET_ENV}" "SWAP_SIZE" "${CONFIGURED_SWAP_SIZE}"

chmod 700 "${MNT_P}/link/etc/immutable-live/config" 2>/dev/null || true
chmod 600 "${TARGET_ENV}" 2>/dev/null || true
log_info "Создан файл .env из .env.example с правами 600"

sync
umount "${MNT_P}"
rmdir "${MNT_P}" 2>/dev/null || true

if [[ -n "${LUKS_PASS}" ]]; then
    cryptsetup luksClose persistence 2>/dev/null || true
    LUKS_OPEN=false
    unset LUKS_PASS LUKS_PASS_CONFIRM
fi

# 7. Монтирование раздела Ventoy (Partition 1) и копирование загрузочных файлов
log_info "Настройка загрузчика Ventoy на разделе ${PART_VTOY}..."
MNT_V=$(mktemp -d)
if ! mount "${PART_VTOY}" "${MNT_V}"; then
    log_error "ERR_VENTOY_PARTITION" PART "${PART_VTOY}"
    exit 1
fi
mkdir -p "${MNT_V}/iso" "${MNT_V}/ventoy"
if [[ -d "${BASE_DIR}/disk/boot/ventoy" ]]; then
    cp -r "${BASE_DIR}/disk/boot/ventoy/." "${MNT_V}/ventoy/"
fi
sync
umount "${MNT_V}"
rmdir "${MNT_V}" 2>/dev/null || true
MNT_V=""

log_info "=================================================================="
log_info "Установка успешно завершена!"
log_info "=================================================================="

$DIALOG --title "$(t 'DIALOG_SUCCESS_TITLE')" --msgbox "$(t 'DIALOG_SUCCESS_DESC' DRIVE "${DRIVE}")" 12 70
