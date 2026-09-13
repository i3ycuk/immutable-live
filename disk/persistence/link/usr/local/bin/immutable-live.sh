#!/usr/bin/env bash
# ==============================================================================
# immutable-live.sh - initialize the system at boot, apply configuration,
# detect ISO changes and clean ISO-dependent state from the persistence
# upperdir (directly, bypassing OverlayFS, so no whiteouts are created).
#
# Safe to rerun any time: boot, --save-packages (from package hooks), --restore.
# ==============================================================================
set -Eeuo pipefail

LOG_FILE=/var/log/immutable-live/immutable-live.log
STATE_DIR=/etc/immutable-live/state
CONFIG_DIR=/etc/immutable-live/config
LOG_DIR=$(dirname "${LOG_FILE}")

PACKAGE_FILE=${STATE_DIR}/user.packages
REMOVED_PACKAGE_FILE=${STATE_DIR}/removed.packages
BASE_PACKAGE_FILE=${STATE_DIR}/base.packages
BASE_MANUAL_FILE=${STATE_DIR}/base.manual
PASSWORD_HASH_FILE=${STATE_DIR}/user_password.hash
GROUPS_FILE=${STATE_DIR}/user.groups
ISO_ID_FILE=${STATE_DIR}/iso.id

# --- Logging (rotated, to protect the flash drive) ---------------------------
MAX_LOG_SIZE=$((512 * 1024))

mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${CONFIG_DIR}"

log() {
    local level=${2:-INFO}
    printf '[%s] [%s] %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)" "${level}" "$*"
}

log_info()  { log "$*" "INFO"; }
log_warn()  { log "$*" "WARN"; }
log_error() { log "$*" "ERROR"; }

if [[ -f ${LOG_FILE} ]]; then
    if (( $(stat -c '%s' "${LOG_FILE}" 2>/dev/null || echo 0) > MAX_LOG_SIZE )); then
        tail -c $((MAX_LOG_SIZE / 2)) "${LOG_FILE}" > "${LOG_FILE}.tmp" 2>/dev/null || true
        mv -f "${LOG_FILE}.tmp" "${LOG_FILE}" 2>/dev/null || true
    fi
fi
exec > >(tee -a "${LOG_FILE}") 2>&1

# --- Config -----------------------------------------------------------------
# Lookup order: ISO live dir, persistence config dir, fallback path.
LIVE_DIR=""

find_live_dir() {
    [[ -n ${LIVE_DIR} ]] && return 0

    local mount_point escaped_path
    local -a candidates=(
        /run/live/medium/live
        /lib/live/mount/medium/live
    )

    while IFS=' ' read -r _ _ _ _ mount_point _; do
        escaped_path=${mount_point//\\040/ }
        [[ ${escaped_path} == */live ]] && candidates+=("${escaped_path}")
    done < /proc/self/mountinfo 2>/dev/null || true

    for mount_point in "${candidates[@]}"; do
        if [[ -f ${mount_point}/filesystem.squashfs || -f ${mount_point}/rootfs.img ]]; then
            LIVE_DIR=${mount_point}
            return 0
        fi
    done
    return 1
}

find_live_dir

load_config() {
    local file
    for file in "${LIVE_DIR}/.env" "${CONFIG_DIR}/.env" "/etc/immutable-live/.env"; do
        if [[ -f ${file} ]]; then
            log_info "Loaded config: ${file}"
            # A bad line in .env must not abort the whole boot process.
            set +e
            # shellcheck disable=SC1090
            source "${file}"
            set -e
            return 0
        fi
    done
    return 0
}

# Saved before the default list below, so .env:ISO_DEPENDENT_DIRS (a space
# separated string) is not overwritten by the script's default array.
USER_ISO_DIRS=${ISO_DEPENDENT_DIRS:-}
load_config
USER_ISO_DIRS=${ISO_DEPENDENT_DIRS:-${USER_ISO_DIRS:-}}

# --- Helpers -----------------------------------------------------------------
sync_env_var() {
    # Write a single quoted value back into the .env file (password, groups).
    local key=$1 value=$2 env_file=""

    if [[ -f ${CONFIG_DIR}/.env ]]; then
        env_file=${CONFIG_DIR}/.env
    elif [[ -n ${LIVE_DIR} && -f ${LIVE_DIR}/.env ]]; then
        env_file=${LIVE_DIR}/.env
    else
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    awk -v k="${key}=" -v v="'${value}'" '
        $0 ~ "^" k { print k v; next }
        { print }
    ' "${env_file}" > "${tmp}" || { rm -f "${tmp}"; return 0; }
    cat "${tmp}" > "${env_file}" 2>/dev/null || true
    rm -f "${tmp}"
    log_info "Updated ${key} in ${env_file}"
}

detect_pkg_manager() {
    if command -v dpkg-query >/dev/null 2>&1; then
        echo "apt"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v dnf >/dev/null 2>&1 || command -v rpm >/dev/null 2>&1; then
        echo "dnf"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        echo "unknown"
    fi
}

PKG_MGR=$(detect_pkg_manager)

# --- Package tracking ---------------------------------------------------------
# Full installed package list (deterministic); used as the base snapshot
# (base.packages) and to detect exactly which packages were removed.
get_installed_packages() {
    case "${PKG_MGR}" in
        apt)
            dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sed 's/:.*//' | sort -u
            ;;
        pacman)
            pacman -Qq 2>/dev/null | sort -u
            ;;
        dnf)
            rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort -u
            ;;
        apk)
            apk info 2>/dev/null | sort -u
            ;;
        *)
            log_warn "Unknown package manager, package tracking skipped"
            ;;
    esac
}

