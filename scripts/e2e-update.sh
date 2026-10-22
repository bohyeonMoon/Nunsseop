#!/bin/bash
# Proves that a copy installed from the DMG replaces itself with the next version, without a click: two copies of this
# build (N and N+1) under a test bundle ID, signed ad hoc, a throwaway EdDSA key, the release scripts' own appcast.sh and
# a local feed served the way GitHub serves releases. N checks, downloads and prepares N+1, and installs it when it quits.
#
#   scripts/e2e-update.sh [--developer-id]
#
# With --developer-id, both are signed with the Developer ID and N is installed under ~/Applications, so the release's
# own rules (UpdateMethod) turn Sparkle on and its same-team checks run; otherwise a test-only Info.plist key lets ad hoc
# copies in a temporary folder update. It quits a running Nunsseop and reopens it afterwards (like check-dmg.sh), and
# fails, keeping a copy of them from before, if the settings of other tools or Nunsseop's own files changed. Not proved here:
# notarization and GitHub itself; the first releases with Sparkle show those.
set -euo pipefail
cd "$(dirname "$0")/.."
step() { echo "▸ $*" >&2; }
fail() { echo "✘ $*" >&2; exit 1; }

ID=io.github.namekun.Nunsseop.e2e
E2E="$(mktemp -d)"
DEVELOPER_ID=0
case "${1:-}" in
    "") ;;
    --developer-id) DEVELOPER_ID=1 ;;
    *) echo "usage: scripts/e2e-update.sh [--developer-id]" >&2; exit 2 ;;
esac
# N's folder: under ~/Applications for the release's rules, else the temporary folder.
INSTALL="$E2E/old"
(( DEVELOPER_ID )) && INSTALL="$HOME/Applications/Nunsseop-e2e-$(basename "$E2E")"
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
WATCHED=("$HOME/.claude/settings.json" "$HOME/.codex/config.toml" "$HOME/.codex/hooks.json" "$HOME/.gemini/settings.json"
         "$HOME/Library/Application Support/Nunsseop")
RUNNING=0
fingerprint() {
    for path in "${WATCHED[@]}"; do
        [[ -e "$path" ]] || { echo "absent $path"; continue; }
        find "$path" -type f -print0 | sort -z | xargs -0 shasum
    done
}
cleanup() {
    # Only this run's processes, by their full path: the real Nunsseop is never matched.
    pkill -f "$E2E/" 2>/dev/null || true
    pkill -f "$INSTALL/" 2>/dev/null || true
    defaults delete "$ID" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" "$E2E"
    [[ "$INSTALL" == "$E2E/old" ]] || rm -rf "$INSTALL"
    if (( RUNNING )); then open -a /Applications/Nunsseop.app || true; fi
}
trap cleanup EXIT

step "Quit Nunsseop for the run"
if pgrep -x Nunsseop >/dev/null; then
    RUNNING=1
    osascript -e 'quit app "Nunsseop"' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -x Nunsseop >/dev/null || break; sleep 0.25; done
    pgrep -x Nunsseop >/dev/null && fail "Nunsseop didn't quit"
fi
mkdir -p "$E2E/backup"
for path in "${WATCHED[@]}"; do [[ -e "$path" ]] && ditto "$path" "$E2E/backup/$(echo "$path" | tr / _)"; done
BEFORE="$(fingerprint)"

