---
name: zeph-mute
description: >
  Mute Zeph push notifications for this project (persists until undone). Stops automatic notifications
  from Stop and AskUserQuestion hooks. Use /zeph-unmute to re-enable.
metadata:
  author: zeph-to
  version: "0.9.0"
  relatedSkills:
    - zeph
    - zeph-unmute
    - zeph-status
  triggers:
    - zeph-mute
    - mute notifications
    - silence notifications
    - silence alerts
    - quiet mode
    - /zeph-mute
---

Mute Zeph notifications for this project (persists until undone).

Run this bash command:

```bash
HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zeph"
mkdir -p "$STATE_DIR"
touch "$STATE_DIR/muted-$HASH"
```

Then confirm to the user, in your own words, that Zeph notifications are now muted for this project (until /zeph-unmute) and that `/zeph-unmute` re-enables them.

## If Things Go Wrong

**Problem**: "Mute doesn't work, still getting notifications"
- **Check**: Did the command complete without error?
- **Verify**: `ls -la "${XDG_STATE_HOME:-$HOME/.local/state}/zeph"/muted-*` (should see the mute file)
- **Fix**: 
  1. Run `/zeph-mute` again
  2. Check that the state dir is writable: `touch "$STATE_DIR/test" && rm "$STATE_DIR/test"`

**Problem**: "Command not found" or "permission denied"
- **Check**: Are you in a shell where bash/dash is available?
- **Fix**: Make sure you're in bash/zsh/sh, not another shell
  - Or run the command directly in Claude Code terminal

**Problem**: "What's the mute file path?"
- **Check**: Run this to find it:
  ```bash
  HASH=$(printf '%s' "$(pwd)" | cksum | cut -d' ' -f1)
  echo "${XDG_STATE_HOME:-$HOME/.local/state}/zeph/muted-$HASH"  # shows the exact path
  ```
- To see if it exists: `[ -f "${XDG_STATE_HOME:-$HOME/.local/state}/zeph/muted-$HASH" ] && echo "Muted" || echo "Active"`
