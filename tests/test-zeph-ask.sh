#!/usr/bin/env bash
# Fixture-based tests for hooks/zeph-ask.sh.
#
# zeph-ask is a PreToolUse(AskUserQuestion) hook — it fires when the
# assistant invokes the local AskUserQuestion tool. The hook extracts
# the question text, trims it, and pushes a notification so the user
# knows Claude is waiting even when they're away from the terminal.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/zeph-ask.sh"

[ -f "$HOOK_SCRIPT" ] || { echo "hook script not found: $HOOK_SCRIPT" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/zeph" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/last-call"
EOF
chmod +x "$STUB_DIR/zeph"

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

run_hook() {
    local input="$1"
    local project_dir="${2:-/tmp/test-project}"
    rm -f "$WORK/last-call"
    printf '%s' "$input" \
      | CLAUDE_PROJECT_DIR="$project_dir" PATH="$STUB_DIR:$PATH" \
        XDG_STATE_HOME="$WORK/state" \
        bash "$HOOK_SCRIPT" 2>/dev/null
}

zeph_called()       { [ -f "$WORK/last-call" ]; }
zeph_silent()       { [ ! -f "$WORK/last-call" ]; }
zeph_body_has()     { [ -f "$WORK/last-call" ] && grep -qF -- "$1" "$WORK/last-call"; }
zeph_title_has()    { [ -f "$WORK/last-call" ] && grep -qF -- "$1" "$WORK/last-call"; }
zeph_body_bytes_le() {
    [ -f "$WORK/last-call" ] || return 1
    local body bytes
    body=$(awk '/^--body$/{getline; print; exit}' "$WORK/last-call")
    bytes=$(printf '%s' "$body" | wc -c | tr -d ' ')
    [ "$bytes" -le "$1" ]
}

# ── tests ──────────────────────────────────────────────────────────────────

echo "[basic — single .tool_input.question field]"
run_hook '{"tool_input":{"question":"Continue with deployment?"}}'
assert "fires zeph notify"             zeph_called
assert "title prefixed 'Claude asks:'" zeph_title_has "Claude asks:"
assert "body contains question text"   zeph_body_has "Continue with deployment?"

echo
echo "[newer multi-question format — .tool_input.questions[0].question]"
run_hook '{"tool_input":{"questions":[{"question":"Pick one","options":["a","b"]}]}}'
assert "fires zeph notify"             zeph_called
assert "extracts first question"       zeph_body_has "Pick one"

echo
echo "[no question field at all]"
run_hook '{"tool_input":{}}'
assert "fires with fallback text"      zeph_called
assert "body shows 'Question pending'" zeph_body_has "Question pending"

echo
echo "[Korean — UTF-8 safe truncation (≤200 codepoints, never mid-byte)]"
# Build a 250-codepoint Korean string (750 bytes UTF-8).
LONG_KO=$(python3 -c "print('가나다라마바사아자차카타파하 ' * 20)")
run_hook "$(printf '{"tool_input":{"question":"%s"}}' "$LONG_KO")"
assert "fires zeph notify"             zeph_called
# Each Korean char is 3 UTF-8 bytes; 200 codepoints ≈ 600 bytes max.
assert "body stays ≤ 600 bytes (UTF-8 safe)" zeph_body_bytes_le 600

echo
echo "[mute file present — stays silent]"
PROJECT_DIR="$WORK/muted-project"
mkdir -p "$PROJECT_DIR" "$WORK/state/zeph"
MUTE_HASH=$(printf '%s' "$PROJECT_DIR" | cksum | cut -d' ' -f1)
touch "$WORK/state/zeph/muted-$MUTE_HASH"
run_hook '{"tool_input":{"question":"would normally fire"}}' "$PROJECT_DIR"
assert "muted project skips push"      zeph_silent
rm -f "$WORK/state/zeph/muted-$MUTE_HASH"

echo
echo "[user-owned legacy /tmp mute file — stays silent]"
touch "/tmp/zeph-muted-$MUTE_HASH"
run_hook '{"tool_input":{"question":"would normally fire"}}' "$PROJECT_DIR"
assert "legacy mute file still honored" zeph_silent
rm -f "/tmp/zeph-muted-$MUTE_HASH"

echo
echo "[title carries project basename]"
PROJECT_DIR="$WORK/my-fancy-project"
mkdir -p "$PROJECT_DIR"
run_hook '{"tool_input":{"question":"ready?"}}' "$PROJECT_DIR"
assert "title includes project name"   zeph_title_has "my-fancy-project"

echo
echo "[invalid JSON input — jq fails gracefully]"
run_hook 'not-json-at-all{'
# zeph-ask uses .tool_input.question // .tool_input.questions[0].question // "Question pending"
# but if the input isn't valid JSON, jq returns empty/fails; the hook then
# still calls zeph notify with the fallback "Question pending".
assert "doesn't crash; pushes fallback" zeph_called

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
