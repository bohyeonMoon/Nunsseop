#!/bin/bash
# Checks the DMG that is about to ship: the app inside has this version, runs on Apple silicon and Intel,
# has an intact signature, and starts, natively and as Intel under Rosetta. Starting it quits a running Nunsseop
# and reopens it afterwards. Without Rosetta the Intel start is skipped, unless REQUIRE_INTEL=1 (as in CI).
#
#   scripts/check-dmg.sh build/Nunsseop-<version>.dmg <version>
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:?usage: scripts/check-dmg.sh <dmg> <version>}"
VERSION="${2:?usage: scripts/check-dmg.sh <dmg> <version>}"
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

step "Version $VERSION"
SHIPPED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$SHIPPED" == "$VERSION" ]] || fail "The app says $SHIPPED"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "io.github.namekun.Nunsseop" ]] \
    || fail "Unexpected bundle identifier"

step "Apple silicon and Intel"
for binary in Contents/MacOS/Nunsseop Contents/Resources/libNowPlayingHelper.dylib; do
    lipo "$APP/$binary" -verify_arch arm64 x86_64 || fail "$binary is $(lipo -archs "$APP/$binary") only"
done

step "Signature"
codesign --verify --deep --strict "$APP" || fail "Signature is broken"

step "Resources"
for item in Contents/Resources/nowplaying.pl Contents/Resources/AppIcon.icns Contents/Resources/en.lproj Contents/Resources/ko.lproj; do
    [[ -e "$APP/$item" ]] || fail "Missing $item"
done

if pgrep -x Nunsseop >/dev/null; then
    RUNNING=1
    osascript -e 'quit app "Nunsseop"' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -x Nunsseop >/dev/null || break; sleep 0.25; done
    pkill -x Nunsseop 2>/dev/null || true
fi
ditto "$APP" "$WORK/Nunsseop.app"

# Starts the copied app with the given prefix (empty, or arch -x86_64) and checks it stays up and answers.
starts() {
    "$@" "$WORK/Nunsseop.app/Contents/MacOS/Nunsseop" >"$WORK/run.log" 2>&1 &
    local pid=$!
    sleep 6
    kill -0 "$pid" 2>/dev/null || { tail -20 "$WORK/run.log" >&2; fail "It quit within 6 seconds"; }
    if [[ "${1:-}" == arch ]]; then
        # P_TRANSLATED: the process really runs the Intel code, under Rosetta.
        (( 0x$(ps -o flags= -p "$pid" | tr -d ' ') & 0x20000 )) || fail "It didn't run as Intel"
    fi
    # No token: the server is up and refuses it.
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 -X POST http://127.0.0.1:47750/notify -d '{}' || true)"
    kill "$pid"; wait "$pid" 2>/dev/null || true
    [[ "$code" == "401" ]] || fail "The local port answered '$code' instead of 401"
    for _ in $(seq 1 20); do curl -s -o /dev/null -m 1 http://127.0.0.1:47750/ || break; sleep 0.25; done
}

step "It starts and answers on its local port"
starts

if arch -x86_64 /usr/bin/true 2>/dev/null; then
    step "It starts as Intel, under Rosetta"
    starts arch -x86_64
elif [[ "${REQUIRE_INTEL:-0}" == 1 ]]; then
    fail "Rosetta isn't installed, so the Intel start can't be checked"
else
    echo "  Skipped the Intel start: Rosetta isn't installed here (CI checks it)" >&2
fi

echo "✔ $DMG is ready to ship" >&2
