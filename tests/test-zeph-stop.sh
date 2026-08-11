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
# The push-mode tests below write /tmp/zeph-pushmode-<hash for "/tmp">; clean it
# on exit so a failed run never leaves a stray mode set on the machine.
TMP_PUSHMODE="/tmp/zeph-pushmode-$(printf '%s' /tmp | cksum | cut -d' ' -f1)"
trap 'rm -rf "$WORK"; rm -f "$TMP_PUSHMODE"' EXIT
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
        XDG_STATE_HOME="$WORK/state" \
        bash "$HOOK_SCRIPT" 2>/dev/null
}

# Push-mode helpers — write/clear the per-project push-mode file the hook reads.
# Hash matches the hook's `printf '%s' "$dir" | cksum` keying.
pushmode_file() { printf '/tmp/zeph-pushmode-%s' "$(printf '%s' "${1:-/tmp}" | cksum | cut -d' ' -f1)"; }
set_pushmode()   { printf '%s' "$1" > "$(pushmode_file "${2:-/tmp}")"; }
clear_pushmode() { rm -f "$(pushmode_file "${1:-/tmp}")"; }

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

# The shipped default with no dial file is `quiet`, so every section that
# exercises the normal-mode heuristic or the Push Signal markers pins the dial
# explicitly — otherwise those cases would all read as "silent because quiet"
# and stop testing what they name. The default itself gets its own section
# below ("push mode: no dial").
set_pushmode normal

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
echo "[regression: string-content turn detection]"
# Real Claude Code logs typed user messages with .message.content as a
# STRING (not an array of blocks). is_real_user must still recognise them
# as turn boundaries — otherwise since_last_user falls back to the whole
# transcript and every per-turn check breaks. main-2-tools.jsonl uses
# string-content user messages throughout; this documents the scenario
# explicitly (the happy path above also exercises it).
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "string-content user turn is detected" zeph_called
assert "summary scoped to this turn"          zeph_body_has "all good"

echo
echo "[legacy array-form user message — is_real_user 'or' branch]"
# Older transcripts wrap typed user input in an array carrying a text
# block. is_real_user must keep matching that shape too.
run_hook "$FIXTURES/main-array-user-2-tools.jsonl"
assert "array-form user turn is detected" zeph_called
assert "summary scoped to this turn"      zeph_body_has "legacy array form summary"

echo
echo "[off-by-one regression — turn-2 push must NOT leak turn-1 text]"
# The bug the string-content fix targets: turn 1 ends with a text answer;
# turn 2 does 2 tools and the Stop hook fires before turn 2's final text
# is flushed. Broken scoping → SUMMARY = turn-1 text → the push leaks the
# previous answer. Fixed → scope to turn 2 → empty summary → default body.
run_hook "$FIXTURES/main-stale-summary.jsonl"
assert     "fires (turn-2 crossed the >=2 gate)"   zeph_called
assert_not "body does NOT leak previous turn text" zeph_body_has "PREV_TURN_ANSWER"
assert     "body falls back to default form"       zeph_body_has "tools"

echo
echo "[multi-turn — scoping respects the LAST real user turn]"
# First turn: 5 tools. Second turn: 1 tool. Stop hook runs at the end of
# the second turn — TOOL_COUNT must count only that turn's 1 tool, not
# 5+1=6. With broken string-content detection it would count all 6 and
# wrongly fire.
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
echo "[mute file present — state dir]"
PROJECT_DIR="$WORK/mute-project"
mkdir -p "$PROJECT_DIR" "$WORK/state/zeph"
MUTE_HASH=$(printf '%s' "$PROJECT_DIR" | cksum | cut -d' ' -f1)
touch "$WORK/state/zeph/muted-$MUTE_HASH"
run_hook "$FIXTURES/main-2-tools.jsonl" "$PROJECT_DIR"
assert "muted project skips push"        zeph_silent
rm -f "$WORK/state/zeph/muted-$MUTE_HASH"

echo
echo "[mute file present — user-owned legacy /tmp]"
touch "/tmp/zeph-muted-$MUTE_HASH"
run_hook "$FIXTURES/main-2-tools.jsonl" "$PROJECT_DIR"
assert "legacy mute file still honored"  zeph_silent
rm -f "/tmp/zeph-muted-$MUTE_HASH"

echo
echo "[transcript_path missing — graceful exit]"
rm -f "$WORK/last-call"
echo '{}' | CLAUDE_PROJECT_DIR=/tmp PATH="$STUB_DIR:$PATH" XDG_STATE_HOME="$WORK/state" bash "$HOOK_SCRIPT" 2>/dev/null
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

