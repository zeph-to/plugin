#!/usr/bin/env bash
# PreToolUse(AskUserQuestion) hook — push the asked question to the user's
# device so they can see it without being at the terminal.

ZEPH_CMD="$(command -v zeph 2>/dev/null || echo "npx -y @zeph-to/cli")"

command -v jq >/dev/null 2>&1 || exit 0

# Shared hook library (hooks/gate.sh): state-file resolution + CLI bounding.
# Bounding matters doubly here — this hook runs BEFORE the AskUserQuestion
# picker appears, so a cold `npx -y` resolve delays the question itself.
. "$(dirname "${BASH_SOURCE[0]}")/gate.sh"

ZEPH_CMD=$(zeph_wrap_timeout "$ZEPH_CMD")

MUTE_HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)

zeph_state_present muted "$MUTE_HASH" >/dev/null && exit 0

INPUT=$(cat)
QUESTION=$(printf '%s' "$INPUT" | jq -r '.tool_input.question // .tool_input.questions[0].question // "Question pending"' 2>/dev/null)

# AskUserQuestion carries its choices in .questions[].options[].label. The
# default extractor dropped them, so the phone saw only the question stem with
# no idea what the options were. Surface the labels so the user at least knows
# the choices — even though this is a one-way notify (the AskUserQuestion picker
# is a LOCAL blocking UI that cannot be answered from the phone).
OPTIONS=$(printf '%s' "$INPUT" | jq -r '[.tool_input.questions[0].options[]?.label // empty] | join(" · ")' 2>/dev/null)

# UTF-8 safe trim to ~200 chars so multibyte characters (e.g. Korean) don't
# get sliced in the middle and turned into mojibake. Falls back to byte-wise
# `head -c` only when python3 is unavailable.
# NOTE: zeph-stop.sh has a near-twin with a DIFFERENT no-python3 fallback —
# `head -c` here (a hard cap is required) vs `cat` there (empty output falls
# through to its default body). Intentionally not merged.
trim_chars() {
    local n="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import sys
n = int(sys.argv[1])
sys.stdout.write(sys.stdin.read()[:n])
' "$n"
    else
        head -c "$n"
    fi
}
QUESTION=$(printf '%s' "$QUESTION" | trim_chars 160)
OPTIONS=$(printf '%s' "$OPTIONS" | trim_chars 120)

PROJECT=$(basename "$CLAUDE_PROJECT_DIR" 2>/dev/null || echo "unknown")

# Build the body: question, the choices (when present), and an honest note that
# this picker must be answered at the terminal — the title says "asks" but a
# one-way notify can't round-trip an AskUserQuestion answer from the phone.
BODY="$QUESTION"
[ -n "$OPTIONS" ] && BODY="$BODY
▸ $OPTIONS"
BODY="$BODY
↳ answer at the terminal (phone can't drive this picker)"

# Default: silent on failure. Opt-in ZEPH_HOOK_DEBUG=1 logs stderr +
# failures (the silent `2>/dev/null` otherwise hides every hook error).
if [ -n "$ZEPH_HOOK_DEBUG" ]; then
    ZEPH_LOG="${ZEPH_HOOK_LOG:-/tmp/zeph-hook.log}"
    $ZEPH_CMD notify --title "Claude asks: $PROJECT" --body "$BODY" \
        >>"$ZEPH_LOG" 2>&1 || echo "[zeph-ask] notify failed at $(date '+%Y-%m-%d %H:%M:%S')" >>"$ZEPH_LOG"
else
    $ZEPH_CMD notify --title "Claude asks: $PROJECT" --body "$BODY" 2>/dev/null || true
fi
