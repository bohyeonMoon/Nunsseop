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
# The Muxy extension the user loads from Nunsseop's own folder (see MuxyBridge.swift).
cp -R Resources/muxy-bridge "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sparkle, for copies installed from the DMG (see UpdateMethod.swift); ditto keeps the framework's symlinks.
FW="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$BIN_DIR/Sparkle.framework" ]] || { echo "No Sparkle.framework in $BIN_DIR" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$FW"
# Its XPC services are for sandboxed apps. Removed before signing: after, it would break the framework's seal.
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"
# SwiftPM doesn't point the executable at Contents/Frameworks. Read into a variable first: under pipefail, grep -q
# stopping early would fail otool with a broken pipe.
LOADS="$(otool -l "$APP/Contents/MacOS/Nunsseop")"
grep -q "@executable_path/../Frameworks" <<<"$LOADS" \
    || install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Nunsseop" 2>/dev/null
xattr -cr "$APP"
./scripts/sign-app.sh "$APP" "$CONFIG"
rm -rf build/Nunsseop.app
mkdir -p build
ditto "$APP" build/Nunsseop.app
rm -rf "$WORK"
echo build/Nunsseop.app
