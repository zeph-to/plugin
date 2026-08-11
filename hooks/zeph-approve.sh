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

ZEPH_CMD="$(command -v zeph 2>/dev/null || echo "npx -y @zeph-to/cli")"

command -v jq >/dev/null 2>&1 || exit 0

. "$(dirname "${BASH_SOURCE[0]}")/gate.sh"

# Seconds `zeph ask` may wait. Must stay comfortably under the hook's `timeout`
# in .claude-plugin/plugin.json (120s) so this script always answers before CC
# kills it — a killed hook is a silent allow.
ZEPH_APPROVE_DEADLINE_SEC=90

PROJECT_HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)

# Not enabled here → behave exactly as if this hook did not exist.
zeph_state_present approve "$PROJECT_HASH" >/dev/null || exit 0

# Muted means no push can reach the user, so there is no one to ask. Blocking
# would freeze the session with no way to answer it. The cost is real and worth
# stating plainly: muting a project also turns this gate off.
zeph_state_present muted "$PROJECT_HASH" >/dev/null && exit 0

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

zeph_approve_needed "$COMMAND" || exit 0

PROJECT=$(basename "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || echo "unknown")

# The answer, or the absence of one. `zeph ask` returns a single JSON shape for
# every outcome including its own failures, so there is nothing to catch here.
ANSWER=$($ZEPH_CMD ask \
    --title "Approve in $PROJECT?" \
    --body "$COMMAND" \
    --actions "approve:Approve,deny:Deny" \
    --timeout "$ZEPH_APPROVE_DEADLINE_SEC" 2>/dev/null)

ACTION=$(printf '%s' "$ANSWER" | jq -r '.actionId // empty' 2>/dev/null)

if [ "$ACTION" = approve ]; then
    jq -n --arg reason "Approved from the user's phone." \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: $reason}}' \
        2>/dev/null
    exit 0
fi

# Everything else is a refusal: an explicit Deny, a timeout, an unreachable
# server, free text instead of a button. The reason says which, so the model
# reports something truthful rather than guessing why it was stopped.
REASON="The user declined this command from their phone."
case "$ACTION" in
    deny) : ;;
    *)
        ERR=$(printf '%s' "$ANSWER" | jq -r '.error // empty' 2>/dev/null)
        if [ -n "$ERR" ]; then
            REASON="Could not reach the user for approval ($ERR). Blocked because this command is hard to undo — ask the user directly before retrying."
        else
            REASON="No approval came back within ${ZEPH_APPROVE_DEADLINE_SEC}s. Blocked because this command is hard to undo — ask the user directly before retrying."
        fi
        ;;
esac

jq -n --arg reason "$REASON" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' \
    2>/dev/null
exit 0