# Packages installed by the user (not dependencies); used only for
# user.packages so restores do not pull in the whole dependency tree.
get_manual_packages() {
    case "${PKG_MGR}" in
        apt)
            if command -v apt-mark >/dev/null 2>&1; then
                apt-mark showmanual 2>/dev/null | sed 's/:.*//' | sort -u
            else
                dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sed 's/:.*//' | sort -u
            fi
            ;;
        pacman)
            pacman -Qeq 2>/dev/null | sort -u
            ;;
        dnf)
            if command -v dnf >/dev/null 2>&1; then
                dnf history userinstalled 2>/dev/null | awk '{print $1}' | sed 's/:.*//' | sort -u
            else
                rpm -qa --userinstalled --qf '%{NAME}\n' 2>/dev/null | sort -u
            fi
            ;;
        apk)
            [[ -f /etc/apk/world ]] && grep -Ev '^[[:space:]#]*$' /etc/apk/world 2>/dev/null | sort -u
            ;;
        *)
            ;;
    esac
}

check_pkg_manager() { [[ ${PKG_MGR} != "unknown" ]]; }

# --- Default ISO-dependent directories to reset on ISO change -----------------
# Directories tightly coupled to the base ISO content. Add your own paths in
# the .env: ISO_DEPENDENT_DIRS="/etc/foo /var/lib/foo"
ISO_DEPENDENT_DIRS=(
    # Color profiles
    /etc/colord
    /var/lib/colord
    /var/cache/colord

    # Display managers (their configs follow the ISO, not the user)
    /etc/gdm3
    /etc/gdm
    /etc/lightdm
    /etc/sddm.conf
    /etc/sddm.conf.d
    /var/lib/gdm3
    /var/lib/gdm
    /var/lib/lightdm
    /var/lib/sddm
    /var/lib/AccountsService
    /etc/systemd/system/display-manager.service

    # System identity and runtime state
    /etc/machine-id
    /var/lib/dbus/machine-id
    /var/lib/dbus
    /var/lib/systemd
    /var/lib/udev

    # Package manager state and caches
    /var/lib/dpkg
    /var/cache/apt
    /var/lib/apt
    /var/lib/alternatives
    /etc/alternatives
    /var/cache/fontconfig
    /var/cache/ldconfig
    /var/cache/man
    /var/cache/debconf
    /etc/ld.so.cache

    # Desktop/system services tied to the ISO version
    /etc/colord
    /var/lib/colord
    /var/cache/colord
    /etc/cups
    /var/cache/cups
    /etc/fwupd
    /var/cache/fwupd
    /var/lib/fwupd
    /var/lib/PackageKit
    /var/cache/swcatalog
    /var/lib/swcatalog
    /var/lib/alsa
    /var/lib/plymouth
    /var/lib/power-profiles-daemon
    /var/lib/udisks2
    /var/lib/xkb
    /etc/X11/xorg.conf.d

    # Logs of ISO-provided services
    /var/log/boot.log
    /var/log/cups
    /var/log/gdm3
    /var/log/lightdm
    /var/log/live
    /var/log/Xorg.0.log
    /var/log/alternatives.log
    /var/log/macchanger.log
    /var/log/sysstat
    /var/log/wtmp
    /var/log/wtmp.db
)

