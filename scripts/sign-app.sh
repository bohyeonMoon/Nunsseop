#!/bin/bash
# Signs an assembled Nunsseop.app from the inside out: Sparkle's helpers, the framework, the now-playing helper, the app.
#
#   scripts/sign-app.sh <app> [debug|release]
#
# CODESIGN_IDENTITY picks the identity. With NUNSSEOP_RELEASE set (release.sh sets it), anything but a Developer ID is an error.
set -euo pipefail
APP="${1:?usage: scripts/sign-app.sh <app> [debug|release]}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
CONFIG="${2:-debug}"
cd "$(dirname "$0")/.."

# A fixed certificate keeps the code requirement stable, so macOS keeps the Accessibility permission across updates:
# a Developer ID one when the keychain has it (releases signed with it are notarized, see make-dmg.sh), else the local
# "Nunsseop Code Signing". Without either, sign ad hoc.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:-Nunsseop Code Signing}"
[[ "$IDENTITY" == "-" ]] || security find-certificate -c "$IDENTITY" >/dev/null 2>&1 || IDENTITY="-"
DEVELOPER_ID=0
[[ "$IDENTITY" == "Developer ID Application:"* ]] && DEVELOPER_ID=1
if [[ -n "${NUNSSEOP_RELEASE:-}" ]] && (( ! DEVELOPER_ID )); then
    echo "A release must be signed with a Developer ID Application certificate, not '$IDENTITY'" >&2
    exit 1
fi

# The hardened runtime, which notarization requires, everywhere, so every build behaves like a release. A notarized
# release also needs a secure timestamp, which takes a trip to Apple.
FLAGS=(--force --options runtime --sign "$IDENTITY")
[[ "$CONFIG" == release && "$IDENTITY" != "-" ]] && FLAGS+=(--timestamp)

# Never --deep: each part keeps its own identifier, and Sparkle's helpers get no entitlements.
FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${FLAGS[@]}" "$FW/Versions/B/Autoupdate" >/dev/null
codesign "${FLAGS[@]}" "$FW/Versions/B/Updater.app" >/dev/null
codesign "${FLAGS[@]}" "$FW" >/dev/null
codesign "${FLAGS[@]}" "$APP/Contents/Resources/libNowPlayingHelper.dylib" >/dev/null

ENTITLEMENTS=Resources/Nunsseop.entitlements
if (( ! DEVELOPER_ID )); then
    # Without a Team ID, library validation refuses Sparkle.framework as code of another team. Such a build never
    # updates itself (UpdateMethod), and check-dmg.sh makes sure a Developer ID build doesn't carry this.
    SCRATCH="$(mktemp -d)"
    trap 'rm -rf "$SCRATCH"' EXIT
    ENTITLEMENTS="$SCRATCH/Nunsseop.entitlements"
    cp Resources/Nunsseop.entitlements "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
fi
codesign "${FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$APP" >/dev/null
