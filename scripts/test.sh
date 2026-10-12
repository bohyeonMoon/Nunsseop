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
#
# A pass that hangs fails instead: after TEST_PASS_TIMEOUT seconds (600), or at once when the test process has crashed and
# `swift test` waits for a process the tests left behind (see `give_up`).
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
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$LOG"' EXIT
status=0

PASS_TIMEOUT="${TEST_PASS_TIMEOUT:-600}"

# The processes of a pass, but this script and `$2`: those that have the pass's output file open (`swift test`), and those that have the
# other end of its pipes open: the test process, and the stand-ins a test left behind (a Python server, a shell script) that it started
# with its own output.
holders() {
    local pids pipes
    pids="$(lsof -t "$1" 2>/dev/null | grep -vx -e "$$" -e "$2" || true)"
    [[ -n "$pids" ]] || return 0
    echo "$pids"
    pipes="$(lsof -p "$(echo $pids | tr ' ' ,)" 2>/dev/null | awk '$5 == "PIPE" { print $6; if ($9 ~ /^->/) print substr($9, 3) }' | sort -u)"
    [[ -n "$pipes" ]] || return 0
    lsof -n 2>/dev/null | grep -F -f <(echo "$pipes") | awk '{ print $2 }' | sort -u | grep -vx -e "$$" -e "$2" || true
}

# Where the test process crashed, from a crash report: the frames of the thread that crashed.
crash_frames() {
    python3 -I -c '
import json, sys
body = json.loads(open(sys.argv[1]).read().split("\n", 1)[1])
print(*(frame.get("symbol", "?")[:150] for frame in body["threads"][body["faultingThread"]]["frames"][:10]), sep="\n")' "$1" 2>/dev/null || true
}

# Says where a pass stands, then ends it with everything that holds its output: the processes by their command, a stack sample of the
# test process if it is still there and, if it crashed, where.
give_up() {
    local name="$1" why="$2" tail_pid="$3" pid report victims
    printf '\n✘ Pass %s: %s\n' "$name" "$why" >&2
    victims="$(holders "$LOG/$name.txt" "$tail_pid")"
    for pid in $victims; do
        ps -o pid=,ppid=,stat=,etime=,command= -p "$pid" | cut -c1-200 >&2 || true
        case "$(ps -o command= -p "$pid" 2>/dev/null)" in
            *swiftpm-testing-helper*|*xctest*)
                sample "$pid" 3 -file "$LOG/$name.sample.txt" >/dev/null 2>&1 || true
                head -n 150 "$LOG/$name.sample.txt" >&2 || true ;;
        esac
    done
    report="$(ls -t "$HOME"/Library/Logs/DiagnosticReports/swiftpm-testing-helper*.ips 2>/dev/null | head -n 1 || true)"
    if [[ -n "$report" && "$report" -nt "$LOG/$name.txt" ]]; then
        echo "The test process crashed: $report" >&2
        crash_frames "$report" >&2
    fi
    kill $victims 2>/dev/null || true
    sleep 1
    kill -9 $victims 2>/dev/null || true
}

# Whether a process of `swift test`, whatever its depth, has ended and not been collected. When the test process crashes while
# a stand-in it started still holds the output, `swift test` keeps waiting for it and the dead process stays as it is.
has_uncollected() {
    ps -axo pid=,ppid=,stat= | awk -v root="$1" '
        { parent[$1] = $2; stat[$1] = $3 }
        END { for (p in parent) { q = p; while (q != "" && q != root && q != 0) q = parent[q]
                                  if (q == root && stat[p] ~ /^Z/) found = 1 }
              exit !found }'
}

# A filter that matches nothing "passes" with 0 tests, so a pass with none is a failure.
run_pass() {
    local name="$1"; shift
    local out="$LOG/$name.txt" waited=0 uncollected=0 hung="" code=0
    echo "▸ Pass: $name" >&2
    : > "$out"
    # The output goes to a file, not into a pipe: a process that holds a pipe open keeps whatever reads the pipe from ending.
    swift_test "$@" > "$out" 2>&1 &
    local test_pid=$!
    tail -f "$out" &
    local tail_pid=$!
    while kill -0 "$test_pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if has_uncollected "$test_pid"; then uncollected=$((uncollected + 1)); else uncollected=0; fi
        if (( uncollected >= 10 )); then hung="the test process ended and swift test is stuck, waiting for a process the tests left that holds its output"; fi
        if (( waited > PASS_TIMEOUT )); then hung="still running after $PASS_TIMEOUT seconds"; fi
        if [[ -n "$hung" ]]; then
            give_up "$name" "$hung" "$tail_pid"
            break
        fi
    done
    wait "$test_pid" || code=$?
    sleep 1
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
    if [[ -n "$hung" || $code -ne 0 ]]; then
        echo "✘ Pass failed: $name" >&2
        status=1
    elif ! grep -qE "Test run with [1-9][0-9]* tests?" "$out"; then
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