# --- Package state ------------------------------------------------------------
# user.packages      = explicitly installed since the base snapshot
# removed.packages   = removed since the base snapshot
# base.packages      = full package list of the current ISO
# base.manual        = manual package list of the current ISO
save_user_packages() {
    # Diff current packages against the base snapshot. Sort is required for
    # comm; the files may also be edited manually.
    check_pkg_manager || return 0

    local current_packages manual_packages
    current_packages=$(mktemp)
    manual_packages=$(mktemp)
    get_installed_packages > "${current_packages}"
    get_manual_packages > "${manual_packages}"

    if [[ ! -s ${BASE_PACKAGE_FILE} ]]; then
        install -D -m 0644 "${current_packages}" "${BASE_PACKAGE_FILE}"
        install -D -m 0644 "${manual_packages}" "${BASE_MANUAL_FILE}"
        : > "${PACKAGE_FILE}"
        : > "${REMOVED_PACKAGE_FILE}"
        rm -f "${current_packages}" "${manual_packages}"
        log_info "Created base package list: ${BASE_PACKAGE_FILE}"
        return 0
    fi

    comm -23 "${manual_packages}" <(sort -u "${BASE_MANUAL_FILE}") \
        | install -D -m 0644 /dev/stdin "${PACKAGE_FILE}"
    comm -23 <(sort -u "${BASE_PACKAGE_FILE}") "${current_packages}" \
        | install -D -m 0644 /dev/stdin "${REMOVED_PACKAGE_FILE}"

    rm -f "${current_packages}" "${manual_packages}"
    log_info "Package lists updated: user.packages ($(wc -l < "${PACKAGE_FILE}" 2>/dev/null || echo 0)), removed.packages ($(wc -l < "${REMOVED_PACKAGE_FILE}" 2>/dev/null || echo 0))"
}

capture_base_packages() {
    # Snapshot the fresh ISO package set right after an ISO change.
    check_pkg_manager || return 0

    local current_packages manual_packages
    current_packages=$(mktemp)
    manual_packages=$(mktemp)
    get_installed_packages > "${current_packages}"
    get_manual_packages > "${manual_packages}"
    install -D -m 0644 "${current_packages}" "${BASE_PACKAGE_FILE}"
    install -D -m 0644 "${manual_packages}" "${BASE_MANUAL_FILE}"
    rm -f "${current_packages}" "${manual_packages}"
    log_info "Captured base package list for the new ISO"
}

install_packages() {
    local packages=$1
    local -a package_array=()
    read -r -a package_array <<< "${packages}"

    case "${PKG_MGR}" in
        apt)
            apt-get update -o Acquire::Http::Timeout=5 -o Acquire::Connect-Timeout=5 || true
            apt-get install -y --no-install-recommends "${package_array[@]}" \
                || log_warn "Failed to install some packages via apt"
            ;;
        pacman)
            pacman -Sy --noconfirm "${package_array[@]}" \
                || log_warn "Failed to install packages via pacman"
            ;;
        dnf)
            dnf install -y "${package_array[@]}" \
                || log_warn "Failed to install packages via dnf"
            ;;
        apk)
            apk add "${package_array[@]}" \
                || log_warn "Failed to install packages via apk"
            ;;
    esac
}

remove_packages() {
    local packages=$1
    local -a package_array=()
    read -r -a package_array <<< "${packages}"

    case "${PKG_MGR}" in
        apt)
            apt-get purge -y "${package_array[@]}" \
                || log_warn "Failed to remove packages via apt"
            ;;
        pacman)
            pacman -Rns --noconfirm "${package_array[@]}" \
                || log_warn "Failed to remove packages via pacman"
            ;;
        dnf)
            dnf remove -y "${package_array[@]}" \
                || log_warn "Failed to remove packages via dnf"
            ;;
        apk)
            apk del "${package_array[@]}" \
                || log_warn "Failed to remove packages via apk"
            ;;
    esac
}

