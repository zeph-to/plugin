#!/usr/bin/env bash
# Tests for hooks/zeph-setup.js (SessionStart hook).
#
# Guards these regressions:
#   - the section extraction from CORE_RULES.md must be non-empty for every
#     branch (a heading rename there would silently inject empty rules —
#     lint-rules-sync validates a different extractor, not this one)
#   - the Mode label must render exactly once ("Mode: Mode: two-way" shipped
#     once from a doubled prefix)
#   - the unconfigured path must emit the setup note, not rules
#   - EVERY branch must stay under Claude Code's inline hook-context ceiling.
#     Above 10,000 chars the harness persists additionalContext to a file and
#     hands the model a 2,000-char preview instead, so the rules below the cut
#     never arrive. The unconditional block was 15,483 bytes and lost most of
#     itself that way; these assertions are what stops that recurring.
#   - each branch injects only what its state can act on: no Push Signal in
#     REMOTE (markers are ignored there), no ask rules without a hook id

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/zeph-setup.js"

[ -f "$HOOK_SCRIPT" ] || { echo "hook script not found: $HOOK_SCRIPT" >&2; exit 1; }
command -v node >/dev/null || { echo "node required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# Empty HOME so the real ~/.zeph/config.json can't leak keys into the test.
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

# Claude Code persists a hook's additionalContext above this many chars
# (cli.js `Pyt(e,t,r,n=k$d)`, `k$d=1e4`) and replaces it with a 2,000-char
# preview. Measured against 2.1.234.
INLINE_CEILING=10000

# State the branches key on lives under XDG_STATE_HOME, keyed by project dir.
STATE="$WORK/state"
PROJECT="$WORK/project"
mkdir -p "$STATE/zeph" "$PROJECT"
PROJECT_HASH=$(printf '%s' "$PROJECT" | cksum | cut -d' ' -f1)
state_reset() { rm -f "$STATE/zeph"/*; }

# run_hook [ENV=val ...] — prints extracted additionalContext.
run_hook() {
    env -i HOME="$WORK/home" PATH="$PATH" XDG_STATE_HOME="$STATE" \
        CLAUDE_PROJECT_DIR="$PROJECT" "$@" node "$HOOK_SCRIPT" 2>/dev/null \
      | jq -r '.hookSpecificOutput.additionalContext // empty'
}

ctx_has()     { printf '%s' "$CTX" | grep -qF -- "$1"; }
ctx_min_len() { [ "${#CTX}" -ge "$1" ]; }
ctx_max_len() { [ "${#CTX}" -le "$1" ]; }
ctx_inline()  { ctx_max_len "$INLINE_CEILING"; }

# ── tests ──────────────────────────────────────────────────────────────────

echo "[NORMAL — API key + hook ID, no remote state]"
state_reset
CTX=$(run_hook ZEPH_API_KEY=test-key ZEPH_HOOK_ID=test-hook)
assert "emits non-trivial rules (≥500 chars)"  ctx_min_len 500
assert "fits inline, uncut"                    ctx_inline
assert "carries two-way rule content"          ctx_has "zeph_ask"
assert "says the user is at the terminal"      ctx_has "the user is at the terminal"
assert "states no ask is owed"                 ctx_has "You owe no"
assert "names what starts REMOTE"              ctx_has "What starts REMOTE"
assert "keeps Rule 13 (compaction)"            ctx_has "after context compaction"
# Rules 3/4/5/6/10/11 are REMOTE-scoped. Injecting them here is the regression
# that made a terminal session block on a phone answer nobody was there to give.
assert_not "no MANDATORY-ask rule"             ctx_has "NEVER end a response"
assert_not "no AskUserQuestion override"       ctx_has "MUST go through"
assert_not "no sticky-REMOTE full text"        ctx_has "State Detection"
assert "labels mode two-way"                   ctx_has "Mode: two-way"
assert_not "no doubled Mode prefix"            ctx_has "Mode: Mode:"

echo
echo "[NORMAL — the Push Signal block follows the project's dial]"
state_reset
CTX=$(run_hook ZEPH_API_KEY=test-key ZEPH_HOOK_ID=test-hook)
assert "no dial → quiet, high is the channel" ctx_has "push dial is **quiet**"
assert_not "quiet hides the skip marker"      ctx_has "zeph: skip"
echo normal > "$STATE/zeph/pushmode-$PROJECT_HASH"
CTX=$(run_hook ZEPH_API_KEY=test-key ZEPH_HOOK_ID=test-hook)
assert "normal dial → all three markers"      ctx_has "zeph: skip"
assert "and the heuristic it overrides"       ctx_has "read-only (Read/Grep/Glob)"
assert "still fits inline"                    ctx_inline

echo
echo "[REMOTE — sticky state is live for this project]"
state_reset
date +%s > "$STATE/zeph/remote-active-$PROJECT_HASH"
CTX=$(run_hook ZEPH_API_KEY=test-key ZEPH_HOOK_ID=test-hook)
assert "fits inline, uncut"                    ctx_inline
assert "says the session is in REMOTE"         ctx_has "this session is in REMOTE"
assert "carries the sticky-REMOTE contract"    ctx_has "State Detection"
assert "carries the MANDATORY-ask rule"        ctx_has "NEVER end a response"
assert "carries the AskUserQuestion override"  ctx_has "MUST go through"
assert "carries the exit marker"               ctx_has "zeph: exit"
assert "keeps Rule 13 (compaction)"            ctx_has "after context compaction"
assert_not "no Push Signal section (ignored in REMOTE)" ctx_has "### Push Signal"

echo
echo "[REMOTE — an expired state file is not REMOTE]"
state_reset
echo $(( $(date +%s) - 14401 )) > "$STATE/zeph/remote-active-$PROJECT_HASH"
CTX=$(run_hook ZEPH_API_KEY=test-key ZEPH_HOOK_ID=test-hook)
assert "falls back to NORMAL"                  ctx_has "the user is at the terminal"

echo
echo "[muted — the hooks are silent, so the rules are three lines]"
state_reset
touch "$STATE/zeph/muted-$PROJECT_HASH"
CTX=$(run_hook ZEPH_API_KEY=test-key ZEPH_HOOK_ID=test-hook)
assert "under 400 chars"                       ctx_max_len 400
assert "says it is muted"                      ctx_has "muted"
assert "says how to lift it"                   ctx_has "/zeph-unmute"
assert_not "no ask rules"                      ctx_has "MANDATORY"
state_reset

echo
echo "[one-way — API key only]"
state_reset
CTX=$(run_hook ZEPH_API_KEY=test-key)
assert "emits non-trivial rules (≥300 chars)"  ctx_min_len 300
assert "fits inline, uncut"                    ctx_inline
assert "carries one-way rule content"          ctx_has "zeph_notify"
assert "labels mode one-way"                   ctx_has "Mode: one-way"
assert "notes two-way tools unavailable"       ctx_has "ZEPH_HOOK_ID"
assert_not "no doubled Mode prefix"            ctx_has "Mode: Mode:"
assert_not "no dead ask rules"                 ctx_has "MANDATORY"
assert_not "no sticky REMOTE"                  ctx_has "State Detection"

echo
echo "[unconfigured — no key anywhere]"
CTX=$(run_hook)
assert "emits the not-configured note"         ctx_has "not configured"
assert_not "does not inject rules"             ctx_has "Mode: "

echo
echo "[unresolved \${VAR} placeholders count as unset]"
CTX=$(run_hook 'ZEPH_API_KEY=${ZEPH_API_KEY}')
assert "placeholder key → not-configured note" ctx_has "not configured"

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
