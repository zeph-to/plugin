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

# ZEPH_HOOK_ID is set explicitly on every runner, never inherited. The hook
# routes button-friendly questions to zeph_ask when a hook id exists, so a
# developer with one exported in their own shell would otherwise see these
# notify assertions fail on their machine and pass in CI.
run_hook() {
    local input="$1"
    local project_dir="${2:-/tmp/test-project}"
    rm -f "$WORK/last-call"
    printf '%s' "$input" \
      | CLAUDE_PROJECT_DIR="$project_dir" PATH="$STUB_DIR:$PATH" \
        XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" \
        ZEPH_HOOK_ID="" \
        bash "$HOOK_SCRIPT" 2>/dev/null
}

# Runner for the routing path: a hook id exists, so a push-shaped question is
# denied and handed back for zeph_ask. Each call gets its own state dir so a
# replay marker from one case can't allow the next one through.
run_hook_routed() {
    local input="$1"
    local state_dir="${2:-$WORK/routed-state-$RANDOM}"
    rm -f "$WORK/last-call"
    printf '%s' "$input" \
      | CLAUDE_PROJECT_DIR=/tmp/test-project PATH="$STUB_DIR:$PATH" \
        XDG_STATE_HOME="$state_dir" XDG_CACHE_HOME="$WORK/cache" \
        ZEPH_HOOK_ID="hook_test_id" \
        bash "$HOOK_SCRIPT" 2>/dev/null
}

