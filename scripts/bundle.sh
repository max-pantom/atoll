#!/usr/bin/env bash
# Builds Atoll.app with SwiftPM only (no Xcode project). macOS only.
# Usage: scripts/bundle.sh [version]   -> dist/Atoll.app
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
BUILD="${GITHUB_RUN_NUMBER:-1}"
APP=dist/Atoll.app

swift build -c release --arch arm64 --arch x86_64 2>/dev/null || swift build -c release
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null || swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Atoll" "$APP/Contents/MacOS/Atoll"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

# App icon: PNG -> .icns with sips + iconutil
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Now Playing helper (macOS 15.4+): ungive/mediaremote-adapter, BSD-3. Optional.
if [ -d vendor/mediaremote-adapter/build/MediaRemoteAdapter.framework ]; then
  mkdir -p "$APP/Contents/Resources/MediaRemoteAdapter"
  cp -R vendor/mediaremote-adapter/build/MediaRemoteAdapter.framework "$APP/Contents/Resources/MediaRemoteAdapter/"
  cp vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$APP/Contents/Resources/MediaRemoteAdapter/"
  [ -f vendor/mediaremote-adapter/build/MediaRemoteAdapterTestClient ] && cp vendor/mediaremote-adapter/build/MediaRemoteAdapterTestClient "$APP/Contents/Resources/MediaRemoteAdapter/"
  cp vendor/mediaremote-adapter/LICENSE "$APP/Contents/Resources/MediaRemoteAdapter/LICENSE" 2>/dev/null || true
fi

# Ad-hoc sign so macOS will run it (not notarized).
codesign --force --deep --sign - "$APP"
echo "Built $APP ($VERSION)"
