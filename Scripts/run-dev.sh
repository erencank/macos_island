#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"${ROOT_DIR}/Scripts/build-app.sh" debug

APP_EXEC="${ROOT_DIR}/build/Island.app/Contents/MacOS/Island"

echo "==> Launching Island.app (with Settings & Simulator window open)..."
pkill -f "Island.app/Contents/MacOS/Island" 2>/dev/null || true
killall NotificationCenter 2>/dev/null || true
"${APP_EXEC}" --open-settings
