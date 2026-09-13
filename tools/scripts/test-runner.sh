#!/usr/bin/env bash
# ==============================================================================
# test-runner.sh - In-place simulation and test harness for immutable-live
# Runs instant (<1s) multi-phase tests: initial boot, same-ISO reboot with sync,
# and ISO switch with full upperdir/whiteout state cleanup verification.
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
SCRIPT_UNDER_TEST="${PROJECT_DIR}/disk/persistence/link/usr/local/bin/immutable-live.sh"

# --- ANSI Color formatting ---
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'
C_MAGENTA='\033[35m'
C_CYAN='\033[36m'
C_GRAY='\033[90m'

pass_count=0
fail_count=0

print_banner() {
    printf "\n${C_BOLD}${C_CYAN}======================================================================${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}       immutable-live: In-Place Test Runner & ISO Switch Simulator    ${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}======================================================================${C_RESET}\n\n"
}

assert_true() {
    local condition=$1 desc=$2
    if eval "${condition}"; then
        printf "  ${C_GREEN}✔ [PASS]${C_RESET} %s\n" "${desc}"
        pass_count=$((pass_count + 1))
    else
        printf "  ${C_RED}✖ [FAIL]${C_RESET} %s\n" "${desc}" >&2
        fail_count=$((fail_count + 1))
    fi
}

assert_file_contains() {
    local file=$1 pattern=$2 desc=$3
    if [[ -f ${file} ]] && grep -q "${pattern}" "${file}" 2>/dev/null; then
        printf "  ${C_GREEN}✔ [PASS]${C_RESET} %s\n" "${desc}"
        pass_count=$((pass_count + 1))
    else
        printf "  ${C_RED}✖ [FAIL]${C_RESET} %s (file: ${file}, pattern: '${pattern}')\n" "${desc}" >&2
        fail_count=$((fail_count + 1))
    fi
}

assert_file_not_exists() {
    local file=$1 desc=$2
    if [[ ! -e ${file} ]]; then
        printf "  ${C_GREEN}✔ [PASS]${C_RESET} %s\n" "${desc}"
        pass_count=$((pass_count + 1))
    else
        printf "  ${C_RED}✖ [FAIL]${C_RESET} %s (unexpected file: ${file})\n" "${desc}" >&2
        fail_count=$((fail_count + 1))
    fi
}

# --- Create isolated sandbox in /tmp ---
SANDBOX=$(mktemp -d -t immutable-live-test-XXXXXX)
trap 'rm -rf "${SANDBOX}"' EXIT

TEST_ROOT="${SANDBOX}/root"
TEST_LIVE="${SANDBOX}/live"
TEST_UPPER="${SANDBOX}/upperdir"
TEST_STATE="${TEST_ROOT}/etc/immutable-live/state"
TEST_CONFIG="${TEST_ROOT}/etc/immutable-live/config"
TEST_LOG="${TEST_ROOT}/var/log/immutable-live/immutable-live.log"

mkdir -p "${TEST_ROOT}" "${TEST_LIVE}" "${TEST_UPPER}" "${TEST_STATE}" "${TEST_CONFIG}" "$(dirname "${TEST_LOG}")"

# Export environment variables for the test run
export IMMUTABLE_ROOT_PREFIX="${TEST_ROOT}"
export IMMUTABLE_STATE_DIR="${TEST_STATE}"
export IMMUTABLE_CONFIG_DIR="${TEST_CONFIG}"
export IMMUTABLE_LOG_FILE="${TEST_LOG}"
export IMMUTABLE_CACHE_DIR="${TEST_ROOT}/var/cache/immutable-live"
export IMMUTABLE_OVERLAY_UPPERDIR="${TEST_UPPER}"
export IMMUTABLE_PKG_MGR="apt"
export IMMUTABLE_MOCK_INSTALLED_PACKAGES="base-files bash coreutils systemd util-linux"
export IMMUTABLE_MOCK_MANUAL_PACKAGES="bash coreutils"

# Create initial .env in sandbox config
cat << 'EOF' > "${TEST_CONFIG}/.env"
# Test environment config
HOSTNAME=StealthStation
LOCALE=en_US.UTF-8
LANGUAGE=en_US:en
KEYBOARD_LAYOUT=us,ru
KEYBOARD_OPTIONS=grp:alt_shift_toggle

USER_NAME=testuser
USER_PASSWORD_HASH='$6$initHash$initialPasswordHash'
USER_GROUPS=sudo,audio,video,plugdev,netdev
AUTOLOGIN=true
HIDE_USER=true
DISABLE_LIVE_USER=true

SWAP_ENABLE=true
SWAP_SIZE=256M
SWAPPINESS=60
EOF

print_banner
printf "${C_GRAY}Sandbox Directory:${C_RESET} %s\n" "${SANDBOX}"
printf "${C_GRAY}Script under test:${C_RESET} %s\n\n" "${SCRIPT_UNDER_TEST}"

start_time=$(date +%s%N 2>/dev/null || date +%s)

