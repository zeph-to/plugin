#!/usr/bin/env bash
# UserPromptSubmit hook — remote-origin detection (ADR-0002) and the sticky
# REMOTE reminder that follows it.
#
# Two jobs, in this order:
#
#   1. Entry. The zeph listener records every phone→pane text injection as a
#      one-shot marker file (`remote-<hash>` under the zeph state dir) holding
#      the epoch second and sha256 of the injected text. When the submitted
#      prompt matches that record, the user is driving this session from their
#      phone, and the hook says so — which enters sticky REMOTE mode
#      (CORE_RULES Rule 9) so every response ends in an answerable zeph_ask.
#      Entry detection is exact: same project (cksum of the dir), fresh
#      (≤15 min), and byte-identical trimmed text. A terminal keystroke racing
#      a phone message can never false-match.
#
#   2. Staying there. The marker is one-shot, but REMOTE is not — the user can
#      answer from the phone on one turn and type at the terminal on the next.
#      Those terminal turns carry no marker and no zeph_ask tool_result, and
#      they are exactly where the mode used to run out of evidence. So entry
#      also records the mode in `remote-active-<hash>` (see gate.sh), and every
#      later turn re-reads it and re-states the mode. Because that lives in a
#      file, it survives context compaction — which is what Rule 13 promises.
#
# No marker and no live state → silent no-op. This hook only ever adds context
# and must never block a prompt (always exit 0).

command -v jq >/dev/null 2>&1 || exit 0

# Shared hook library (hooks/gate.sh): state-file resolution.
. "$(dirname "${BASH_SOURCE[0]}")/gate.sh"

HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)

# Mute outranks everything (Rule 12) — stay silent and leave the marker
# unconsumed (the next inject overwrites it anyway). The REMOTE state is left
# alone too: mute suspends the pushing, it does not end the remote session.
zeph_state_present muted "$HASH" >/dev/null && exit 0

# Drain stdin unconditionally. This hook can now emit on a turn where nothing
# about the prompt matters, and returning while the pipe is still full leaves
# the writer to take a SIGPIPE.
INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)

hash_stdin() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        return 1
    fi
}

# rc 0 when this prompt is a verified phone injection. Consumes the marker on a
# match, deletes it once stale, and otherwise leaves it in place so a prompt
# that simply isn't the injected one can still match on a later turn.
remote_origin_match() {
    local marker ts recorded ws prompt digest
    [ -n "$PROMPT" ] || return 1
    marker=$(zeph_state_present remote "$HASH") || return 1

    # Marker format: "<epochSec> <sha256hex>\n" (written by cli listener.ts).
    read -r ts recorded < "$marker" 2>/dev/null || return 1
    case "$ts" in '' | *[!0-9]*) return 1 ;; esac
    [ -n "$recorded" ] || return 1

    # Freshness: 15 minutes. The window is deliberately generous — false
    # positives are already impossible without an exact hash match; its only
    # job is to stop the SAME text typed at the terminal much later from
    # re-flagging. It must survive the real gap between injection and prompt
    # submit: a message sent while the agent is mid-turn queues until the
    # turn ends, which can easily exceed a minute. Stale markers are dead
    # weight (can never flag) — delete instead of leaving them behind.
    if [ $(( $(date +%s) - ts )) -gt 900 ]; then
        rm -f "$marker"
        return 1
    fi

    # Trim both ends — the terminal may normalize trailing whitespace between
    # send-keys and the prompt. Explicit ASCII whitespace set, NOT [[:space:]]:
    # the POSIX class is locale-dependent (a UTF-8 locale may include U+00A0
    # etc.) and the listener hashes with the same explicit ASCII-only trim —
    # both sides must strip the exact same bytes or the digests diverge.
    ws=$' \t\r\n\f\v'
    prompt="${PROMPT#"${PROMPT%%[!${ws}]*}"}"
    prompt="${prompt%"${prompt##*[!${ws}]}"}"

    digest=$(printf '%s' "$prompt" | hash_stdin) || return 1
    [ "$digest" = "$recorded" ] || return 1

    # Matched — consume the marker so an identical later prompt (e.g. typed at
    # the terminal) can't re-flag. The explicit `return 0` matters: `rm` fails
    # on a read-only state dir, and letting its status be this function's would
    # turn a verified phone message into a no-match. The match is valid whether
    # or not the housekeeping lands — same rule the TS twin states at
    # cli/src/remote-hook.ts ("emit anyway").
    rm -f "$marker"
    return 0
}

# Exactly one additionalContext per invocation: entry wins over the reminder,
# because on the entry turn the reminder would say strictly less.
if remote_origin_match; then
    if [ -n "${ZEPH_HOOK_ID:-}" ]; then
        # Only a two-way session has a mode to stay in — without zeph_ask there
        # is nothing for a later turn to be reminded of, so no state is written.
        zeph_remote_touch "$HASH"
        CTX='# System note (Zeph remote-origin detect)

This user message arrived from the user'"'"'s phone via Zeph agent chat (verified by the listener — exact text match). The user is driving this session remotely and is NOT at the terminal. Enter sticky REMOTE mode now (CORE_RULES Rule 9): end EVERY response with `zeph_ask` (buttons + free-text) until the user sends an exit signal (done/stop/exit). Plain-text questions are invisible to them.'
    else
        CTX='# System note (Zeph remote-origin detect)

This user message arrived from the user'"'"'s phone via Zeph agent chat (verified by the listener — exact text match), but ZEPH_HOOK_ID is not set, so two-way tools (zeph_ask/zeph_prompt/zeph_input) are unavailable. Make your final message self-contained — the Stop-hook push is the user'"'"'s only feedback channel. If you have not already mentioned it this session, tell the user once that running `npx @zeph-to/cli setup` upgrades this into a two-way remote session (buttons + text replies from the phone).'
    fi
elif [ -n "${ZEPH_HOOK_ID:-}" ] && zeph_remote_active "$HASH"; then
    # Deliberately one sentence: this goes out on EVERY turn of a remote
    # session, so anything longer would spend per-turn what the rule text
    # spends once.
    CTX='# System note (Zeph)

This session is still in sticky REMOTE mode — the user has been driving it from their phone and may not be at the terminal to read this. End this response with `zeph_ask` (CORE_RULES Rule 9).'
else
    exit 0
fi

jq -n --arg ctx "$CTX" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
exit 0
