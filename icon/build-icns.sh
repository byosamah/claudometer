#!/usr/bin/env bash
# build-icns.sh - generate Resources/AppIcon.icns from the 1024 master.
# The master (icon/Claudometer-1024.png) is the coral sunburst mascot on a
# warm-charcoal squircle. Source design: icon/icon-source.html.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="${DIR}/icon/Claudometer-1024.png"
ICONSET="${DIR}/icon/AppIcon.iconset"

[ -f "${MASTER}" ] || { echo "missing ${MASTER}"; exit 1; }

rm -rf "${ICONSET}"; mkdir -p "${ICONSET}"
gen() { sips -z "$1" "$1" "${MASTER}" --out "${ICONSET}/$2" >/dev/null; }

# All sizes macOS expects in an .icns, generated from the single 1024 master.
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
cp "${MASTER}" "${ICONSET}/icon_512x512@2x.png"   # 1024

iconutil -c icns "${ICONSET}" -o "${DIR}/Resources/AppIcon.icns"
rm -rf "${ICONSET}"
echo "wrote ${DIR}/Resources/AppIcon.icns"
