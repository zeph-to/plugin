#!/usr/bin/env bash
# Report Claude Code's state to herdr (https://herdr.dev) for a `zeph cc` session.
#
# herdr finds agents by a pane's foreground process. In a `zeph cc` pane that is
# the tmux client — Claude Code runs under the tmux server — so the agent never
# shows in herdr's sidebar. herdr's answer for agents it cannot see is the
# report API (`herdr pane report-agent`), which this hook drives from Claude
# Code's own events.
#
# Which herdr pane: the CLI wrapper records it on every attach as tmux session
# options (cli config `HERDR_SESSION_OPTIONS`) and clears them on an attach from
# outside herdr. Read from tmux, not this process's env, because the agent
# outlives the pane it was started in. No options -> not in herdr -> no-op, and
# that includes plain `claude` in a herdr pane, which herdr detects itself.
#
# Usage: zeph-herdr.sh <start|working|idle|blocked|tool|end>
#   tool — PostToolUse: back to `working` only if the last report was `blocked`
#          (a permission prompt or a question was answered).
#
# Never slows Claude Code down: herdr runs in the background, failures are
# ignored, and a state equal to the last one reported is not sent again.

read -r -d '' _ 2>/dev/null   # hook input is unused; drain it (a builtin: no fork per tool call)

[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || exit 0

event="${1:-}"
state_dir="${TMPDIR:-/tmp}/zeph-herdr"
state_file="$state_dir/${TMUX_PANE//[^A-Za-z0-9]/_}"

last_seq=0 last_state='' last_pane=''
[ -f "$state_file" ] && read -r last_seq last_state last_pane <"$state_file"

# The hot path: every tool call lands here. Skip the tmux round trip unless it
# can change something.
[ "$event" = tool ] && [ "$last_state" != blocked ] && exit 0

command -v tmux >/dev/null 2>&1 || exit 0
IFS=$'\t' read -r pane sock bin < <(
    tmux display-message -p -t "$TMUX_PANE" '#{@zeph_herdr_pane}	#{@zeph_herdr_socket}	#{@zeph_herdr_bin}' 2>/dev/null
)
[ -n "${pane:-}" ] && [ -n "${sock:-}" ] || exit 0
[ -n "${bin:-}" ] && [ -x "$bin" ] || bin="$(command -v herdr)" || exit 0

case "$event" in
    start | idle) state=idle ;;
    working | tool) state=working ;;
    blocked) state=blocked ;;
    end) state=released ;;
    *) exit 0 ;;
esac

# Reattached from another herdr pane: the last report went somewhere else.
[ "$pane" != "$last_pane" ] && last_state=''
[ "$event" != start ] && [ "$state" = "$last_state" ] && exit 0

# herdr drops a report whose seq is not above the last one it accepted from
# this source, so seq must grow across sessions and restarts: microseconds since
# the epoch (perl ships with macOS; `date +%N` does not), bumped past the last.
seq="$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1e6' 2>/dev/null)"
[ -n "$seq" ] || seq="$(date +%s)000000"
[ "$seq" -gt "$last_seq" ] 2>/dev/null || seq=$((last_seq + 1))

mkdir -p "$state_dir" 2>/dev/null
if [ "$state" = released ]; then
    rm -f "$state_file"
    set -- pane release-agent "$pane" --source zeph --agent 'zeph cc' --seq "$seq"
else
    printf '%s %s %s\n' "$seq" "$state" "$pane" >"$state_file"
    set -- pane report-agent "$pane" --source zeph --agent 'zeph cc' --state "$state" --seq "$seq"
fi

# Detached: the hook returns at once. Out-of-order arrivals are harmless — the
# seq above makes herdr keep the newest.
HERDR_SOCKET_PATH="$sock" nohup "$bin" "$@" >/dev/null 2>&1 &
exit 0
