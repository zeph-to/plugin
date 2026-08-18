#!/usr/bin/env bash
# Fixture-based tests for hooks/zeph-remote.sh (ADR-0002).
#
# zeph-remote is a UserPromptSubmit hook — it flags prompts that the zeph
# listener injected from the user's phone (exact-text sha256 match against
# a one-shot marker file) and emits additionalContext that enters sticky
# REMOTE mode. Everything else must be a silent no-op with exit 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/zeph-remote.sh"

[ -f "$HOOK_SCRIPT" ] || { echo "hook script not found: $HOOK_SCRIPT" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

WORK=$(mktemp -d)
LEGACY_MARKERS=()
cleanup() {
    rm -rf "$WORK"
    for f in ${LEGACY_MARKERS[@]+"${LEGACY_MARKERS[@]}"}; do rm -f "$f"; done
}
trap cleanup EXIT

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

assert_not() {
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    if ! "$@"; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$desc")
    fi
}

hash_of() { printf '%s' "$1" | cksum | cut -d' ' -f1; }
sha_of()  { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }

marker_path() { echo "$WORK/state/zeph/remote-$(hash_of "$1")"; }
state_path()  { echo "$WORK/state/zeph/remote-active-$(hash_of "$1")"; }

# write_state <project_dir> [age_seconds] — sticky REMOTE state, as the hook
# writes it: one epoch second naming the last time REMOTE was confirmed.
write_state() {
    local dir="$1" age="${2:-0}"
    mkdir -p "$WORK/state/zeph"
    printf '%s\n' "$(( $(date +%s) - age ))" > "$(state_path "$dir")"
}

# write_marker <project_dir> <text> [age_seconds]
write_marker() {
    local dir="$1" text="$2" age="${3:-0}"
    mkdir -p "$WORK/state/zeph"
    printf '%s %s\n' "$(( $(date +%s) - age ))" "$(sha_of "$text")" > "$(marker_path "$dir")"
}

# run_hook <prompt> <project_dir> [hook_id]
# Echoes hook stdout; exit status is the hook's exit status.
run_hook() {
    local prompt="$1" project_dir="$2" hook_id="${3:-}"
    jq -n --arg p "$prompt" '{prompt: $p}' \
      | CLAUDE_PROJECT_DIR="$project_dir" XDG_STATE_HOME="$WORK/state" \
        ZEPH_HOOK_ID="$hook_id" bash "$HOOK_SCRIPT" 2>/dev/null
}

ctx_of() { jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

# ── tests ──────────────────────────────────────────────────────────────────

echo "[fresh marker + matching prompt + ZEPH_HOOK_ID → REMOTE context]"
P="$WORK/proj-a"
write_marker "$P" "fix the login bug"
OUT=$(run_hook "fix the login bug" "$P" "hook_123")
RC=$?
CTX=$(printf '%s' "$OUT" | ctx_of)
assert "exit 0"                          [ "$RC" -eq 0 ]
assert "emits additionalContext"         [ -n "$CTX" ]
assert "context enters REMOTE mode"      grep -q "REMOTE mode" <<<"$CTX"
assert "context names UserPromptSubmit"  grep -q '"hookEventName": *"UserPromptSubmit"' <<<"$OUT"
assert "marker consumed (one-shot)"      [ ! -f "$(marker_path "$P")" ]
# The transition turn is the only channel that ships Rule 9 in full: the
# SessionStart hook gives a NORMAL session a two-line stub, because it cannot
# know a phone message is coming. If this stops arriving, that stub is a
# promise nothing keeps.
assert "carries Rule 9 in full"          grep -q "State Detection" <<<"$CTX"
assert "including the exit marker"       grep -q "zeph: exit" <<<"$CTX"
assert "and the REMOTE timeout window"   grep -q "300–600 s" <<<"$CTX"

echo
echo "[matching prompt, ZEPH_HOOK_ID unset → one-way conversion CTA]"
P="$WORK/proj-oneway"
write_marker "$P" "check the deploy status"
CTX=$(run_hook "check the deploy status" "$P" | ctx_of)
assert "emits additionalContext"      [ -n "$CTX" ]
assert "mentions setup CTA"           grep -q "npx @zeph-to/cli setup" <<<"$CTX"
assert_not "does not claim two-way"   grep -q "end EVERY response" <<<"$CTX"
assert "marker consumed"              [ ! -f "$(marker_path "$P")" ]

echo
echo "[text mismatch → silent, marker kept (terminal race can't false-match)]"
P="$WORK/proj-mismatch"
write_marker "$P" "the phone message"
OUT=$(run_hook "something typed at the terminal" "$P" "hook_123")
assert "no output"     [ -z "$OUT" ]
assert "marker kept"   [ -f "$(marker_path "$P")" ]

echo
echo "[within the 15-min window (e.g. long agent turn) → still matches]"
P="$WORK/proj-longturn"
write_marker "$P" "sent during a long turn" 600
CTX=$(run_hook "sent during a long turn" "$P" "hook_123" | ctx_of)
assert "matches at 10 min"  [ -n "$CTX" ]

echo
echo "[stale marker (>15min) → silent, marker deleted (housekeeping)]"
P="$WORK/proj-stale"
write_marker "$P" "old command" 1000
OUT=$(run_hook "old command" "$P" "hook_123")
assert "no output"       [ -z "$OUT" ]
assert "marker deleted"  [ ! -f "$(marker_path "$P")" ]

echo
echo "[muted project → silent, marker left unconsumed]"
P="$WORK/proj-muted"
write_marker "$P" "while muted"
touch "$WORK/state/zeph/muted-$(hash_of "$P")"
OUT=$(run_hook "while muted" "$P" "hook_123")
assert "no output"     [ -z "$OUT" ]
assert "marker kept"   [ -f "$(marker_path "$P")" ]

echo
echo "[no marker at all → silent no-op]"
P="$WORK/proj-none"
OUT=$(run_hook "any prompt" "$P" "hook_123")
RC=$?
assert "no output"  [ -z "$OUT" ]
assert "exit 0"     [ "$RC" -eq 0 ]

echo
echo "[whitespace-padded prompt still matches (trim mirrors listener)]"
P="$WORK/proj-trim"
write_marker "$P" "run the tests"
CTX=$(run_hook "  run the tests
" "$P" "hook_123" | ctx_of)
assert "matches after trim"  [ -n "$CTX" ]

echo
echo "[multi-line prompt matches byte-for-byte]"
P="$WORK/proj-multiline"
ML=$'first line\nsecond line'
write_marker "$P" "$ML"
CTX=$(run_hook "$ML" "$P" "hook_123" | ctx_of)
assert "multi-line match"  [ -n "$CTX" ]

echo
echo "[trailing U+00A0 NBSP survives the trim on both sides (ASCII-only parity)]"
P="$WORK/proj-nbsp"
NB=$'nbsp end\xc2\xa0'
write_marker "$P" "$NB"
CTX=$(run_hook "$NB" "$P" "hook_123" | ctx_of)
assert "NBSP-suffixed text matches"  [ -n "$CTX" ]

echo
echo "[malformed marker content → silent, no crash]"
P="$WORK/proj-garbage"
mkdir -p "$WORK/state/zeph"
printf 'not-a-timestamp junk\n' > "$(marker_path "$P")"
OUT=$(run_hook "whatever" "$P" "hook_123")
RC=$?
assert "no output"        [ -z "$OUT" ]
assert "marker deleted"   [ ! -f "$(marker_path "$P")" ]
assert "exit 0"     [ "$RC" -eq 0 ]

echo
echo "[empty prompt → silent no-op]"
P="$WORK/proj-empty"
write_marker "$P" "phone text"
OUT=$(printf '{"prompt":""}' \
  | CLAUDE_PROJECT_DIR="$P" XDG_STATE_HOME="$WORK/state" ZEPH_HOOK_ID=x bash "$HOOK_SCRIPT" 2>/dev/null)
assert "no output"    [ -z "$OUT" ]
assert "marker kept"  [ -f "$(marker_path "$P")" ]

echo
echo "[legacy /tmp marker owned by current user → honored]"
P="$WORK/proj-legacy"
LEGACY="/tmp/zeph-remote-$(hash_of "$P")"
LEGACY_MARKERS+=("$LEGACY")
printf '%s %s\n' "$(date +%s)" "$(sha_of "legacy path text")" > "$LEGACY"
CTX=$(run_hook "legacy path text" "$P" "hook_123" | ctx_of)
assert "legacy marker matches"   [ -n "$CTX" ]
assert "legacy marker consumed"  [ ! -f "$LEGACY" ]

echo
echo "[sticky state alive, no marker → the user is back at the terminal: leave REMOTE]"
P="$WORK/proj-sticky"
write_state "$P"
OUT=$(run_hook "typed at the terminal mid-session" "$P" "hook_123")
RC=$?
CTX=$(printf '%s' "$OUT" | ctx_of)
assert "exit 0"                  [ "$RC" -eq 0 ]
assert "says REMOTE has ended"   grep -q "LEFT sticky REMOTE mode" <<<"$CTX"
assert "state cleared"           [ ! -f "$(state_path "$P")" ]
assert_not "not the entry note"  grep -q "arrived from the user's phone" <<<"$CTX"

echo
echo "[the exit note is emitted once — later terminal turns are silent]"
OUT=$(run_hook "and another one" "$P" "hook_123")
assert "no output"  [ -z "$OUT" ]

echo
echo "[fresh marker left unmatched → REMOTE survives (a phone message is in flight)]"
# The digest missing is not evidence the user typed: the message may be queued
# behind a long turn, or the two sides may hash a composition differently.
# Dropping REMOTE here strands a user who is still holding the phone.
P="$WORK/proj-pending"
write_state "$P"
write_marker "$P" "the phone message"
OUT=$(run_hook "not the injected text" "$P" "hook_123")
assert "no output"     [ -z "$OUT" ]
assert "state kept"    [ -f "$(state_path "$P")" ]
assert "marker kept"   [ -f "$(marker_path "$P")" ]

echo
echo "[empty prompt with a marker pending → no evidence, state kept]"
P="$WORK/proj-empty-sticky"
write_state "$P"
write_marker "$P" "the phone message"
OUT=$(printf '{"prompt":""}' \
  | CLAUDE_PROJECT_DIR="$P" XDG_STATE_HOME="$WORK/state" ZEPH_HOOK_ID=x bash "$HOOK_SCRIPT" 2>/dev/null)
assert "no output"   [ -z "$OUT" ]
assert "state kept"  [ -f "$(state_path "$P")" ]

echo
echo "[stale marker on a live REMOTE session → still a terminal turn, REMOTE ends]"
P="$WORK/proj-stale-sticky"
write_state "$P"
write_marker "$P" "old phone text" 1000
CTX=$(run_hook "typed at the terminal" "$P" "hook_123" | ctx_of)
assert "says REMOTE has ended"  grep -q "LEFT sticky REMOTE mode" <<<"$CTX"
assert "state cleared"          [ ! -f "$(state_path "$P")" ]
assert "stale marker swept"     [ ! -f "$(marker_path "$P")" ]

echo
echo "[a phone message after that re-enters REMOTE (re-entry is one message)]"
P="$WORK/proj-sticky"
write_marker "$P" "back on the phone"
CTX=$(run_hook "back on the phone" "$P" "hook_123" | ctx_of)
assert "entry note again"  grep -q "arrived from the user's phone" <<<"$CTX"
assert "state written"     [ -f "$(state_path "$P")" ]

echo
echo "[marker match writes the sticky state]"
P="$WORK/proj-enter"
write_marker "$P" "start from the phone"
CTX=$(run_hook "start from the phone" "$P" "hook_123" | ctx_of)
assert "entered REMOTE"   [ -n "$CTX" ]
assert "state written"    [ -f "$(state_path "$P")" ]
assert "marker consumed"  [ ! -f "$(marker_path "$P")" ]

echo
echo "[sticky state alive but muted → silent (mute outranks, Rule 12)]"
P="$WORK/proj-sticky-muted"
write_state "$P"
touch "$WORK/state/zeph/muted-$(hash_of "$P")"
OUT=$(run_hook "anything" "$P" "hook_123")
assert "no output"   [ -z "$OUT" ]
assert "state kept"  [ -f "$(state_path "$P")" ]

echo
echo "[sticky state past the TTL → silent, state swept (no SessionEnd hook exists)]"
P="$WORK/proj-sticky-stale"
write_state "$P" 20000
OUT=$(run_hook "much later" "$P" "hook_123")
RC=$?
assert "no output"       [ -z "$OUT" ]
assert "exit 0"          [ "$RC" -eq 0 ]
assert "state deleted"   [ ! -f "$(state_path "$P")" ]

echo
echo "[sticky state alive, ZEPH_HOOK_ID unset → silent (no zeph_ask to remind about)]"
P="$WORK/proj-sticky-oneway"
write_state "$P"
OUT=$(run_hook "typed at the terminal" "$P")
assert "no output"   [ -z "$OUT" ]
assert "state kept"  [ -f "$(state_path "$P")" ]

echo
echo "[garbled sticky state → silent, swept]"
P="$WORK/proj-sticky-garbage"
mkdir -p "$WORK/state/zeph"
printf 'not-a-timestamp\n' > "$(state_path "$P")"
OUT=$(run_hook "whatever" "$P" "hook_123")
RC=$?
assert "no output"      [ -z "$OUT" ]
assert "exit 0"         [ "$RC" -eq 0 ]
assert "state deleted"  [ ! -f "$(state_path "$P")" ]

echo
echo "[state written as an exponent is swept, not read as a far-future stamp]"
# Parity regression: bash rejects any non-digit, so the TS twin must too —
# Number('1e10') would otherwise resolve to a year-2286 timestamp and keep
# REMOTE alive forever on a file bash throws away.
P="$WORK/proj-sticky-exponent"
mkdir -p "$WORK/state/zeph"
printf '1e10\n' > "$(state_path "$P")"
OUT=$(run_hook "whatever" "$P" "hook_123")
assert "no output"      [ -z "$OUT" ]
assert "state deleted"  [ ! -f "$(state_path "$P")" ]

echo
echo "[unremovable marker still enters REMOTE (housekeeping is not the verdict)]"
# Regression: the match function used to return `rm`'s status, so a state dir
# the user cannot write turned a verified phone message into a no-match.
if [ "$(id -u)" -eq 0 ]; then
    echo "  – skipped (running as root; rm cannot be made to fail)"
else
    P="$WORK/proj-rm-fails"
    write_marker "$P" "phone text under a locked dir"
    chmod 555 "$WORK/state/zeph"
    CTX=$(run_hook "phone text under a locked dir" "$P" "hook_123" | ctx_of)
    chmod 755 "$WORK/state/zeph"
    assert "still enters REMOTE"  grep -q "REMOTE mode" <<<"$CTX"
    rm -f "$(marker_path "$P")"
fi

# ── summary ────────────────────────────────────────────────────────────────

echo
echo "────────────────────────────────"
echo "PASS: $PASS / $TOTAL"
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
