#!/usr/bin/env bash
# Stop hook — push a completion notification once Claude finishes a response
# that did real work (≥ 2 tool calls THIS TURN). Stays silent when:
#   - the project is muted
#   - jq is not installed
#   - the response already sent a zeph_ask / zeph_prompt (avoid duplicates)

ZEPH_CMD="$(command -v zeph 2>/dev/null || echo "npx -y @zeph-to/hook-sdk")"

command -v jq >/dev/null 2>&1 || exit 0

MUTE_HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
[ -f "/tmp/zeph-muted-${MUTE_HASH}" ] && exit 0

INPUT=$(cat)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    exit 0
fi

# Scope all checks to "entries since the last *real* user message" — Claude
# Code logs tool_results as synthetic user messages, so a naive
# role=="user" filter would slice mid-turn. A real user turn is a user
# message whose content carries a text block.
JQ_SINCE_USER='
def is_real_user:
    .message?.role == "user"
    and ((.message?.content // []) | map(.type) | index("text") != null);
def since_last_user:
    . as $all
    | ($all | map(is_real_user) | reverse | index(true)) as $rev
    | if $rev == null then $all
      else $all[(length - $rev):]
      end;
'

# Count actual tool_use blocks this turn.
TOOL_COUNT=$(jq -rs "$JQ_SINCE_USER"'
    since_last_user
    | [.[]
       | .message?
       | (.content // [])[]?
       | select(.type == "tool_use")]
    | length
' "$TRANSCRIPT" 2>/dev/null)
TOOL_COUNT=${TOOL_COUNT:-0}

if [ "$TOOL_COUNT" -lt 2 ]; then
    exit 0
fi

# Skip if the assistant already sent a zeph_ask / zeph_prompt this turn —
# that already delivers a notification, so the Stop hook would duplicate.
ALREADY_ASKED=$(jq -rs "$JQ_SINCE_USER"'
    since_last_user
    | [.[]
       | .message?
       | (.content // [])[]?
       | select(.type == "tool_use")
       | .name // ""
       | select(. == "zeph_ask" or . == "zeph_prompt")]
    | length
' "$TRANSCRIPT" 2>/dev/null)
ALREADY_ASKED=${ALREADY_ASKED:-0}

if [ "$ALREADY_ASKED" -gt 0 ]; then
    exit 0
fi

PROJECT=$(basename "$CLAUDE_PROJECT_DIR" 2>/dev/null || echo "unknown")
BRANCH=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")

# Pull the last assistant text content this turn as the body summary.
SUMMARY=$(jq -rs "$JQ_SINCE_USER"'
    since_last_user
    | [.[]
       | select(.message?.role == "assistant")
       | (.message?.content // [])
       | map(select(.type == "text") | .text)
       | join(" ")
       | select(. != "")]
    | last // ""
' "$TRANSCRIPT" 2>/dev/null)

# UTF-8 safe trim to ~280 chars (phone push bodies are short). Falls back to
# pass-through if python3 is unavailable.
trim_chars() {
    local n="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import sys
n = int(sys.argv[1])
sys.stdout.write(sys.stdin.read()[:n])
' "$n"
    else
        cat
    fi
}

BODY="${BRANCH} — ${TOOL_COUNT} tools"
if [ -n "$SUMMARY" ] && [ "$SUMMARY" != "null" ]; then
    TRIMMED=$(printf '%s' "$SUMMARY" | trim_chars 280)
    [ -n "$TRIMMED" ] && BODY="$TRIMMED"
fi

# Extract session UUID from transcript path (more reliable than cache file).
# Fallback to the MCP server's per-user session cache for older Claude Code
# versions that didn't expose a UUID-bearing transcript_path. The cache file
# moved from /tmp (symlink-race prone, world-writable parent) to ~/.cache —
# read both during the migration window.
SESSION_ID=$(printf '%s' "$TRANSCRIPT" | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' | tail -n1)
if [ -z "$SESSION_ID" ]; then
    ZEPH_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zeph"
    SESSION_ID=$(cat "$ZEPH_CACHE_DIR/session-${MUTE_HASH}" 2>/dev/null \
              || cat "/tmp/zeph-session-${MUTE_HASH}" 2>/dev/null)
fi
SESSION_FLAG=""
[ -n "$SESSION_ID" ] && SESSION_FLAG="--session $SESSION_ID"

# shellcheck disable=SC2086
$ZEPH_CMD notify --title "Claude: $PROJECT" --body "$BODY" --type hook $SESSION_FLAG 2>/dev/null || true
