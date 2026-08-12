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
#   2. Leaving. The marker is one-shot, but REMOTE is not — it is recorded in
#      `remote-active-<hash>` (see gate.sh) so it outlives the entry turn and
#      survives context compaction, which is what Rule 13 promises. A prompt
#      that reaches this hook without a marker was typed at the terminal: the
#      only way text becomes a prompt without one is the user's own keyboard
#      (phone answers to a zeph_ask come back as a tool_result and never reach
#      a prompt hook at all). The user is back, so the mode ends here — clear
#      the state and say so once. Re-entry costs one more phone message.
#      The exception is a fresh marker left unmatched: a phone message is in
#      flight, the evidence is ambiguous, and the mode is left exactly as it
#      was (see remote_origin_match's three-way verdict).
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
# the writer to take a SIGPIPE. Parsing it is a different question — see below.
INPUT=$(cat)

hash_stdin() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        return 1
    fi
}

# Three-way verdict, because "not a phone message" and "typed at the terminal"
# are not the same claim and the exit branch may only act on the second:
#
#   0 PHONE      verified injection; marker consumed
#   1 KEYBOARD   no marker this prompt could ever have matched — the user typed
#   2 UNCLEAR    a fresh marker is sitting here unmatched, so a phone message is
#                in flight (queued behind a long turn, or a digest the two sides
#                compute differently). Ambiguous evidence must not be read as
#                "the user is back": that would drop them out of REMOTE while
#                they are still holding the phone, with no answerable push left.
#                Also an unreadable prompt while such a marker is pending. With
#                no marker in play an empty prompt still reads as KEYBOARD: the
#                listener never injects empty text, so there is nothing in
#                flight to be ambiguous about — and testing emptiness before
#                the marker would put a jq spawn on every prompt in every
#                project, which is what the file test above exists to avoid.
remote_origin_match() {
    local marker ts recorded ws prompt digest

    # Marker existence first, and it is a plain file test. Every prompt in every
    # project reaches this line, and the overwhelmingly common answer is "no
    # marker" — so nothing below may run before it, least of all the `jq` spawn
    # that parses the prompt out of the payload.
    marker=$(zeph_state_present remote "$HASH") || return 1

    prompt=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
    [ -n "$prompt" ] || return 2

    # Marker format: "<epochSec> <sha256hex>\n" (written by cli listener.ts).
    # Junk here can never match anything, so it says nothing about who typed —
    # same verdict as no marker at all.
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
    prompt="${prompt#"${prompt%%[!${ws}]*}"}"
    prompt="${prompt%"${prompt##*[!${ws}]}"}"

    digest=$(printf '%s' "$prompt" | hash_stdin) || return 2
    [ "$digest" = "$recorded" ] || return 2

    # Matched — consume the marker so an identical later prompt (e.g. typed at
    # the terminal) can't re-flag. The explicit `return 0` matters: `rm` fails
    # on a read-only state dir, and letting its status be this function's would
    # turn a verified phone message into a no-match. The match is valid whether
    # or not the housekeeping lands — same rule the TS twin states at
    # cli/src/remote-hook.ts ("emit anyway").
    rm -f "$marker"
    return 0
}

# Exactly one additionalContext per invocation, and the verdict decides which:
# PHONE enters, KEYBOARD leaves, UNCLEAR says nothing and leaves the mode as it
# was — the pending marker will speak for itself on the turn it matches.
remote_origin_match
ORIGIN=$?

if [ "$ORIGIN" -eq 0 ]; then
    if [ -n "${ZEPH_HOOK_ID:-}" ]; then
        # Only a two-way session has a mode to stay in — without zeph_ask there
        # is nothing for a later turn to be reminded of, so no state is written.
        zeph_remote_touch "$HASH"
        CTX='# System note (Zeph remote-origin detect)

This user message arrived from the user'"'"'s phone via Zeph agent chat (verified by the listener — exact text match). The user is driving this session remotely and is NOT at the terminal. Enter sticky REMOTE mode now (CORE_RULES Rule 9): end EVERY response with `zeph_ask` (buttons + free-text) until the user exits — an exit signal (done/stop/exit), or a prompt they type at the terminal, which this hook will tell you about. Plain-text questions are invisible to them.'
    else
        CTX='# System note (Zeph remote-origin detect)

This user message arrived from the user'"'"'s phone via Zeph agent chat (verified by the listener — exact text match), but ZEPH_HOOK_ID is not set, so two-way tools (zeph_ask/zeph_prompt/zeph_input) are unavailable. Make your final message self-contained — the Stop-hook push is the user'"'"'s only feedback channel. If you have not already mentioned it this session, tell the user once that running `npx @zeph-to/cli setup` upgrades this into a two-way remote session (buttons + text replies from the phone).'
    fi
elif [ "$ORIGIN" -eq 1 ] && [ -n "${ZEPH_HOOK_ID:-}" ] && zeph_remote_active "$HASH"; then
    # KEYBOARD on a live REMOTE session: the user typed this at the terminal,
    # so they are back and REMOTE ends. Emitted once — the state is gone, so
    # every later terminal turn is a silent no-op and costs nothing per turn.
    zeph_remote_clear "$HASH"
    CTX='# System note (Zeph)

The user typed this prompt at the terminal, so this session has LEFT sticky REMOTE mode — answer normally (CORE_RULES Rule 4) and do not end this response with `zeph_ask` just to keep the loop alive. Rule 3 still holds: if you actually ask the user something, ask it with `zeph_ask`. Re-entry is automatic the moment they send another message from their phone.'
else
    exit 0
fi

jq -n --arg ctx "$CTX" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
exit 0
