#!/usr/bin/env bash
# ==============================================================================
# immutable-live.sh — единая служба инициализации, авто-очистки ISO и сохранения пакетов
# ==============================================================================
set -Eeuo pipefail

LOG_FILE=/var/log/immutable-live/immutable-live.log
STATE_DIR=/etc/immutable-live/state
ISO_ID_FILE=${STATE_DIR}/iso.id
CONFIG_DIR=/etc/immutable-live/config

mkdir -p "$(dirname "${LOG_FILE}")" "${STATE_DIR}" "${CONFIG_DIR}"

log() {
    local level=${2:-INFO}
    printf '[%s] [%s] %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)" "${level}" "$*"
}

log_info()  { log "$*" "INFO"; }
log_warn()  { log "$*" "WARN"; }
log_error() { log "$*" "ERROR"; }
log_debug() { log "$*" "DEBUG"; }

exec > >(tee -a "${LOG_FILE}") 2>&1

log_info "=== Запуск immutable-live ==="

# --- Поиск live-каталога ----------------------------------------------------
find_live_dir() {
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
            printf '%s\n' "${mount_point}"
            return 0
        fi
    done
    return 1
}

LIVE_DIR=$(find_live_dir || true)

# --- Загрузка конфигурации --------------------------------------------------
load_config() {
    local file
    for file in "${LIVE_DIR}/.env" "${CONFIG_DIR}/.env" "/etc/immutable-live/.env"; do
        if [[ -n ${file} && -f ${file} ]]; then
            log_info "Загружен файл конфигурации: ${file}"
            # Ошибка в любой строке .env не должна ронять весь скрипт
            set +e
            # shellcheck disable=SC1090
            source "${file}"
            set -e
            return 0
        fi
    done
    return 0
}
load_config

# --- Синхронизация значения обратно в .env (пароль, группы) -------------------
sync_env_var() {
    local key=$1 value=$2
    local env_file=""
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
    log_info "Обновлён параметр ${key} в ${env_file}"
}

# --- Детекция пакетного менеджера -------------------------------------------
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

# --- Получение списка текущих системных пакетов -----------------------------
# ПОЛНЫЙ список пакетов (детерминированный). Используется как база (base.packages)
# и для точного определения удалённых пакетов (без путаницы с метапакетами).
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
            log_warn "Неизвестный пакетный менеджер, отслеживание пакетов пропущено"
            ;;
    esac
}

# --- Список ПРОГРАММ, установленных пользователем (не зависимости) -------------
# Используется ТОЛЬКО для user.packages, чтобы не тащить зависимости.
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
            if [[ -f /etc/apk/world ]]; then
                grep -Ev '^[[:space:]#]*$' /etc/apk/world 2>/dev/null | sort -u
            fi
            ;;
        *)
            ;;
    esac
}

# --- Инициализация списков пакетов -----------------------------------------
PACKAGE_FILE=${STATE_DIR}/user.packages
REMOVED_PACKAGE_FILE=${STATE_DIR}/removed.packages
BASE_PACKAGE_FILE=${STATE_DIR}/base.packages
BASE_MANUAL_FILE=${STATE_DIR}/base.manual

