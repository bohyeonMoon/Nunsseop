#!/bin/bash
# Checks the DMG that is about to ship: the app inside has this version (and build), runs on Apple silicon, has an intact
# signature, carries Sparkle as releases need it, and starts. Starting it quits a running Nunsseop and reopens it afterwards.
# With NUNSSEOP_RELEASE set (release.sh sets it), the app must be signed with a Developer ID and notarized.
#
#   scripts/check-dmg.sh build/Nunsseop-<version>.dmg <version> [<build>]
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:?usage: scripts/check-dmg.sh <dmg> <version>}"
VERSION="${2:?usage: scripts/check-dmg.sh <dmg> <version>}"
BUILD="${3:-}"
step() { echo "▸ $*" >&2; }
fail() { echo "✘ $*" >&2; exit 1; }

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
RUNNING=0
cleanup() {
    pkill -f "$WORK/Nunsseop.app/Contents/MacOS/Nunsseop" 2>/dev/null || true
    hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
    rm -rf "$WORK"
    if (( RUNNING )); then open -a /Applications/Nunsseop.app || true; fi
}
trap cleanup EXIT

step "Mount"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
APP="$MOUNT/Nunsseop.app"
[[ -d "$APP" ]] || fail "No Nunsseop.app in the DMG"
[[ -L "$MOUNT/Applications" ]] || fail "No Applications link in the DMG"
FW="$APP/Contents/Frameworks/Sparkle.framework"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }

step "Version $VERSION"
SHIPPED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$SHIPPED" == "$VERSION" ]] || fail "The app says $SHIPPED"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "io.github.namekun.Nunsseop" ]] \
    || fail "Unexpected bundle identifier"
# Sparkle compares builds, so they must be plain, increasing numbers.
[[ "$(plist CFBundleVersion)" =~ ^[1-9][0-9]*$ ]] || fail "The build '$(plist CFBundleVersion)' isn't a plain number"
[[ -z "$BUILD" || "$(plist CFBundleVersion)" == "$BUILD" ]] || fail "The app's build is $(plist CFBundleVersion), expected $BUILD"

step "Apple silicon"
for binary in Contents/MacOS/Nunsseop Contents/Resources/libNowPlayingHelper.dylib; do
    lipo "$APP/$binary" -verify_arch arm64 || fail "$binary is $(lipo -archs "$APP/$binary")"
done

step "Signature"
codesign --verify --deep --strict "$APP" || fail "Signature is broken"
# Read into a variable first: `grep -q` stops reading at the first match, and under pipefail codesign's broken pipe fails the check.
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
grep -Eq "flags=.*[(,]runtime[),]" <<<"$SIGNATURE" || fail "The app isn't signed with the hardened runtime"
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
for key in automation.apple-events device.camera device.audio-input personal-information.calendars; do
    grep -q "com.apple.security.$key" <<<"$ENTITLEMENTS" || fail "The app lacks the $key entitlement"
done
DEVELOPER_ID=0
grep -q "^Authority=Developer ID Application:" <<<"$SIGNATURE" && DEVELOPER_ID=1
[[ -z "${NUNSSEOP_RELEASE:-}" ]] || (( DEVELOPER_ID )) || fail "A release must be signed with a Developer ID"
TEAM="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGNATURE")"
# Copies replace themselves only with the release team's builds (UpdateMethod.releaseTeam).
RELEASE_TEAM="$(sed -n 's/.*static let releaseTeam = "\(.*\)"/\1/p' Sources/Nunsseop/UpdateMethod.swift)"
[[ -z "${NUNSSEOP_RELEASE:-}" || "$TEAM" == "$RELEASE_TEAM" ]] || fail "A release must be signed by team $RELEASE_TEAM, not '$TEAM'"
# Every piece of code, Sparkle's included, signed as the app is: the same team, the hardened runtime, and for a Developer ID
# the certificate and a secure timestamp. Code of another team is refused at launch, and Sparkle won't install an update
# whose Autoupdate is signed by someone else.
while IFS= read -r -d '' file; do
    [[ "$(file -b "$file")" == Mach-O* ]] || continue
    NESTED="$(codesign -dvv "$file" 2>&1)" || fail "${file#"$APP"/} isn't signed"
    grep -Eq "flags=.*[(,]runtime[),]" <<<"$NESTED" || fail "${file#"$APP"/} isn't signed with the hardened runtime"
    [[ "$(sed -n 's/^TeamIdentifier=//p' <<<"$NESTED")" == "$TEAM" ]] || fail "${file#"$APP"/} isn't signed by the app's team ($TEAM)"
    if (( DEVELOPER_ID )); then
        grep -q "^Authority=Developer ID Application:" <<<"$NESTED" || fail "${file#"$APP"/} isn't signed with the Developer ID"
        grep -q "^Timestamp=" <<<"$NESTED" || fail "${file#"$APP"/} has no secure timestamp"
    fi