step "Build N and N+1"
# Always this source, as a release build: a debug build never updates itself.
CODESIGN_IDENTITY=- ./scripts/bundle.sh release >/dev/null
KEY_PUBLIC="$(swift scripts/e2e/genkey.swift "$E2E/key")"
chmod 600 "$E2E/key"
variant() { # <folder> <build> <version> [anywhere]
    ditto build/Nunsseop.app "$1/Nunsseop.app"
    # The build folder may sync (iCloud Desktop) and add Finder info, which a signature refuses.
    xattr -cr "$1/Nunsseop.app"
    local info="$1/Nunsseop.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleVersion $2" -c "Set :CFBundleShortVersionString $3" \
        -c "Set :SUFeedURL http://127.0.0.1:$PORT/appcast.xml" -c "Set :SUPublicEDKey $KEY_PUBLIC" \
        -c "Set :SUEnableAutomaticChecks true" -c "Add :SUAutomaticallyUpdate bool true" "$info"
    if (( DEVELOPER_ID )); then
        ./scripts/sign-app.sh "$1/Nunsseop.app"
    else
        [[ -n "${4:-}" ]] && /usr/libexec/PlistBuddy -c "Add :NunsseopUpdaterAnywhere bool true" "$info"
        CODESIGN_IDENTITY=- ./scripts/sign-app.sh "$1/Nunsseop.app" release
    fi
}
variant "$INSTALL" 9001 0.0.1 anywhere
variant "$E2E/new" 9002 0.0.2 anywhere
variant "$E2E/gated" 9001 0.0.1
if (( DEVELOPER_ID )); then
    [[ "$(codesign -dvv "$INSTALL/Nunsseop.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')" != "not set" ]] || fail "No Developer ID to sign with"
fi

step "Sign N+1 and its feed"
mkdir -p "$E2E/stage" "$E2E/files"
ditto "$E2E/new/Nunsseop.app" "$E2E/stage/Nunsseop.app"
ln -s /Applications "$E2E/stage/Applications"
# hdiutil has hung here once (macOS 27, where it is deprecated): give it two minutes, then end it, its helper included,
# and try again. Its own volume name keeps it clear of a "Nunsseop" DMG someone left mounted.
image() {
    hdiutil create -quiet -volname "Nunsseop E2E" -srcfolder "$E2E/stage" -ov -format UDZO "$E2E/files/Nunsseop-0.0.2.dmg" 2>/dev/null &
    local pid=$!
    for _ in $(seq 1 240); do kill -0 "$pid" 2>/dev/null || { wait "$pid"; return; }; sleep 0.5; done
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
}
image || image || fail "hdiutil couldn't make the update's DMG"
printf 'A test update.\n' >"$E2E/notes.md"
SPARKLE_ED_KEY_FILE="$E2E/key" ./scripts/appcast.sh "$E2E/files/Nunsseop-0.0.2.dmg" 0.0.2 9002 "$E2E/notes.md" \
    "$E2E/files/appcast.xml" "http://127.0.0.1:$PORT/files" >/dev/null
python3 -I scripts/e2e/feed.py "$PORT" "$E2E/files" "$E2E/feed.log" &
disown
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/files/appcast.xml" && break; sleep 0.1; done
: >"$E2E/feed.log"

# The test domain starts with Nunsseop's notifications off, so it doesn't touch the hooks of other tools.
defaults write "$ID" localNotifications -bool false

step "A copy outside the release's rules leaves Sparkle alone"
"$E2E/gated/Nunsseop.app/Contents/MacOS/Nunsseop" >"$E2E/gated.log" 2>&1 &
GATED=$!
sleep 15
kill -0 "$GATED" 2>/dev/null || { tail -20 "$E2E/gated.log" >&2; fail "The gated copy quit"; }
kill "$GATED"; wait "$GATED" 2>/dev/null || true
[[ ! -s "$E2E/feed.log" ]] || fail "The gated copy asked the feed: $(tr '\n' ' ' <"$E2E/feed.log")"

step "N finds, downloads and prepares N+1"
"$INSTALL/Nunsseop.app/Contents/MacOS/Nunsseop" >"$E2E/old.log" 2>&1 &
OLD=$!
for _ in $(seq 1 180); do grep -q "GET /files/Nunsseop-0.0.2.dmg" "$E2E/feed.log" && break; sleep 0.5; done
grep -q "GET /appcast.xml" "$E2E/feed.log" || fail "N never asked for the feed"
grep -q "GET /files/Nunsseop-0.0.2.dmg" "$E2E/feed.log" || fail "N never downloaded N+1: $(tr '\n' ' ' <"$E2E/feed.log")"
# Sparkle verifies the download and readies its installer before it installs on quit.
for _ in $(seq 1 60); do pgrep -f "Caches/$ID" >/dev/null && break; sleep 0.5; done
sleep 5
kill -0 "$OLD" 2>/dev/null || { tail -20 "$E2E/old.log" >&2; fail "N quit on its own"; }

step "N quits and N+1 takes its place"
kill -TERM "$OLD"; wait "$OLD" 2>/dev/null || true
INFO="$INSTALL/Nunsseop.app/Contents/Info.plist"
for _ in $(seq 1 120); do [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO" 2>/dev/null)" == 9002 ]] && break; sleep 0.5; done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" == 9002 ]] || fail "N wasn't replaced (build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO"))"
codesign --verify --deep --strict "$INSTALL/Nunsseop.app" || fail "The installed N+1's signature is broken"
"$INSTALL/Nunsseop.app/Contents/MacOS/Nunsseop" --print-update-team >/dev/null || fail "The installed N+1 doesn't start"
UNEXPECTED="$(grep -vE '^GET /(appcast.xml|files/appcast.xml|files/Nunsseop-0.0.2.dmg)$' "$E2E/feed.log" || true)"
[[ -z "$UNEXPECTED" ]] || fail "Unexpected requests to the feed: $UNEXPECTED"

step "Nothing else changed"
pkill -f "$E2E/" 2>/dev/null || true
pkill -f "$INSTALL/" 2>/dev/null || true
sleep 1
if [[ "$(fingerprint)" != "$BEFORE" ]]; then
    diff <(echo "$BEFORE") <(fingerprint) >&2 || true
    # Not put back: something else may have changed them meanwhile, such as Claude Code its own settings.
    KEPT="$(mktemp -d "${TMPDIR:-/tmp}/nunsseop-e2e-before.XXXXXX")"
    ditto "$E2E/backup" "$KEPT"
    fail "Files of other tools or of Nunsseop changed during the run; their copies from before are in $KEPT"
fi
echo "✔ A DMG install updated itself from 0.0.1 (9001) to 0.0.2 (9002)" >&2
