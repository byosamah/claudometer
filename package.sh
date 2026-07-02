#!/usr/bin/env bash
# package.sh - build Claudometer.app and wrap it in a drag-to-Applications .dmg.
#
# Distribution is PHASED:
#   * Default (no env vars): ad-hoc signed app inside the .dmg. Free. Gatekeeper
#     blocks the first launch; on macOS 26 (right-click -> Open was removed) the
#     unblock is System Settings -> Privacy & Security -> "Open Anyway". This is
#     the "share with friends now" path.
#   * Signed + notarized (set the env vars below): Developer-ID codesign with a
#     hardened runtime, then notarize + staple the .dmg so it opens with a clean
#     double-click anywhere. This is the one-step flip to "share with anyone".
#
# To enable the signed path, export before running:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="claudometer-notary"   # a stored `notarytool` keychain profile
# (create the profile once with:
#   xcrun notarytool store-credentials claudometer-notary \
#     --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD)
set -euo pipefail

APP_NAME="Claudometer"
APP="${APP_NAME}.app"
DMG="${APP_NAME}.dmg"          # constant name so releases/latest/download/<DMG> is stable

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)"

# 1. Build the app bundle (compiles + assembles + ad-hoc signs).
./build.sh

# 2. If a Developer-ID identity is provided, re-sign with a hardened runtime and
#    a secure timestamp (both are required for notarization).
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo ">> Developer-ID codesigning (hardened runtime)"
    codesign --force --options runtime --timestamp \
        --sign "${SIGN_IDENTITY}" "${APP}"
    codesign --verify --strict --verbose=2 "${APP}"
else
    echo ">> NOTE: no SIGN_IDENTITY set -> ad-hoc signed (unsigned distribution)."
    echo "   macOS 26 first-launch unblock: System Settings -> Privacy & Security ->"
    echo "   'Open Anyway' (right-click -> Open no longer works). Set SIGN_IDENTITY to notarize."
fi

# 3. Assemble a drag-to-Applications staging folder and build the compressed .dmg.
#    Staging lives inside the repo (a guaranteed-writable location) rather than
#    /var/folders, which a restricted shell sandbox may refuse.
echo ">> building ${DMG} (v${VERSION}, build ${BUILD})"
STAGING="${SCRIPT_DIR}/.dmg-build"
trap 'rm -rf "${STAGING}"' EXIT
rm -rf "${STAGING}"
mkdir -p "${STAGING}"
cp -R "${APP}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
rm -f "${DMG}"
hdiutil create -quiet -volname "${APP_NAME}" -srcfolder "${STAGING}" \
    -ov -format UDZO "${DMG}"

# 4. Notarize + staple the .dmg when credentials are present.
if [[ -n "${SIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
    echo ">> notarizing ${DMG} (this can take a few minutes)"
    xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${DMG}"
    echo ">> notarized + stapled."
else
    echo ">> NOTE: skipping notarization (set SIGN_IDENTITY + NOTARY_PROFILE to enable)."
fi

echo ">> packaged: ${SCRIPT_DIR}/${DMG}"
