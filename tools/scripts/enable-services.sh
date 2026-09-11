#!/usr/bin/env bash
# ==============================================================================
# enable-services.sh
# Включает все сервисы immutable-live в systemd БЕЗ загрузки системы.
#
# Использует офлайн-режим systemctl:  systemctl enable --root=<persistence-root>
# Это создаёт симлинки в <root>/etc/systemd/system/<target>.wants/.
#
# Использование:
#   ./tools/scripts/enable-services.sh            # корень по умолчанию: disk/persistence
#   ./tools/scripts/enable-services.sh /path/to/root    # явный корень persistence
# ==============================================================================
set -Eeuo pipefail

SERVICES=(immutable-live.service)

log() { printf '[enable-services] %s\n' "$*"; }
fail() { printf '[enable-services] ОШИБКА: %s\n' "$*" >&2; exit 1; }

command -v systemctl >/dev/null 2>&1 || fail 'systemctl не найден в системе'

# --- Определение корня persistence -------------------------------------------
if [[ $# -ge 1 ]]; then
    ROOT=$1
else
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
    ROOT="${SCRIPT_DIR}/disk/persistence"
fi
ROOT=$(realpath -m "${ROOT}")

SYSTEMD_DIR="${ROOT}/etc/systemd/system"
[[ -d "${ROOT}/link/etc/systemd/system" ]] && SYSTEMD_DIR="${ROOT}/link/etc/systemd/system"

[[ -d ${ROOT} ]] || fail "Корень persistence не найден: ${ROOT}"
[[ -d ${SYSTEMD_DIR} ]] || fail "Нет каталога systemd: ${SYSTEMD_DIR}"
log "Корень persistence: ${ROOT} (systemd: ${SYSTEMD_DIR})"

# --- Проверка наличия unit-файлов ---------------------------------------------
for service in "${SERVICES[@]}"; do
    [[ -f ${SYSTEMD_DIR}/${service} ]] \
        || fail "Unit-файл не найден: ${SYSTEMD_DIR}/${service}"
done

# --- Включение сервисов в корне persistence ------------------------------------
# Используем relative пути для корректной работы внутри persistence root
for service in "${SERVICES[@]}"; do
    log "Включение: ${service}"
    mkdir -p "${SYSTEMD_DIR}/multi-user.target.wants"
    ln -sfn "../${service}" "${SYSTEMD_DIR}/multi-user.target.wants/${service}"
done

# --- Итоговое состояние ---------------------------------------------------------
log "---- Итоговые симлинки (.*.wants) ----"
find "${SYSTEMD_DIR}" -maxdepth 2 -type l -name '*.service' -printf '%p -> %l\n' | sort
log "Готово. Симлинки созданы офлайн; при следующей загрузке live-системы сервисы запустятся автоматически."