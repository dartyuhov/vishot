#!/usr/bin/env bash
# Builds Vishot.app. Pass "install" to copy it to ~/Applications and relaunch.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Vishot.app
# Signing with the same certificate every time keeps the Screen Recording permission across rebuilds.
IDENTITY="${VISHOT_SIGN_IDENTITY:-Apple Development}"
ARCH="${VISHOT_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
if [[ "$ARCH" != "$(uname -m)" ]]; then
  echo "Build on a native $ARCH host (cross-compilation is not a release check)." >&2
  exit 1
fi
TRIPLE="$ARCH-apple-macosx14.0"
export MACOSX_DEPLOYMENT_TARGET=14.0

swift build -c release --force-resolved-versions --triple "$TRIPLE"
BIN_DIR="$(swift build -c release --triple "$TRIPLE" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/Vishot" "$APP/Contents/MacOS/Vishot"
cp "$BIN_DIR/VishotCLI" "$APP/Contents/Helpers/vishot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/ThirdPartyNotices.txt"
cp Resources/FontLicenses.txt "$APP/Contents/Resources/FontLicenses.txt"
# The landing page's fonts, which the overlay and the editor use too (Fonts.swift).
mkdir -p "$APP/Contents/Resources/Fonts"
cp site/fonts/*.woff2 "$APP/Contents/Resources/Fonts/"
python3 - "$APP/Contents/Info.plist" "$(git rev-parse HEAD)" <<'PY'
import os, plistlib, re, sys
path, commit = sys.argv[1:]
with open(path, 'rb') as f:
    info = plistlib.load(f)
version = info['CFBundleShortVersionString']
build = os.environ.get('VISHOT_BUILD_VERSION', version)
if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
    raise SystemExit('Expected a regular major.minor.patch bundle version')
if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', build):
    raise SystemExit('Expected a numeric bundle build version')
info.update(CFBundleVersion=build, VishotSourceCommit=commit)
with open(path, 'wb') as f:
    plistlib.dump(info, f)
PY
# Sign nested code first with the same stable identity, then seal the app.
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Helpers/vishot"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x Vishot || true
  rm -rf ~/Applications/Vishot.app
  mkdir -p ~/Applications
  cp -R "$APP" ~/Applications/
  open ~/Applications/Vishot.app
  echo "Installed to ~/Applications/Vishot.app"
fi
