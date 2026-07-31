---
name: zeph-status
description: >
  Check Zeph notification status for this project (persists until undone). Shows whether notifications
  are muted or active, the current push mode (normal/quiet/loud), and whether it
  came from this project or a `--global` default. Use before muting or changing
  push mode to see current state.
metadata:
  author: zeph-to
  version: "0.10.0"
  relatedSkills:
    - zeph
    - zeph-mute
    - zeph-unmute
    - zeph-quiet
    - zeph-loud
    - zeph-normal
  triggers:
    - zeph-status
    - check zeph status
    - notification status
    - mute status
    - push mode
    - /zeph-status
---

Check Zeph mute + push-mode status.

Run this bash command:

```bash
HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zeph"
# Legacy /tmp files (older versions) count only when owned by the current user.
# Canonical resolution lives in hooks/gate.sh zeph_state_present — keep in sync.
if [ -f "$STATE_DIR/muted-$HASH" ] || { [ -f "/tmp/zeph-muted-$HASH" ] && [ -O "/tmp/zeph-muted-$HASH" ]; }; then
  echo "MUTED"
else
  echo "ACTIVE"
fi
MODE_FILE=""; SCOPE=""
if [ -f "$STATE_DIR/pushmode-$HASH" ]; then
  MODE_FILE="$STATE_DIR/pushmode-$HASH"; SCOPE="this project"
elif [ -f "/tmp/zeph-pushmode-$HASH" ] && [ -O "/tmp/zeph-pushmode-$HASH" ]; then
  MODE_FILE="/tmp/zeph-pushmode-$HASH"; SCOPE="this project"
elif [ -f "$STATE_DIR/pushmode-default" ]; then
  MODE_FILE="$STATE_DIR/pushmode-default"; SCOPE="global default"
fi
# No dial anywhere → quiet, the shipped default. A dial file that exists but
# reads empty is a corrupted setting, and the hook resolves it to normal —
# mirror that here or the status line contradicts what actually happens.
if [ -n "$MODE_FILE" ]; then
  MODE=$(tr -d '[:space:]' < "$MODE_FILE"); MODE="${MODE:-normal}"
else
  MODE="quiet"; SCOPE="built-in default — no dial set"
fi
echo "PUSH MODE: $MODE ($SCOPE)"
if [ -f "$STATE_DIR/auto-$HASH" ]; then
  read -r DEADLINE MINUTES < "$STATE_DIR/auto-$HASH"
  echo "AUTO MODE: $(( (DEADLINE - $(date +%s)) / 60 ))m remaining of ${MINUTES}m"
fi
```

Report the result in your own words:
- `MUTED` → notifications are muted for this project; `/zeph-unmute` re-enables them.
- `ACTIVE` → notifications are active; `/zeph-mute` silences them.
- `PUSH MODE: quiet` → only high-priority pushes reach them. This is the
  shipped default, so it is what a project with no dial reports.
- `PUSH MODE: normal` → the per-turn heuristic decides (push on real work,
  silent on read-only). Set with `/zeph-normal`.
- `PUSH MODE: loud` → every turn pushes; `/zeph-normal` turns it down.
- The parenthetical says where the mode came from: `this project` (a dial set
  here), `global default` (set with `--global`, inherited by every project that
  has none of its own), or `built-in default — no dial set`. `/zeph-normal`
  overrides the first two here; `/zeph-normal --global` clears the global one
  everywhere, which leaves projects back on the built-in quiet.
- Quiet does not mean nothing arrives: questions still push (the model's
  `zeph_ask` and the AskUserQuestion mirror are outside the dial), and a
  session that goes idle for five minutes still sends its completion push.
- `AUTO MODE: ...` → a `/zeph-auto` session is running with that much budget left.

(Push mode only applies when not muted — mute overrides everything.)

## If Things Go Wrong

**Problem**: "Command returns nothing"
- **Check**: Run the command again, piece by piece:
  ```bash
  pwd  # shows your current directory
  HASH=$(printf '%s' "$(pwd)" | cksum | cut -d' ' -f1)
  echo "Checking: ${XDG_STATE_HOME:-$HOME/.local/state}/zeph/muted-$HASH"
  [ -f "${XDG_STATE_HOME:-$HOME/.local/state}/zeph/muted-$HASH" ] && echo "MUTED" || echo "ACTIVE"
  ```
- **Fix**: One of the pieces should show the issue (directory, hash, or file check)

**Problem**: "Shows ACTIVE but /zeph-mute should have muted it"
- **Check**: Did `/zeph-mute` complete successfully? Did it say "muted"?
- **Verify**: Look for the file manually:
  ```bash
  ls -la "${XDG_STATE_HOME:-$HOME/.local/state}/zeph"/muted-*  # shows all mute files
  ```
- **Fix**: Run `/zeph-mute` again, then `/zeph-status` to confirm

**Problem**: "Shows MUTED but I ran /zeph-unmute"
- **Check**: Is the mute file still there after /zeph-unmute?
  ```bash
  HASH=$(printf '%s' "$(pwd)" | cksum | cut -d' ' -f1)
  ls -la "${XDG_STATE_HOME:-$HOME/.local/state}/zeph/muted-$HASH" "/tmp/zeph-muted-$HASH"  # should NOT exist after unmute
  ```
- **Fix**: Run `/zeph-unmute` again, then check that the file is gone

**Problem**: "Mute status different between terminals"
- **Note**: Mute is based on project directory (hashed). If you're in different directories, each has its own mute state.
- **Check**: Are you in the same directory? `pwd`
- **Fix**: 
  - Use absolute path: `cd /exact/path/to/project`
  - Or set `CLAUDE_PROJECT_DIR=/exact/path` in environment
