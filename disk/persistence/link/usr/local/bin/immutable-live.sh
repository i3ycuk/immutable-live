#!/usr/bin/env bash
# ==============================================================================
# immutable-live.sh - Initialize system settings and clean ISO-dependent state
# from the persistence upperdir when booting on live Linux images.
# ==============================================================================
set -Eeuo pipefail

LOG_FILE=${IMMUTABLE_LOG_FILE:-/var/log/immutable-live/immutable-live.log}
CONFIG_DIR=${IMMUTABLE_CONFIG_DIR:-/etc/immutable-live/config}
STATE_DIR=${IMMUTABLE_STATE_DIR:-/etc/immutable-live/state}
CACHE_BASE_DIR=${IMMUTABLE_CACHE_DIR:-/var/cache/immutable-live}
ROOT_PREFIX=${IMMUTABLE_ROOT_PREFIX:-""}
ISO_ID_FILE=${STATE_DIR}/iso.id
PASSWORD_HASH_FILE=${STATE_DIR}/user_password.hash
GROUPS_FILE=${STATE_DIR}/user.groups

MAX_LOG_SIZE=$((512 * 1024))
LIVE_DIR=""

mkdir -p "$(dirname "${LOG_FILE}")" "${STATE_DIR}" "${CONFIG_DIR}" "${CACHE_BASE_DIR}" 2>/dev/null || true

# --- Logging & Visual Presentation -------------------------------------------
C_RESET=$'\033[0m'
C_CYAN=$'\033[36m'
C_YELLOW=$'\033[33m'
C_GREEN=$'\033[32m'
C_RED=$'\033[31m'
C_GRAY=$'\033[90m'
C_BOLD=$'\033[1m'
C_MAGENTA=$'\033[35m'
C_WHITE=$'\033[37;1m'

show_boot_art() {
    # If graphical Plymouth splash is active (e.g. Pedro Raccoon), let it animate
    if command -v plymouth >/dev/null 2>&1 && plymouth --ping 2>/dev/null; then
        return 0
    fi

    # Skip if running non-interactively without a TTY unless explicitly forced
    if [[ ! -t 1 && ! -w /dev/tty && -z ${IMMUTABLE_FORCE_ANIMATION:-} ]]; then
        return 0
    fi

    local frames=(
# Frame 0: Egg starts top-left, Hare peeking from top window
"${C_CYAN}  .----------------------------------------------------------.
  |  ${C_YELLOW}ЭЛЕКТРОНИКА ИМ-02${C_CYAN}       ${C_WHITE}НУ, ПОГОДИ!${C_CYAN}       ${C_GREEN}СЧЁТ: [ 000 ]${C_CYAN} |
  |                                                          |
  |  ${C_MAGENTA}(\\_/)${C_CYAN}                                                   |
  |  ${C_MAGENTA}(o.o)${C_YELLOW}*${C_CYAN}                                                  |
  |  ${C_WHITE}(o)${C_GRAY}\\====\\${C_CYAN}                  ${C_CYAN}/\\_/\\${C_CYAN}                 ${C_GRAY}/====/${C_CYAN} |
  |     ${C_GRAY}\\====\\${C_CYAN}                ${C_CYAN}( -.-)${C_CYAN}               ${C_GRAY}/====/${C_CYAN}    |
  |                            ${C_CYAN}(  > )\\_${C_WHITE}/${C_CYAN}                     |
  |     ${C_GRAY}\\====\\${C_CYAN}                 ${C_CYAN}/ | \\${C_CYAN}                 ${C_GRAY}/====/${C_CYAN}  |
  |      ${C_GRAY}\\====\\${C_CYAN}               ${C_CYAN}/  |  \\${C_CYAN}               ${C_GRAY}/====/${C_CYAN}   |
  |                          ${C_GRAY}=============${C_CYAN}                   |
  '----------------------------------------------------------'
           ${C_YELLOW}[ ••• LOADING IMMUTABLE LIVE SYSTEM ••• ]${C_RESET}"

# Frame 1: Egg rolling down top-left, Wolf reaching up-left with basket
"${C_CYAN}  .----------------------------------------------------------.
  |  ${C_YELLOW}ЭЛЕКТРОНИКА ИМ-02${C_CYAN}       ${C_WHITE}НУ, ПОГОДИ!${C_CYAN}       ${C_GREEN}СЧЁТ: [ 000 ]${C_CYAN} |
  |                                                          |
  |  ${C_MAGENTA}(\\_/)${C_CYAN}                                                   |
  |  ${C_MAGENTA}(o.o)${C_YELLOW}*${C_CYAN}                 ${C_WHITE}\\_/${C_CYAN} /) /)                        |
  |     ${C_GRAY}\\=${C_WHITE}(o)${C_GRAY}=\\${C_CYAN}             ${C_CYAN}\\_/(o.o)${C_CYAN}                  ${C_GRAY}/====/${C_CYAN} |
  |     ${C_GRAY}\\====\\${C_CYAN}                ${C_CYAN}(  > )${C_CYAN}               ${C_GRAY}/====/${C_CYAN}    |
  |                            ${C_CYAN}/ | \\${C_CYAN}                         |
  |     ${C_GRAY}\\====\\${C_CYAN}                ${C_CYAN}/  |  \\${C_CYAN}                ${C_GRAY}/====/${C_CYAN}  |
  |      ${C_GRAY}\\====\\${C_CYAN}                                     ${C_GRAY}/====/${C_CYAN}   |
  |                          ${C_GRAY}=============${C_CYAN}                   |
  '----------------------------------------------------------'
           ${C_YELLOW}[ ••• LOADING IMMUTABLE LIVE SYSTEM ••• ]${C_RESET}"

# Frame 2: Caught top-left! Score 001!
"${C_CYAN}  .----------------------------------------------------------.
  |  ${C_YELLOW}ЭЛЕКТРОНИКА ИМ-02${C_CYAN}       ${C_WHITE}НУ, ПОГОДИ!${C_CYAN}       ${C_GREEN}СЧЁТ: [ 001 ]${C_CYAN} |
  |                                                          |
  |                                                          |
  |                         ${C_WHITE}\\(o)/${C_CYAN} /) /)                      |
  |     ${C_GRAY}\\====\\${C_CYAN}              ${C_CYAN}\\_/(^.^)${C_YELLOW} *${C_CYAN}                ${C_GRAY}/====/${C_CYAN} |
  |     ${C_GRAY}\\====\\${C_CYAN}                ${C_CYAN}(  > )${C_CYAN}               ${C_GRAY}/====/${C_CYAN}    |
  |                            ${C_CYAN}/ | \\${C_CYAN}                         |
  |     ${C_GRAY}\\====\\${C_CYAN}                ${C_CYAN}/  |  \\${C_CYAN}                ${C_GRAY}/====/${C_CYAN}  |
  |      ${C_GRAY}\\====\\${C_CYAN}                                     ${C_GRAY}/====/${C_CYAN}   |
  |                          ${C_GRAY}=============${C_CYAN}                   |
  '----------------------------------------------------------'
           ${C_YELLOW}[ ••• INITIALIZING SYSTEM MODULES ••• ]${C_RESET}"

