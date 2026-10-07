#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns and site/favicon.svg from the logo's two masters: Resources/logo/vishot-mark.svg
# (32 px) and vishot-mark-16.svg (16 px). Every size is a master scaled by a whole number, so the pixels stay crisp.
# The masters already sit on macOS's icon grid, so they aren't padded here.
# Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")/.."

SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((size * scale))
    master=Resources/logo/vishot-mark.svg
    [[ $px == 16 ]] && master=Resources/logo/vishot-mark-16.svg
    name="icon_${size}x${size}$([[ $scale == 2 ]] && echo @2x || true).png"
    rsvg-convert -w "$px" -h "$px" "$master" -o "$SET/$name"
  done
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"

cp Resources/logo/vishot-mark.svg site/favicon.svg
echo "Wrote site/favicon.svg"
