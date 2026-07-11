#!/usr/bin/env bash
# Tests for hooks/zeph-setup.js (SessionStart hook).
#
# Guards three regressions:
#   - the mode-section extraction from CORE_RULES.md must be non-empty for
#     both modes (a heading rename there would silently inject empty rules
#     — lint-rules-sync validates a different extractor, not this one)
#   - the Mode label must render exactly once ("Mode: Mode: two-way" shipped
#     once from a doubled prefix)
#   - the unconfigured path must emit the setup note, not rules

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

# run_hook [ENV=val ...] — prints extracted additionalContext.
run_hook() {
    env -i HOME="$WORK/home" PATH="$PATH" "$@" node "$HOOK_SCRIPT" 2>/dev/null \
      | jq -r '.hookSpecificOutput.additionalContext // empty'
}

ctx_has()     { printf '%s' "$CTX" | grep -qF -- "$1"; }
ctx_min_len() { [ "${#CTX}" -ge "$1" ]; }

# ── tests ──────────────────────────────────────────────────────────────────

echo "[two-way — API key + hook ID]"
CTX=$(run_hook ZEPH_API_KEY=test-key ZEPH_HOOK_ID=test-hook)
assert "emits non-trivial rules (≥500 chars)"  ctx_min_len 500
assert "carries two-way rule content"          ctx_has "zeph_ask"
assert "labels mode two-way"                   ctx_has "Mode: two-way"
assert_not "no doubled Mode prefix"            ctx_has "Mode: Mode:"

echo
echo "[one-way — API key only]"
CTX=$(run_hook ZEPH_API_KEY=test-key)
assert "emits non-trivial rules (≥300 chars)"  ctx_min_len 300
assert "carries one-way rule content"          ctx_has "zeph_notify"
assert "labels mode one-way"                   ctx_has "Mode: one-way"
assert "notes two-way tools unavailable"       ctx_has "ZEPH_HOOK_ID"
assert_not "no doubled Mode prefix"            ctx_has "Mode: Mode:"

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
