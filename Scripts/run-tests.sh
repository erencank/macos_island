#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${SDKROOT:-}" ]]; then
    if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
        export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    fi
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/island-clang-cache}"

cd "${ROOT_DIR}"
swift run \
    --disable-sandbox \
    --scratch-path /tmp/island-build \
    --cache-path /tmp/island-swiftpm-cache \
    --manifest-cache local \
    -Xswiftc -module-cache-path -Xswiftc /tmp/island-swift-cache \
    IslandTestsRunner