save_user_packages() {
    [[ "${PKG_MGR}" == "unknown" ]] && return 0
    local current_packages manual_packages
    current_packages=$(mktemp)
    manual_packages=$(mktemp)
    get_installed_packages > "${current_packages}"
    get_manual_packages > "${manual_packages}"

    if [[ ! -s ${BASE_PACKAGE_FILE} ]]; then
        install -D -m 0644 "${current_packages}" "${BASE_PACKAGE_FILE}"
        install -D -m 0644 "${manual_packages}" "${BASE_MANUAL_FILE}"
        touch "${PACKAGE_FILE}" "${REMOVED_PACKAGE_FILE}"
        log_info "Создан базовый список пакетов (полный): ${BASE_PACKAGE_FILE}"
        rm -f "${current_packages}" "${manual_packages}"
        return 0
    fi

    # Явно установленные пользователем программы (без зависимостей и архитектуры)
    comm -23 "${manual_packages}" <(sort -u "${BASE_MANUAL_FILE}") \
        | install -D -m 0644 /dev/stdin "${PACKAGE_FILE}"

    # ТОЧНО удалённые пакеты: были в полном списке базового ISO, но отсутствуют сейчас.
    # (gparted попадёт сюда, а не метапакет kali-linux-default, если он не удалялся)
    comm -23 <(sort -u "${BASE_PACKAGE_FILE}") "${current_packages}" \
        | install -D -m 0644 /dev/stdin "${REMOVED_PACKAGE_FILE}"

    rm -f "${current_packages}" "${manual_packages}"
    log_info "Списки пользовательских пакетов обновлены: user.packages ($(wc -l < "${PACKAGE_FILE}" 2>/dev/null || echo 0)) и removed.packages ($(wc -l < "${REMOVED_PACKAGE_FILE}" 2>/dev/null || echo 0))"
}

# --- Обработка вызова быстрого сохранения пакетов из хука --------------------
if [[ "${1:-}" == "--save-packages" || "${1:-}" == "save" ]]; then
    save_user_packages
    exit 0
fi

capture_base_packages() {
    [[ "${PKG_MGR}" == "unknown" ]] && return 0
    local current_packages manual_packages
    current_packages=$(mktemp)
    manual_packages=$(mktemp)
    get_installed_packages > "${current_packages}"
    get_manual_packages > "${manual_packages}"
    install -D -m 0644 "${current_packages}" "${BASE_PACKAGE_FILE}"
    install -D -m 0644 "${manual_packages}" "${BASE_MANUAL_FILE}"
    rm -f "${current_packages}" "${manual_packages}"
    log_info "Обновлён базовый список пакетов для нового ISO"
}

restore_user_packages() {
    [[ "${PKG_MGR}" == "unknown" ]] && return 0

    # 1. Восстановление (установка) пользовательских пакетов
    if [[ -s ${PACKAGE_FILE} ]]; then
        local packages
        packages=$(grep -Ev '^[[:space:]#]*$' "${PACKAGE_FILE}" | sort -u | tr '\n' ' ')
        if [[ -n ${packages} ]]; then
            log_info "Установка сохраненных пакетов (${PKG_MGR}): ${packages}"
            read -r -a package_array <<< "${packages}"

            case "${PKG_MGR}" in
                apt)
                    apt-get update -o Acquire::Http::Timeout=5 -o Acquire::Connect-Timeout=5 || true
                    apt-get install -y --no-install-recommends "${package_array[@]}" || log_warn "Ошибка при восстановлении некоторых пакетов через apt"
                    ;;
                pacman)
                    pacman -Sy --noconfirm "${package_array[@]}" || log_warn "Ошибка при восстановлении пакетов через pacman"
                    ;;
                dnf)
                    dnf install -y "${package_array[@]}" || log_warn "Ошибка при восстановлении пакетов через dnf"
                    ;;
                apk)
                    apk add "${package_array[@]}" || log_warn "Ошибка при восстановлении пакетов через apk"
                    ;;
            esac
        fi
    fi

    # 2. Удаление пакетов, которые пользователь удалял из базового ISO
    if [[ -s ${REMOVED_PACKAGE_FILE} ]]; then
        local rm_packages
        rm_packages=$(grep -Ev '^[[:space:]#]*$' "${REMOVED_PACKAGE_FILE}" | sort -u | tr '\n' ' ')
        if [[ -n ${rm_packages} ]]; then
            log_info "Удаление ранее сброшенных системных пакетов (${PKG_MGR}): ${rm_packages}"
            read -r -a rm_package_array <<< "${rm_packages}"

            case "${PKG_MGR}" in
                apt)
                    apt-get purge -y "${rm_package_array[@]}" || log_warn "Ошибка при удалении пакетов через apt"
                    ;;
                pacman)
                    pacman -Rns --noconfirm "${rm_package_array[@]}" || log_warn "Ошибка при удалении пакетов через pacman"
                    ;;
                dnf)
                    dnf remove -y "${rm_package_array[@]}" || log_warn "Ошибка при удалении пакетов через dnf"
                    ;;
                apk)
                    apk del "${rm_package_array[@]}" || log_warn "Ошибка при удалении пакетов через apk"
                    ;;
            esac
        fi
    fi

    return 0
}