done < <(find "$APP" -type f -print0)
# Only a build without a team needs this to load Sparkle; a release keeps library validation.
if (( DEVELOPER_ID )) && grep -q "disable-library-validation" <<<"$ENTITLEMENTS"; then
    fail "A Developer ID build must not disable library validation"
fi

# Signed with a Developer ID, it must be notarized, the app and the DMG each with its ticket.
if (( DEVELOPER_ID )); then
    step "Notarized"
    spctl --assess --type execute "$APP" 2>/dev/null || fail "Gatekeeper rejects the app"
    xcrun stapler validate -q "$APP" || fail "The app has no notarization ticket"
    xcrun stapler validate -q "$DMG" || fail "The DMG has no notarization ticket"
    spctl --assess --type open --context context:primary-signature "$DMG" 2>/dev/null || fail "Gatekeeper rejects the DMG"
fi

step "Sparkle"
for item in Versions/B/Sparkle Versions/B/Autoupdate Versions/B/Updater.app; do
    [[ -e "$FW/$item" ]] || fail "Sparkle.framework lacks $item"
done
[[ -L "$FW/Versions/Current" && -L "$FW/Sparkle" ]] || fail "Sparkle.framework lost its symlinks"
[[ ! -e "$FW/Versions/B/XPCServices" && ! -e "$FW/XPCServices" ]] || fail "Sparkle's XPC services are for sandboxed apps"
LOADS="$(otool -l "$APP/Contents/MacOS/Nunsseop")"
grep -q "@executable_path/../Frameworks" <<<"$LOADS" || fail "The app can't find Contents/Frameworks"
repo() { /usr/libexec/PlistBuddy -c "Print :$1" Resources/Info.plist; }
[[ "$(plist SUFeedURL)" == "$(repo SUFeedURL)" ]] || fail "SUFeedURL is '$(plist SUFeedURL)'"
[[ "$(plist SUPublicEDKey)" == "$(repo SUPublicEDKey)" && "$(base64 -D <<<"$(plist SUPublicEDKey)" | wc -c | tr -d ' ')" == 32 ]] \
    || fail "SUPublicEDKey isn't the repository's 32 byte key"
[[ "$(plist SURequireSignedFeed)" == true && "$(plist SUVerifyUpdateBeforeExtraction)" == true ]] || fail "Sparkle's signature checks are off"
[[ "$(plist SUEnableAutomaticChecks)" == false ]] || fail "Sparkle's own scheduled checks are on"
[[ -z "$(plist NunsseopUpdaterAnywhere)" ]] || fail "The test-only NunsseopUpdaterAnywhere key is in the app"
# The Team ID the app reads from its own signature, which decides whether it updates itself (UpdateMethod).
READ="$("$APP/Contents/MacOS/Nunsseop" --print-update-team)"
[[ "$READ" == "${TEAM/#not set/none}" ]] || fail "The app reads its team as '$READ', its signature says '$TEAM'"

step "Resources"
for item in Contents/Resources/nowplaying.pl Contents/Resources/AppIcon.icns Contents/Resources/en.lproj Contents/Resources/ko.lproj \
            Contents/Resources/muxy-bridge/package.json Contents/Resources/muxy-bridge/background.js Contents/Resources/muxy-bridge/helper.html Contents/Resources/muxy-bridge/helper.js; do
    [[ -e "$APP/$item" ]] || fail "Missing $item"
done

step "It starts and answers on its local port"
if pgrep -x Nunsseop >/dev/null; then
    RUNNING=1
    osascript -e 'quit app "Nunsseop"' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -x Nunsseop >/dev/null || break; sleep 0.25; done
    pkill -x Nunsseop 2>/dev/null || true
fi
ditto "$APP" "$WORK/Nunsseop.app"
"$WORK/Nunsseop.app/Contents/MacOS/Nunsseop" >"$WORK/run.log" 2>&1 &
PID=$!
sleep 6
kill -0 "$PID" 2>/dev/null || { tail -20 "$WORK/run.log" >&2; fail "It quit within 6 seconds"; }
# No token: the server is up and refuses it.
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 2 -X POST http://127.0.0.1:47750/notify -d '{}' || true)"
[[ "$CODE" == "401" ]] || fail "The local port answered '$CODE' instead of 401"
kill "$PID"; wait "$PID" 2>/dev/null || true

echo "✔ $DMG is ready to ship" >&2
