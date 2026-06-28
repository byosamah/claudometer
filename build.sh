#!/usr/bin/env bash
# build.sh - compile + assemble + ad-hoc sign NotchPilot.app (no Xcode required).
# Toolchain: Swift 6.4 via Command Line Tools, direct swiftc (SwiftPM not used).
set -euo pipefail

APP_NAME="NotchPilot"
SRC_DIR="Sources/NotchPilot"
PLIST="Info.plist"
APP="${APP_NAME}.app"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# 1. compile all sources directly with swiftc (-parse-as-library because we use @main)
echo ">> compiling ${APP_NAME} (swiftc, arm64)"
swiftc -parse-as-library \
    "${SRC_DIR}"/*.swift \
    -o "${APP_NAME}"

# 2. assemble the .app bundle
echo ">> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
mv "${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "${PLIST}" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"
plutil -lint "${APP}/Contents/Info.plist"

# 3. ad-hoc codesign ("-" identity). SMAppService needs a valid signature.
echo ">> ad-hoc codesigning"
codesign --force --deep --sign - "${APP}"
codesign --verify --deep --strict --verbose=2 "${APP}"

echo ">> built: ${SCRIPT_DIR}/${APP}"
