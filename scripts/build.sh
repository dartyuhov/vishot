#!/usr/bin/env bash
# Builds Vishot.app. Pass "install" to copy it to ~/Applications and relaunch.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Vishot.app
# Signing with the same certificate every time keeps the Screen Recording permission across rebuilds.
IDENTITY="${VISHOT_SIGN_IDENTITY:-Apple Development}"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Vishot" "$APP/Contents/MacOS/Vishot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x Vishot || true
  rm -rf ~/Applications/Vishot.app
  mkdir -p ~/Applications
  cp -R "$APP" ~/Applications/
  open ~/Applications/Vishot.app
  echo "Installed to ~/Applications/Vishot.app"
fi
