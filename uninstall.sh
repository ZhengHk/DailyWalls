#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — Quit DailyWalls and remove the installed app bundle
#
# Usage:
#   ./uninstall.sh               — quit + remove /Applications/DailyWalls.app
#   ./uninstall.sh --purge-data    — also remove cached wallpapers and logs
# =============================================================================
set -euo pipefail

APP_NAME="DailyWalls"
BUNDLE_NAME="DailyWalls.app"
INSTALL_PATH="/Applications/${BUNDLE_NAME}"
PURGE_DATA=false

for arg in "$@"; do
    case "$arg" in
        --purge-data) PURGE_DATA=true ;;
        -h|--help)
            sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $arg (try --help)"
            exit 1
            ;;
    esac
done

echo "==> Stopping ${APP_NAME} if running..."
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.5

if [[ -d "${INSTALL_PATH}" ]]; then
    echo "==> Removing ${INSTALL_PATH}..."
    rm -rf "${INSTALL_PATH}"
    echo "==> App removed."
else
    echo "==> Not installed at ${INSTALL_PATH} (nothing to remove)."
fi

if [[ "$PURGE_DATA" == true ]]; then
    PICTURES_DIR="${HOME}/Pictures/ms-wallpapers"
    LOG_DIR="${HOME}/.dailywalls"
    echo "==> Purging user data..."
    if [[ -d "${PICTURES_DIR}" ]]; then
        rm -rf "${PICTURES_DIR}"
        echo "    Removed ${PICTURES_DIR}"
    fi
    if [[ -d "${LOG_DIR}" ]]; then
        rm -rf "${LOG_DIR}"
        echo "    Removed ${LOG_DIR}"
    fi
fi

echo "==> Uninstall complete."