#!/usr/bin/env bash
# Tests for scripts/zeph-mode.sh — the one script behind /zeph-mode.
#
# Guards these regressions:
#   - each word writes the state file the hooks read (gate.sh zeph_state_present),
#     keyed by the same project hash, so a dial set here is the dial the Stop
#     hook sees
#   - --global only for push dials; a bad argument writes nothing
#   - status names where the dial came from (project / global / built-in default)
#   - after a change the script re-emits the SessionStart rules for the NEW
#     state: those rules never re-run mid-session, so without this a
#     quiet→normal switch leaves the model without the skip/push markers
#   - a failing rules refresh never undoes the change the user asked for

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE_SCRIPT="$SCRIPT_DIR/../scripts/zeph-mode.sh"

[ -f "$MODE_SCRIPT" ] || { echo "script not found: $MODE_SCRIPT" >&2; exit 1; }
command -v node >/dev/null || { echo "node required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()

assert() {
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    if "$@"; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$desc")
    fi
}

STATE="$WORK/state"
S="$STATE/zeph"
# A space in the path: the project dir reaches the script as one stdin line
# and must hash exactly as the hooks hash CLAUDE_PROJECT_DIR.
PROJECT="$WORK/my project"
mkdir -p "$S" "$PROJECT"
HASH=$(printf '%s' "$PROJECT" | cksum | cut -d' ' -f1)
state_reset() { rm -f "$S"/* "/tmp/zeph-muted-$HASH" "/tmp/zeph-pushmode-$HASH" "$WORK/pwned" "$WORK/pwned2" "$WORK/pwned3"; }

# run_mode_raw <dir-line> <args-line> — feeds stdin the way the skill's
# heredoc does; stdout+stderr into OUT, exit code into RC. ZEPH_HOOK_ID makes
# the re-emitted rules the two-way NORMAL branch.
run_mode_raw() {
    OUT=$(printf '%s\n%s\n' "$1" "$2" | env -i HOME="$WORK/home" PATH="$PATH" \
        XDG_STATE_HOME="$STATE" ZEPH_API_KEY=test-key ZEPH_HOOK_ID=test-hook \
        bash "$MODE_SCRIPT" 2>&1)
    RC=$?
}
run_mode() { run_mode_raw "$PROJECT" "$*"; }

out_has()   { printf '%s' "$OUT" | grep -qF -- "$1"; }
out_lacks() { ! out_has "$1"; }
rc_is()     { [ "$RC" -eq "$1" ]; }
file_is()   { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
exists()    { [ -e "$1" ]; }
absent()    { [ ! -e "$1" ]; }
state_empty() { [ -z "$(ls -A "$S")" ]; }

# ── tests ──────────────────────────────────────────────────────────────────

echo "[status — no dial anywhere]"
state_reset
run_mode
assert "exits 0"                               rc_is 0
assert "reports active"                        out_has "NOTIFICATIONS: active"
assert "quiet is the built-in default"         out_has "PUSH MODE: quiet (built-in default"
assert "prints the usage line"                 out_has "/zeph-mode [quiet|normal|loud|mute|unmute] [--global]"
assert "writes nothing"                        state_empty
assert "does not re-emit rules"                out_lacks "Zeph rules"

echo "[project dials]"
for m in quiet normal loud; do
    state_reset
    run_mode "$m"
    assert "$m: exits 0"                       rc_is 0
    assert "$m: writes pushmode-<hash>"        file_is "$S/pushmode-$HASH" "$m"
    assert "$m: status says this project"      out_has "PUSH MODE: $m (this project)"
done

echo "[--global dial]"
state_reset
run_mode --global loud
assert "flag order does not matter"            rc_is 0
assert "writes pushmode-default"               file_is "$S/pushmode-default" loud
assert "leaves the project dial alone"         absent "$S/pushmode-$HASH"
assert "status says global default"            out_has "PUSH MODE: loud (global default)"
run_mode normal
assert "project dial wins over global"         out_has "PUSH MODE: normal (this project)"

echo "[mute / unmute]"
state_reset
run_mode mute
assert "mute touches muted-<hash>"             exists "$S/muted-$HASH"
assert "status says muted"                     out_has "NOTIFICATIONS: muted"
assert "re-emitted rules are the muted note"   out_has "muted for this project"
assert "muted note points at the new command"  out_has "/zeph-mode unmute"
touch "/tmp/zeph-muted-$HASH"
run_mode unmute
assert "unmute removes muted-<hash>"           absent "$S/muted-$HASH"
assert "unmute removes the legacy /tmp file"   absent "/tmp/zeph-muted-$HASH"
assert "status says active"                    out_has "NOTIFICATIONS: active"

echo "[legacy /tmp state counts in status]"
state_reset
touch "/tmp/zeph-muted-$HASH"
printf 'loud' > "/tmp/zeph-pushmode-$HASH"
run_mode
assert "status reports it muted"               out_has "NOTIFICATIONS: muted"
assert "legacy dial reads as this project"     out_has "PUSH MODE: loud (this project)"
state_reset

echo "[auto state]"
state_reset
printf '%s 90\n' "$(( $(date +%s) + 3600 ))" > "$S/auto-$HASH"
run_mode
assert "reports the remaining budget"          out_has "m remaining of 90m"
# No spaces in the payload: `read` splits on them, which would defuse it.
printf 'a[$(date>%s)] 90\n' "$WORK/pwned" > "$S/auto-$HASH"
run_mode
assert "a non-numeric auto file is reported"   out_has "AUTO MODE: unreadable state file"
assert "and never evaluated"                   absent "$WORK/pwned"
assert "status still finishes"                 out_has "/zeph-mode [quiet|normal|loud|mute|unmute] [--global]"
state_reset

echo "[shell text in the arguments is data, not code]"
state_reset
run_mode_raw "$PROJECT" "quiet; touch $WORK/pwned2 \$(touch $WORK/pwned3)"
assert "rejected as a bad argument"            rc_is 2
assert "nothing ran"                           absent "$WORK/pwned2"
assert "nothing ran in \$( )"                   absent "$WORK/pwned3"
assert "no state written"                      state_empty

echo "[rules refresh after a change]"
state_reset
run_mode normal
assert "normal: rules carry the skip marker"   out_has "zeph: skip"
assert "normal: tells the model to replace"    out_has "replace the Zeph rules from session start"
run_mode quiet
assert "quiet: rules say the dial is quiet"    out_has "push dial is **quiet**"
assert "quiet: no skip marker"                 out_lacks "zeph: skip"

echo "[bad arguments write nothing]"
for args in "mute --global" "quiet loud" "shout" "unmute --global" "--global"; do
    state_reset
    # shellcheck disable=SC2086 # word-splitting the case is the point
    run_mode $args
    assert "'$args': exit 2"                   rc_is 2
    assert "'$args': usage shown"              out_has "/zeph-mode [quiet|normal|loud|mute|unmute] [--global]"
    assert "'$args': no state written"         state_empty
done

echo "[empty or unsubstituted project dir falls back to pwd]"
state_reset
OUT=$(cd "$PROJECT" && printf '\nloud\n' | env -i HOME="$WORK/home" PATH="$PATH" \
    XDG_STATE_HOME="$STATE" bash "$MODE_SCRIPT" 2>&1); RC=$?
# env -i drops PWD, so bash takes getcwd — the physical path (/private/var on macOS).
PWD_HASH=$(cd "$PROJECT" && pwd -P | tr -d '\n' | cksum | cut -d' ' -f1)
assert "exits 0"                               rc_is 0
assert "hashes the working directory"          file_is "$S/pushmode-$PWD_HASH" loud
state_reset
OUT=$(cd "$PROJECT" && printf '%s\nnormal\n' '${CLAUDE_PROJECT_DIR}' | env -i HOME="$WORK/home" \
    PATH="$PATH" XDG_STATE_HOME="$STATE" bash "$MODE_SCRIPT" 2>&1); RC=$?
assert "a literal placeholder hashes pwd too"  file_is "$S/pushmode-$PWD_HASH" normal

echo "[rules refresh failure keeps the change]"
state_reset
NODELESS="$WORK/bin"; mkdir -p "$NODELESS"
for tool in bash cksum cut tr cat mkdir rm touch printf date ls dirname; do
    p=$(command -v "$tool") && ln -sf "$p" "$NODELESS/$tool"
done
OUT=$(printf '%s\nloud\n' "$PROJECT" | env -i HOME="$WORK/home" PATH="$NODELESS" \
    XDG_STATE_HOME="$STATE" "$NODELESS/bash" "$MODE_SCRIPT" 2>&1); RC=$?
assert "exits 0 without node"                  rc_is 0
assert "dial still written"                    file_is "$S/pushmode-$HASH" loud
assert "warns that rules were not refreshed"   out_has "could not refresh"

# ── summary ────────────────────────────────────────────────────────────────

echo
echo "Result: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
exit 0