# Frame 3: Egg starts top-right, Wolf turns right
"${C_CYAN}  .----------------------------------------------------------.
  |  ${C_YELLOW}ЭЛЕКТРОНИКА ИМ-02${C_CYAN}       ${C_WHITE}НУ, ПОГОДИ!${C_CYAN}       ${C_GREEN}СЧЁТ: [ 001 ]${C_CYAN} |
  |                                                          |
  |                                                          |
  |                                                          |
  |     ${C_GRAY}\\====\\${C_CYAN}                 ${C_CYAN}/\\_/\\${C_CYAN}              ${C_GRAY}/====/${C_WHITE}(o)${C_CYAN}  |
  |     ${C_GRAY}\\====\\${C_CYAN}                ${C_CYAN}( -.-)${C_CYAN}             ${C_GRAY}/====/${C_CYAN}      |
  |                         ${C_WHITE}\\_/${C_CYAN}( <  )                        |
  |     ${C_GRAY}\\====\\${C_CYAN}                 ${C_CYAN}/ | \\${C_CYAN}                 ${C_GRAY}/====/${C_CYAN}  |
  |      ${C_GRAY}\\====\\${C_CYAN}               ${C_CYAN}/  |  \\${C_CYAN}               ${C_GRAY}/====/${C_CYAN}   |
  |                          ${C_GRAY}=============${C_CYAN}                   |
  '----------------------------------------------------------'
           ${C_YELLOW}[ ••• PREPARING PERSISTENCE OVERLAY ••• ]${C_RESET}"

# Frame 4: Caught top-right! Score 002!
"${C_CYAN}  .----------------------------------------------------------.
  |  ${C_YELLOW}ЭЛЕКТРОНИКА ИМ-02${C_CYAN}       ${C_WHITE}НУ, ПОГОДИ!${C_CYAN}       ${C_GREEN}СЧЁТ: [ 002 ]${C_CYAN} |
  |                                                          |
  |                                                          |
  |                                ${C_CYAN}(\\ (\\ ${C_WHITE}\\(o)/${C_CYAN}               |
  |     ${C_GRAY}\\====\\${C_CYAN}               ${C_YELLOW}*${C_CYAN}  (^.^) \\_/             ${C_GRAY}/====/${C_CYAN} |
  |     ${C_GRAY}\\====\\${C_CYAN}                ${C_CYAN}( <  )${C_CYAN}               ${C_GRAY}/====/${C_CYAN}    |
  |                            ${C_CYAN}/ | \\${C_CYAN}                         |
  |     ${C_GRAY}\\====\\${C_CYAN}                ${C_CYAN}/  |  \\${C_CYAN}                ${C_GRAY}/====/${C_CYAN}  |
  |      ${C_GRAY}\\====\\${C_CYAN}                                     ${C_GRAY}/====/${C_CYAN}   |
  |                          ${C_GRAY}=============${C_CYAN}                   |
  '----------------------------------------------------------'
           ${C_YELLOW}[ ••• VERIFYING ISO FINGERPRINT ••• ]${C_RESET}"

# Frame 5: Egg rolling bottom-left
"${C_CYAN}  .----------------------------------------------------------.
  |  ${C_YELLOW}ЭЛЕКТРОНИКА ИМ-02${C_CYAN}       ${C_WHITE}НУ, ПОГОДИ!${C_CYAN}       ${C_GREEN}СЧЁТ: [ 002 ]${C_CYAN} |
  |                                                          |
  |  ${C_MAGENTA}(\\_/)${C_CYAN}                                                   |
  |  ${C_MAGENTA}(o.o)${C_YELLOW}*${C_CYAN}                                                  |
  |     ${C_GRAY}\\====\\${C_CYAN}                 ${C_CYAN}/\\_/\\${C_CYAN}                  ${C_GRAY}/====/${C_CYAN} |
  |     ${C_GRAY}\\====\\${C_CYAN}                ${C_CYAN}(O_O)${C_CYAN}                ${C_GRAY}/====/${C_CYAN}    |
  |     ${C_GRAY}\\=${C_WHITE}(o)${C_GRAY}=\\${C_CYAN}             ${C_WHITE}\\_/${C_CYAN}(  > )                        |
  |      ${C_GRAY}\\====\\${C_CYAN}                ${C_CYAN}/ | \\${C_CYAN}                 ${C_GRAY}/====/${C_CYAN}  |
  |                           ${C_CYAN}/  |  \\${C_CYAN}               ${C_GRAY}/====/${C_CYAN}   |
  |                          ${C_GRAY}=============${C_CYAN}                   |
  '----------------------------------------------------------'
           ${C_YELLOW}[ ••• SYNCHRONIZING SYSTEM STATE ••• ]${C_RESET}"

# Frame 6: Caught bottom-left! Score 003!
"${C_CYAN}  .----------------------------------------------------------.
  |  ${C_YELLOW}ЭЛЕКТРОНИКА ИМ-02${C_CYAN}       ${C_WHITE}НУ, ПОГОДИ!${C_CYAN}       ${C_GREEN}СЧЁТ: [ 003 ]${C_CYAN} |
  |                                                          |
  |  ${C_MAGENTA}(\\_/)${C_CYAN}                                                   |
  |  ${C_MAGENTA}(^.^)${C_YELLOW}*${C_CYAN}                    ${C_CYAN}/\\_/\\${C_CYAN}                         |
  |     ${C_GRAY}\\====\\${C_CYAN}                ${C_CYAN}(^o^)${C_CYAN}                   ${C_GRAY}/====/${C_CYAN} |
  |     ${C_GRAY}\\====\\${C_CYAN}          ${C_WHITE}\\(o)/${C_CYAN}(  > )                ${C_GRAY}/====/${C_CYAN}    |
  |                            ${C_CYAN}/ | \\${C_CYAN}                         |
  |     ${C_GRAY}\\====\\${C_CYAN}                ${C_CYAN}/  |  \\${C_CYAN}                ${C_GRAY}/====/${C_CYAN}  |
  |      ${C_GRAY}\\====\\${C_CYAN}                                     ${C_GRAY}/====/${C_CYAN}   |
  |                          ${C_GRAY}=============${C_CYAN}                   |
  '----------------------------------------------------------'
           ${C_GREEN}[ ••• IMMUTABLE LIVE READY TO LAUNCH ••• ]${C_RESET}"
)

    local num_lines=13
    local f

    # Reserve lines on terminal
    for ((i=0; i<num_lines; i++)); do
        printf "\n"
    done

    # Hide cursor
    printf "\033[?25l"

    for f in "${frames[@]}"; do
        printf "\033[%dA\r%b\n" "$num_lines" "$f"
        sleep 0.22
    done

    # Restore cursor
    printf "\033[?25h\n"
}

