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
# no idea what the options were. Surface the labels so the user knows the
# choices — this push is one-way, but the answer itself need not be: when the
# session runs in tmux under `zeph listener`, the phone's terminal mirror can
# drive the picker directly (see mirror_available below).
OPTIONS=$(printf '%s' "$INPUT" | jq -r '[.tool_input.questions[0].options[]?.label // empty] | join(" · ")' 2>/dev/null)

# ── Route the question, or let the picker open ───────────────────────────────
#
# CORE_RULES rules 10/11 already say a button-friendly question belongs in
# `zeph_ask`. Enforcing that here closes the path where ignoring the rule
# succeeds quietly and strands whoever is holding a phone. `zeph_ask_decide`
# (hooks/gate.sh) owns the judgment; this block only measures the inputs.
#
# Honest about how far this goes: the BLOCK is deterministic, the RECOVERY is
# not. Nothing here can make the model call `zeph_ask` — it can only make the
# wrong path fail loudly instead of silently, and hand over the text needed to
# do the right thing.

# Falls back to a NON-NUMERIC sentinel, not 0. A jq failure means the input
# could not be measured, and zeph_ask_decide reads anything non-numeric as
# "don't guess, allow". Falling back to 0 would instead look like a genuinely
# short question and route it — turning unparseable input into a deny.
ask_measure() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null || echo unmeasurable; }

HAS_PREVIEW=$(ask_measure '[.tool_input.questions[]?.options[]?.preview // empty] | if length > 0 then 1 else 0 end')
QUESTION_CHARS=$(ask_measure '(.tool_input.question // .tool_input.questions[0].question // "") | length')
# Longest label+description across every option: `description` is where long
# content actually lands, so measuring labels alone would miss the carve-out.
OPTION_CHARS=$(ask_measure '[.tool_input.questions[]?.options[]? | ((.label // "") + (.description // "")) | length] | max // 0')

# Keyed on the whole tool_input, not the question stem: "Proceed?" recurs
# constantly in one session and would collide with unrelated questions.
ASK_HASH=$(printf '%s' "$INPUT" | jq -cS '.tool_input' 2>/dev/null | cksum | tr -d ' ')
[ -n "$ASK_HASH" ] || ASK_HASH=none
# Project-scoped, like every other state file (`muted-<project>`): the same
# question in two projects within the window is ordinary, and one project's
# deny must not let the other's picker through.
ASK_KEY="${MUTE_HASH}-${ASK_HASH}"

HOOKID_PRESENT=0
[ -n "${ZEPH_HOOK_ID:-}" ] && HOOKID_PRESENT=1
REPLAY=0
zeph_ask_replay_seen "$ASK_KEY" && REPLAY=1

# muted is passed as 0 because a muted project already left this script at the
# `zeph_state_present muted` check above. The parameter stays in the function's
# signature so the decision reads completely on its own in the vectors.
if [ "$(zeph_ask_decide "$HOOKID_PRESENT" 0 "$HAS_PREVIEW" "$QUESTION_CHARS" "$OPTION_CHARS" "$REPLAY")" = deny ]; then
    zeph_ask_replay_mark "$ASK_KEY"
    # Deliberately NOT trimmed: trim_chars below exists for the device feed
    # preview, and the model has to re-ask this question verbatim.
    #
    # No `$ZEPH_CMD` on this path, and no other network call. Claude Code's
    # behaviour when a hook times out is undocumented — if it fails open, a
    # hook that hangs here would let the picker through while the user believes
    # it was routed; if it fails closed, the picker is blocked with no reason
    # attached and the model has nothing to act on. Neither can happen if the
    # path cannot block.
    OPTION_LINE=""
    [ -n "$OPTIONS" ] && OPTION_LINE=" Options: $OPTIONS."
    jq -n --arg reason "Do not use AskUserQuestion here. Ask this exact question again with the zeph_ask tool so the user can answer it from their phone: \"$QUESTION\".$OPTION_LINE Map each option to a zeph_ask action and use the response in place of the picker." \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' \
        2>/dev/null
    exit 0