# ==============================================================================
# PHASE 1: Initial Boot with ISO #1 (e.g. Kali Linux)
# ==============================================================================
printf "${C_BOLD}${C_BLUE}▶ PHASE 1: First Boot with ISO #1 (Kali Linux Image)${C_RESET}\n"
printf "${C_GRAY}  Generating mock squashfs image for ISO #1...${C_RESET}\n"

# Create mock squashfs #1 with specific content and mtime
printf 'ISO_1_KALI_LINUX_SQUASHFS_DATA_HEADER' > "${TEST_LIVE}/filesystem.squashfs"
dd if=/dev/urandom bs=1024 count=1024 status=none >> "${TEST_LIVE}/filesystem.squashfs"
touch -d '2026-01-01 12:00:00' "${TEST_LIVE}/filesystem.squashfs"

# Also set LIVE_DIR candidate for the script
mkdir -p "${TEST_ROOT}/run/live/medium/live"
ln -sf "${TEST_LIVE}/filesystem.squashfs" "${TEST_ROOT}/run/live/medium/live/filesystem.squashfs"

# Execute script
"${SCRIPT_UNDER_TEST}"

# Verifications for Phase 1
printf "\n${C_BOLD}Phase 1 Assertions:${C_RESET}\n"
assert_true "[[ -s ${TEST_STATE}/iso.id ]]" "Initial ISO fingerprint generated in iso.id"
assert_file_contains "${TEST_ROOT}/etc/hostname" "StealthStation" "Hostname correctly set to StealthStation"
assert_file_contains "${TEST_ROOT}/etc/locale.conf" "LANG=en_US.UTF-8" "Locale written to /etc/locale.conf"
assert_file_contains "${TEST_ROOT}/etc/default/keyboard" "XKBLAYOUT=\"us,ru\"" "Keyboard layout written to /etc/default/keyboard"
assert_file_contains "${TEST_ROOT}/etc/lightdm/lightdm.conf.d/01-immutable-autologin.conf" "autologin-user=testuser" "LightDM autologin configured"
assert_file_contains "${TEST_ROOT}/etc/gdm3/daemon.conf" "AutomaticLogin=testuser" "GDM3 autologin configured"
assert_file_contains "${TEST_ROOT}/etc/sddm.conf.d/01-immutable-autologin.conf" "User=testuser" "SDDM autologin configured"
assert_file_contains "${TEST_ROOT}/etc/apt/apt.conf.d/98-immutable-cache" "Dir::Cache::archives" "APT persistent cache configured"
assert_file_contains "${TEST_ROOT}/etc/apt/apt.conf.d/99-immutable-live" "immutable-live.sh --save-packages" "APT post-invoke hook installed"

iso_id_1=$(cat "${TEST_STATE}/iso.id")
printf "${C_GRAY}  Recorded ISO #1 ID: %s${C_RESET}\n\n" "${iso_id_1}"

# ==============================================================================
# PHASE 2: User Activity & Reboot on Same ISO #1 (Test sync back to .env)
# ==============================================================================
printf "${C_BOLD}${C_BLUE}▶ PHASE 2: User Activity & Reboot on Same ISO #1${C_RESET}\n"
printf "${C_GRAY}  Simulating user password change via passwd, user installing 'nmap', and adding to 'docker' group...${C_RESET}\n"

# Simulate OS-level shadow password change
mkdir -p "${TEST_ROOT}/etc"
NEW_SHADOW_HASH='$6$changedHash$newRuntimePasswordFromPasswd'
printf 'testuser:%s:19800:0:99999:7:::\n' "${NEW_SHADOW_HASH}" > "${TEST_ROOT}/etc/shadow"

# Simulate adding user to 'docker' group in /etc/group
printf 'root:x:0:\nsudo:x:27:testuser\naudio:x:29:testuser\nvideo:x:44:testuser\nplugdev:x:46:testuser\nnetdev:x:101:testuser\ndocker:x:999:testuser\n' > "${TEST_ROOT}/etc/group"

# Simulate user installing 'nmap' and 'wireshark' packages in system
export IMMUTABLE_MOCK_INSTALLED_PACKAGES="base-files bash coreutils systemd util-linux nmap wireshark libpcap"
export IMMUTABLE_MOCK_MANUAL_PACKAGES="bash coreutils nmap wireshark"

# Pre-populate upperdir with dummy files and whiteout markers (as if working on ISO #1)
mkdir -p "${TEST_UPPER}/etc/gdm3" "${TEST_UPPER}/var/cache/apt/archives" "${TEST_UPPER}/var/lib/dpkg" "${TEST_UPPER}/etc/pam.d"
touch "${TEST_UPPER}/etc/gdm3/daemon.conf"
touch "${TEST_UPPER}/var/cache/apt/archives/sample.deb"
touch "${TEST_UPPER}/var/lib/dpkg/status.tmp"
touch "${TEST_UPPER}/etc/pam.d/.wh.sudo"
touch "${TEST_UPPER}/etc/gdm3/.wh.custom.conf"

# Execute script again (same ISO reboot)
"${SCRIPT_UNDER_TEST}"