echo
echo "[B1 read-only floor — turn whose tools are all Read/Grep/Glob → skip]"
# Exploration noise: the #1 false-positive the old ≥2-tool gate produced.
# No marker + every tool read-only → suppress deterministically (no model dep).
run_hook "$FIXTURES/main-readonly-only.jsonl"
assert "read-only-only turn stays silent" zeph_silent

echo
echo "[marker: skip — suppress a turn that WOULD fire]"
# Read+Edit (mixed, crosses every heuristic) but the model tagged it skip.
run_hook "$FIXTURES/main-marker-skip.jsonl"
assert "skip marker silences a ≥2 mixed-tool turn" zeph_silent

echo
echo "[marker: push — force a push the heuristic would skip]"
# Single Bash (force-push): 1 tool < 2 → heuristic stays silent; push marker fires.
run_hook "$FIXTURES/main-marker-push.jsonl"
assert     "push marker fires below the heuristic" zeph_called
assert     "body carries the summary"              zeph_body_has "force-pushed main"
assert_not "marker stripped from body"             zeph_body_has "<!--"

echo
echo "[marker: high — force push at high priority]"
run_hook "$FIXTURES/main-marker-high.jsonl"
assert     "high marker fires"             zeph_called
assert     "push carries --priority flag"  zeph_body_has "--priority"
assert     "priority value is high"        zeph_body_has "high"
assert_not "marker stripped from body"     zeph_body_has "<!--"

echo
echo "[marker: malformed no-space variant — detected AND stripped (leak guard)]"
# `<!--zeph:push-->` (no spaces). Detect and strip share one pattern, so a
# slightly-off marker can never be detected-but-not-stripped → no plaintext leak.
run_hook "$FIXTURES/main-marker-nospace.jsonl"
assert     "no-space push marker still fires"   zeph_called
assert     "body carries the summary"           zeph_body_has "release tag"
assert_not "no-space marker stripped from body" zeph_body_has "<!--"
assert_not "no leftover zeph token in body"     zeph_body_has "zeph:"

echo
echo "[marker: newline-split — NOT a valid marker (detect/strip symmetry)]"
# A marker whose whitespace spans a newline is honoured by NEITHER detect nor
# strip: MARKER_RE uses [[:blank:]] (no newline), so bash's whole-buffer match
# and sed's line-by-line strip agree — it is simply not a marker. Guards against
# the asymmetry where bash detects (fires) a marker sed cannot strip (leak).
# Here a 1-tool turn → no marker detected → heuristic <2 → silent.
run_hook "$FIXTURES/main-marker-newline.jsonl"
assert "newline-split push marker is ignored (1-tool turn stays silent)" zeph_silent

echo
echo "[push mode: quiet — only a high marker survives]"
# User dial (mirrors mute): quiet suppresses every auto-push except high.
set_pushmode quiet
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "quiet suppresses a normal push (mixed-tool turn)" zeph_silent
run_hook "$FIXTURES/main-marker-high.jsonl"
assert     "quiet still lets a high marker through" zeph_called
assert     "high push keeps --priority"            zeph_body_has "--priority"
run_hook "$FIXTURES/main-marker-push.jsonl"
assert "quiet suppresses a plain push marker" zeph_silent
set_pushmode normal

echo
echo "[push mode: loud — push every turn, override skip / <2 / B1]"
set_pushmode loud
run_hook "$FIXTURES/main-1-tool.jsonl"
assert "loud fires on a <2-tool turn"            zeph_called
run_hook "$FIXTURES/main-readonly-only.jsonl"
assert "loud fires on an all-read-only turn"     zeph_called
run_hook "$FIXTURES/main-marker-skip.jsonl"
assert "loud overrides a skip marker"            zeph_called
run_hook "$FIXTURES/main-with-zeph-ask.jsonl"
assert "loud still respects dedup (ask already pushed)" zeph_silent
set_pushmode normal

echo
echo "[push mode: no dial — quiet is the default]"
# A fresh install has no dial file. The hook passes the (empty) dial contents
# straight to zeph_gate_decide, whose 5th-argument default decides. This is the
# behavior every existing install inherits on upgrade, so it is asserted
# directly rather than left to the gate unit tests.
clear_pushmode
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "no dial suppresses a mixed-tool turn" zeph_silent
run_hook "$FIXTURES/main-marker-push.jsonl"
assert "no dial suppresses a plain push marker" zeph_silent
run_hook "$FIXTURES/main-marker-high.jsonl"
assert "no dial still lets a high marker through" zeph_called

