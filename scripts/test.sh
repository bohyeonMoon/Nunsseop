#!/bin/bash
# Runs the tests. With only the Command Line Tools selected, SwiftPM can't find Testing.framework
# on its own, so point the compiler and the test runner at it. With Xcode selected (CI), it finds it.
#
#   scripts/test.sh              two passes that never overlap: everything else, then the exhaustive tests
#   scripts/test.sh --filter X   one run, with the arguments passed to `swift test`
#
# The exhaustive tests sweep all of Unicode or draw thousands of glyphs: seconds of CPU on every core, which on a
# three core CI runner starves the tests that wait for a real event with a deadline. They have `exhaustive` at the
# start of their name (and the `.exhaustive` tag; see PermissionTestSupport.swift), and `swift test` can't select by tag.
# CI runs this script, so it runs the same two passes.
set -euo pipefail
cd "$(dirname "$0")/.."

EXHAUSTIVE='/exhaustive'

swift_test() {
    local CLT=/Library/Developer/CommandLineTools/Library/Developer
    if [[ "$(xcode-select -p 2>/dev/null || true)" == /Library/Developer/CommandLineTools && -d "$CLT/Frameworks/Testing.framework" ]]; then
        swift test -Xswiftc -F"$CLT/Frameworks" \
            -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
    else
        swift test "$@"
    fi
}

if (( $# > 0 )); then
    swift_test "$@"
    exit
fi

LOG="$(mktemp -d)"
trap 'rm -rf "$LOG"' EXIT
status=0

# A filter that matches nothing "passes" with 0 tests, so a pass with none is a failure.
run_pass() {
    local name="$1"; shift
    echo "▸ Pass: $name" >&2
    if ! swift_test "$@" 2>&1 | tee "$LOG/$name.txt"; then
        echo "✘ Pass failed: $name" >&2
        status=1
    elif ! grep -qE "Test run with [1-9][0-9]* tests?" "$LOG/$name.txt"; then
        echo "✘ Pass ran no tests: $name" >&2
        status=1
    fi
}

run_pass "everything-else" --skip "$EXHAUSTIVE"
run_pass "exhaustive" --filter "$EXHAUSTIVE"

echo "▸ Summaries" >&2
for name in everything-else exhaustive; do
    echo "$name: $(grep -E 'Test run with' "$LOG/$name.txt" | tail -1)" >&2
done
exit "$status"
