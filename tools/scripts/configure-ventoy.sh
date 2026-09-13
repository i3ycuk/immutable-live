#!/usr/bin/env bash
# ==============================================================================
# configure-ventoy.sh - Optimized Ventoy configuration for auto-booting
# ==============================================================================
set -Eeuo pipefail

TARGET_JSON="$(dirname "$0")/../../disk/boot/ventoy/ventoy.json"

echo "Configuring Ventoy for auto-boot..."

cat > "${TARGET_JSON}" <<EOF
{
    "control": [
        { "VTOY_DEFAULT_SEARCH_ROOT": "/iso" },
        { "VTOY_DEFAULT_IMAGE": "last" },
        { "VTOY_MENU_TIMEOUT": "1" },
        { "VTOY_FILT_DOT_UNDERSCORE_FILE": "1" },
        { "VTOY_WIN11_BYPASS_CHECK": "1" },
        { "VTOY_DEFAULT_KBD_LAYOUT": "English" },
        { "VTOY_MENU_TIP": "0" },
        { "VTOY_SECONDARY_BOOT_MODE": "1" }
    ],
    "theme": {
        "display_mode": "CLI",
        "ventoy_left": "5%",
        "ventoy_top": "95%",
        "ventoy_color": "#eff0f1"
    }
}
EOF

echo "Ventoy configuration updated: timeout 1s, text-mode optimized."