# --- Фоновое восстановление пакетов после смены ISO (не блокирует загрузку) ---
if [[ "${1:-}" == "--restore" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    log_info "=== Фоновое восстановление пакетов ==="
    restore_user_packages
    save_user_packages
    log_info "=== Восстановление пакетов завершено ==="
    exit 0
fi

# --- Автоматическое определение и очистка ISO-зависимых директорий ---------
get_iso_dependent_directories() {
    local -a dirs=()

    # 1. Системы управления пакетами (Debian, Arch, RedHat, Alpine)
    case "${PKG_MGR}" in
        apt)
            dirs+=(/var/lib/apt /var/lib/dpkg /var/cache/apt /var/lib/alternatives /etc/alternatives)
            ;;
        pacman)
            dirs+=(/var/lib/pacman/local /var/cache/pacman/pkg)
            ;;
        dnf)
            dirs+=(/var/lib/rpm /var/lib/dnf /var/cache/dnf /var/cache/yum)
            ;;
        apk)
            dirs+=(/lib/apk/db /var/cache/apk)
            ;;
    esac

    # 2. Динамические кэши системных библиотек, оборудования и systemd
    dirs+=(
        /etc/ld.so.cache
        /var/lib/systemd/catalog
        /var/lib/systemd/coredump
        /var/cache/fontconfig
    )

    # 3. Пользовательские дополнения из конфигурации (.env: ISO_DEPENDENT_DIRS)
    if [[ -n ${ISO_DEPENDENT_DIRS:-} ]]; then
        IFS=' ' read -r -a custom_dirs <<< "${ISO_DEPENDENT_DIRS}"
        dirs+=("${custom_dirs[@]}")
    fi

    printf '%s\n' "${dirs[@]}" | sort -u
}

clean_iso_dependent_state() {
    log_info "Умная и безопасная очистка ISO-зависимых каталогов..."

    # 1. Безопасный сброс PAM: НЕ удаляем файлы pam.d вслепую (чтобы не сломать sudo/login),
    # а удаляем whiteout-файлы и принудительно обновляем конфигурацию PAM под текущий ISO.
    if [[ -d /etc/pam.d ]]; then
        log_info "Восстановление оригинальных правил PAM текущего ISO..."
        find /etc/pam.d -name '.wh.*' -delete 2>/dev/null || true
        if command -v pam-auth-update >/dev/null 2>&1; then
            pam-auth-update --package --force 2>/dev/null || true
        fi
    fi

    # 2. Умная очистка баз пакетов и кэшей
    local target
    while read -r target; do
        [[ -n ${target} ]] || continue
        if [[ -d ${target} ]]; then
            log_info "Очистка ISO-зависимого каталога: ${target}"
            find "${target}" -mindepth 1 -delete 2>/dev/null || true
        elif [[ -f ${target} ]]; then
            log_info "Удаление ISO-зависимого кэш-файла: ${target}"
            rm -f "${target}" 2>/dev/null || true
        fi
    done < <(get_iso_dependent_directories)

    # 3. Восстановление кэша системных библиотек для нового ISO
    if command -v ldconfig >/dev/null 2>&1; then
        log_info "Обновление кэша системных библиотек (ldconfig)..."
        ldconfig 2>/dev/null || true
    fi

    # 4. Пересборка системных альтернатив (x-session-manager и др.),
    #    чтобы не сломать графический вход (чёрный экран)
    if command -v update-alternatives >/dev/null 2>&1; then
        log_info "Пересборка системных альтернатив..."
        update-alternatives --all 2>/dev/null || true
    fi

    # 5. Удаление маскирующих whiteout-файлов overlay (.wh.*) в /etc, /var
    log_info "Удаление маскирующих whiteout-файлов overlay (.wh.*)..."
    find /etc /var -name '.wh.*' -delete 2>/dev/null || true
    return 0
}