echo
echo "[push mode: dial file present but empty — normal, not quiet]"
# An empty dial file is a corrupted dial, not an absent one. Reading it as
# quiet would turn a broken write into silence the user cannot explain, and it
# would also split the two implementations: the TS twin's normalizePushMode('')
# returns normal. The hook substitutes normal before the gate sees it.
printf '' > "$(pushmode_file /tmp)"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "empty dial falls back to the normal heuristic" zeph_called
clear_pushmode

echo
echo "[push mode: project hash unavailable — normal, not quiet]"
# Without `cksum` the hook cannot key any state file, so it cannot find a dial
# even if one exists. That is a broken environment, not a user who left the dial
# alone, and the quiet default must not absorb it — the TS twin's readPushMode
# returns `normal` for the same failure (`if (!hash) return 'normal'`), and
# silence is the one symptom the user cannot tell apart from working correctly.
cat > "$STUB_DIR/cksum" <<'CKSUM'
#!/bin/bash
exit 127
CKSUM
chmod +x "$STUB_DIR/cksum"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "an unhashable project falls back to the normal heuristic" zeph_called
run_hook "$FIXTURES/main-readonly-only.jsonl"
assert "and the normal heuristic still applies its floors" zeph_silent
rm -f "$STUB_DIR/cksum"

echo
echo "[push mode: global default — /zeph-quiet --global]"
# `pushmode-default` is the machine-wide fallback, consulted only when the
# project has no dial of its own (state dir or legacy /tmp).
mkdir -p "$WORK/state/zeph"
printf 'quiet' > "$WORK/state/zeph/pushmode-default"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "global quiet suppresses a normal push"          zeph_silent
run_hook "$FIXTURES/main-marker-high.jsonl"
assert "global quiet still lets a high marker through"  zeph_called
# A per-project dial outranks it — that's how /zeph-normal opts one project out.
GLOBAL_PROJECT="$WORK/global-project"
mkdir -p "$GLOBAL_PROJECT"
GP_HASH=$(printf '%s' "$GLOBAL_PROJECT" | cksum | cut -d' ' -f1)
printf 'normal' > "$WORK/state/zeph/pushmode-$GP_HASH"
run_hook "$FIXTURES/main-2-tools.jsonl" "$GLOBAL_PROJECT"
assert "project dial overrides the global default"      zeph_called
rm -f "$WORK/state/zeph/pushmode-default" "$WORK/state/zeph/pushmode-$GP_HASH"

echo
echo "[mute has no global default — project-only by design]"
# Mute is presence-keyed, so a global mute file could never be lifted for a
# single project. Only `pushmode` falls back to `-default`; lock that here.
set_pushmode normal
touch "$WORK/state/zeph/muted-default"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "muted-default does not silence an unmuted project" zeph_called
rm -f "$WORK/state/zeph/muted-default"

echo
echo "[exit marker clears sticky REMOTE — including on the silent quiet path]"
# The free-text exit is the one signal the server cannot see, so the model
# marks it and this hook acts on it. It has to work on a stock quiet install,
# where the gate returns silent and everything after it never runs.
remote_state_file() { printf '%s/state/zeph/remote-active-%s' "$WORK" "$(printf '%s' "${1:-/tmp}" | cksum | cut -d' ' -f1)"; }
clear_pushmode
mkdir -p "$WORK/state/zeph"
date +%s > "$(remote_state_file)"
run_hook "$FIXTURES/main-marker-exit.jsonl"
assert "no push on the quiet default"  zeph_silent
assert "REMOTE state cleared anyway"   [ ! -f "$(remote_state_file)" ]

echo
echo "[exit marker never leaks into the push body]"
set_pushmode loud
date +%s > "$(remote_state_file)"
run_hook "$FIXTURES/main-marker-exit.jsonl"
assert     "pushes (loud)"                zeph_called
assert     "body keeps the real summary"  zeph_body_has "Cleaned up the scratch files."
assert_not "body does not carry the raw marker"  zeph_body_has "zeph: exit"
assert     "REMOTE state cleared"         [ ! -f "$(remote_state_file)" ]
clear_pushmode

echo
echo "[no exit marker leaves sticky REMOTE alone]"
set_pushmode loud
date +%s > "$(remote_state_file)"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "REMOTE state untouched"  [ -f "$(remote_state_file)" ]
rm -f "$(remote_state_file)"
clear_pushmode

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
