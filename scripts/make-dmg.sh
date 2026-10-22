#!/bin/bash
# Builds a release app and packages it as build/Nunsseop-<version>.dmg. An app signed with a Developer ID is notarized
# and stapled, and so is the DMG.
#
#   scripts/make-dmg.sh                  build, notarize, package
#   scripts/make-dmg.sh --check-notary   only check that Apple accepts the notarization credentials
#
# Notarization uses an App Store Connect API key when NOTARY_KEY (the .p8 file), NOTARY_KEY_ID and NOTARY_ISSUER are
# set, in the environment or in ~/.config/nunsseop/notary.env (override with NUNSSEOP_NOTARY_ENV); otherwise the
# notarytool credentials saved under the keychain profile $NOTARY_PROFILE (default "nunsseop").
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_ENV="${NUNSSEOP_NOTARY_ENV:-$HOME/.config/nunsseop/notary.env}"
# shellcheck source=/dev/null
[[ -f "$NOTARY_ENV" ]] && source "$NOTARY_ENV"
if [[ -n "${NOTARY_KEY:-}" ]]; then
    [[ -r "$NOTARY_KEY" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]] \
        || { echo "NOTARY_KEY needs a readable .p8 file, NOTARY_KEY_ID and NOTARY_ISSUER" >&2; exit 1; }
    AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
    AUTH=(--keychain-profile "${NOTARY_PROFILE:-nunsseop}")
fi
if [[ "${1:-}" == --check-notary ]]; then
    xcrun notarytool history "${AUTH[@]}" >/dev/null || { echo "Apple doesn't accept the notarization credentials (${AUTH[*]:0:2})" >&2; exit 1; }
    exit 0
fi

./scripts/bundle.sh release >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DEVELOPER_ID="$(codesign -dvv build/Nunsseop.app 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)"
[[ -z "${NUNSSEOP_RELEASE:-}" || -n "$DEVELOPER_ID" ]] || { echo "A release must be signed with a Developer ID and notarized" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Waits for Apple's answer; anything but Accepted prints the log and stops.
notarize() {
    xcrun notarytool submit "$1" "${AUTH[@]}" --wait --timeout 2h --output-format json >"$WORK/submit.json" \
        || { cat "$WORK/submit.json" >&2; echo "Notarization of $1 failed or timed out" >&2; exit 1; }
    local status id
    status="$(plutil -extract status raw "$WORK/submit.json" 2>/dev/null || true)"
    id="$(plutil -extract id raw "$WORK/submit.json" 2>/dev/null || true)"
    if [[ "$status" != "Accepted" ]]; then
        [[ -n "$id" ]] && xcrun notarytool log "$id" "${AUTH[@]}" >&2
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
ditto build/Nunsseop.app "$STAGE/Nunsseop.app"
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
