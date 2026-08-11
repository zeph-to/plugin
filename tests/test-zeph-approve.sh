#!/usr/bin/env bash
# Fixture-based tests for hooks/zeph-approve.sh.
#
# The gate is opt-in and blocking, so the rows that matter most are the ones
# where it must NOT act: not enabled, muted, or an ordinary command. A gate that
# blocks when it shouldn't freezes someone's terminal for 90 seconds.
#
# The `zeph` CLI is stubbed, so no push is ever sent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/zeph-approve.sh"

[ -f "$HOOK_SCRIPT" ] || { echo "hook script not found: $HOOK_SCRIPT" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR" "$WORK/state/zeph"

PROJECT_DIR="$WORK/project"
mkdir -p "$PROJECT_DIR"
HASH=$(printf '%s' "$PROJECT_DIR" | cksum | cut -d' ' -f1)

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()

assert() {
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    if "$@"; then echo "  ✓ $desc"; PASS=$((PASS + 1));
    else echo "  ✗ $desc"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc"); fi
}
assert_not() {
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    if ! "$@"; then echo "  ✓ $desc"; PASS=$((PASS + 1));
    else echo "  ✗ $desc"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc"); fi
}

# Stub `zeph ask`: prints whatever the current scenario wants, and records that
# it was called at all.
stub_ask() {
    cat > "$STUB_DIR/zeph" <<EOF
#!/bin/bash
touch "$WORK/ask-was-called"
printf '%s' '$1'
EOF
    chmod +x "$STUB_DIR/zeph"
}

run_hook() {
    rm -f "$WORK/ask-was-called"
    printf '%s' "$1" \
      | CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$STUB_DIR:$PATH" \
        XDG_STATE_HOME="$WORK/state" \
        bash "$HOOK_SCRIPT" 2>/dev/null
}

decision_is() { [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = "$1" ]; }
reason_has()  { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null | grep -qF -- "$1"; }
asked()       { [ -f "$WORK/ask-was-called" ]; }
silent()      { [ -z "$OUT" ]; }

RM='{"tool_input":{"command":"rm -rf ./dist"}}'

echo "[not enabled — the hook is inert]"
stub_ask '{"answered":true,"actionId":"approve"}'
OUT=$(run_hook "$RM")
assert "emits no decision"          silent
assert_not "never asks"             asked

touch "$WORK/state/zeph/approve-$HASH"

echo
echo "[enabled + dangerous command — waits for the phone]"
stub_ask '{"answered":true,"actionId":"approve"}'
OUT=$(run_hook "$RM")
assert "asks the user"              asked
assert "allows on approval"         decision_is allow

echo
echo "[enabled + ordinary command — runs untouched]"
stub_ask '{"answered":true,"actionId":"approve"}'
OUT=$(run_hook '{"tool_input":{"command":"npm run build"}}')
assert "emits no decision"          silent
assert_not "never asks"             asked

echo
echo "[explicit refusal from the phone]"
stub_ask '{"answered":true,"actionId":"deny"}'
OUT=$(run_hook "$RM")
assert "denies"                     decision_is deny
assert "says the user declined"     reason_has "declined"

echo
echo "[no answer within the deadline — silence is a refusal]"
# The opposite of the AskUserQuestion hook: there `allow` is the safe
# direction, here it is the dangerous one.
stub_ask '{"answered":false}'
OUT=$(run_hook "$RM")
assert "denies"                     decision_is deny
assert "says no approval came back" reason_has "No approval came back"

echo
echo "[cannot reach the server — still a refusal, and says why]"
stub_ask '{"answered":false,"error":"offline"}'
OUT=$(run_hook "$RM")
assert "denies"                     decision_is deny
assert "names the transport error"  reason_has "offline"

echo
echo "[free text instead of a button is not an approval]"
stub_ask '{"answered":true,"value":"maybe later"}'
OUT=$(run_hook "$RM")
assert "denies"                     decision_is deny

echo
echo "[muted — nobody can be asked, so nothing is blocked]"
touch "$WORK/state/zeph/muted-$HASH"
stub_ask '{"answered":true,"actionId":"approve"}'
OUT=$(run_hook "$RM")
assert "emits no decision"          silent
assert_not "never asks"             asked
rm -f "$WORK/state/zeph/muted-$HASH"

echo
echo "[malformed input cannot block a session]"
stub_ask '{"answered":true,"actionId":"approve"}'
OUT=$(run_hook 'not-json-at-all{')
assert "emits no decision"          silent

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
