---
name: zeph-unmute
description: >
  Unmute Zeph push notifications for this project (persists until undone). Re-enables automatic
  notifications from Stop and AskUserQuestion hooks. Use after /zeph-mute to turn them back on.
metadata:
  author: zeph-to
  version: "0.8.0"
  relatedSkills:
    - zeph
    - zeph-mute
    - zeph-status
  triggers:
    - zeph-unmute
    - unmute notifications
    - enable notifications
    - re-enable alerts
    - /zeph-unmute
---

Unmute Zeph notifications for this project (persists until undone).

Run this bash command:

```bash
HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zeph"
rm -f "$STATE_DIR/muted-$HASH" "/tmp/zeph-muted-$HASH"   # legacy /tmp too
```

Then confirm to the user, in your own words, that Zeph notifications are re-enabled for this project (persists until undone).

## If Things Go Wrong

**Problem**: "Unmute doesn't work, still muted"
- **Check**: Run `/zeph-status` to verify actual state
- **Verify**: The mute file should be gone:
  ```bash
  HASH=$(printf '%s' "$(pwd)" | cksum | cut -d' ' -f1)
  ls -la "${XDG_STATE_HOME:-$HOME/.local/state}/zeph/muted-$HASH"  # should NOT exist
  ```
- **Fix**: 
  1. Run `/zeph-unmute` again
  2. Check `/zeph-status`
  3. If still shows MUTED: mute file may have been recreated, try unmute once more

**Problem**: "rm: permission denied"
- **Check**: Is the state dir writable? `ls -ld "${XDG_STATE_HOME:-$HOME/.local/state}/zeph"`
- **Fix**: It's under your home directory — fix ownership/permissions if something else created it

**Problem**: "Notifications still not appearing after unmuting"
- **Check**: Did you restart Claude Code?
- **Fix**: Restart Claude Code for the change to take effect
- **Verify**: Run `/zeph-status` to confirm ACTIVE

**Problem**: "Wrong project got unmuted"
- **Note**: Each project has its own mute state (based on directory)
- **Fix**: 
  1. Verify you're in the right directory: `pwd`
  2. If needed, mute/unmute in the correct project directory
  3. Use absolute paths if you switch between project folders often
