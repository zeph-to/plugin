#!/usr/bin/env bash
# Stop hook — push a completion notification once Claude finishes a response
# that did real work (≥ 2 tool calls THIS TURN). Stays silent when:
#   - the project is muted
#   - jq is not installed
#   - the response already sent a zeph_ask / zeph_prompt (avoid duplicates)

ZEPH_CMD="$(command -v zeph 2>/dev/null || echo "npx -y @zeph-to/cli")"

command -v jq >/dev/null 2>&1 || exit 0

MUTE_HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
[ -f "/tmp/zeph-muted-${MUTE_HASH}" ] && exit 0

INPUT=$(cat)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    exit 0
fi

# Claude Code invokes the Stop hook for every Claude-CLI-driven session that
# terminates — not just the main interactive turn. That includes:
#   - Sub-agents spawned via the Task tool. Their transcripts live under
#     <project>/<session-uuid>/subagents/agent-<id>.jsonl. They typically
#     run many internal tool calls, so they always pass the >=2 gate and
#     fire a spurious push at the end of an interactive turn that used
#     Task at all.
#   - Background observer sessions (e.g. claude-mem) that record memory
#     by spinning up their own short Claude sessions. Their transcripts
#     have project-hash paths like `-Users-.--claude-mem-observer-sessions/`
#     and fire constantly, producing pushes when the user is doing nothing.
# Skip both — we only want the *main* interactive turn ending.
case "$TRANSCRIPT" in
    */subagents/*) exit 0 ;;
    *observer*)    exit 0 ;;
esac

# Scope all checks to "entries since the last *real* user message" — Claude
# Code logs tool_results as synthetic user messages, so a naive
# role=="user" filter would slice mid-turn.
#
# What counts as a *real* user turn:
#   - A message the user typed. Current Claude Code logs these with
#     `.message.content` as a plain STRING. Older transcripts used an
#     array carrying a {"type":"text"} block. Both forms count.
#   - A tool_result is also a user-role message, but its content is an
#     array of tool_result blocks with no text block — it does NOT count.
#
# Defensive note: system prompts and meta events also carry STRING
# content. `content_blocks` guards every array access with
# `type == "array"` so `map(.type)` never crashes on a string ("Cannot
# iterate over string", which would silently kill the Stop hook).
#
# History: 0.5.1 added that string guard to stop the crash, but routed
# is_real_user through `content_blocks` too. Once Claude Code switched
# typed user messages to string content, the guard turned every real
# turn into [] — is_real_user never matched, since_last_user silently
# fell back to the whole transcript, and per-turn scoping died (stale
# summaries, cumulative tool counts). is_real_user now treats non-empty
# string content as a real turn directly.
JQ_SINCE_USER='
def content_blocks:
    .message?.content as $c
    | if ($c | type) == "array" then $c else [] end;
def is_real_user:
    .message?.role == "user"
    and (
        ((.message?.content | type) == "string"
         and (.message?.content | length) > 0)
        or (content_blocks | map(.type) | index("text") != null)
    );
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
       | content_blocks[]
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
       | content_blocks[]
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

# Pull the last assistant text content THIS turn as the body summary.
#
# Timing: Claude Code fires the Stop hook a beat before it flushes the
# turn's final assistant text line to the transcript file. A single read
# therefore often misses the summary — it lands an instant later. Re-read
# a few times (cheap; it's a local file) until the text appears, then
# give up and let BODY fall back to the generic "branch — N tools" form.
# Note this only matters for the body text: tool_use entries are written
# as the turn runs, so TOOL_COUNT / ALREADY_ASKED above are unaffected.
extract_summary() {
    jq -rs "$JQ_SINCE_USER"'
        since_last_user
        | [.[]
           | select(.message?.role == "assistant")
           | content_blocks
           | map(select(.type == "text") | .text)
           | join(" ")
           | select(. != "")]
        | last // ""
    ' "$TRANSCRIPT" 2>/dev/null
}

SUMMARY=$(extract_summary)
summary_tries=0
while [ -z "$SUMMARY" ] && [ "$summary_tries" -lt 5 ]; do
    sleep 0.2
    SUMMARY=$(extract_summary)
    summary_tries=$((summary_tries + 1))
done

# Match the original 0.4.0 behavior of passing the full assistant summary
# through to `zeph notify`. The CLI itself decides what to do with long
# bodies — anything over 512 bytes is auto-uploaded as a file attachment
# and the push gets a 200-char preview plus a file link.
#
# Previous 0.5.0–0.5.2 trimmed to 280 chars here, which collapsed
# English-mostly summaries under the 512-byte threshold and suppressed the
# file-upload path — the push arrived truncated with no way to read the
# rest. This restores the 5000-codepoint cap from 0.4.0 (UTF-8 safe via
# python3, falling through to cat if python is missing).
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
    # Match the original 0.4.0 behavior (jq's `.[0:5000]`) — 5000 codepoints
    # is enough to trigger zeph-cli's >512-byte file-upload path for any
    # multi-paragraph summary, while still capping runaway content. The
    # `[ -n "$TRIMMED" ]` guard preserves the default BODY if trim_chars
    # somehow returns empty (defense in depth — same as 0.4.0 had).
    TRIMMED=$(printf '%s' "$SUMMARY" | trim_chars 5000)
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
