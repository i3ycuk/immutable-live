#!/usr/bin/env bash
# ==============================================================================
# locale.sh - Language detection and message loading for immutable-live
# ==============================================================================
# Usage: source locale/locale.sh

detect_locale() {
    local lang="${LANG:-${LC_MESSAGES:-en}}"
    lang="${lang%%_*}"
    lang="${lang%%.*}"
    
    case "${lang}" in
        ru|uk|be|kz)
            echo "ru"
            ;;
        *)
            echo "en"
            ;;
    esac
}

load_locale() {
    local lang
    lang=$(detect_locale)
    local locale_file="${BASE_DIR}/locale/${lang}.sh"
    
    if [[ -f "${locale_file}" ]]; then
        # shellcheck disable=SC1090
        source "${locale_file}"
    else
        # Fallback to English
        source "${BASE_DIR}/locale/en.sh"
    fi
    
    export MSG
}

t() {
    local key="${1:-}"
    shift || true
    local text="${MSG[$key]:-}"

    if [[ -z "$text" ]]; then
        printf '[MISSING: %s]\n' "$key"
        return 1
    fi

    if (( $# % 2 != 0 )); then
        printf 'Invalid translation arguments for key %s\n' "$key" >&2
        return 2
    fi

    while (( $# > 0 )); do
        local placeholder="{$1}"
        text="${text//$placeholder/$2}"
        shift 2
    done

    printf '%b\n' "$text"
}

t_if_defined() {
    local key="$1"
    [[ -n "${MSG[$key]:-}" ]] && t "$@"
}

# Auto-load locale when sourced
if [[ -n "${BASE_DIR:-}" ]]; then
    load_locale
fi