#!/usr/bin/env bash
# Fixture-based tests for hooks/zeph-stop.sh.
#
# No external test framework — plain bash with a tiny assert helper.
# Stubs `zeph` on PATH so we can assert on the CLI invocation arguments
# without sending real pushes.
#
# Usage:
#   ./tests/test-zeph-stop.sh           # run from repo root
#   bash tests/test-zeph-stop.sh
#
# Exit code 0 = all pass; non-zero = some failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/zeph-stop.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

[ -f "$HOOK_SCRIPT" ] || { echo "hook script not found: $HOOK_SCRIPT" >&2; exit 1; }

# Ensure required deps for the hook itself
command -v jq >/dev/null     || { echo "jq required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

# Generate the long-summary fixture if missing
[ -f "$FIXTURES/main-long-summary-ko.jsonl" ] || bash "$FIXTURES/gen-long-summary.sh" >/dev/null

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR"

# Stub zeph CLI that records its arguments to a file we can grep.
cat > "$STUB_DIR/zeph" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/last-call"
EOF
chmod +x "$STUB_DIR/zeph"

# Assertion plumbing — collected + reported at the end.
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

# Hook invocation helper. Wipes the last-call record, optionally puts
# transcript at a custom path, then pipes the input JSON to the hook.
run_hook() {
    local transcript="$1"
    local project_dir="${2:-/tmp}"
    rm -f "$WORK/last-call"
    echo "{\"transcript_path\":\"$transcript\"}" \
      | CLAUDE_PROJECT_DIR="$project_dir" PATH="$STUB_DIR:$PATH" \
        bash "$HOOK_SCRIPT" 2>/dev/null
}

zeph_called()   { [ -f "$WORK/last-call" ]; }
zeph_silent()   { [ ! -f "$WORK/last-call" ]; }
zeph_body_has() { [ -f "$WORK/last-call" ] && grep -qF -- "$1" "$WORK/last-call"; }
zeph_body_bytes_gt() {
    [ -f "$WORK/last-call" ] || return 1
    local body bytes
    body=$(awk '/^--body$/{getline; print; exit}' "$WORK/last-call")
    bytes=$(printf '%s' "$body" | wc -c | tr -d ' ')
    [ "$bytes" -gt "$1" ]
}

# ── tests ──────────────────────────────────────────────────────────────────

echo "[main 2-tool turn — happy path]"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "fires zeph notify"               zeph_called
assert "body carries assistant summary"  zeph_body_has "all good"
assert "title includes project name"     zeph_body_has "Claude:"

echo
echo "[main 1-tool turn — below threshold]"
run_hook "$FIXTURES/main-1-tool.jsonl"
assert "stays silent (TOOL_COUNT < 2)"   zeph_silent

echo
echo "[main turn with zeph_ask — dedup]"
run_hook "$FIXTURES/main-with-zeph-ask.jsonl"
assert "stays silent (ALREADY_ASKED > 0)" zeph_silent

echo
echo "[regression: string-content system message doesn't crash jq]"
# main-2-tools.jsonl already starts with a string-content system message.
# If is_real_user crashes on `map(.type)` over a string, TOOL_COUNT comes
# back empty, the hook exits at the < 2 gate, and we get false silence.
# So this test piggybacks on the happy path above — if 'fires' passed,
# the guard works. Document it explicitly here too:
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "hook survives string content"    zeph_called

echo
echo "[multi-turn — scoping respects the LAST real user turn]"
# First turn: 5 tools. Second turn: 1 tool. Stop hook runs at the end
# of the second turn — must count only that turn's 1 tool, not 5+1=6.
run_hook "$FIXTURES/main-multi-turn.jsonl"
assert "ignores tool_use from earlier turns" zeph_silent

echo
echo "[subagent transcript — must be skipped]"
SUB_DIR="$WORK/sub/subagents"
mkdir -p "$SUB_DIR"
cp "$FIXTURES/main-2-tools.jsonl" "$SUB_DIR/agent-test.jsonl"
run_hook "$SUB_DIR/agent-test.jsonl"
assert "subagent transcript silenced"    zeph_silent

echo
echo "[observer transcript — must be skipped]"
OBS_DIR="$WORK/observer-sessions"
mkdir -p "$OBS_DIR"
cp "$FIXTURES/main-2-tools.jsonl" "$OBS_DIR/session.jsonl"
run_hook "$OBS_DIR/session.jsonl"
assert "observer transcript silenced"    zeph_silent

echo
echo "[mute file present]"
PROJECT_DIR="$WORK/mute-project"
mkdir -p "$PROJECT_DIR"
MUTE_HASH=$(printf '%s' "$PROJECT_DIR" | cksum | cut -d' ' -f1)
touch "/tmp/zeph-muted-$MUTE_HASH"
run_hook "$FIXTURES/main-2-tools.jsonl" "$PROJECT_DIR"
assert "muted project skips push"        zeph_silent
rm -f "/tmp/zeph-muted-$MUTE_HASH"

echo
echo "[transcript_path missing — graceful exit]"
rm -f "$WORK/last-call"
echo '{}' | CLAUDE_PROJECT_DIR=/tmp PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" 2>/dev/null
assert "exits cleanly on empty input"    zeph_silent

echo
echo "[transcript file does not exist]"
run_hook "/tmp/nonexistent-zeph-test-transcript-$$.jsonl"
assert "skips when file missing"         zeph_silent

echo
echo "[empty SUMMARY — falls back to 'branch — N tools']"
run_hook "$FIXTURES/main-empty-summary.jsonl"
assert "still fires (≥2 tools, no text)" zeph_called
assert "body falls back to default form" zeph_body_has "tools"

echo
echo "[long Korean summary >512B — triggers CLI file-upload path]"
run_hook "$FIXTURES/main-long-summary-ko.jsonl"
assert "fires zeph notify"               zeph_called
assert "body exceeds 512 bytes"          zeph_body_bytes_gt 512

echo
echo "[trim cap — body never exceeds 5000 codepoints (~15000 bytes for Korean)]"
# Korean 1 char = 3 UTF-8 bytes. 5000 codepoints ≤ 15000 bytes.
run_hook "$FIXTURES/main-long-summary-ko.jsonl"
assert_not "body stays under 15000-byte safety cap" zeph_body_bytes_gt 15000

# ── summary ────────────────────────────────────────────────────────────────

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