printf "\n${C_BOLD}Phase 2 Assertions (Same-ISO reboot & Sync):${C_RESET}\n"
assert_true "[[ \$(cat '${TEST_STATE}/iso.id') == '${iso_id_1}' ]]" "ISO ID unchanged on reboot"
assert_file_contains "${TEST_CONFIG}/.env" "${NEW_SHADOW_HASH}" "Password hash from /etc/shadow synchronized back to .env"
assert_file_contains "${TEST_CONFIG}/.env" "docker" "New group 'docker' merged and synchronized back to .env"
assert_file_contains "${TEST_STATE}/packages/apt/user.packages" "nmap" "User-installed package 'nmap' saved in state"

# ==============================================================================
# PHASE 3: ISO Switch (e.g. Kali Linux -> Debian / Arch Linux)
# ==============================================================================
printf "\n${C_BOLD}${C_BLUE}▶ PHASE 3: ISO Switch (Debian / Arch Linux Image booted)${C_RESET}\n"
printf "${C_GRAY}  Replacing squashfs image with new ISO metadata & content...${C_RESET}\n"

# Create mock squashfs #2 with completely different metadata & content
printf 'ISO_2_DEBIAN_ARCH_NEW_SQUASHFS_DATA' > "${TEST_LIVE}/filesystem.squashfs"
dd if=/dev/urandom bs=1024 count=1024 status=none >> "${TEST_LIVE}/filesystem.squashfs"
touch -d '2026-09-13 18:30:00' "${TEST_LIVE}/filesystem.squashfs"

# New ISO clean package baseline
export IMMUTABLE_MOCK_INSTALLED_PACKAGES="base-files bash coreutils systemd-v256 util-linux"
export IMMUTABLE_MOCK_MANUAL_PACKAGES="bash coreutils"

# Execute script (detects ISO change)
"${SCRIPT_UNDER_TEST}"

iso_id_2=$(cat "${TEST_STATE}/iso.id")
printf "\n${C_BOLD}Phase 3 Assertions (ISO Switch & Upperdir Cleanup):${C_RESET}\n"
assert_true "[[ '${iso_id_2}' != '${iso_id_1}' ]]" "New ISO ID detected and saved (${iso_id_2:0:20}...)"
assert_file_not_exists "${TEST_UPPER}/var/cache/apt/archives/sample.deb" "Stale package cache wiped from upperdir"
assert_file_not_exists "${TEST_UPPER}/var/lib/dpkg/status.tmp" "Stale package manager state wiped from upperdir"
assert_file_not_exists "${TEST_UPPER}/etc/pam.d/.wh.sudo" "Stale OverlayFS whiteout .wh.sudo purged from upperdir"
assert_file_not_exists "${TEST_UPPER}/etc/gdm3/.wh.custom.conf" "Stale OverlayFS whiteout .wh.custom.conf purged from upperdir"
assert_file_contains "${TEST_CONFIG}/.env" "${NEW_SHADOW_HASH}" "User password hash preserved across ISO switch"
assert_file_contains "${TEST_STATE}/packages/apt/user.packages" "nmap" "User package list preserved for restore on new ISO"

end_time=$(date +%s%N 2>/dev/null || date +%s)
duration_ms="0"
if [[ ${end_time} =~ ^[0-9]{19}$ && ${start_time} =~ ^[0-9]{19}$ ]]; then
    duration_ms=$(( (end_time - start_time) / 1000000 ))
fi

# ==============================================================================
# Summary & Log output
# ==============================================================================
printf "\n${C_BOLD}${C_CYAN}======================================================================${C_RESET}\n"
printf "${C_BOLD}Execution Log Output (tail from %s):${C_RESET}\n" "${TEST_LOG}"
printf "${C_BOLD}${C_CYAN}======================================================================${C_RESET}\n"
tail -n 35 "${TEST_LOG}" | while IFS= read -r line; do
    if [[ ${line} == *"ERROR"* ]]; then
        printf "${C_RED}%s${C_RESET}\n" "${line}"
    elif [[ ! ${line} =~ ^\[[0-9] && ${line} == *"==="* ]]; then
        printf "${C_BOLD}${C_CYAN}%s${C_RESET}\n" "${line}"
    elif [[ ${line} == *"---"* ]]; then
        printf "${C_YELLOW}%s${C_RESET}\n" "${line}"
    elif [[ ${line} == *"ISO change detected"* || ${line} == *"Enabling automatic login"* ]]; then
        printf "${C_GREEN}%s${C_RESET}\n" "${line}"
    else
        printf "${C_GRAY}%s${C_RESET}\n" "${line}"
    fi
done

printf "\n${C_BOLD}${C_CYAN}======================================================================${C_RESET}\n"
if (( fail_count == 0 )); then
    printf "${C_BOLD}${C_GREEN}✔ ALL TESTS PASSED! (${pass_count} passed, ${fail_count} failed)${C_RESET}\n"
    printf "${C_GRAY}Total Execution Time: %s ms${C_RESET}\n" "${duration_ms}"
else
    printf "${C_BOLD}${C_RED}✖ SOME TESTS FAILED! (${pass_count} passed, ${fail_count} failed)${C_RESET}\n"
fi
printf "${C_BOLD}${C_CYAN}======================================================================${C_RESET}\n\n"

exit "${fail_count}"