log() {
    local msg=$1
    local level=${2:-INFO}
    local timestamp
    timestamp=$(date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    printf '[%s] [%-5s] %s\n' "${timestamp}" "${level}" "${msg}"
}

log_info()  { log "$1" "INFO"; }
log_warn()  { log "$1" "WARN"; }
log_error() { log "$1" "ERROR"; }

plymouth_msg() {
    if command -v plymouth >/dev/null 2>&1 && plymouth --ping 2>/dev/null; then
        plymouth message --text="$1" 2>/dev/null || true
    fi
}

if [[ -f ${LOG_FILE} ]]; then
    if (( $(stat -c '%s' "${LOG_FILE}" 2>/dev/null || echo 0) > MAX_LOG_SIZE )); then
        tail -c $((MAX_LOG_SIZE / 2)) "${LOG_FILE}" > "${LOG_FILE}.tmp" 2>/dev/null || true
        mv -f "${LOG_FILE}.tmp" "${LOG_FILE}" 2>/dev/null || true
    fi
fi
exec > >(tee -a "${LOG_FILE}") 2>&1

show_boot_art

# --- Default ISO-dependent directories to reset on ISO change -----------------
DEFAULT_ISO_DEPENDENT_DIRS=(
    # Color profiles
    /etc/colord
    /var/lib/colord
    /var/cache/colord

    # Display managers & login services (GDM, LightDM, SDDM, Greetd, LXDM, Ly)
    /etc/gdm3
    /etc/gdm
    /etc/lightdm
    /etc/sddm.conf
    /etc/sddm.conf.d
    /etc/greetd
    /etc/lxdm
    /var/lib/gdm3
    /var/lib/gdm
    /var/lib/lightdm
    /var/lib/sddm
    /var/lib/greetd
    /var/lib/lxdm
    /var/lib/ly
    /var/lib/AccountsService
    /etc/systemd/system/display-manager.service

    # System identity and runtime state
    /etc/machine-id
    /var/lib/dbus/machine-id
    /var/lib/dbus
    /var/lib/systemd
    /var/lib/udev

    # Package manager state and caches (Debian, Arch, Fedora, openSUSE, Alpine)
    /var/lib/dpkg
    /var/cache/apt
    /var/lib/apt
    /var/lib/alternatives
    /etc/alternatives
    /var/cache/debconf
    /var/lib/pacman/local
    /var/cache/pacman/pkg
    /var/lib/pacman/sync
    /var/lib/rpm
    /var/lib/dnf
    /var/cache/dnf
    /var/cache/yum
    /var/lib/zypp
    /var/cache/zypp
    /lib/apk/db
    /var/cache/apk

    # Shared library, font, and desktop catalog caches
    /etc/ld.so.cache
    /var/cache/fontconfig
    /var/cache/ldconfig
    /var/cache/man
    /var/lib/PackageKit
    /var/cache/swcatalog
    /var/lib/swcatalog

    # Desktop/system hardware services
    /etc/cups
    /var/cache/cups
    /etc/fwupd
    /var/cache/fwupd
    /var/lib/fwupd
    /var/lib/alsa
    /var/lib/pipewire
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

# --- Package Management (Per-Distro Tracking & Persistent Caching) ------------
detect_pkg_manager() {
    if command -v dpkg-query >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    elif command -v zypper >/dev/null 2>&1; then
        echo "zypper"
    elif [[ -n ${IMMUTABLE_PKG_MGR:-} ]]; then
        echo "${IMMUTABLE_PKG_MGR}"
    else
        echo "unknown"
    fi
}

PKG_MGR=$(detect_pkg_manager)
PKG_STATE_DIR="${STATE_DIR}/packages/${PKG_MGR}"
PKG_CACHE_DIR="${CACHE_BASE_DIR}/${PKG_MGR}"

BASE_PACKAGE_FILE="${PKG_STATE_DIR}/base.packages"
BASE_MANUAL_FILE="${PKG_STATE_DIR}/base.manual"
USER_PACKAGE_FILE="${PKG_STATE_DIR}/user.packages"
REMOVED_PACKAGE_FILE="${PKG_STATE_DIR}/removed.packages"

get_installed_packages() {
    if [[ -n ${IMMUTABLE_MOCK_INSTALLED_PACKAGES:-} ]]; then
        printf '%s\n' ${IMMUTABLE_MOCK_INSTALLED_PACKAGES} | sort -u
        return 0
    fi

    case "${PKG_MGR}" in
        apt)
            dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sed 's/:.*//' | sort -u
            ;;
        pacman)
            pacman -Qq 2>/dev/null | sort -u
            ;;
        dnf|zypper)
            rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort -u
            ;;
        apk)
            apk info 2>/dev/null | sort -u
            ;;
        *)
            ;;
    esac
}

get_manual_packages() {
    if [[ -n ${IMMUTABLE_MOCK_MANUAL_PACKAGES:-} ]]; then
        printf '%s\n' ${IMMUTABLE_MOCK_MANUAL_PACKAGES} | sort -u
        return 0
    fi

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
                dnf history userinstalled 2>/dev/null | awk 'NR>1 {print $1}' | sed 's/:.*//' | sort -u
            else
                rpm -qa --userinstalled --qf '%{NAME}\n' 2>/dev/null | sort -u
            fi
            ;;
        apk)
            [[ -f ${ROOT_PREFIX}/etc/apk/world ]] && grep -Ev '^[[:space:]#]*$' "${ROOT_PREFIX}/etc/apk/world" 2>/dev/null | sort -u
            ;;
        *)
            ;;
    esac
}

capture_base_packages() {
    [[ ${PKG_MGR} == "unknown" ]] && return 0

    mkdir -p "${PKG_STATE_DIR}"
    local current_all current_manual
    current_all=$(mktemp)
    current_manual=$(mktemp)

    get_installed_packages > "${current_all}"
    get_manual_packages > "${current_manual}"

    install -D -m 0644 "${current_all}" "${BASE_PACKAGE_FILE}"
    install -D -m 0644 "${current_manual}" "${BASE_MANUAL_FILE}"
    rm -f "${current_all}" "${current_manual}"

    local count
    count=$(wc -l < "${BASE_PACKAGE_FILE}" 2>/dev/null || echo 0)
    log_info "Captured ${PKG_MGR} baseline package list (${count} packages in ${BASE_PACKAGE_FILE})"
}

save_user_packages() {
    [[ ${PKG_MGR} == "unknown" ]] && return 0
    mkdir -p "${PKG_STATE_DIR}"

    local current_all current_manual
    current_all=$(mktemp)
    current_manual=$(mktemp)

    get_installed_packages > "${current_all}"
    get_manual_packages > "${current_manual}"

    if [[ ! -s ${BASE_PACKAGE_FILE} ]]; then
        install -D -m 0644 "${current_all}" "${BASE_PACKAGE_FILE}"
        install -D -m 0644 "${current_manual}" "${BASE_MANUAL_FILE}"
        : > "${USER_PACKAGE_FILE}"
        : > "${REMOVED_PACKAGE_FILE}"
        rm -f "${current_all}" "${current_manual}"
        log_info "Initialized initial ${PKG_MGR} base snapshot: ${BASE_PACKAGE_FILE}"
        return 0
    fi

    # User-added: explicitly installed packages absent from base snapshot
    comm -23 "${current_manual}" <(sort -u "${BASE_MANUAL_FILE}") \
        | install -D -m 0644 /dev/stdin "${USER_PACKAGE_FILE}"

    # User-removed: packages present in base snapshot but absent from current system
    comm -23 <(sort -u "${BASE_PACKAGE_FILE}") "${current_all}" \
        | install -D -m 0644 /dev/stdin "${REMOVED_PACKAGE_FILE}"

    rm -f "${current_all}" "${current_manual}"

    local added_count removed_count
    added_count=$(wc -l < "${USER_PACKAGE_FILE}" 2>/dev/null || echo 0)
    removed_count=$(wc -l < "${REMOVED_PACKAGE_FILE}" 2>/dev/null || echo 0)
    log_info "Saved user package state for ${PKG_MGR}: +${added_count} user packages, -${removed_count} removed"
}

