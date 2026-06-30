#!/usr/bin/env bash
# Stop hook — push a completion notification once Claude finishes a response.
# A Push Signal marker in the response (`<!-- zeph: skip|push|high -->`) overrides
# the default; absent one, the turn pushes only if it did real work — ≥2 tool
# calls AND not all read-only (Read/Grep/Glob). Stays silent when:
#   - the project is muted
#   - jq is not installed
#   - the response already sent a zeph_ask / zeph_prompt (avoid duplicates)
#   - a `skip` marker, or the no-marker heuristic above, says so

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

# ── Per-turn tool tallies (one jq pass) ──────────────────────────────────────
# Three counts drive the gate, all derived from the same tool_use list, so a
# single jq pass emits them as one "ask tools nonreadonly" tuple:
#   ALREADY_ASKED     — zeph_ask/zeph_prompt this turn (a push already went out)
#   TOOL_COUNT        — total tool_use blocks
#   NONREADONLY_COUNT — tools that are NOT read-only (Read/Grep/Glob); a turn
#                       with zero is exploration noise the B1 floor drops.
read ALREADY_ASKED TOOL_COUNT NONREADONLY_COUNT < <(jq -rs "$JQ_SINCE_USER"'
    since_last_user
    | [.[] | content_blocks[] | select(.type == "tool_use") | .name // ""] as $tools
    | "\($tools | map(select(. == "zeph_ask" or . == "zeph_prompt")) | length) \($tools | length) \($tools | map(select(. != "Read" and . != "Grep" and . != "Glob")) | length)"
' "$TRANSCRIPT" 2>/dev/null)
ALREADY_ASKED=${ALREADY_ASKED:-0}
TOOL_COUNT=${TOOL_COUNT:-0}
NONREADONLY_COUNT=${NONREADONLY_COUNT:-0}

# Dedup: if the assistant already sent a zeph_ask / zeph_prompt this turn, that
# already delivered a notification — never double-fire (checked before the marker
# gate so a Push Signal can never stack a second push on top of an ask-push).
[ "$ALREADY_ASKED" -gt 0 ] && exit 0

# Last assistant text THIS turn — needed both to read the Push Signal marker and
# (later) as the push body.
#
# Timing: Claude Code fires the Stop hook a beat before it flushes the turn's
# final assistant text. A single read often misses it — it lands an instant
# later. Marker detection uses only a SHORT bounded wait: a fast-exit turn (skip
# / read-only / <2 tools) must never block on a body it will never send. The
# longer body wait runs only once a push is committed (further down).
extract_last_text() {
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

TEXT=$(extract_last_text)
marker_tries=0
while [ -z "$TEXT" ] && [ "$marker_tries" -lt 3 ]; do
    sleep 0.15
    TEXT=$(extract_last_text)
    marker_tries=$((marker_tries + 1))
done

# Push Signal — the model steers this turn's push by emitting a marker. ONE
# pattern drives BOTH detect (bash `[[ =~ ]]`) and strip (`sed`), so a
# slightly-malformed marker can never be detected-but-not-stripped (which would
# leak the raw `<!-- zeph: ... -->` into the plaintext push body). The gaps use
# `[[:blank:]]` (space/tab only, NOT newline) on purpose: bash matches the whole
# multiline text in one buffer while sed works line-by-line, so a newline-spanning
# class would let bash detect a marker sed can't strip. With `[[:blank:]]` neither
# spans a newline, so detection and stripping stay symmetric. The rule emits a
# single-line lowercase marker, so no newline or case-insensitive matching needed.
MARKER_RE='<!--[[:blank:]]*zeph:[[:blank:]]*(skip|push|high)[[:blank:]]*-->'
MARKER=""
[[ "$TEXT" =~ $MARKER_RE ]] && MARKER="${BASH_REMATCH[1]}"

# ── Gate: marker overrides the volume heuristic ──────────────────────────────
#   skip      → suppress
#   push/high → force a push even below the heuristic (high → high priority)
#   (no marker) → <2 tools OR all read-only → suppress; otherwise push
PRIORITY=""
case "$MARKER" in
    skip) exit 0 ;;
    high) PRIORITY="high" ;;
    push) : ;;
    *)
        [ "$TOOL_COUNT" -lt 2 ] && exit 0
        [ "$NONREADONLY_COUNT" -eq 0 ] && exit 0
        ;;
esac

PROJECT=$(basename "$CLAUDE_PROJECT_DIR" 2>/dev/null || echo "unknown")
BRANCH=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")

# A push is now committed. Extend the wait for the body text — the late flush
# this targets only matters here, for turns that actually push.
SUMMARY="$TEXT"
summary_tries=0
while [ -z "$SUMMARY" ] && [ "$summary_tries" -lt 5 ]; do
    sleep 0.2
    SUMMARY=$(extract_last_text)
    summary_tries=$((summary_tries + 1))
done

# Strip the marker from the body with the SAME pattern used to detect it.
[ -n "$SUMMARY" ] && SUMMARY=$(printf '%s' "$SUMMARY" | sed -E "s/$MARKER_RE//g")

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

# A `high` Push Signal escalates the push priority; skip/push/none leave the CLI
# default (normal).
PRIORITY_FLAG=""
[ -n "$PRIORITY" ] && PRIORITY_FLAG="--priority $PRIORITY"

# Default: stay silent on failure (a hook must never disrupt the session).
# Opt-in: set ZEPH_HOOK_DEBUG=1 to capture stderr + failures to a log for
# support, since the silent `2>/dev/null` otherwise hides every hook error.
# shellcheck disable=SC2086
if [ -n "$ZEPH_HOOK_DEBUG" ]; then
    ZEPH_LOG="${ZEPH_HOOK_LOG:-/tmp/zeph-hook.log}"
    $ZEPH_CMD notify --title "Claude: $PROJECT" --body "$BODY" --type hook $SESSION_FLAG $PRIORITY_FLAG \
        >>"$ZEPH_LOG" 2>&1 || echo "[zeph-stop] notify failed at $(date '+%Y-%m-%d %H:%M:%S')" >>"$ZEPH_LOG"
else
    $ZEPH_CMD notify --title "Claude: $PROJECT" --body "$BODY" --type hook $SESSION_FLAG $PRIORITY_FLAG 2>/dev/null || true
fi
