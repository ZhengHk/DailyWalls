#!/usr/bin/env bash
# =============================================================================
# install.sh — Build release DailyWalls.app and install to /Applications
#
# Usage:
#   ./install.sh                 — build (native arch) + install + launch
#   ./install.sh --arch arm64    — Apple Silicon build
#   ./install.sh --arch x86_64   — Intel build
#   ./install.sh --no-launch     — install without opening the app
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

exec ./build.sh "$@" install