---
name: zeph-unmute
description: >
  Unmute Zeph push notifications for this session. Re-enables automatic
  notifications from Stop and AskUserQuestion hooks. Use after /zeph-mute to turn them back on.
metadata:
  author: zeph-to
  version: "0.4.0"
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

Unmute Zeph notifications for this session.

Run this bash command:

```bash
HASH=$(echo -n "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
rm -f "/tmp/zeph-muted-$HASH"
```

Then confirm to the user, in your own words, that Zeph notifications are re-enabled for this session.

## If Things Go Wrong

**Problem**: "Unmute doesn't work, still muted"
- **Check**: Run `/zeph-status` to verify actual state
- **Verify**: The mute file should be gone:
  ```bash
  HASH=$(echo -n "$(pwd)" | cksum | cut -d' ' -f1)
  ls -la /tmp/zeph-muted-$HASH  # should NOT exist
  ```
- **Fix**: 
  1. Run `/zeph-unmute` again
  2. Check `/zeph-status`
  3. If still shows MUTED: mute file may have been recreated, try unmute once more

**Problem**: "rm: permission denied"
- **Check**: Is /tmp writable? `touch /tmp/test && rm /tmp/test`
- **Fix**: Check /tmp permissions: `ls -ld /tmp` (should show rwxrwxrwt or similar)
- If /tmp is locked: restart your terminal and try again

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
