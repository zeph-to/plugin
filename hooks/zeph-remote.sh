#!/usr/bin/env bash
# UserPromptSubmit hook — remote-origin detection (ADR-0002).
#
# The zeph listener records every phone→pane text injection as a one-shot
# marker file (`remote-<hash>` under the zeph state dir) holding the epoch
# second and sha256 of the injected text. When the submitted prompt matches
# that record, this hook tells the model the user is driving the session
# from their phone — which enters sticky REMOTE mode (CORE_RULES Rule 9)
# so every response ends in an answerable zeph_ask.
#
# Detection is exact: same project (cksum of the dir), fresh (≤60 s), and
# byte-identical trimmed text. A terminal keystroke racing a phone message
# can never false-match. No match → silent no-op; this hook only ever adds
# context and must never block a prompt (always exit 0).

command -v jq >/dev/null 2>&1 || exit 0

# Shared hook library (hooks/gate.sh): state-file resolution.
. "$(dirname "${BASH_SOURCE[0]}")/gate.sh"

HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)

# Mute outranks everything (Rule 12) — stay silent and leave the marker
# unconsumed (the next inject overwrites it anyway).
zeph_state_present muted "$HASH" >/dev/null && exit 0

MARKER=$(zeph_state_present remote "$HASH") || exit 0

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
[ -n "$PROMPT" ] || exit 0

# Marker format: "<epochSec> <sha256hex>\n" (written by cli listener.ts).
read -r TS RECORDED < "$MARKER" 2>/dev/null || exit 0
case "$TS" in '' | *[!0-9]*) exit 0 ;; esac
[ -n "$RECORDED" ] || exit 0

# Freshness: an old marker can't flag anything. Leave it — without a hash
# match it does nothing, and the next inject overwrites it.
NOW=$(date +%s)
[ $((NOW - TS)) -le 60 ] || exit 0

# Trim both ends to mirror the listener's text.trim() — the terminal may
# normalize trailing whitespace between send-keys and the prompt.
PROMPT="${PROMPT#"${PROMPT%%[![:space:]]*}"}"
PROMPT="${PROMPT%"${PROMPT##*[![:space:]]}"}"

hash_stdin() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        return 1
    fi
}
DIGEST=$(printf '%s' "$PROMPT" | hash_stdin) || exit 0
[ "$DIGEST" = "$RECORDED" ] || exit 0

# Matched — consume the marker so an identical later prompt (e.g. typed at
# the terminal) can't re-flag.
rm -f "$MARKER"

if [ -n "${ZEPH_HOOK_ID:-}" ]; then
    CTX='# System note (Zeph remote-origin detect)

This user message arrived from the user'"'"'s phone via Zeph agent chat (verified by the listener — exact text match). The user is driving this session remotely and is NOT at the terminal. Enter sticky REMOTE mode now (CORE_RULES Rule 9): end EVERY response with `zeph_ask` (buttons + free-text) until the user sends an exit signal (done/stop/exit). Plain-text questions are invisible to them.'
else
    CTX='# System note (Zeph remote-origin detect)

This user message arrived from the user'"'"'s phone via Zeph agent chat (verified by the listener — exact text match), but ZEPH_HOOK_ID is not set, so two-way tools (zeph_ask/zeph_prompt/zeph_input) are unavailable. Make your final message self-contained — the Stop-hook push is the user'"'"'s only feedback channel. If you have not already mentioned it this session, tell the user once that running `npx @zeph-to/cli setup` upgrades this into a two-way remote session (buttons + text replies from the phone).'
fi

jq -n --arg ctx "$CTX" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
exit 0