fi

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

# Session id — the key the server uses to recognize that this question already
# notified. Without it the listener's `blocked` agent.state push fires a second
# notification for the same question seconds later. Extraction mirrors
# zeph-stop.sh: UUID out of the transcript path, MCP session cache as the
# fallback, and the same argv-injection guard on the cache value (it expands
# unquoted below, and the legacy /tmp copy has a world-writable parent).
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "$TRANSCRIPT" | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' | tail -n1)
if [ -z "$SESSION_ID" ]; then
    ZEPH_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zeph"
    SESSION_ID=$(cat "$ZEPH_CACHE_DIR/session-${MUTE_HASH}" 2>/dev/null \
              || cat "/tmp/zeph-session-${MUTE_HASH}" 2>/dev/null)
    case "$SESSION_ID" in
        *[!A-Za-z0-9_-]*) SESSION_ID="" ;;
    esac
fi
SESSION_FLAG=""
[ -n "$SESSION_ID" ] && SESSION_FLAG="--session $SESSION_ID"

# High priority because this push now stands alone. The server suppresses its
# `blocked` agent.state twin once this one is on file, and that twin was high —
# sending this at the default `normal` would quietly demote every question the
# user gets on their phone.

# Can the phone drive this pane? Two signals, and it takes both:
#   1. this session sits in a tmux pane ($TMUX), and
#   2. the listener daemon is alive (~/.zeph/listener.pid + a liveness check —
#      the bash twin of listener-process.ts readListenerPid, which does the
#      same `process.kill(pid, 0)`).
# With both, the picker is reachable: it renders in `tmux capture-pane` and the
# phone's arrow/Enter buttons reach it through the listener's key injection
# (listener.ts ALLOWED_KEYS → `tmux send-keys`). With either missing there is no
# mirror, and the terminal is the only way in.
#
# `kill -0` is a builtin and the pid file is a local read, so this costs no
# subprocess and no network — it stays well inside the hook's 10s budget.
mirror_available() {
    [ -n "${TMUX:-}" ] || return 1
    local pid
    pid=$(cat "$HOME/.zeph/listener.pid" 2>/dev/null) || return 1
    # Numeric-only: `kill -0` would otherwise take a job spec or a negative
    # process group from a corrupted file.
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null
}

# Build the body: question, the choices (when present), and where the answer can
# actually be given. The title says "asks", so the last line has to be true for
# THIS session — claiming a mirror that isn't there strands the user on the
# phone, and denying one that is there sends them to a desk they didn't need.
BODY="$QUESTION"
[ -n "$OPTIONS" ] && BODY="$BODY
▸ $OPTIONS"
if mirror_available; then
    BODY="$BODY
↳ answer at the terminal, or from the phone's terminal mirror (↑/↓ then Enter)"
else
    BODY="$BODY
↳ answer at the terminal"
fi

# Default: silent on failure. Opt-in ZEPH_HOOK_DEBUG=1 logs stderr +
# failures (the silent `2>/dev/null` otherwise hides every hook error).
# shellcheck disable=SC2086
if [ -n "$ZEPH_HOOK_DEBUG" ]; then
    ZEPH_LOG="${ZEPH_HOOK_LOG:-/tmp/zeph-hook.log}"
    $ZEPH_CMD notify --title "Claude asks: $PROJECT" --body "$BODY" --priority high $SESSION_FLAG \
        >>"$ZEPH_LOG" 2>&1 || echo "[zeph-ask] notify failed at $(date '+%Y-%m-%d %H:%M:%S')" >>"$ZEPH_LOG"
else
    $ZEPH_CMD notify --title "Claude asks: $PROJECT" --body "$BODY" --priority high $SESSION_FLAG 2>/dev/null || true
fi
