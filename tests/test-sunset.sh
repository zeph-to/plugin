#!/usr/bin/env bash
# Tests for the sunset gate (hooks/sunset.sh, and its copy in hooks/zeph-setup.js).
#
# Zeph's agent features end on 2026-11-01 (D). From D on, every hook the plugin
# registers must exit 0 at once: no network, no `zeph`/`npx` run, no waiting, and
# never a deny — zeph-approve.sh in particular must fail open. The rows that
# matter are the "after D" ones; the before-D rows only prove the harness can see
# a call (so an empty call log means something) and that the setup hook says so.
#
# `zeph`, `npx`, `curl`, `herdr` and `tmux` are stubs on PATH that append their
# argv to one log; after D that log must stay empty. PATH holds only the stubs
# plus symlinks to the few real tools a hook needs, so a stray real `zeph` or
# `npx` cannot satisfy or hide a call.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../hooks"
FIXTURES="$SCRIPT_DIR/fixtures"
for f in sunset.sh zeph-setup.js zeph-stop.sh zeph-ask.sh zeph-approve.sh zeph-remote.sh zeph-herdr.sh; do
    [ -f "$HOOKS/$f" ] || { echo "hook script not found: $HOOKS/$f" >&2; exit 1; }
done
command -v node >/dev/null || { echo "node required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
BASH_BIN=$(command -v bash)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/stubs"; TOOLS="$WORK/tools"; CALLS="$WORK/calls.log"
STATE="$WORK/state"; PROJECT="$WORK/project"; HOME_DIR="$WORK/home"
mkdir -p "$STUBS" "$TOOLS" "$STATE/zeph" "$PROJECT" "$HOME_DIR"
: > "$CALLS"
HASH=$(printf '%s' "$PROJECT" | cksum | cut -d' ' -f1)

for t in node jq date dirname cksum cut cat tr sed grep head wc sleep python3; do
    p=$(command -v "$t") && ln -s "$p" "$TOOLS/$t"
done
for s in zeph npx curl herdr tmux; do
    cat > "$STUBS/$s" <<EOS
#!/bin/bash
echo "$s \$*" >> "$CALLS"
# approve reads this as 'zeph ask' output; harmless for the others
printf '%s' '{"answered":true,"actionId":"approve"}'
EOS
    chmod +x "$STUBS/$s"
done

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()
check() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then echo "  ✓ $desc"; PASS=$((PASS + 1));
    else echo "  ✗ $desc"; echo "      expected: $expected"; echo "      actual:   $actual"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc"); fi
}

END_LINE="Zeph agent features ended on 2026-11-01. This plugin no longer does anything; remove it with: claude plugin uninstall zeph@zeph"
BEFORE_LINE="Zeph agent features end on 2026-11-01. After that this plugin does nothing; remove it with: claude plugin uninstall zeph@zeph"

# run <today> <stdin> <cmd...> — sets OUT (stdout) and RC; the call log is reset first.
run() {
    local today="$1" input="$2"; shift 2
    : > "$CALLS"
    OUT=$(printf '%s' "$input" | env -i HOME="$HOME_DIR" PATH="$STUBS:$TOOLS" XDG_STATE_HOME="$STATE" \
        CLAUDE_PROJECT_DIR="$PROJECT" ZEPH_SUNSET_TODAY="$today" ZEPH_API_KEY=k ZEPH_HOOK_ID=h \
        TMUX=/tmp/tmux,1,0 TMUX_PANE=%1 CLAUDE_CODE_ENTRYPOINT=cli TMPDIR="$WORK" \
        "$BASH_BIN" -c 'exec "$@"' _ "$@" 2>/dev/null)
    RC=$?
}
calls() { wc -l < "$CALLS" | tr -d ' '; }

# Make every hook live-looking: approve switched on, REMOTE active, a real transcript.
touch "$STATE/zeph/approve-$HASH" "$STATE/zeph/remote-active-$HASH"
TRANSCRIPT="$FIXTURES/main-2-tools.jsonl"
STOP_IN=$(jq -nc --arg t "$TRANSCRIPT" '{transcript_path:$t,session_id:"s"}')
ASK_IN='{"tool_input":{"question":"Deploy?"}}'
RM_IN='{"tool_input":{"command":"rm -rf ./dist"}}'
PROMPT_IN='{"prompt":"hello"}'