restore_user_packages() {
    # Apply the saved user package state on top of the new ISO package set.
    check_pkg_manager || return 0

    local packages rm_packages

    packages=$(grep -Ev '^[[:space:]#]*$' "${PACKAGE_FILE}" 2>/dev/null | sort -u | tr '\n' ' ')
    if [[ -n ${packages} ]]; then
        log_info "Installing saved packages (${PKG_MGR}): ${packages}"
        install_packages "${packages}"
    fi

    rm_packages=$(grep -Ev '^[[:space:]#]*$' "${REMOVED_PACKAGE_FILE}" 2>/dev/null | sort -u | tr '\n' ' ')
    if [[ -n ${rm_packages} ]]; then
        log_info "Removing packages previously purged from the base ISO (${PKG_MGR}): ${rm_packages}"
        remove_packages "${rm_packages}"
    fi
}

find_overlay_upperdir() {
    # Find the OverlayFS upperdir of the root filesystem.
    # Try findmnt -T / (target-specific) first, fall back to /proc/mounts.
    local upperdir
    upperdir=$(findmnt -n -T / -o OPTIONS 2>/dev/null | tr ',' '\n' \
        | sed -n 's/^upperdir=//p' | head -n1)
    if [[ -n ${upperdir} && -d ${upperdir} ]]; then
        printf '%s\n' "${upperdir%%:*}"
        return 0
    fi
    upperdir=$(grep -m1 ' overlay / ' /proc/mounts 2>/dev/null \
        | sed -n 's/.*upperdir=\([^,]*\).*/\1/p')
    if [[ -n ${upperdir} && -d ${upperdir} ]]; then
        printf '%s\n' "${upperdir%%:*}"
        return 0
    fi
    return 1
}

