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
#    -target pins the deployment target to macOS 26 so the Liquid Glass APIs
#    (.glassEffect, GlassEffectContainer, .buttonStyle(.glass)) resolve directly,
#    with no availability fallbacks. LSMinimumSystemVersion is already 26.0.
echo ">> compiling ${APP_NAME} (swiftc, arm64, -O, macOS 26 target)"
swiftc -O -parse-as-library \
    -target arm64-apple-macos26.0 \
    "${SRC_DIR}"/*.swift \
    -o "${APP_NAME}"

# 2. assemble the .app bundle
echo ">> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
mv "${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "${PLIST}" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"
# bundle resources (the mascot HTML/SVG/GSAP) so Bundle.main can find them
if [ -d Resources ]; then cp -R Resources/. "${APP}/Contents/Resources/"; fi
plutil -lint "${APP}/Contents/Info.plist"

# 3. ad-hoc codesign ("-" identity). SMAppService needs a valid signature.
#    No --deep: it's deprecated for signing and there is no nested code here.
echo ">> ad-hoc codesigning"
codesign --force --sign - "${APP}"
codesign --verify --strict --verbose=2 "${APP}"

echo ">> built: ${SCRIPT_DIR}/${APP}"
