#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DMG_STAGING="${BUILD_DIR}/dmg-staging"

VERSION="${1:-${APP_VERSION:-1.0.0}}"
DMG_NAME="${2:-Island}"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}.dmg"

"${ROOT_DIR}/Scripts/build-app.sh" release "${VERSION}"

echo "==> Preparing DMG staging directory..."
rm -rf "${DMG_STAGING}" "${DMG_PATH}"
mkdir -p "${DMG_STAGING}"

cp -R "${BUILD_DIR}/Island.app" "${DMG_STAGING}/Island.app"
ln -s /Applications "${DMG_STAGING}/Applications"

echo "==> Creating distributable disk image at ${DMG_PATH}..."
hdiutil create \
    -volname "Island" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "${DMG_PATH}"

rm -rf "${DMG_STAGING}"
echo "==> Done! Distributable DMG created at: ${DMG_PATH}"
