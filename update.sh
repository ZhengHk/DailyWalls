#!/usr/bin/env bash
# =============================================================================
# update.sh — Quick dev loop: quit, remove app, rebuild, reinstall, launch
#
# Keeps your wallpapers, favorites, and logs (does not run uninstall --purge-data).
#
# Usage:
#   ./update.sh                  — rebuild + reinstall (native arch) + launch
#   ./update.sh --arch arm64     — Apple Silicon build
#   ./update.sh --no-launch      — install without opening the app
#
# Same flags as install.sh (passed through to build.sh).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "==> DailyWalls update: uninstall → rebuild → install"
echo ""

./uninstall.sh

echo ""
./install.sh "$@"