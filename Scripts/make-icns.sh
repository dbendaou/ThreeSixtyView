#!/bin/bash
# Build Resources/AppIcon.icns from Resources/AppIcon.png.
# Command Line Tools only: sips resizes, iconutil packs the iconset.
# Sizes are 16, 32, 128, 256, and 512 at 1x and @2x (16 through 1024).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="Resources/AppIcon.png"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
trap 'rm -rf "$(dirname "$SET")"' EXIT

resize() {
  local pixels="$1"
  local name="$2"
  sips -z "$pixels" "$pixels" "$SRC" --out "$SET/$name" >/dev/null
}

resize 16   icon_16x16.png
resize 32   icon_16x16@2x.png
resize 32   icon_32x32.png
resize 64   icon_32x32@2x.png
resize 128  icon_128x128.png
resize 256  icon_128x128@2x.png
resize 256  icon_256x256.png
resize 512  icon_256x256@2x.png
resize 512  icon_512x512.png
resize 1024 icon_512x512@2x.png

iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