# Paths that must NEVER be cleaned, regardless of ISO changes.
PROTECTED_PATHS=(
    /home /home/*
    /opt /opt/*
    /var/log /var/log/*
    /etc/NetworkManager /etc/NetworkManager/*
)

is_protected() {
    local path=$1 pattern
    for pattern in "${PROTECTED_PATHS[@]}"; do
        [[ ${path} == ${pattern} ]] && return 0
    done
    return 1
}

# Delete a path inside the upperdir directly: no whiteouts are created for
# files coming from the lowerdir (ISO). Deleting via the merged view would
# leave .wh.* markers that would hide the same files from a NEW ISO.
clean_upper_path() {
    local upperdir=$1 merged_path=$2
    local upper_path="${upperdir}${merged_path}"

    if is_protected "${merged_path}"; then
        log_warn "Skipping protected path: ${merged_path}"
        return 0
    fi

    if [[ -d ${upper_path} ]]; then
        log_info "Cleaning upperdir dir: ${upper_path}"
        find "${upper_path}" -mindepth 1 -delete 2>/dev/null || true
    elif [[ -f ${upper_path} ]]; then
        log_info "Cleaning upperdir file: ${upper_path}"
        rm -f "${upper_path}" 2>/dev/null || true
    fi
}

get_iso_dependent_directories() {
    # Merge the default list with user additions from .env:ISO_DEPENDENT_DIRS.
    local -a dirs=("${ISO_DEPENDENT_DIRS[@]}")

    if [[ -n ${USER_ISO_DIRS:-} ]]; then
        local -a custom_dirs=()
        IFS=' ' read -r -a custom_dirs <<< "${USER_ISO_DIRS}"
        dirs+=("${custom_dirs[@]}")
    fi

    printf '%s\n' "${dirs[@]}" | sort -u
}

# PAM whiteout markers are covered by the general .wh.* cleanup below.

clean_iso_dependent_state() {
    log_info "Cleaning ISO-dependent state..."

    local upperdir=""
    upperdir=$(find_overlay_upperdir || true)

    if [[ -z ${upperdir} ]]; then
        # Fallback: merged view. Creates whiteouts for ISO files, but is only
        # used when the persistence layout is not OverlayFS.
        log_warn "OverlayFS upperdir not found, cleaning via merged view"
        local target
        while read -r target; do
            [[ -n ${target} ]] || continue
            if is_protected "${target}"; then
                log_warn "Skipping protected path: ${target}"
                continue
            fi
            if [[ -d ${target} ]]; then
                log_info "Cleaning dir: ${target}"
                find "${target}" -mindepth 1 -delete 2>/dev/null || true
            elif [[ -f ${target} ]]; then
                rm -f "${target}" 2>/dev/null || true
            fi
        done < <(get_iso_dependent_directories)
        return 0
    fi

    log_info "OverlayFS upperdir: ${upperdir}"

    # Drop the display-manager symlink so the new ISO can pick its own DM.
    rm -f "/etc/systemd/system/display-manager.service" 2>/dev/null || true

    local target
    while read -r target; do
        [[ -n ${target} ]] || continue
        clean_upper_path "${upperdir}" "${target}"
    done < <(get_iso_dependent_directories)

    # Remove stale overlay whiteouts from persistence (they mask new ISO files).
    log_info "Removing overlay whiteout markers from upperdir..."
    find "${upperdir}/etc" "${upperdir}/var" -name '.wh.*' -delete 2>/dev/null || true

    # Refresh system caches for the new ISO.
    command -v ldconfig >/dev/null 2>&1 && ldconfig 2>/dev/null || true
    command -v update-alternatives >/dev/null 2>&1 && update-alternatives --all 2>/dev/null || true

    return 0
}

get_iso_id() {
    # Fast ISO fingerprint: size + mtime + sha256 of the first 1 MiB.
    # <0.01s instead of minutes to hash a 4GB image on a slow USB stick.
    local squashfs_file=""
    if [[ -n ${LIVE_DIR} && -f ${LIVE_DIR}/filesystem.squashfs ]]; then
        squashfs_file="${LIVE_DIR}/filesystem.squashfs"
    elif [[ -n ${LIVE_DIR} && -f ${LIVE_DIR}/rootfs.img ]]; then
        squashfs_file="${LIVE_DIR}/rootfs.img"
    fi

    if [[ -n ${squashfs_file} ]]; then
        local meta head_hash
        meta=$(stat -c '%s-%Y' "${squashfs_file}" 2>/dev/null || true)
        head_hash=$(head -c 1048576 "${squashfs_file}" 2>/dev/null | sha256sum | awk '{print $1}')
        printf '%s-%s\n' "${meta}" "${head_hash}"
    elif [[ -f /etc/os-release ]]; then
        sha256sum /etc/os-release | awk '{print $1}'
    else
        return 1
    fi
}

# --- Execution modes -----------------------------------------------------------
case ${1:-} in
    --save-packages|save)
        # Called from package manager hooks: quick diff, no boot work.
        [[ -s ${BASE_PACKAGE_FILE} ]] && save_user_packages
        exit 0
        ;;
    --restore)
        # Called in the background after an ISO change; must not block boot.
        export DEBIAN_FRONTEND=noninteractive
        log_info "=== Background package restore ==="
        restore_user_packages
        save_user_packages
        log_info "=== Package restore finished ==="
        exit 0
        ;;
    ""|--boot)
        ;;
    *)
        echo "Usage: $0 [--save-packages|save|--restore|--boot]" >&2
        exit 2
        ;;
esac

# --- Main boot flow ---------------------------------------------------------
current_iso=$(get_iso_id || true)
previous_iso=$(cat "${ISO_ID_FILE}" 2>/dev/null || true)
ISO_CHANGED=false

if [[ -n ${current_iso} ]]; then
    if [[ -n ${previous_iso} && ${previous_iso} != "${current_iso}" ]]; then
        ISO_CHANGED=true
        log_info "ISO change detected: ${previous_iso} -> ${current_iso}"
        clean_iso_dependent_state
        printf '%s\n' "${current_iso}" > "${ISO_ID_FILE}"
        capture_base_packages
        # Heavy package restore runs in the BACKGROUND so boot (and the
        # display manager) are not blocked by long installs.
        if [[ -s ${PACKAGE_FILE} || -s ${REMOVED_PACKAGE_FILE} ]]; then
            log_info "Starting background package restore"
            nohup /usr/local/bin/immutable-live.sh --restore >> "${LOG_DIR}/restore.log" 2>&1 &
            disown || true
        fi
    elif [[ -z ${previous_iso} ]]; then
        log_info "First boot: saved fingerprint of the current ISO (${current_iso})"
        printf '%s\n' "${current_iso}" > "${ISO_ID_FILE}"
        capture_base_packages
        ISO_CHANGED=true
    else
        log_info "ISO unchanged (${current_iso})"
    fi
else
    log_warn "Could not determine ISO ID"
fi

# On ISO change the base lists are already fresh (capture_base_packages); on a
# normal boot just refresh the user package lists.
[[ ${ISO_CHANGED} == "true" ]] || save_user_packages

# --- System configuration -----------------------------------------------------
configure_system() {
    # 1. Hostname
    local host_name=${HOSTNAME:-}
    if [[ -n ${host_name} ]]; then
        log_info "Setting hostname: ${host_name}"
        printf '%s\n' "${host_name}" > /etc/hostname
        if command -v hostnamectl >/dev/null 2>&1; then
            hostnamectl set-hostname "${host_name}" 2>/dev/null || true
        else
            hostname "${host_name}" 2>/dev/null || true
        fi

        if [[ -f /etc/hosts ]]; then
            if grep -q "127.0.1.1" /etc/hosts; then
                sed -i "s/127.0.1.1.*/127.0.1.1\t${host_name}/g" /etc/hosts
            else
                printf '127.0.1.1\t%s\n' "${host_name}" >> /etc/hosts
            fi
        fi
    fi

    # 2. Locale / language
    local sys_locale=${LOCALE:-}
    local sys_lang=${LANGUAGE:-}
    if [[ -n ${sys_locale} ]]; then
        log_info "Setting system locale: ${sys_locale}"
        mkdir -p /etc/default
        {
            echo "LANG=${sys_locale}"
            [[ -n ${sys_lang} ]] && echo "LANGUAGE=${sys_lang}"
        } > /etc/default/locale
        {
            echo "LANG=${sys_locale}"
            [[ -n ${sys_lang} ]] && echo "LANGUAGE=${sys_lang}"
        } > /etc/locale.conf 2>/dev/null || true
        if command -v localectl >/dev/null 2>&1; then
            localectl set-locale LANG="${sys_locale}" 2>/dev/null || true
        fi
    fi

    # 3. Keyboard layout
    local kb_layout=${KEYBOARD_LAYOUT:-${KEYMAP:-}}
    local kb_variant=${KEYBOARD_VARIANT:-}
    local kb_options=${KEYBOARD_OPTIONS:-grp:alt_shift_toggle}
    if [[ -n ${kb_layout} ]]; then
        log_info "Setting keyboard layout: ${kb_layout}"
        mkdir -p /etc/default
        cat <<EOF > /etc/default/keyboard
XKBMODEL="pc105"
XKBLAYOUT="${kb_layout}"
XKBVARIANT="${kb_variant}"
XKBOPTIONS="${kb_options}"
BACKSPACE="guess"
EOF
        if command -v localectl >/dev/null 2>&1; then
            localectl set-x11-keymap "${kb_layout}" "pc105" "${kb_variant}" "${kb_options}" 2>/dev/null || true
        fi
    fi

    # 4. DNS servers
    local dns_servers=${DNS_SERVERS:-}
    if [[ -n ${dns_servers} ]]; then
        log_info "Setting DNS servers: ${dns_servers}"
        local dns tmp_resolv
        tmp_resolv=$(mktemp)
        for dns in ${dns_servers}; do
            printf 'nameserver %s\n' "${dns}" >> "${tmp_resolv}"
        done
        cat "${tmp_resolv}" > /etc/resolv.conf 2>/dev/null || true
        rm -f "${tmp_resolv}"
    fi
}
configure_system