# --- Определение ID текущего ISO --------------------------------------------
# Использует мгновенное считывание метаданных (размер + mtime) и хэш 1-го мегабайта.
# Это занимает <0.01с вместо нескольких минут на вычисление SHA256 4GB файла на медленной USB-флешке.
get_iso_id() {
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

current_iso=$(get_iso_id || true)
previous_iso=$(cat "${ISO_ID_FILE}" 2>/dev/null || true)

if [[ -n ${current_iso} ]]; then
    if [[ -n ${previous_iso} && ${previous_iso} != "${current_iso}" ]]; then
        log_info "Обнаружена смена ISO: ${previous_iso} -> ${current_iso}"
        clean_iso_dependent_state
        printf '%s\n' "${current_iso}" > "${ISO_ID_FILE}"
        capture_base_packages
        # Тяжёлое восстановление пакетов — в ФОНЕ, чтобы загрузка не висела и
        # дисплейный менеджер не уходил в чёрный экран из-за таймаута
        if [[ -s ${PACKAGE_FILE} || -s ${REMOVED_PACKAGE_FILE} ]]; then
            log_info "Запуск восстановления пакетов в фоновом режиме (не блокирует загрузку)"
            mkdir -p /var/log/immutable-live
            nohup /usr/local/bin/immutable-live.sh --restore \
                >>/var/log/immutable-live/restore.log 2>&1 &
            disown || true
        fi
    elif [[ -z ${previous_iso} ]]; then
        log_info "Первичный запуск: сохранён отпечаток текущего ISO (${current_iso})"
        printf '%s\n' "${current_iso}" > "${ISO_ID_FILE}"
        capture_base_packages
    else
        log_info "ISO не изменился (${current_iso})"
    fi
else
    log_warn "Не удалось определить ID ISO"
fi

save_user_packages

# --- Настройка системы (Hostname, Locale, Keyboard, DNS) --------------------
configure_system() {
    # 1. Имя хоста (Hostname)
    local host_name=${HOSTNAME:-}
    if [[ -n ${host_name} ]]; then
        log_info "Установка имени хоста: ${host_name}"
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

    # 2. Локаль и язык системы (Locale & Language)
    local sys_locale=${LOCALE:-}
    local sys_lang=${LANGUAGE:-}
    if [[ -n ${sys_locale} ]]; then
        log_info "Установка локали системы: ${sys_locale}"
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

    # 3. Раскладка клавиатуры (Keyboard Layout)
    local kb_layout=${KEYBOARD_LAYOUT:-${KEYMAP:-}}
    local kb_variant=${KEYBOARD_VARIANT:-}
    local kb_options=${KEYBOARD_OPTIONS:-grp:alt_shift_toggle}
    if [[ -n ${kb_layout} ]]; then
        log_info "Установка раскладки клавиатуры: ${kb_layout}"
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

    # 4. DNS-серверы
    local dns_servers=${DNS_SERVERS:-}
    if [[ -n ${dns_servers} ]]; then
        log_info "Установка DNS серверов: ${dns_servers}"
        local dns
        local tmp_resolv
        tmp_resolv=$(mktemp)
        for dns in ${dns_servers}; do
            printf 'nameserver %s\n' "${dns}" >> "${tmp_resolv}"
        done
        cat "${tmp_resolv}" > /etc/resolv.conf 2>/dev/null || true
        rm -f "${tmp_resolv}"
    fi

    return 0
}
configure_system

# --- Настройка пользователя --------------------------------------------------
configure_user() {
    local username=${USER_NAME:-live}
    local pass_hash=${USER_PASSWORD_HASH:-}
    local shell=${USER_SHELL:-/bin/bash}
    local groups_csv=${USER_GROUPS:-sudo,audio,video,plugdev,netdev}
    local hide_user=${HIDE_USER:-false}
    local disable_live_user=${DISABLE_LIVE_USER:-${DISABLE_ISO_USER:-false}}

    log_info "Настройка пользователя ${username}..."

    # 1. Проверка существования пользователя перед созданием
    if id "${username}" >/dev/null 2>&1; then
        log_info "Пользователь ${username} уже существует, обновление настроек..."
        usermod -s "${shell}" "${username}" 2>/dev/null || true
    else
        log_info "Создание пользователя ${username} (shell: ${shell})..."
        useradd -m -s "${shell}" "${username}" || log_warn "Не удалось создать пользователя ${username}"
    fi

    # 2. Пароль: учитываем смену пароля внутри системы и синхронизируем её в .env
    local shadow_hash
    shadow_hash=$(getent shadow "${username}" 2>/dev/null | cut -d: -f2 || true)
    local saved_hash_file="${STATE_DIR}/user_password.hash"
    local saved_hash
    saved_hash=$(cat "${saved_hash_file}" 2>/dev/null || true)

    if [[ -n ${shadow_hash} && ${shadow_hash} != "!" && ${shadow_hash} != "*" ]]; then
        if [[ -n ${saved_hash} && ${shadow_hash} != "${saved_hash}" ]]; then
            log_info "Обнаружена смена пароля в ОС — сохраняем и обновляем .env..."
            printf '%s\n' "${shadow_hash}" > "${saved_hash_file}"
            sync_env_var USER_PASSWORD_HASH "${shadow_hash}"
        elif [[ -z ${saved_hash} ]]; then
            printf '%s\n' "${shadow_hash}" > "${saved_hash_file}"
        fi
    elif [[ -n ${pass_hash} ]]; then
        log_info "Установка пароля из конфигурации для ${username}..."
        usermod -p "${pass_hash}" "${username}" || log_warn "Не удалось установить пароль"
        printf '%s\n' "${pass_hash}" > "${saved_hash_file}"
        sync_env_var USER_PASSWORD_HASH "${pass_hash}"
    fi

    # 3. Двусторонняя синхронизация групп: .env -> система (добавление/удаление)
    #    и система -> .env (актуальный состав)
    local groups_file="${STATE_DIR}/user.groups"
    local -a desired_groups=()
    local -a managed_groups=()
    local g d c

    IFS=',' read -r -a desired_groups <<< "${groups_csv}"
    [[ -f ${groups_file} ]] && mapfile -t managed_groups < "${groups_file}"

    local primary_group
    primary_group=$(id -ng "${username}" 2>/dev/null || true)

    local -a current_groups=()
    while read -r g; do
        [[ -n ${g} && ${g} != "${primary_group}" ]] && current_groups+=("${g}")
    done < <(id -nG "${username}" 2>/dev/null | tr ' ' '\n')

    # Удаляем ранее управляемые группы, которых больше нет в .env
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

    # Добавляем желаемые группы (создавая отсутствующие)
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

    # Сохраняем управляемые группы и синхронизируем актуальный состав в .env
    printf '%s\n' "${desired_groups[@]}" > "${groups_file}"
    local effective_groups
    effective_groups=$(IFS=','; echo "${current_groups[*]}")
    sync_env_var USER_GROUPS "${effective_groups}"
    log_info "Синхронизированы группы для ${username}: ${effective_groups}"

    # 4. Скрытие пользователя на экране входа
    if [[ ${hide_user} == "true" || ${hide_user} == "yes" ]]; then
        chmod 700 "/home/${username}" 2>/dev/null || true
        mkdir -p /var/lib/AccountsService/users
        printf '[User]\nSystemAccount=true\n' > "/var/lib/AccountsService/users/${username}"
    fi

    # 5. DISABLE_LIVE_USER=true — УДАЛЯЕМ стандартного пользователя ISO (не просто
    #    блокируем вход): учётка не существует в системе и не создаётся
    if [[ ${disable_live_user} == "true" || ${disable_live_user} == "yes" ]]; then
        local default_iso_users=(live kali user debian ubuntu mint arch)
        local iso_user
        for iso_user in "${default_iso_users[@]}"; do
            if [[ ${iso_user} != "${username}" ]] && id "${iso_user}" >/dev/null 2>&1; then
                log_info "Удаление стандартного ISO-пользователя: ${iso_user}"
                userdel -r "${iso_user}" 2>/dev/null || \
                    usermod -L -s /sbin/nologin "${iso_user}" 2>/dev/null || true
            fi
        done
    fi

    return 0
}
configure_user

# --- Настройка SWAP ----------------------------------------------------------
configure_swap() {
    local swap_enable=${SWAP_ENABLE:-true}
    local swap_file=${SWAP_FILE:-/var/swap/swapfile}
    local swap_size=${SWAP_SIZE:-2G}
    local swappiness=${SWAPPINESS:-10}

    [[ ${swap_enable} == "true" ]] || { log_info "SWAP отключен в конфигурации"; return 0; }

    log_info "Настройка SWAP (${swap_file}, ${swap_size})..."
    mkdir -p "$(dirname "${swap_file}")"

    if [[ ! -f ${swap_file} ]]; then
        log_info "Создание SWAP файла..."
        fallocate -l "${swap_size}" "${swap_file}" 2>/dev/null || \
            dd if=/dev/zero of="${swap_file}" bs=1M count=2048 2>/dev/null
        chmod 600 "${swap_file}"
        mkswap "${swap_file}" >/dev/null
    fi

    if ! swapon --show | grep -q "${swap_file}"; then
        swapon "${swap_file}" || log_warn "Не удалось включить SWAP"
    fi

    sysctl -w vm.swappiness="${swappiness}" >/dev/null 2>&1 || true
    return 0
}
configure_swap

# --- Настройка времени и NTP -------------------------------------------------
configure_time() {
    local timezone=${TIMEZONE:-}
    local ntp_enable=${NTP_ENABLE:-true}

    if [[ -n ${timezone} && -f "/usr/share/zoneinfo/${timezone}" ]]; then
        log_info "Установка таймзоны: ${timezone}"
        ln -sf "/usr/share/zoneinfo/${timezone}" /etc/localtime
    fi

    if [[ ${ntp_enable} == "true" ]]; then
        if command -v timedatectl >/dev/null 2>&1; then
            timedatectl set-ntp true 2>/dev/null || true
        fi
    fi
    return 0
}
configure_time

# --- Установка хуков пакетного менеджера для мгновенного сохранения ---
configure_pkg_hooks() {
    # APT (Debian / Kali / Ubuntu)
    if [[ -d /etc/apt/apt.conf.d ]]; then
        cat <<'EOF' > /etc/apt/apt.conf.d/99-immutable-live
DPkg::Post-Invoke { "/usr/local/bin/immutable-live.sh --save-packages >/dev/null 2>&1 || true"; };
EOF
        log_info "Установлен пост-транзакционный хук для APT"
    fi

    # DNF (Fedora / RHEL)
    if [[ -d /etc/dnf/plugins ]]; then
        mkdir -p /etc/dnf/plugins
        cat <<'EOF' > /etc/dnf/plugins/immutable-live.conf
[main]
enabled=1
EOF
        log_info "Установлен пост-транзакционный хук для DNF"
    fi

    # Pacman (Arch Linux)
    if [[ -d /etc/pacman.d ]]; then
        mkdir -p /etc/pacman.d/hooks
        cat <<'EOF' > /etc/pacman.d/hooks/99-immutable-live.hook
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
        log_info "Установлен пост-транзакционный хук для Pacman"
    fi

    # APK (Alpine)
    if [[ -d /etc/apk ]] && command -v apk >/dev/null 2>&1; then
        cat <<'EOF' > /etc/apk/post-install.d/99-immutable-live.sh
#!/bin/sh
/usr/local/bin/immutable-live.sh --save-packages >/dev/null 2>&1 || true
EOF
        chmod +x /etc/apk/post-install.d/99-immutable-live.sh 2>/dev/null || true
        log_info "Установлен пост-транзакционный хук для APK"
    fi
    return 0
}
configure_pkg_hooks

log_info "=== Выполнение immutable-live завершено успешно ==="
