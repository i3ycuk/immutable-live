#!/usr/bin/env bash
# ==============================================================================
# enable-services.sh - enable immutable-live services in systemd WITHOUT
# booting the system.
#
# Uses systemctl offline mode:  systemctl enable --root=<persistence-root>
# This creates symlinks in <root>/etc/systemd/system/<target>.wants/.
#
# Usage:
#   ./tools/scripts/enable-services.sh                 # default root: disk/persistence
#   ./tools/scripts/enable-services.sh /path/to/root   # explicit persistence root
# ==============================================================================
set -Eeuo pipefail

SERVICES=(immutable-live.service)

log() { printf '[enable-services] %s\n' "$*"; }
fail() { printf '[enable-services] ERROR: %s\n' "$*" >&2; exit 1; }

command -v systemctl >/dev/null 2>&1 || fail 'systemctl not found'

# --- Determine the persistence root -------------------------------------------
if [[ $# -ge 1 ]]; then
    ROOT=$1
else
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
    ROOT="${SCRIPT_DIR}/disk/persistence"
fi
ROOT=$(realpath -m "${ROOT}")

SYSTEMD_DIR="${ROOT}/etc/systemd/system"
[[ -d "${ROOT}/link/etc/systemd/system" ]] && SYSTEMD_DIR="${ROOT}/link/etc/systemd/system"

[[ -d ${ROOT} ]] || fail "Persistence root not found: ${ROOT}"
[[ -d ${SYSTEMD_DIR} ]] || fail "No systemd directory: ${SYSTEMD_DIR}"
log "Persistence root: ${ROOT} (systemd: ${SYSTEMD_DIR})"

# --- Check unit files -----------------------------------------------------------
for service in "${SERVICES[@]}"; do
    [[ -f ${SYSTEMD_DIR}/${service} ]] \
        || fail "Unit file not found: ${SYSTEMD_DIR}/${service}"
done

# --- Enable services inside the persistence root --------------------------------
# Relative paths keep the symlinks valid inside the persistence root.
for service in "${SERVICES[@]}"; do
    log "Enabling: ${service}"
    mkdir -p "${SYSTEMD_DIR}/multi-user.target.wants"
    ln -sfn "../${service}" "${SYSTEMD_DIR}/multi-user.target.wants/${service}"
done

# --- Result ----------------------------------------------------------------------
log "---- Resulting symlinks (.*.wants) ----"
find "${SYSTEMD_DIR}" -maxdepth 2 -type l -name '*.service' -printf '%p -> %l\n' | sort
log "Done. Symlinks created offline; services will start on the next live boot."