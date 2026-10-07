#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns and site/favicon.svg from Resources/logo/vishot-mark.svg, the one source of the logo.
# Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")/.."

SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((size * scale))
    # macOS icon grid: the rounded square is 824 of 1024, centered.
    body=$((px * 824 / 1024))
    name="icon_${size}x${size}$([[ $scale == 2 ]] && echo @2x || true).png"
    rsvg-convert -w "$body" -h "$body" Resources/logo/vishot-mark.svg \
      | magick - -background none -gravity center -extent "${px}x${px}" "PNG32:$SET/$name"
  done
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"

cp Resources/logo/vishot-mark.svg site/favicon.svg
echo "Wrote site/favicon.svg"