# --- User configuration --------------------------------------------------------
configure_user() {
    local username=${USER_NAME:-live}
    local pass_hash=${USER_PASSWORD_HASH:-}
    local shell=${USER_SHELL:-/bin/bash}
    local groups_csv=${USER_GROUPS:-sudo,audio,video,plugdev,netdev}
    local hide_user=${HIDE_USER:-false}
    local disable_live_user=${DISABLE_LIVE_USER:-${DISABLE_ISO_USER:-false}}

    log_info "Configuring user ${username}..."

    # 1. Ensure the user exists
    if id "${username}" >/dev/null 2>&1; then
        log_info "User ${username} exists, updating settings..."
        usermod -s "${shell}" "${username}" 2>/dev/null || true
    else
        log_info "Creating user ${username} (shell: ${shell})..."
        useradd -m -s "${shell}" "${username}" || log_warn "Failed to create user ${username}"
    fi

    # 2. Password: pick up changes made in the OS and sync them back to .env
    local shadow_hash saved_hash
    shadow_hash=$(getent shadow "${username}" 2>/dev/null | cut -d: -f2 || true)
    saved_hash=$(cat "${PASSWORD_HASH_FILE}" 2>/dev/null || true)

    if [[ -n ${shadow_hash} && ${shadow_hash} != "!" && ${shadow_hash} != "*" ]]; then
        if [[ -n ${saved_hash} && ${shadow_hash} != "${saved_hash}" ]]; then
            log_info "Password changed in the OS - saving and updating .env..."
            printf '%s\n' "${shadow_hash}" > "${PASSWORD_HASH_FILE}"
            sync_env_var USER_PASSWORD_HASH "${shadow_hash}"
        elif [[ -z ${saved_hash} ]]; then
            printf '%s\n' "${shadow_hash}" > "${PASSWORD_HASH_FILE}"
        fi
    elif [[ -n ${pass_hash} ]]; then
        log_info "Setting password from config for ${username}..."
        usermod -p "${pass_hash}" "${username}" || log_warn "Failed to set password"
        printf '%s\n' "${pass_hash}" > "${PASSWORD_HASH_FILE}"
        sync_env_var USER_PASSWORD_HASH "${pass_hash}"
    fi

    # 3. Two-way group sync: .env -> system (add/remove), system -> .env
    local -a desired_groups=()
    local -a managed_groups=()
    local -a current_groups=()
    local g d c

    IFS=',' read -r -a desired_groups <<< "${groups_csv}"
    [[ -f ${GROUPS_FILE} ]] && mapfile -t managed_groups < "${GROUPS_FILE}"

    local primary_group
    primary_group=$(id -ng "${username}" 2>/dev/null || true)

    while read -r g; do
        [[ -n ${g} && ${g} != "${primary_group}" ]] && current_groups+=("${g}")
    done < <(id -nG "${username}" 2>/dev/null | tr ' ' '\n')

    # Drop previously managed groups that are no longer in .env
    for g in "${managed_groups[@]}"; do
        local in_desired=false
        for d in "${desired_groups[@]}"; do
            d=${d// /}
            [[ ${g} == "${d}" ]] && in_desired=true
        done
        if [[ ${in_desired} == false ]]; then
            local -a new_groups=()
            for c in "${current_groups[@]}"; do
                [[ ${c} != "${g}" ]] && new_groups+=("${c}")
            done
            current_groups=("${new_groups[@]}")
        fi
    done

    # Add desired groups, creating any that are missing
    for d in "${desired_groups[@]}"; do
        d=${d// /}
        [[ -n ${d} ]] || continue
        if ! getent group "${d}" >/dev/null 2>&1; then
            groupadd "${d}" 2>/dev/null || true
        fi
        local present=false
        for c in "${current_groups[@]}"; do
            [[ ${c} == "${d}" ]] && present=true
        done
        [[ ${present} == false ]] && current_groups+=("${d}")
    done

    if [[ ${#current_groups[@]} -gt 0 ]]; then
        usermod -G "$(IFS=','; echo "${current_groups[*]}")" "${username}" 2>/dev/null || true
    fi

    # Save the managed group list and sync the effective set back to .env
    printf '%s\n' "${desired_groups[@]}" > "${GROUPS_FILE}"
    local effective_groups
    effective_groups=$(IFS=','; echo "${current_groups[*]}")
    sync_env_var USER_GROUPS "${effective_groups}"
    log_info "Synced groups for ${username}: ${effective_groups}"

    # 4. Hide the user on the login screen
    if [[ ${hide_user} == "true" || ${hide_user} == "yes" ]]; then
        chmod 700 "/home/${username}" 2>/dev/null || true
        mkdir -p /var/lib/AccountsService/users
        printf '[User]\nSystemAccount=true\n' > "/var/lib/AccountsService/users/${username}"
    fi

# 5. DISABLE_LIVE_USER=true: remove the ISO default user entirely (the
    #    account does not exist and is never recreated)
    if [[ ${disable_live_user} == "true" || ${disable_live_user} == "yes" ]]; then
        local default_iso_users=(live kali user debian ubuntu mint arch)
        local iso_user
        for iso_user in "${default_iso_users[@]}"; do
            if [[ ${iso_user} != "${username}" ]] && id "${iso_user}" >/dev/null 2>&1; then
                log_info "Removing default ISO user: ${iso_user}"
                userdel -r "${iso_user}" 2>/dev/null \
                    || usermod -L -s /sbin/nologin "${iso_user}" 2>/dev/null || true
            fi
        done
    fi
}
configure_user

# --- Swap configuration --------------------------------------------------------
configure_swap() {
    local swap_enable=${SWAP_ENABLE:-true}
    local swap_file=${SWAP_FILE:-/var/swap/swapfile}
    local swap_size=${SWAP_SIZE:-2G}
    local swappiness=${SWAPPINESS:-10}

    [[ ${swap_enable} == "true" ]] || { log_info "SWAP disabled in config"; return 0; }

    log_info "Configuring SWAP (${swap_file}, ${swap_size})..."
    mkdir -p "$(dirname "${swap_file}")"

    if [[ ! -f ${swap_file} ]]; then
        log_info "Creating SWAP file..."
        fallocate -l "${swap_size}" "${swap_file}" 2>/dev/null \
            || dd if=/dev/zero of="${swap_file}" bs=1M count=2048 2>/dev/null
        chmod 600 "${swap_file}"
        mkswap "${swap_file}" >/dev/null
    fi

    if ! swapon --show | grep -q "${swap_file}"; then
        swapon "${swap_file}" || log_warn "Failed to enable SWAP"
    fi

    sysctl -w vm.swappiness="${swappiness}" >/dev/null 2>&1 || true
}
configure_swap

# --- Time and NTP ----------------------------------------------------------------
configure_time() {
    local timezone=${TIMEZONE:-}
    local ntp_enable=${NTP_ENABLE:-true}

    if [[ -n ${timezone} && -f "/usr/share/zoneinfo/${timezone}" ]]; then
        log_info "Setting timezone: ${timezone}"
        ln -sf "/usr/share/zoneinfo/${timezone}" /etc/localtime
    fi

    if [[ ${ntp_enable} == "true" ]] && command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true 2>/dev/null || true
    fi
}
configure_time

# --- Package manager hooks (instant package save) ------------------------------
# Written only if missing, to spare flash writes.
configure_pkg_hooks() {
    local hook_content hook_path

    # APT (Debian / Kali / Ubuntu)
    if [[ -d /etc/apt/apt.conf.d ]]; then
        hook_path=/etc/apt/apt.conf.d/99-immutable-live
        hook_content='DPkg::Post-Invoke { "/usr/local/bin/immutable-live.sh --save-packages >/dev/null 2>&1 || true"; };'
        if [[ ! -f ${hook_path} ]] || ! grep -q "immutable-live" "${hook_path}" 2>/dev/null; then
            printf '%s\n' "${hook_content}" > "${hook_path}"
            log_info "Installed post-transaction hook for APT"
        fi
    fi

    # DNF (Fedora / RHEL)
    if [[ -d /etc/dnf/plugins ]]; then
        hook_path=/etc/dnf/plugins/immutable-live.conf
        if [[ ! -f ${hook_path} ]]; then
            printf '[main]\nenabled=1\n' > "${hook_path}"
            log_info "Installed post-transaction hook for DNF"
        fi
    fi

    # Pacman (Arch Linux)
    if [[ -d /etc/pacman.d ]]; then
        hook_path=/etc/pacman.d/hooks/99-immutable-live.hook
        if [[ ! -f ${hook_path} ]]; then
            mkdir -p /etc/pacman.d/hooks
            cat <<'HOOKEOF' > "${hook_path}"
[Trigger]
Operation = Install
Operation = Remove
Operation = Upgrade
Type = Package
Target = *

[Action]
When = PostTransaction
Exec = /usr/local/bin/immutable-live.sh --save-packages
HOOKEOF
            log_info "Installed post-transaction hook for Pacman"
        fi
    fi

    # APK (Alpine)
    if [[ -d /etc/apk ]] && command -v apk >/dev/null 2>&1; then
        hook_path=/etc/apk/post-install.d/99-immutable-live.sh
        if [[ ! -f ${hook_path} ]]; then
            printf '#!/bin/sh\n/usr/local/bin/immutable-live.sh --save-packages >/dev/null 2>&1 || true\n' > "${hook_path}"
            chmod +x "${hook_path}" 2>/dev/null || true
            log_info "Installed post-transaction hook for APK"
        fi
    fi
}
configure_pkg_hooks

log_info "=== immutable-live boot finished ==="