setup_package_caching() {
    [[ ${PKG_MGR} == "unknown" ]] && return 0

    case "${PKG_MGR}" in
        apt)
            local archives_dir="${PKG_CACHE_DIR}/archives"
            mkdir -p "${archives_dir}/partial"
            local apt_conf="${ROOT_PREFIX}/etc/apt/apt.conf.d/98-immutable-cache"
            if [[ ! -f ${apt_conf} ]]; then
                mkdir -p "$(dirname "${apt_conf}")"
                cat << EOF > "${apt_conf}"
Dir::Cache::archives "${archives_dir}";
APT::Keep-Downloaded-Packages "true";
Binary::apt::APT::Keep-Downloaded-Packages "true";
EOF
                log_info "Configured APT to persist downloaded .deb packages in ${archives_dir}"
            fi
            ;;
        pacman)
            mkdir -p "${PKG_CACHE_DIR}/pkg"
            ;;
        dnf)
            mkdir -p "${PKG_CACHE_DIR}"
            ;;
        apk)
            mkdir -p "${PKG_CACHE_DIR}"
            ;;
    esac
}

restore_user_packages() {
    [[ ${PKG_MGR} == "unknown" ]] && return 0

    # 1. Re-install user-added packages
    if [[ -s ${USER_PACKAGE_FILE} ]]; then
        local -a pkgs=()
        mapfile -t pkgs < <(grep -Ev '^[[:space:]#]*$' "${USER_PACKAGE_FILE}" | sort -u)
        if [[ ${#pkgs[@]} -gt 0 ]]; then
            log_info "Restoring ${#pkgs[@]} user package(s) for ${PKG_MGR}: ${pkgs[*]}"
            case "${PKG_MGR}" in
                apt)
                    local archives_dir="${PKG_CACHE_DIR}/archives"
                    mkdir -p "${archives_dir}/partial"
                    apt-get update -o Acquire::Http::Timeout=5 -o Acquire::Connect-Timeout=5 2>/dev/null || true
                    apt-get install -y --no-install-recommends \
                        -o Dir::Cache::archives="${archives_dir}" \
                        "${pkgs[@]}" 2>&1 | while read -r line; do log_info "  [apt] ${line}"; done || log_warn "Some packages failed to install via apt"
                    ;;
                pacman)
                    local cache_dir="${PKG_CACHE_DIR}/pkg"
                    mkdir -p "${cache_dir}"
                    pacman -Sy --noconfirm --needed --cachedir "${cache_dir}" "${pkgs[@]}" 2>&1 | while read -r line; do log_info "  [pacman] ${line}"; done || log_warn "Some packages failed to install via pacman"
                    ;;
                dnf)
                    local cache_dir="${PKG_CACHE_DIR}"
                    mkdir -p "${cache_dir}"
                    dnf install -y -C "${pkgs[@]}" 2>/dev/null \
                        || dnf install -y "${pkgs[@]}" 2>&1 | while read -r line; do log_info "  [dnf] ${line}"; done || log_warn "Some packages failed to install via dnf"
                    ;;
                apk)
                    local cache_dir="${PKG_CACHE_DIR}"
                    mkdir -p "${cache_dir}"
                    apk add --cache-dir "${cache_dir}" "${pkgs[@]}" 2>&1 | while read -r line; do log_info "  [apk] ${line}"; done || log_warn "Some packages failed to install via apk"
                    ;;
            esac
        fi
    fi

    # 2. Purge user-removed packages
    if [[ -s ${REMOVED_PACKAGE_FILE} ]]; then
        local -a rm_pkgs=()
        mapfile -t rm_pkgs < <(grep -Ev '^[[:space:]#]*$' "${REMOVED_PACKAGE_FILE}" | sort -u)
        if [[ ${#rm_pkgs[@]} -gt 0 ]]; then
            log_info "Purging ${#rm_pkgs[@]} package(s) removed by user: ${rm_pkgs[*]}"
            case "${PKG_MGR}" in
                apt)
                    apt-get purge -y "${rm_pkgs[@]}" 2>&1 | while read -r line; do log_info "  [apt-purge] ${line}"; done || log_warn "Some packages failed to purge via apt"
                    ;;
                pacman)
                    pacman -Rns --noconfirm "${rm_pkgs[@]}" 2>&1 | while read -r line; do log_info "  [pacman-remove] ${line}"; done || log_warn "Some packages failed to remove via pacman"
                    ;;
                dnf)
                    dnf remove -y "${rm_pkgs[@]}" 2>&1 | while read -r line; do log_info "  [dnf-remove] ${line}"; done || log_warn "Some packages failed to remove via dnf"
                    ;;
                apk)
                    apk del "${rm_pkgs[@]}" 2>&1 | while read -r line; do log_info "  [apk-del] ${line}"; done || log_warn "Some packages failed to delete via apk"
                    ;;
            esac
        fi
    fi
}

configure_pkg_hooks() {
    [[ ${PKG_MGR} == "unknown" ]] && return 0

    case "${PKG_MGR}" in
        apt)
            local hook_path="${ROOT_PREFIX}/etc/apt/apt.conf.d/99-immutable-live"
            if [[ ! -f ${hook_path} ]]; then
                mkdir -p "$(dirname "${hook_path}")"
                cat << 'EOF' > "${hook_path}"
DPkg::Post-Invoke { "/usr/local/bin/immutable-live.sh --save-packages >/dev/null 2>&1 || true"; };
EOF
                log_info "Installed APT post-transaction hook in ${hook_path}"
            fi
            ;;
        pacman)
            local hook_path="${ROOT_PREFIX}/etc/pacman.d/hooks/99-immutable-live.hook"
            if [[ ! -f ${hook_path} ]]; then
                mkdir -p "$(dirname "${hook_path}")"
                cat << 'EOF' > "${hook_path}"
[Trigger]
Operation = Install
Operation = Remove
Operation = Upgrade
Type = Package
Target = *

[Action]
When = PostTransaction
Exec = /usr/local/bin/immutable-live.sh --save-packages
EOF
                log_info "Installed Pacman post-transaction hook in ${hook_path}"
            fi
            ;;
        dnf)
            local hook_path="${ROOT_PREFIX}/etc/dnf/plugins/immutable-live.conf"
            if [[ ! -f ${hook_path} ]]; then
                mkdir -p "$(dirname "${hook_path}")"
                printf '[main]\nenabled=1\n' > "${hook_path}"
                log_info "Installed DNF post-transaction hook in ${hook_path}"
            fi
            ;;
        apk)
            local hook_path="${ROOT_PREFIX}/etc/apk/post-install.d/99-immutable-live.sh"
            if [[ ! -f ${hook_path} ]]; then
                mkdir -p "$(dirname "${hook_path}")"
                printf '#!/bin/sh\n/usr/local/bin/immutable-live.sh --save-packages >/dev/null 2>&1 || true\n' > "${hook_path}"
                chmod +x "${hook_path}" 2>/dev/null || true
                log_info "Installed APK post-transaction hook in ${hook_path}"
            fi
            ;;
    esac
}

