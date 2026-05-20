#!/usr/bin/env bash
# PreToolUse(AskUserQuestion) hook — push the asked question to the user's
# device so they can see it without being at the terminal.

ZEPH_CMD="$(command -v zeph 2>/dev/null || echo "npx -y @zeph-to/hook-sdk")"

command -v jq >/dev/null 2>&1 || exit 0

MUTE_HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
[ -f "/tmp/zeph-muted-${MUTE_HASH}" ] && exit 0

INPUT=$(cat)
QUESTION=$(printf '%s' "$INPUT" | jq -r '.tool_input.question // .tool_input.questions[0].question // "Question pending"' 2>/dev/null)

# UTF-8 safe trim to ~200 chars so multibyte characters (e.g. Korean) don't
# get sliced in the middle and turned into mojibake. Falls back to byte-wise
# `head -c` only when python3 is unavailable.
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
QUESTION=$(printf '%s' "$QUESTION" | trim_chars 200)

PROJECT=$(basename "$CLAUDE_PROJECT_DIR" 2>/dev/null || echo "unknown")

$ZEPH_CMD notify --title "Claude asks: $PROJECT" --body "$QUESTION" 2>/dev/null || true
