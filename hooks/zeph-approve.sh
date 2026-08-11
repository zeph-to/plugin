#!/usr/bin/env bash
# PreToolUse(Bash) hook — hold a hard-to-undo command until the user approves
# it from their phone.
#
# ⚠️ A SPEED BUMP, NOT A SECURITY BOUNDARY. `zeph_approve_needed` (hooks/gate.sh)
# matches text in a command string; anything deliberately evading it will.
# What this catches is the accident — an agent reaching for `rm -rf` or a prod
# deploy while nobody is watching the terminal.
#
# OPT-IN, per project. Claude Code fails OPEN when a hook times out (measured
# 2026-08-11: the hook process is killed at its `timeout` and the tool call runs
# anyway, with nothing shown in the pane). A gate that can silently become no
# gate must not switch itself on, and a gate that blocks a terminal session for
# a minute must not surprise anyone. Enable it by creating:
#
#     ~/.local/state/zeph/approve-<project-hash>
#
# where <project-hash> is `cksum` of the project directory — the same key the
# mute and push-mode dials use.
#
# Because CC fails open, this hook never relies on CC's timeout: it gives
# `zeph ask` a deadline well inside its own, and answers `deny` itself when
# that passes. Silence is a refusal here, which is the opposite of the
# AskUserQuestion hook next door — there `allow` is the safe direction, here it
# is the dangerous one.

command -v jq >/dev/null 2>&1 || exit 0

. "$(dirname "${BASH_SOURCE[0]}")/gate.sh"

# Two bounds, and the gap between them is the whole safety argument.
#
# plugin.json gives this hook 120s. A killed hook is a SILENT ALLOW, so the
# script must answer well before that — and "the ask waits 90s" is not enough on
# its own, because the wait is not the only thing that takes time: a cold
# `npx -y @zeph-to/cli` resolve happens first, and a poll request already in
# flight when the deadline passes adds up to another 10s (ask.ts checks the
# deadline at the top of its loop).
#
# So the inner deadline is what `zeph ask` waits for a human, and the outer cap
# bounds the whole CLI invocation including startup. If the outer cap fires the
# output is empty, which falls through to deny below — late is a refusal, never
# a pass.
ZEPH_APPROVE_DEADLINE_SEC=75
ZEPH_APPROVE_CLI_CAP_SEC=100

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
# `printf '%s'`, NOT a here-string: `<<<` appends a newline and cksum would
# hash a different byte sequence, giving this hook a key that no longer matches
# the one zeph-ask.sh and zeph-stop.sh compute for the same project.
PROJECT_HASH=$(printf '%s' "$PROJECT_DIR" | cksum)
PROJECT_HASH=${PROJECT_HASH%% *}

# Not enabled here → behave exactly as if this hook did not exist.
zeph_state_present approve "$PROJECT_HASH" >/dev/null || exit 0

# Muted means no push can reach the user, so there is no one to ask. Blocking
# would freeze the session with no way to answer it. The cost is real and worth
# stating plainly: muting a project also turns this gate off.
zeph_state_present muted "$PROJECT_HASH" >/dev/null && exit 0

INPUT=$(cat)
COMMAND=$(jq -r '.tool_input.command // empty' <<< "$INPUT" 2>/dev/null)

zeph_approve_needed "$COMMAND" || exit 0

PROJECT=${PROJECT_DIR##*/}
[ -n "$PROJECT" ] || PROJECT=unknown

# Resolved here rather than at the top: this hook runs on EVERY Bash tool call
# and is off by default, so `command -v zeph` at load time would be a fork spent
# on every command for every user who never opted in.
ZEPH_CMD="$(command -v zeph 2>/dev/null || echo "npx -y @zeph-to/cli")"
ZEPH_CMD=$(zeph_wrap_timeout "$ZEPH_CMD" "$ZEPH_APPROVE_CLI_CAP_SEC")
# The answer, or the absence of one. `zeph ask` returns a single JSON shape for
# every outcome including its own failures, so there is nothing to catch here.
# shellcheck disable=SC2086 -- $ZEPH_CMD is a command line, not one word
ANSWER=$($ZEPH_CMD ask \
    --title "Approve in $PROJECT?" \
    --body "$COMMAND" \
    --actions "approve:Approve,deny:Deny" \
    --timeout "$ZEPH_APPROVE_DEADLINE_SEC" 2>/dev/null)

ACTION=$(jq -r '.actionId // empty' <<< "$ANSWER" 2>/dev/null)

if [ "$ACTION" = approve ]; then
    zeph_hook_decision allow "Approved from the user's phone."
    exit 0
fi

# Everything else is a refusal: an explicit Deny, a timeout, an unreachable
# server, free text instead of a button. The reason says which, so the model
# reports something truthful rather than guessing why it was stopped.
REASON="The user declined this command from their phone."
case "$ACTION" in
    deny) : ;;
    *)
        ERR=$(jq -r '.error // empty' <<< "$ANSWER" 2>/dev/null)
        if [ -n "$ERR" ]; then
            REASON="Could not reach the user for approval ($ERR). Blocked because this command is hard to undo — ask the user directly before retrying."
        else
            REASON="No approval came back within ${ZEPH_APPROVE_DEADLINE_SEC}s. Blocked because this command is hard to undo — ask the user directly before retrying."
        fi
        ;;
esac

zeph_hook_decision deny "$REASON"
exit 0