echo "harness sanity (before D: the stub is called)"
run 2026-10-20 "$RM_IN" "$BASH_BIN" "$HOOKS/zeph-approve.sh"
check "approve before D reaches the zeph stub" 1 "$([ "$(calls)" -ge 1 ] && echo 1 || echo 0)"

for TODAY in 2026-11-01 2026-11-02 2027-03-15; do
    echo "after D ($TODAY): every hook exits 0 and touches nothing"
    for spec in "zeph-stop.sh|$STOP_IN" "zeph-ask.sh|$ASK_IN" "zeph-approve.sh|$RM_IN" \
                "zeph-remote.sh|$PROMPT_IN"; do
        h="${spec%%|*}"; input="${spec#*|}"
        run "$TODAY" "$input" "$BASH_BIN" "$HOOKS/$h"
        check "$h: exit 0" 0 "$RC"
        check "$h: no output (no deny, no ask, no context)" "" "$OUT"
        check "$h: no zeph/npx/curl/herdr/tmux call" 0 "$(calls)"
    done
    for ev in start working idle blocked tool end; do
        run "$TODAY" '{}' "$BASH_BIN" "$HOOKS/zeph-herdr.sh" "$ev"
        check "zeph-herdr.sh $ev: exit 0, silent, no call" "0||0" "$RC|$OUT|$(calls)"
    done
    run "$TODAY" '{}' node "$HOOKS/zeph-setup.js"
    check "zeph-setup.js: exit 0" 0 "$RC"
    check "zeph-setup.js: SessionStart context is exactly the end line" "$END_LINE" \
        "$(printf '%s' "$OUT" | jq -r 'select(.hookSpecificOutput.hookEventName == "SessionStart") | .hookSpecificOutput.additionalContext')"
    check "zeph-setup.js: no call" 0 "$(calls)"
done

echo "approve fails open after D (never a deny, even for a destructive command)"
run 2026-11-01 "$RM_IN" "$BASH_BIN" "$HOOKS/zeph-approve.sh"
check "no permissionDecision in the output" "" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"

echo "far-future date still reads as ended"
run 9999-01-01 '{}' node "$HOOKS/zeph-setup.js"
check "zeph-setup.js: end line" "$END_LINE" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')"

echo "day before D: hooks still work, setup announces the end date"
run 2026-10-31 '{}' node "$HOOKS/zeph-setup.js"
check "zeph-setup.js: exit 0" 0 "$RC"
check "zeph-setup.js: SessionStart event" SessionStart "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')"
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
check "zeph-setup.js: ends with the before-D line" "$BEFORE_LINE" "$(printf '%s' "$CTX" | tail -n 1)"
check "zeph-setup.js: before-D line appears once" 1 "$(printf '%s' "$CTX" | grep -cF "$BEFORE_LINE")"
check "zeph-setup.js: still injects the rules" 1 "$([ "${#CTX}" -gt 1000 ] && echo 1 || echo 0)"
run 2026-10-20 '{}' node "$HOOKS/zeph-setup.js"
check "2026-10-20: before-D line present" 1 "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -cF "$BEFORE_LINE")"
check "2026-10-20: end line absent" 0 "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -cF "ended on")"
run 2026-10-31 "$RM_IN" "$BASH_BIN" "$HOOKS/zeph-approve.sh"
check "approve the day before D still runs the gate" 1 "$([ "$(calls)" -ge 1 ] && echo 1 || echo 0)"

echo "sunset.sh unit: boundary"
gate() { env -i PATH="$TOOLS" ZEPH_SUNSET_TODAY="$1" "$BASH_BIN" -c '. "$1"; zeph_sunset_ended && echo ended || echo live' _ "$HOOKS/sunset.sh" 2>/dev/null; }
check "2026-10-31 live" live "$(gate 2026-10-31)"
check "2026-11-01 ended" ended "$(gate 2026-11-01)"
check "2026-12-01 ended" ended "$(gate 2026-12-01)"
check "2027-01-01 ended" ended "$(gate 2027-01-01)"
check "real clock (no override) agrees with date -u" "$([ "$(date -u +%Y-%m-%d)" \< 2026-11-01 ] && echo live || echo ended)" \
    "$(env -i PATH="$TOOLS" "$BASH_BIN" -c '. "$1"; zeph_sunset_ended && echo ended || echo live' _ "$HOOKS/sunset.sh" 2>/dev/null)"

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
