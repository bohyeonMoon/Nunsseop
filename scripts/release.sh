#!/bin/bash
# Releases a new version: runs every check (scripts/preflight.sh), bumps the version, builds the DMG and checks
# it (scripts/check-dmg.sh), signs it and its Sparkle feed (scripts/appcast.sh), and only then commits, tags, publishes
# the GitHub release, checks what GitHub serves and updates the Homebrew tap.
#
#   scripts/release.sh <version> [notes-file]
#
# Notes come from the file, or from $EDITOR when no file is given. The tap repo is expected at
# ../homebrew-tap (override with TAP_DIR).
set -euo pipefail
cd "$(dirname "$0")/.."
# sign-app.sh, make-dmg.sh and check-dmg.sh then accept nothing but a Developer ID, notarized.
export NUNSSEOP_RELEASE=1
# A release is signed with the keychain's key, the one checked below, never a test key file (see appcast.sh).
unset SPARKLE_ED_KEY_FILE

VERSION="${1:?usage: scripts/release.sh <version> [notes-file]}"
NOTES_FILE="${2:-}"
TAP_DIR="${TAP_DIR:-../homebrew-tap}"
CASK="$TAP_DIR/Casks/nunsseop.rb"
PLIST="Resources/Info.plist"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3" >&2; exit 1; }
[[ "$(git branch --show-current)" == "main" ]] || { echo "Release from main" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree is not clean" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "v$VERSION already exists" >&2; exit 1; }
[[ -f "$CASK" ]] || { echo "Homebrew tap not found at $TAP_DIR" >&2; exit 1; }

if [[ -z "$NOTES_FILE" ]]; then
    NOTES_FILE="$(mktemp)"
    "${EDITOR:-vi}" "$NOTES_FILE"
fi
[[ -s "$NOTES_FILE" ]] || { echo "Release notes are empty" >&2; exit 1; }

# Copies installed from the DMG accept only updates signed with the key whose public half is in Info.plist. -p only
# prints it: without arguments generate_keys would make a new key if the keychain had none.
swift package resolve >/dev/null
KEY="$(.build/artifacts/sparkle/Sparkle/bin/generate_keys -p 2>&1 || true)"
[[ "$KEY" == "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")" ]] \
    || { echo "The keychain's Sparkle key isn't the SUPublicEDKey in $PLIST, so copies would refuse this update (generate_keys said: $KEY)" >&2; exit 1; }

# The build to give this release: above anything ever shipped, betas included, since Sparkle compares builds. The feed
# follows GitHub's latest release, so a release published another way, such as a beta, must be a pre-release.
# Read into a variable first: a grep that stops early under pipefail would fail the loop feeding it.
SHIPPED="$(git tag -l 'v*' | while read -r tag; do git show "$tag:$PLIST"; done)"
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST")"
FEED="$(mktemp)"
CODE="$(curl -sL -m 30 -o "$FEED" -w '%{http_code}' "$FEED_URL" || true)"
if [[ "$CODE" == 200 ]]; then
    FEED_BUILD="$(python3 -I scripts/appcast.py max-build "$FEED")"
elif [[ "$CODE" == 404 ]] && ! grep -q SUFeedURL <<<"$SHIPPED"; then
    FEED_BUILD=0   # no release has had a feed yet
else
    echo "The published feed $FEED_URL answered '$CODE'; copies installed from the DMG can't see updates" >&2
    exit 1
fi
TAG_BUILD="$(git tag -l 'v*' | while read -r tag; do git show "$tag:$PLIST" | plutil -extract CFBundleVersion raw -o - - 2>/dev/null; echo; done \
    | grep -E '^[0-9]+$' | sort -n | tail -1)"

./scripts/preflight.sh

# Until the version commit is pushed, a failure puts the bumped files back.
PUSHED=0
trap '(( PUSHED )) || git checkout -q -- "$PLIST" docs/index.html' EXIT

OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUILD="$(( $(printf '%s\n' "$PLIST_BUILD" "$FEED_BUILD" "${TAG_BUILD:-0}" | sort -n | tail -1) + 1 ))"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
sed -i '' "s|<b>v$OLD_VERSION</b>|<b>v$VERSION</b>|" docs/index.html
grep -q "<b>v$VERSION</b>" docs/index.html || { echo "The site's version badge wasn't updated" >&2; exit 1; }

DMG="$(./scripts/make-dmg.sh)"
./scripts/check-dmg.sh "$DMG" "$VERSION" "$BUILD"
./scripts/appcast.sh "$DMG" "$VERSION" "$BUILD" "$NOTES_FILE" build/appcast.xml >/dev/null

git add "$PLIST" docs/index.html
git commit -q -m "Version $VERSION"
git tag "v$VERSION"
git push -q origin main "v$VERSION"
PUSHED=1

# Also under a name without the version, which the site's download button finds at releases/latest/download/Nunsseop.dmg.
cp "$DMG" build/Nunsseop.dmg
# A draft first: what GitHub stored must be what was signed before anyone, Sparkle included, can see it.
gh release create "v$VERSION" "$DMG" build/Nunsseop.dmg build/appcast.xml --title "v$VERSION" --notes-file "$NOTES_FILE" --draft
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
STORED="$(mktemp -d)"
gh release download "v$VERSION" --dir "$STORED" --pattern appcast.xml --pattern "$(basename "$DMG")"
cmp -s "$STORED/appcast.xml" build/appcast.xml && [[ "$(shasum -a 256 "$STORED/$(basename "$DMG")" | cut -d' ' -f1)" == "$SHA" ]] \
    || { echo "The draft release v$VERSION doesn't hold what was signed; delete it (gh release delete v$VERSION) and the tag" >&2; exit 1; }
gh release edit "v$VERSION" --draft=false --latest

# What GitHub serves must be what was signed, before Homebrew points anyone at it. The release's own URLs first;
# they can take a moment to appear.
SERVED="$(mktemp -d)"
for _ in $(seq 1 24); do
    curl -fsL -m 60 -o "$SERVED/appcast.xml" "https://github.com/namekun/Nunsseop/releases/download/v$VERSION/appcast.xml" \
        && curl -fsL -m 300 -o "$SERVED/dmg" "https://github.com/namekun/Nunsseop/releases/download/v$VERSION/$(basename "$DMG")" && break
    sleep 5
done
ROLLBACK="mark the release a draft again (gh release edit v$VERSION --draft=true) so copies keep the previous feed"
cmp -s "$SERVED/appcast.xml" build/appcast.xml || { echo "The published appcast.xml isn't the one signed; $ROLLBACK" >&2; exit 1; }
[[ "$(shasum -a 256 "$SERVED/dmg" | cut -d' ' -f1)" == "$SHA" ]] || { echo "The published DMG isn't the one signed; $ROLLBACK" >&2; exit 1; }
git -C "$TAP_DIR" pull -q --ff-only
sed -i '' -e "s/version \"[0-9.]*\"/version \"$VERSION\"/" -e "s/sha256 \"[0-9a-f]*\"/sha256 \"$SHA\"/" "$CASK"
grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$SHA\"" "$CASK" \
    || { echo "The cask wasn't updated; fix $CASK by hand" >&2; exit 1; }
git -C "$TAP_DIR" commit -qam "nunsseop $VERSION"
git -C "$TAP_DIR" push -q

# The address built into the app follows "latest", which can lag behind; a warning, since the release is out.
for _ in $(seq 1 36); do
    curl -fsL -m 30 -o "$SERVED/latest.xml" "$FEED_URL" && cmp -s "$SERVED/latest.xml" build/appcast.xml && break
    sleep 5
done
cmp -s "$SERVED/latest.xml" build/appcast.xml || echo "⚠ $FEED_URL doesn't serve this release's feed yet; check it" >&2
echo "Released v$VERSION, build $BUILD ($DMG, sha256 $SHA)"
