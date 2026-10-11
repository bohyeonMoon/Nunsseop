#!/bin/bash
# Builds the Swift package and wraps the binary in an .app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

# Pass "release" for a build to use day to day; the debug build adds snapshot/demo flags.
CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

# Assemble and sign outside the project folder: a synced folder (iCloud Desktop) keeps adding
# Finder info to the bundle, which a certificate signature rejects.
WORK="$(mktemp -d)"
APP="$WORK/Nunsseop.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Nunsseop" "$APP/Contents/MacOS/Nunsseop"
cp "$BIN_DIR/libNowPlayingHelper.dylib" Resources/nowplaying.pl "$APP/Contents/Resources/"
cp -R Resources/*.lproj Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
# A fixed certificate keeps the code requirement stable, so macOS keeps the Accessibility
# permission across updates. Without it, sign ad hoc.
IDENTITY="${CODESIGN_IDENTITY:-Nunsseop Code Signing}"
security find-certificate -c "$IDENTITY" >/dev/null 2>&1 || IDENTITY="-"
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/libNowPlayingHelper.dylib" >/dev/null
codesign --force --sign "$IDENTITY" "$APP" >/dev/null
rm -rf build/Nunsseop.app
mkdir -p build
ditto "$APP" build/Nunsseop.app
rm -rf "$WORK"
echo build/Nunsseop.app
