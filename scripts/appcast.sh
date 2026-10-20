#!/bin/bash
# Signs a finished DMG for Sparkle and writes the signed feed that offers it. Uploads nothing.
#
#   scripts/appcast.sh <dmg> <version> <build> <notes-file> <out> [base-url]
#
# The EdDSA key is the one in the login keychain (generate_keys made it), or the file $SPARKLE_ED_KEY_FILE.
set -euo pipefail
DMG="${1:?usage: scripts/appcast.sh <dmg> <version> <build> <notes-file> <out> [base-url]}"
VERSION="${2:?}" BUILD="${3:?}" NOTES="${4:?}" OUT="${5:?}"
BASE="${6:-https://github.com/namekun/Nunsseop/releases/download/v$VERSION}"
cd "$(dirname "$0")/.."

TOOLS=.build/artifacts/sparkle/Sparkle/bin
swift package resolve >/dev/null
[[ -x "$TOOLS/sign_update" ]] || { echo "Sparkle's sign_update is not in $TOOLS" >&2; exit 1; }
KEY=()
[[ -n "${SPARKLE_ED_KEY_FILE:-}" ]] && KEY=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
sign() { "$TOOLS/sign_update" ${KEY[@]+"${KEY[@]}"} "$@"; }

# After make-dmg.sh: stapling changes the DMG's bytes, and the signature is of the bytes users download.
SIGNATURE="$(sign -p "$DMG")"
LENGTH="$(stat -f %z "$DMG")"
URL="$BASE/$(basename "$DMG")"
python3 -I scripts/appcast.py render --version "$VERSION" --build "$BUILD" --url "$URL" --length "$LENGTH" \
    --signature "$SIGNATURE" --notes "$NOTES" --min-os "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)" \
    --out "$OUT"
# Info.plist asks for a signed feed (SURequireSignedFeed): sign_update puts the signature into the file.
sign --disable-signing-warning "$OUT" >/dev/null
sign --verify "$OUT" >/dev/null || { echo "The feed's signature doesn't verify" >&2; exit 1; }
sign --verify "$DMG" "$SIGNATURE" >/dev/null || { echo "The DMG's signature doesn't verify" >&2; exit 1; }
python3 -I scripts/appcast.py check "$OUT" --version "$VERSION" --build "$BUILD" --url "$URL" --length "$LENGTH" --signature "$SIGNATURE"
echo "$OUT"
