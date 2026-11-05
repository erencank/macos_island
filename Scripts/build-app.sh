#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/Island.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

CONFIG="${1:-debug}"

# Auto-select MacOSX26.5.sdk if the default symlink points to an mismatched beta SDK
if [[ -z "${SDKROOT:-}" ]]; then
    if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
        export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    fi
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/island-clang-cache}"
SWIFT_MODULE_CACHE="/tmp/island-swift-cache"
SCRATCH_PATH="/tmp/island-build"

echo "==> [1/4] Compiling MediaRemote helper bridge dylib..."
mkdir -p "${BUILD_DIR}"
clang -dynamiclib \
    -fobjc-arc \
    -isysroot "${SDKROOT:-$(xcrun --show-sdk-path)}" \
    -framework Foundation \
    -framework IOBluetooth \
    "${ROOT_DIR}/Scripts/MediaRemoteBridge.m" \
    -o "${BUILD_DIR}/libIslandMediaRemoteBridge.dylib"

echo "==> [2/4] Building Island Swift targets (${CONFIG})..."
cd "${ROOT_DIR}"
swift build \
    -c "${CONFIG}" \
    --product Island \
    --disable-sandbox \
    --scratch-path "${SCRATCH_PATH}" \
    --cache-path /tmp/island-swiftpm-cache \
    --manifest-cache local \
    -Xswiftc -module-cache-path -Xswiftc "${SWIFT_MODULE_CACHE}"

BIN_PATH="${SCRATCH_PATH}/arm64-apple-macosx/${CONFIG}/Island"
if [[ ! -f "${BIN_PATH}" ]]; then
    BIN_PATH="$(swift build -c "${CONFIG}" --product Island --disable-sandbox --scratch-path "${SCRATCH_PATH}" --cache-path /tmp/island-swiftpm-cache --manifest-cache local --show-bin-path)/Island"
fi

echo "==> [3/4] Assembling Island.app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/Island"
cp "${BUILD_DIR}/libIslandMediaRemoteBridge.dylib" "${RESOURCES_DIR}/libIslandMediaRemoteBridge.dylib"

cat > "${CONTENTS_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Island</string>
    <key>CFBundleIdentifier</key>
    <string>com.island.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Island</string>
    <key>CFBundleDisplayName</key>
    <string>Island</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Island uses Apple Events to read Now Playing track metadata and control playback in Spotify and Apple Music.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Island monitors Bluetooth device connections and battery levels to display status indicators in the notch.</string>
    <key>NSLocationUsageDescription</key>
    <string>Island uses Location Services to display the connected Wi-Fi network name (SSID) in the Dynamic Island.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Island uses Location Services to display the connected Wi-Fi network name (SSID) in the Dynamic Island.</string>
</dict>
</plist>
EOF

echo "==> [4/4] Signing Island.app bundle..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Successfully built ${APP_BUNDLE}"