# Same as run_hook, but with control over the two signals that decide whether
# the phone can drive this pane: $TMUX and the listener pid file under $HOME.
run_hook_mirror() {
    local input="$1" home="$2" tmux_val="$3"
    rm -f "$WORK/last-call"
    printf '%s' "$input" \
      | CLAUDE_PROJECT_DIR=/tmp/test-project PATH="$STUB_DIR:$PATH" \
        XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" \
        HOME="$home" TMUX="$tmux_val" ZEPH_HOOK_ID="" \
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
# argv is one flag/value per line, so the session id is the line after --session.
zeph_session_is() {
    [ -f "$WORK/last-call" ] || return 1
    local got
    got=$(awk '/^--session$/{getline; print; exit}' "$WORK/last-call")
    [ "$got" = "$1" ]
}
zeph_no_session()   { [ -f "$WORK/last-call" ] && ! grep -qx -- '--session' "$WORK/last-call"; }
zeph_priority_is() {
    [ -f "$WORK/last-call" ] || return 1
    local got
    got=$(awk '/^--priority$/{getline; print; exit}' "$WORK/last-call")
    [ "$got" = "$1" ]
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
echo "[priority — the suppressed blocked twin was high, so this must be too]"
run_hook '{"tool_input":{"question":"ready?"}}'
assert "sends --priority high"           zeph_priority_is "high"

echo
echo "[session id — transcript_path carries the Claude session UUID]"
# The server correlates this push with the listener's `blocked` agent.state push
# by session id; without it the same question notifies twice.
UUID="8f14e45f-ceea-467a-9f43-2b8c1e4f9a01"
run_hook "$(printf '{"transcript_path":"/Users/x/.claude/projects/p/%s.jsonl","tool_input":{"question":"ready?"}}' "$UUID")"
assert "passes --session with the UUID"  zeph_session_is "$UUID"

echo
echo "[session id — absent transcript_path stays unflagged]"
run_hook '{"tool_input":{"question":"ready?"}}'
assert "fires without --session"         zeph_no_session

echo
echo "[session id — falls back to the MCP session cache]"
CACHE_PROJECT="$WORK/cached-project"
mkdir -p "$CACHE_PROJECT" "$WORK/cache/zeph"
CACHE_HASH=$(printf '%s' "$CACHE_PROJECT" | cksum | cut -d' ' -f1)
printf 'sess_abc123\n' > "$WORK/cache/zeph/session-$CACHE_HASH"
run_hook '{"tool_input":{"question":"ready?"}}' "$CACHE_PROJECT"
assert "uses cached session id"          zeph_session_is "sess_abc123"

echo
echo "[session id — tampered cache can't inject argv]"
printf 'sess_abc; rm -rf /\n' > "$WORK/cache/zeph/session-$CACHE_HASH"
run_hook '{"tool_input":{"question":"ready?"}}' "$CACHE_PROJECT"
assert "rejects non-token cache value"   zeph_no_session
rm -f "$WORK/cache/zeph/session-$CACHE_HASH"

echo
echo "[mirror hint — listener alive AND in tmux, so the phone can drive the picker]"
# The picker renders in `tmux capture-pane` and a `send-keys Down` moves the
# selection, so a user on the phone CAN answer it — but only when the listener
# daemon is up and this session sits in a tmux pane. Both signals or neither.
MIRROR_HOME="$WORK/mirror-home"
mkdir -p "$MIRROR_HOME/.zeph"
printf '%s\n' "$$" > "$MIRROR_HOME/.zeph/listener.pid"   # $$ is alive by definition
run_hook_mirror '{"tool_input":{"question":"ready?"}}' "$MIRROR_HOME" '/tmp/tmux-501/default,1,0'
assert "body offers the phone's mirror"      zeph_body_has "terminal mirror"

echo
echo "[mirror hint — outside tmux, no mirror to offer]"
run_hook_mirror '{"tool_input":{"question":"ready?"}}' "$MIRROR_HOME" ''
assert "still points at the terminal"        zeph_body_has "answer at the terminal"
assert_not "makes no mirror claim"           zeph_body_has "terminal mirror"

echo
echo "[mirror hint — in tmux but listener never ran]"
NO_LISTENER_HOME="$WORK/no-listener-home"
mkdir -p "$NO_LISTENER_HOME"
run_hook_mirror '{"tool_input":{"question":"ready?"}}' "$NO_LISTENER_HOME" '/tmp/tmux-501/default,1,0'
assert_not "makes no mirror claim"           zeph_body_has "terminal mirror"

echo
echo "[mirror hint — stale pid file (daemon gone)]"
STALE_HOME="$WORK/stale-home"
mkdir -p "$STALE_HOME/.zeph"
sh -c 'exit 0' & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null
printf '%s\n' "$DEAD_PID" > "$STALE_HOME/.zeph/listener.pid"
run_hook_mirror '{"tool_input":{"question":"ready?"}}' "$STALE_HOME" '/tmp/tmux-501/default,1,0'
assert_not "dead pid claims nothing"         zeph_body_has "terminal mirror"

echo
echo "[mirror hint — garbage pid file can't reach kill]"
GARBAGE_HOME="$WORK/garbage-home"
mkdir -p "$GARBAGE_HOME/.zeph"
printf '%s\n' '-1; rm -rf /' > "$GARBAGE_HOME/.zeph/listener.pid"
run_hook_mirror '{"tool_input":{"question":"ready?"}}' "$GARBAGE_HOME" '/tmp/tmux-501/default,1,0'
assert "still pushes"                        zeph_called
assert_not "non-numeric pid claims nothing"  zeph_body_has "terminal mirror"

echo
echo "[routing — a push-shaped question is blocked and handed to zeph_ask]"
OUT=$(run_hook_routed '{"tool_input":{"questions":[{"question":"Apply fix A or B?","options":[{"label":"Apply A"},{"label":"Apply B"}]}]}}')
deny_json_has() { printf '%s' "$OUT" | jq -e "$1" >/dev/null 2>&1; }
assert "emits a PreToolUse deny"       deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'
assert "echoes the hook event name"    deny_json_has '.hookSpecificOutput.hookEventName == "PreToolUse"'
assert "names zeph_ask in the reason"  deny_json_has '.hookSpecificOutput.permissionDecisionReason | test("zeph_ask")'
assert "carries the question verbatim" deny_json_has '.hookSpecificOutput.permissionDecisionReason | test("Apply fix A or B\\?")'
assert "carries the option labels"     deny_json_has '.hookSpecificOutput.permissionDecisionReason | test("Apply A")'
# The model's zeph_ask will push; a notify here would double-send the question.
assert "sends no push of its own"      zeph_silent

echo
echo "[routing — the reason is not truncated like a feed preview]"
LONG_Q=$(python3 -c "print('Should we ' + 'really ' * 30 + 'do it?')")   # ~230 chars, under the 400 limit
OUT=$(run_hook_routed "$(printf '{"tool_input":{"questions":[{"question":"%s","options":[{"label":"Yes"}]}]}}' "$LONG_Q")")
assert "keeps the whole question"      deny_json_has "$(printf '.hookSpecificOutput.permissionDecisionReason | test("do it\\\\?")')"

echo
echo "[routing — carve-out (a): an option preview needs the terminal]"
OUT=$(run_hook_routed '{"tool_input":{"questions":[{"question":"Which layout?","options":[{"label":"A","preview":"+---+\n|   |\n+---+"},{"label":"B"}]}]}}')
assert_not "does not deny"             deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'
assert "falls through to the push"     zeph_called

echo
echo "[routing — carve-out (b): a long option description needs the terminal]"
LONG_D=$(python3 -c "print('detail ' * 40)")   # ~280 chars, over the 240 limit
OUT=$(run_hook_routed "$(printf '{"tool_input":{"questions":[{"question":"Pick","options":[{"label":"A","description":"%s"},{"label":"B"}]}]}}' "$LONG_D")")
assert_not "does not deny"             deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'
assert "falls through to the push"     zeph_called

echo
echo "[routing — no hook id means no zeph_ask to route to]"
run_hook '{"tool_input":{"questions":[{"question":"Apply fix?","options":[{"label":"Yes"}]}]}}'
assert "pushes instead of denying"     zeph_called

echo
echo "[routing — a retry gets through so the session cannot be trapped]"
REPLAY_STATE="$WORK/replay-state"
SAME='{"tool_input":{"questions":[{"question":"Proceed?","options":[{"label":"Yes"},{"label":"No"}]}]}}'
OUT=$(run_hook_routed "$SAME" "$REPLAY_STATE")
assert "first attempt is denied"       deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'
OUT=$(run_hook_routed "$SAME" "$REPLAY_STATE")
assert_not "second attempt is allowed" deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'
assert "and pushes as before"          zeph_called

echo
echo "[routing — a different question in the same window is still denied]"
OTHER='{"tool_input":{"questions":[{"question":"Continue?","options":[{"label":"Yes"},{"label":"No"}]}]}}'
OUT=$(run_hook_routed "$OTHER" "$REPLAY_STATE")
assert "no collision with the first"   deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'

echo
echo "[routing — input jq cannot read is pushed, not denied]"
# A deny here would block the picker over a question the hook never managed to
# read, leaving the model a reason built from empty strings.
run_hook_routed 'not-json-at-all{'
assert "unmeasurable input still pushes" zeph_called

echo
echo "[routing — the deny path never shells out to the CLI]"
# A stub that fails loudly stands in for the real binary: if the deny path
# called it, the marker file would exist. The undocumented hook-timeout
# behaviour is why this path must not be able to block at all.
cat > "$STUB_DIR/zeph" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/last-call"
touch "$WORK/cli-was-called"
EOF
chmod +x "$STUB_DIR/zeph"
rm -f "$WORK/cli-was-called"
run_hook_routed '{"tool_input":{"questions":[{"question":"Deploy now?","options":[{"label":"Yes"}]}]}}' >/dev/null
assert "no CLI invocation on deny"     test ! -f "$WORK/cli-was-called"

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
