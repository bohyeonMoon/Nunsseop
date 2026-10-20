#!/bin/bash
# Builds a release app and packages it as build/Nunsseop-<version>.dmg. An app signed with a Developer ID is notarized
# and stapled, and so is the DMG, with the notarytool credentials saved under the profile $NOTARY_PROFILE (default
# "nunsseop"; see `xcrun notarytool store-credentials`).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh release >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DEVELOPER_ID="$(codesign -dvv build/Nunsseop.app 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)"
PROFILE="${NOTARY_PROFILE:-nunsseop}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Waits for Apple's answer; anything but Accepted prints the log and stops.
notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --timeout 2h --output-format json >"$WORK/submit.json" \
        || { cat "$WORK/submit.json" >&2; echo "Notarization of $1 failed or timed out (profile '$PROFILE')" >&2; exit 1; }
    local status id
    status="$(plutil -extract status raw "$WORK/submit.json" 2>/dev/null || true)"
    id="$(plutil -extract id raw "$WORK/submit.json" 2>/dev/null || true)"
    if [[ "$status" != "Accepted" ]]; then
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
        echo "Notarization of $1: ${status:-no answer}" >&2
        exit 1
    fi
}

# The app gets its own ticket, so it opens offline once it has left the DMG (Homebrew copies it out).
if [[ -n "$DEVELOPER_ID" ]]; then
    ditto -c -k --keepParent build/Nunsseop.app "$WORK/Nunsseop.zip"
    notarize "$WORK/Nunsseop.zip"
    xcrun stapler staple -q build/Nunsseop.app >&2
fi

STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R build/Nunsseop.app "$STAGE/"
xattr -cr "$STAGE/Nunsseop.app"
codesign --verify --deep --strict "$STAGE/Nunsseop.app"
ln -s /Applications "$STAGE/Applications"
DMG="build/Nunsseop-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Nunsseop" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [[ -n "$DEVELOPER_ID" ]]; then
    codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
    notarize "$DMG"
    xcrun stapler staple -q "$DMG" >&2
fi
echo "$DMG"