# --- Helpers -----------------------------------------------------------------
find_live_dir() {
    [[ -n ${LIVE_DIR} ]] && return 0

    local mount_point escaped_path
    local -a candidates=(
        ${ROOT_PREFIX}/run/live/medium/live
        ${ROOT_PREFIX}/run/live/medium
        ${ROOT_PREFIX}/lib/live/mount/medium/live
        /run/live/medium/live
        /run/live/medium
        /lib/live/mount/medium/live
        /run/archiso/bootmnt/arch/x86_64
        /run/archiso/bootmnt
        /run/initramfs/live
        /run/initramfs/livedev
        /media/cdrom
        /media/usb
    )

    while IFS=' ' read -r _ _ _ _ mount_point _; do
        escaped_path=${mount_point//\\040/ }
        [[ ${escaped_path} == */live || ${escaped_path} == */archiso/* || ${escaped_path} == */initramfs/* ]] \
            && candidates+=("${escaped_path}")
    done < /proc/self/mountinfo 2>/dev/null || true

    local -a image_names=(
        filesystem.squashfs
        rootfs.img
        rootfs.squashfs
        airootfs.sfs
        LiveOS/squashfs.img
        LiveOS/rootfs.img
    )

    for mount_point in "${candidates[@]}"; do
        for img in "${image_names[@]}"; do
            if [[ -f ${mount_point}/${img} ]]; then
                LIVE_DIR=${mount_point}
                log_info "Detected live media mount at: ${LIVE_DIR} (image: ${img})"
                return 0
            fi
        done
    done

    log_warn "Live media mount directory could not be found among standard paths"
    return 1
}

load_config() {
    local file
    for file in "${LIVE_DIR}/.env" "${CONFIG_DIR}/.env" "/etc/immutable-live/.env"; do
        if [[ -f ${file} ]]; then
            log_info "Loaded configuration from: ${file}"
            set +e
            # shellcheck disable=SC1090
            source "${file}"
            set -e
            return 0
        fi
    done
    log_warn "No .env configuration file found; proceeding with system defaults"
    return 0
}

sync_env_var() {
    local key=$1 value=$2
    local env_file=""

    if [[ -f ${CONFIG_DIR}/.env ]]; then
        env_file=${CONFIG_DIR}/.env
    elif [[ -n ${LIVE_DIR} && -f ${LIVE_DIR}/.env ]]; then
        env_file=${LIVE_DIR}/.env
    else
        log_warn "Cannot synchronize ${key}: no writable .env file found"
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    local safe_val="${value//\'/\'\\\'\'}"

    awk -v k="${key}" -v v="'${safe_val}'" '
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
    ' "${env_file}" > "${tmp}" || { rm -f "${tmp}"; return 0; }

    cat "${tmp}" > "${env_file}" 2>/dev/null || true
    rm -f "${tmp}"
    log_info "Synchronized '${key}' into ${env_file} (${#value} chars)"
}

find_overlay_upperdir() {
    if [[ -n ${IMMUTABLE_OVERLAY_UPPERDIR:-} && -d ${IMMUTABLE_OVERLAY_UPPERDIR} ]]; then
        printf '%s\n' "${IMMUTABLE_OVERLAY_UPPERDIR}"
        return 0
    fi

    local upperdir
    upperdir=$(findmnt -n -T / -o OPTIONS 2>/dev/null | tr ',' '\n' | sed -n 's/^upperdir=//p' | head -n1)
    if [[ -n ${upperdir} && -d ${upperdir} ]]; then
        printf '%s\n' "${upperdir%%:*}"
        return 0
    fi
    upperdir=$(grep -m1 ' overlay / ' /proc/mounts 2>/dev/null | sed -n 's/.*upperdir=\([^,]*\).*/\1/p')
    if [[ -n ${upperdir} && -d ${upperdir} ]]; then
        printf '%s\n' "${upperdir%%:*}"
        return 0
    fi
    return 1
}

clean_upper_path() {
    local upperdir=$1 merged_path=$2
    local upper_path="${upperdir}${merged_path}"

    if [[ -d ${upper_path} ]]; then
        log_info "Removing upperdir directory: ${upper_path}"
        find "${upper_path}" -mindepth 1 -delete 2>/dev/null || true
    elif [[ -f ${upper_path} ]]; then
        log_info "Removing upperdir file: ${upper_path}"
        rm -f "${upper_path}" 2>/dev/null || true
    fi
}

clean_iso_dependent_state() {
    log_info "Starting cleanup of ISO-dependent state..."

    local upperdir
    upperdir=$(find_overlay_upperdir || true)

    if [[ -z ${upperdir} ]]; then
        log_warn "OverlayFS upperdir not detected; performing fallback cleanup directly on filesystem"
        local target
        for target in "${DEFAULT_ISO_DEPENDENT_DIRS[@]}"; do
            [[ -n ${target} ]] || continue
            if [[ -d ${target} ]]; then
                log_info "Cleaning directory: ${target}"
                find "${target}" -mindepth 1 -delete 2>/dev/null || true
            elif [[ -f ${target} ]]; then
                log_info "Removing file: ${target}"
                rm -f "${target}" 2>/dev/null || true
            fi
        done
        return 0
    fi

    log_info "OverlayFS upperdir path confirmed: ${upperdir}"

    local target
    for target in "${DEFAULT_ISO_DEPENDENT_DIRS[@]}"; do
        [[ -n ${target} ]] || continue
        clean_upper_path "${upperdir}" "${target}"
    done

    log_info "Purging OverlayFS whiteout markers (.wh.*) from upperdir..."
    local wh_count
    wh_count=$(find "${upperdir}/etc" "${upperdir}/var" -name '.wh.*' 2>/dev/null | wc -l || echo 0)
    find "${upperdir}/etc" "${upperdir}/var" -name '.wh.*' -delete 2>/dev/null || true
    log_info "Purged ${wh_count} whiteout markers to unmask clean ISO lowerdir files"

    if [[ -z ${ROOT_PREFIX} ]] && command -v ldconfig >/dev/null 2>&1; then
        log_info "Regenerating dynamic linker cache (ldconfig)..."
        ldconfig 2>/dev/null || true
    fi

    log_info "ISO-dependent state cleanup complete"
    return 0
}

get_iso_id() {
    local -a image_names=(
        filesystem.squashfs
        rootfs.img
        rootfs.squashfs
        airootfs.sfs
        LiveOS/squashfs.img
        LiveOS/rootfs.img
    )
    local target_img=""

    if [[ -n ${LIVE_DIR} ]]; then
        for img in "${image_names[@]}"; do
            if [[ -f ${LIVE_DIR}/${img} ]]; then
                target_img="${LIVE_DIR}/${img}"
                break
            fi
        done
    fi

    if [[ -n ${target_img} ]]; then
        local meta head_hash
        meta=$(stat -c '%s-%Y' "${target_img}" 2>/dev/null || true)
        head_hash=$(head -c 1048576 "${target_img}" 2>/dev/null | sha256sum | awk '{print $1}')
        printf '%s-%s\n' "${meta}" "${head_hash}"
    elif [[ -f /etc/os-release ]]; then
        sha256sum /etc/os-release | awk '{print $1}'
    else
        uname -r 2>/dev/null || true
    fi
}

# --- System configuration -----------------------------------------------------
configure_system() {
    # 1. Hostname
    local host_name=${HOSTNAME:-}
    if [[ -n ${host_name} ]]; then
        log_info "Setting system hostname to '${host_name}'"
        mkdir -p "${ROOT_PREFIX}/etc"
        printf '%s\n' "${host_name}" > "${ROOT_PREFIX}/etc/hostname"
        if [[ -z ${ROOT_PREFIX} ]] && command -v hostnamectl >/dev/null 2>&1; then
            hostnamectl set-hostname "${host_name}" 2>/dev/null || true
        elif [[ -z ${ROOT_PREFIX} ]]; then
            hostname "${host_name}" 2>/dev/null || true
        fi

        if [[ -f ${ROOT_PREFIX}/etc/hosts ]]; then
            if grep -q "127.0.1.1" "${ROOT_PREFIX}/etc/hosts"; then
                sed -i "s/127.0.1.1.*/127.0.1.1\t${host_name}/g" "${ROOT_PREFIX}/etc/hosts"
            else
                printf '127.0.1.1\t%s\n' "${host_name}" >> "${ROOT_PREFIX}/etc/hosts"
            fi
            log_info "Updated /etc/hosts with entry '127.0.1.1 ${host_name}'"
        fi
    fi

    # 2. Locale / language (Systemd standard + Debian standard)
    local sys_locale=${LOCALE:-}
    local sys_lang=${LANGUAGE:-}
    if [[ -n ${sys_locale} ]]; then
        log_info "Setting locale: LANG='${sys_locale}', LANGUAGE='${sys_lang:-none}'"
        mkdir -p "${ROOT_PREFIX}/etc/default" "${ROOT_PREFIX}/etc"
        local locale_cfg="LANG=${sys_locale}"
        [[ -n ${sys_lang} ]] && locale_cfg="${locale_cfg}"$'\n'"LANGUAGE=${sys_lang}"
        printf '%s\n' "${locale_cfg}" > "${ROOT_PREFIX}/etc/locale.conf" 2>/dev/null || true
        printf '%s\n' "${locale_cfg}" > "${ROOT_PREFIX}/etc/default/locale" 2>/dev/null || true
        if [[ -z ${ROOT_PREFIX} ]] && command -v localectl >/dev/null 2>&1; then
            localectl set-locale LANG="${sys_locale}" 2>/dev/null || true
        fi
    fi

    # 3. Keyboard layout (Console vconsole.conf + X11 default/keyboard)
    local kb_layout=${KEYBOARD_LAYOUT:-${KEYMAP:-}}
    local kb_variant=${KEYBOARD_VARIANT:-}
    local kb_options=${KEYBOARD_OPTIONS:-grp:alt_shift_toggle}
    if [[ -n ${kb_layout} ]]; then
        log_info "Setting keyboard: layout='${kb_layout}', variant='${kb_variant:-default}', options='${kb_options}'"
        mkdir -p "${ROOT_PREFIX}/etc/default" "${ROOT_PREFIX}/etc"
        # Linux console (Arch, Fedora, openSUSE, systemd-vconsole)
        printf 'KEYMAP="%s"\n' "${kb_layout%%,*}" > "${ROOT_PREFIX}/etc/vconsole.conf" 2>/dev/null || true
        # X11 / Debian / Ubuntu
        cat <<EOF > "${ROOT_PREFIX}/etc/default/keyboard"
XKBMODEL="pc105"
XKBLAYOUT="${kb_layout}"
XKBVARIANT="${kb_variant}"
XKBOPTIONS="${kb_options}"
BACKSPACE="guess"
EOF
        if [[ -z ${ROOT_PREFIX} ]] && command -v localectl >/dev/null 2>&1; then
            localectl set-x11-keymap "${kb_layout}" "pc105" "${kb_variant}" "${kb_options}" 2>/dev/null || true
        fi
    fi

    # 4. Plymouth theme enforcement if pedro-raccoon theme is installed
    if command -v plymouth-set-default-theme >/dev/null 2>&1 && [[ -d ${ROOT_PREFIX}/usr/share/plymouth/themes/pedro-raccoon || -d /usr/share/plymouth/themes/pedro-raccoon ]]; then
        plymouth-set-default-theme pedro-raccoon 2>/dev/null || true
    fi
}

# --- Autologin configuration ----------------------------------------------------
configure_autologin() {
    local username=$1
    local autologin=${AUTOLOGIN:-false}

    if [[ ${autologin} == "true" || ${autologin} == "yes" ]]; then
        log_info "Enabling automatic login for user '${username}' across display managers"

        # Add to autologin/nopasswdlogin group if present (LightDM / PAM requirement)
        local g
        for g in autologin nopasswdlogin; do
            if getent group "${g}" >/dev/null 2>&1; then
                usermod -aG "${g}" "${username}" 2>/dev/null || true
                log_info "Added '${username}' to system group '${g}' for passwordless login"
            fi
        done

        # LightDM
        mkdir -p "${ROOT_PREFIX}/etc/lightdm/lightdm.conf.d"
        cat <<EOF > "${ROOT_PREFIX}/etc/lightdm/lightdm.conf.d/01-immutable-autologin.conf"
[Seat:*]
autologin-user=${username}
autologin-user-timeout=0
EOF
        log_info "Configured LightDM autologin in /etc/lightdm/lightdm.conf.d/01-immutable-autologin.conf"

        # GDM3 (Debian / Kali / Ubuntu)
        mkdir -p "${ROOT_PREFIX}/etc/gdm3"
        local gdm3_cfg="${ROOT_PREFIX}/etc/gdm3/daemon.conf"
        if [[ ! -f ${gdm3_cfg} ]]; then
            printf '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=%s\n' "${username}" > "${gdm3_cfg}"
        else
            sed -i '/AutomaticLogin/d' "${gdm3_cfg}" 2>/dev/null || true
            if grep -q '\[daemon\]' "${gdm3_cfg}"; then
                sed -i "/\[daemon\]/a AutomaticLoginEnable=True\nAutomaticLogin=${username}" "${gdm3_cfg}" 2>/dev/null || true
            else
                printf '\n[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=%s\n' "${username}" >> "${gdm3_cfg}"
            fi
        fi
        log_info "Configured GDM3 autologin in ${gdm3_cfg}"

        # GDM (Fedora / Arch / RHEL)
        mkdir -p "${ROOT_PREFIX}/etc/gdm"
        local gdm_cfg="${ROOT_PREFIX}/etc/gdm/custom.conf"
        if [[ ! -f ${gdm_cfg} ]]; then
            printf '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=%s\n' "${username}" > "${gdm_cfg}"
        else
            sed -i '/AutomaticLogin/d' "${gdm_cfg}" 2>/dev/null || true
            if grep -q '\[daemon\]' "${gdm_cfg}"; then
                sed -i "/\[daemon\]/a AutomaticLoginEnable=True\nAutomaticLogin=${username}" "${gdm_cfg}" 2>/dev/null || true
            else
                printf '\n[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=%s\n' "${username}" >> "${gdm_cfg}"
            fi
        fi
        log_info "Configured GDM autologin in ${gdm_cfg}"

        # SDDM (KDE)
        mkdir -p "${ROOT_PREFIX}/etc/sddm.conf.d"
        cat <<EOF > "${ROOT_PREFIX}/etc/sddm.conf.d/01-immutable-autologin.conf"
[Autologin]
User=${username}
EOF
        log_info "Configured SDDM autologin in /etc/sddm.conf.d/01-immutable-autologin.conf"

        # LXDM (LXDE / LXQt)
        if [[ -f ${ROOT_PREFIX}/etc/lxdm/lxdm.conf ]]; then
            sed -i "s/^#\?[[:space:]]*autologin=.*/autologin=${username}/" "${ROOT_PREFIX}/etc/lxdm/lxdm.conf" 2>/dev/null || true
            log_info "Configured LXDM autologin in /etc/lxdm/lxdm.conf"
        fi

        # TTY1 Console fallback (systemd getty)
        if command -v agetty >/dev/null 2>&1 || [[ -n ${ROOT_PREFIX} ]]; then
            mkdir -p "${ROOT_PREFIX}/etc/systemd/system/getty@tty1.service.d"
            cat <<EOF > "${ROOT_PREFIX}/etc/systemd/system/getty@tty1.service.d/autologin.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin ${username} %I \$TERM
EOF
            log_info "Configured TTY1 console autologin via systemd getty override"
        fi
    else
        log_info "Autologin disabled for '${username}' (AUTOLOGIN=${autologin}); clearing previous overrides"
        rm -f "${ROOT_PREFIX}/etc/lightdm/lightdm.conf.d/01-immutable-autologin.conf" 2>/dev/null || true
        rm -f "${ROOT_PREFIX}/etc/sddm.conf.d/01-immutable-autologin.conf" 2>/dev/null || true
        rm -f "${ROOT_PREFIX}/etc/systemd/system/getty@tty1.service.d/autologin.conf" 2>/dev/null || true

        for gdm_file in "${ROOT_PREFIX}/etc/gdm3/daemon.conf" "${ROOT_PREFIX}/etc/gdm/custom.conf"; do
            if [[ -f ${gdm_file} ]]; then
                sed -i '/AutomaticLogin/d' "${gdm_file}" 2>/dev/null || true
            fi
        done
        if [[ -f ${ROOT_PREFIX}/etc/lxdm/lxdm.conf ]]; then
            sed -i "s/^autologin=.*/#autologin=/" "${ROOT_PREFIX}/etc/lxdm/lxdm.conf" 2>/dev/null || true
        fi
    fi
}

# --- User configuration --------------------------------------------------------
configure_user() {
    local username=${USER_NAME:-live}
    local pass_hash=${USER_PASSWORD_HASH:-}
    local groups_csv=${USER_GROUPS:-sudo,audio,video,plugdev,netdev}
    local hide_user=${HIDE_USER:-false}
    local disable_live_user=${DISABLE_LIVE_USER:-${DISABLE_ISO_USER:-false}}

    log_info "Configuring user profile for '${username}'..."

    # Determine default shell (fallback to /bin/sh if /bin/bash is missing)
    local shell=/bin/bash
    if [[ ! -x ${shell} ]]; then
        shell=/bin/sh
        log_info "Selected fallback shell: ${shell}"
    fi

    # Cross-distro admin group: Debian uses 'sudo', Arch/Fedora/Alpine/SUSE use 'wheel'
    if getent group sudo >/dev/null 2>&1 && [[ ${groups_csv} == *wheel* && ${groups_csv} != *sudo* ]]; then
        groups_csv="${groups_csv},sudo"
        log_info "Detected 'sudo' group on system; added to managed groups"
    elif getent group wheel >/dev/null 2>&1 && [[ ${groups_csv} == *sudo* && ${groups_csv} != *wheel* ]]; then
        groups_csv="${groups_csv},wheel"
        log_info "Detected 'wheel' group on system; added to managed groups"
    fi

    # 1. Ensure the user exists
    if id "${username}" >/dev/null 2>&1; then
        log_info "User '${username}' exists (UID: $(id -u "${username}")), updating login shell to ${shell}"
        usermod -s "${shell}" "${username}" 2>/dev/null || true
    else
        log_info "Creating new user account '${username}' with shell '${shell}' and home directory"
        useradd -m -s "${shell}" "${username}" 2>/dev/null || log_warn "useradd not applicable in this environment"
    fi

    # 2. Password: pick up changes made in the OS and sync them back to .env
    local shadow_hash=""
    if [[ -f ${ROOT_PREFIX}/etc/shadow ]]; then
        shadow_hash=$(grep -E "^${username}:" "${ROOT_PREFIX}/etc/shadow" 2>/dev/null | cut -d: -f2 || true)
    elif command -v getent >/dev/null 2>&1; then
        shadow_hash=$(getent shadow "${username}" 2>/dev/null | cut -d: -f2 || true)
    fi
    local saved_hash
    saved_hash=$(cat "${PASSWORD_HASH_FILE}" 2>/dev/null || true)

    if [[ -n ${shadow_hash} && ${shadow_hash} != "!" && ${shadow_hash} != "*" ]]; then
        if [[ -n ${saved_hash} && ${shadow_hash} != "${saved_hash}" ]]; then
            log_info "Detected OS-level password change for '${username}' -> updating .env and cache"
            printf '%s\n' "${shadow_hash}" > "${PASSWORD_HASH_FILE}"
            sync_env_var USER_PASSWORD_HASH "${shadow_hash}"
        elif [[ -z ${saved_hash} ]]; then
            log_info "Cached initial password hash from /etc/shadow for '${username}'"
            printf '%s\n' "${shadow_hash}" > "${PASSWORD_HASH_FILE}"
        fi
    elif [[ -n ${pass_hash} ]]; then
        log_info "Applying password hash from .env for user '${username}'"
        usermod -p "${pass_hash}" "${username}" 2>/dev/null || true
        printf '%s\n' "${pass_hash}" > "${PASSWORD_HASH_FILE}"
        sync_env_var USER_PASSWORD_HASH "${pass_hash}"
    fi

    # 3. Two-way group sync: .env -> system (add/remove), system -> .env
    local -a desired_groups=()
    local -a managed_groups=()
    local -a current_groups=()
    local g d cur

    IFS=',' read -r -a desired_groups <<< "${groups_csv}"
    [[ -f ${GROUPS_FILE} ]] && mapfile -t managed_groups < "${GROUPS_FILE}"

    local primary_group=""
    primary_group=$(id -ng "${username}" 2>/dev/null || echo "${username}")

    if [[ -f ${ROOT_PREFIX}/etc/group ]]; then
        while IFS=: read -r gname _ _ members; do
            [[ -n ${members:-} ]] || continue
            local -a mem_arr=()
            IFS=',' read -r -a mem_arr <<< "${members}"
            for m in "${mem_arr[@]}"; do
                [[ ${m} == "${username}" && ${gname} != "${primary_group}" ]] && current_groups+=("${gname}")
            done
        done < "${ROOT_PREFIX}/etc/group"
    elif command -v id >/dev/null 2>&1; then
        while read -r g; do
            [[ -n ${g} && ${g} != "${primary_group}" ]] && current_groups+=("${g}")
        done < <(id -nG "${username}" 2>/dev/null | tr ' ' '\n')
    fi

    # Drop previously managed groups that are no longer in .env
    for g in "${managed_groups[@]}"; do
        local in_desired=false
        for d in "${desired_groups[@]}"; do
            d=${d// /}
            [[ ${g} == "${d}" ]] && in_desired=true
        done
        if [[ ${in_desired} == false ]]; then
            log_info "Removing user '${username}' from obsolete group '${g}'"
            local -a remaining_groups=()
            for cur in "${current_groups[@]}"; do
                [[ ${cur} != "${g}" ]] && remaining_groups+=("${cur}")
            done
            current_groups=("${remaining_groups[@]}")
        fi
    done

    # Add desired groups, creating any that are missing
    for d in "${desired_groups[@]}"; do
        d=${d// /}
        [[ -n ${d} ]] || continue
        if ! getent group "${d}" >/dev/null 2>&1; then
            groupadd "${d}" 2>/dev/null || true
            log_info "Created missing group '${d}'"
        fi
        local present=false
        for cur in "${current_groups[@]}"; do
            [[ ${cur} == "${d}" ]] && present=true
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
    log_info "User '${username}' group membership: [${effective_groups}]"

    # 4. Hide the user on the login screen
    if [[ ${hide_user} == "true" || ${hide_user} == "yes" ]]; then
        chmod 700 "${ROOT_PREFIX}/home/${username}" 2>/dev/null || true
        mkdir -p "${ROOT_PREFIX}/var/lib/AccountsService/users"
        printf '[User]\nSystemAccount=true\n' > "${ROOT_PREFIX}/var/lib/AccountsService/users/${username}"
        log_info "Hidden '${username}' from display manager user lists (AccountsService SystemAccount=true)"
    fi

    # 5. DISABLE_LIVE_USER=true: remove the ISO default user entirely (the
    #    account does not exist and is never recreated)
    if [[ ${disable_live_user} == "true" || ${disable_live_user} == "yes" ]]; then
        local default_iso_users=(live kali user debian ubuntu mint arch alarm fedora alpine manjaro nixos guest linux void gentoo)
        local iso_user
        for iso_user in "${default_iso_users[@]}"; do
            if [[ ${iso_user} != "${username}" ]] && id "${iso_user}" >/dev/null 2>&1; then
                log_info "Purging default live ISO user account '${iso_user}'..."
                userdel -r "${iso_user}" 2>/dev/null \
                    || usermod -L -s /sbin/nologin "${iso_user}" 2>/dev/null || true
                log_info "Removed default live user '${iso_user}'"
            fi
        done
    fi

    # 6. Autologin configuration for the configured user
    configure_autologin "${username}"
}

# --- Swap configuration --------------------------------------------------------
configure_swap() {
    local swap_enable=${SWAP_ENABLE:-true}
    local swap_file=/var/swap/swapfile
    local swap_path="${ROOT_PREFIX}${swap_file}"
    local swap_size=${SWAP_SIZE:-2G}
    local swappiness=${SWAPPINESS:-10}

    [[ ${swap_enable} == "true" ]] || { log_info "Swap is disabled in configuration (SWAP_ENABLE=${swap_enable})"; return 0; }

    log_info "Configuring swap file '${swap_file}' (target size: ${swap_size}, swappiness: ${swappiness})..."
    mkdir -p "$(dirname "${swap_path}")" 2>/dev/null || true

    if [[ ! -f ${swap_path} ]]; then
        log_info "Allocating swap file '${swap_file}' (${swap_size})..."
        fallocate -l "${swap_size}" "${swap_path}" 2>/dev/null \
            || dd if=/dev/zero of="${swap_path}" bs=1M count=64 2>/dev/null || true
        chmod 600 "${swap_path}" 2>/dev/null || true
        mkswap "${swap_path}" >/dev/null 2>&1 || true
        log_info "Initialized new ext4 swap space on '${swap_file}'"
    fi

    if ! swapon --show 2>/dev/null | grep -q "${swap_file}"; then
        if [[ -z ${ROOT_PREFIX} ]]; then
            swapon "${swap_path}" 2>/dev/null && log_info "Activated swap on '${swap_file}'" || log_warn "Failed to activate swap on '${swap_file}'"
        else
            log_info "Swap file '${swap_file}' created in sandbox"
        fi
    else
        log_info "Swap file '${swap_file}' is already active"
    fi

    if [[ -z ${ROOT_PREFIX} ]]; then
        sysctl -w vm.swappiness="${swappiness}" >/dev/null 2>&1 || true
        log_info "Set vm.swappiness=${swappiness}"
    fi
}

# --- Execution Modes -----------------------------------------------------------
case ${1:-} in
    --save-packages|save)
        [[ ${PKG_MGR} != "unknown" ]] && save_user_packages
        exit 0
        ;;
    --restore)
        export DEBIAN_FRONTEND=noninteractive
        log_info "=== Background Package Restore: Started for ${PKG_MGR} ==="
        restore_user_packages
        save_user_packages
        log_info "=== Background Package Restore: Complete ==="
        exit 0
        ;;
    ""|--boot)
        ;;
    *)
        echo "Usage: $0 [--save-packages|--restore|--boot]" >&2
        exit 2
        ;;
esac

# --- Main --------------------------------------------------------------------
log_info "======================================================================"
log_info "=== immutable-live: Boot Initialization Started                   ==="
log_info "======================================================================"
plymouth_msg "Starting immutable-live initialization..."

find_live_dir
load_config

log_info "--- [1/4] ISO Change Detection & Upperdir State Verification ---"
plymouth_msg "Verifying system state & ISO fingerprint..."

current_iso=$(get_iso_id || true)
previous_iso=$(cat "${ISO_ID_FILE}" 2>/dev/null || true)
ISO_CHANGED=false

if [[ -n ${current_iso} ]]; then
    if [[ -n ${previous_iso} && ${previous_iso} != "${current_iso}" ]]; then
        ISO_CHANGED=true
        log_info "ISO image change detected!"
        log_info "  Previous ISO ID: ${previous_iso}"
        log_info "  Current  ISO ID: ${current_iso}"
        plymouth_msg "Cleaning ISO-dependent state for new image..."
        clean_iso_dependent_state
        printf '%s\n' "${current_iso}" > "${ISO_ID_FILE}"
        log_info "Saved new ISO fingerprint to ${ISO_ID_FILE}"
        capture_base_packages

        # Background package restore: runs non-blocking so Display Manager boots instantly
        if [[ -s ${USER_PACKAGE_FILE} || -s ${REMOVED_PACKAGE_FILE} ]]; then
            log_info "Queuing background user package restore for ${PKG_MGR}..."
            if [[ -z ${ROOT_PREFIX} ]]; then
                nohup /usr/local/bin/immutable-live.sh --restore >> "${LOG_FILE}.restore.log" 2>&1 & disown || true
            else
                restore_user_packages || true
            fi
        fi
    elif [[ -z ${previous_iso} ]]; then
        log_info "First boot detected: saving initial ISO fingerprint (${current_iso})"
        printf '%s\n' "${current_iso}" > "${ISO_ID_FILE}"
        capture_base_packages
        ISO_CHANGED=true
    else
        log_info "ISO image unchanged (${current_iso})"
    fi
else
    log_warn "Could not determine ISO ID fingerprint; skipping ISO change cleanup"
fi

# On regular boot, update package diff
[[ ${ISO_CHANGED} == "true" ]] || save_user_packages

log_info "--- [2/4] Applying System & User Configuration ---"
plymouth_msg "Applying user profile & settings..."
configure_system
configure_user

log_info "--- [3/4] Configuring Swap Space ---"
plymouth_msg "Configuring swap space..."
configure_swap

log_info "--- [4/4] Package Caching & Hooks ---"
plymouth_msg "Configuring package hooks & cache..."
setup_package_caching
configure_pkg_hooks

plymouth_msg "System ready!"

log_info "======================================================================"
log_info "=== immutable-live: Boot Initialization Complete                   ==="
log_info "======================================================================"
