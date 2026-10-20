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
xattr -cr "$APP"
# A fixed certificate keeps the code requirement stable, so macOS keeps the Accessibility permission across updates:
# a Developer ID one when the keychain has it (releases signed with it are notarized, see make-dmg.sh), else the local
# "Nunsseop Code Signing". Without either, sign ad hoc.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:-Nunsseop Code Signing}"
security find-certificate -c "$IDENTITY" >/dev/null 2>&1 || IDENTITY="-"
# The hardened runtime, which notarization requires, everywhere, so every build behaves like a release. A notarized
# release also needs a secure timestamp, which takes a trip to Apple.
FLAGS=(--force --options runtime --sign "$IDENTITY")
[[ "$CONFIG" == release && "$IDENTITY" != "-" ]] && FLAGS+=(--timestamp)
codesign "${FLAGS[@]}" "$APP/Contents/Resources/libNowPlayingHelper.dylib" >/dev/null
codesign "${FLAGS[@]}" --entitlements Resources/Nunsseop.entitlements "$APP" >/dev/null
rm -rf build/Nunsseop.app
mkdir -p build
ditto "$APP" build/Nunsseop.app
rm -rf "$WORK"
echo build/Nunsseop.app
