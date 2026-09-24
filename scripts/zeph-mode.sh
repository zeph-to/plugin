#!/usr/bin/env bash
# /zeph-mode — read or change this project's Zeph notification state.
#
#   stdin line 1: project dir   line 2: [quiet|normal|loud|mute|unmute] [--global]
#
# Input comes on stdin, not argv: the skill writes both lines inside a quoted
# heredoc, so the substituted $ARGUMENTS and ${CLAUDE_PROJECT_DIR} are never
# parsed by the shell — `quiet; $(date)` stays one bad word for the case below.
#
# No word → status only. A word → write the state file, print status, then
# re-emit the SessionStart rules for the new state: that hook's rules are
# state-conditional and never re-run mid-session, so without the refresh a
# quiet→normal switch leaves the model on the quiet branch.
#
# State resolution is gate.sh's (zeph_state_present / zeph_read_pushmode) —
# the same functions the Stop and Ask hooks read, so status cannot disagree
# with what they do. The project dir is the skill's substituted
# ${CLAUDE_PROJECT_DIR} (that variable is not in the Bash tool's env); empty or
# left unsubstituted → $PWD.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../hooks/gate.sh
. "$ROOT/hooks/gate.sh"

USAGE='Usage: /zeph-mode [quiet|normal|loud|mute|unmute] [--global]'

usage_error() {
    printf 'zeph-mode: %s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

IFS= read -r DIR || true
read -r -a ARGS || true
case "$DIR" in
    ''|'${'*) DIR="$PWD" ;;
esac
HASH=$(printf '%s' "$DIR" | cksum | cut -d' ' -f1)

WORD=""; GLOBAL=0
for arg in ${ARGS[@]+"${ARGS[@]}"}; do
    case "$arg" in
        --global) GLOBAL=1 ;;
        quiet|normal|loud|mute|unmute)
            [ -z "$WORD" ] || usage_error "one mode at a time"
            WORD="$arg" ;;
        *) usage_error "unknown argument '$arg'" ;;
    esac
done

if [ "$GLOBAL" -eq 1 ]; then
    case "$WORD" in
        quiet|normal|loud) ;;
        "") usage_error "--global needs quiet, normal or loud" ;;
        *) usage_error "--global applies to push dials only; mute is per-project" ;;
    esac
fi

mkdir -p "$ZEPH_STATE_DIR"
case "$WORD" in
    quiet|normal|loud)
        if [ "$GLOBAL" -eq 1 ]; then
            printf '%s' "$WORD" > "$ZEPH_STATE_DIR/pushmode-default"
        else
            printf '%s' "$WORD" > "$ZEPH_STATE_DIR/pushmode-$HASH"
        fi ;;
    mute) touch "$ZEPH_STATE_DIR/muted-$HASH" ;;
    unmute) rm -f "$ZEPH_STATE_DIR/muted-$HASH" "/tmp/zeph-muted-$HASH" ;;
esac

# ── status ──────────────────────────────────────────────────────────────────

if zeph_state_present muted "$HASH" >/dev/null; then
    echo "NOTIFICATIONS: muted"
else
    echo "NOTIFICATIONS: active"
fi

if DIAL_FILE=$(zeph_state_present pushmode "$HASH"); then
    case "$DIAL_FILE" in
        */pushmode-default) SOURCE="global default" ;;
        *) SOURCE="this project" ;;
    esac
else
    SOURCE="built-in default — no dial set"
fi
echo "PUSH MODE: $(zeph_read_pushmode "$HASH") ($SOURCE)"

if AUTO_FILE=$(zeph_state_present auto "$HASH"); then
    read -r DEADLINE MINUTES < "$AUTO_FILE" || true
    # Digits only before $(( )): bash arithmetic evaluates a variable's text, so
    # a crafted auto file could otherwise run a command.
    case "${DEADLINE:-}${MINUTES:-}" in
        ''|*[!0-9]*) echo "AUTO MODE: unreadable state file $AUTO_FILE" ;;
        *) echo "AUTO MODE: $(( (DEADLINE - $(date +%s)) / 60 ))m remaining of ${MINUTES}m" ;;
    esac
fi
echo "$USAGE"

[ -n "$WORD" ] || exit 0

# ── rules refresh ───────────────────────────────────────────────────────────

RULES=$(CLAUDE_PROJECT_DIR="$DIR" node "$ROOT/hooks/zeph-setup.js" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)

if [ -z "$RULES" ]; then
    echo "zeph-mode: could not refresh the session rules (node, jq or hooks/zeph-setup.js failed); the change above still applies — a new session picks up its rules."
    exit 0
fi

printf '\n=== Zeph rules — replace the Zeph rules from session start ===\n\n%s\n' "$RULES"
