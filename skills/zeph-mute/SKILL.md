---
name: zeph-mute
description: >
  Mute Zeph push notifications for this session. Stops automatic notifications
  from Stop and AskUserQuestion hooks. Use /zeph-unmute to re-enable.
metadata:
  author: zeph-to
  version: "0.4.0"
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

Mute Zeph notifications for this session.

Run this bash command:

```bash
HASH=$(echo -n "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
touch "/tmp/zeph-muted-$HASH"
```

Then confirm to the user, in your own words, that Zeph notifications are now muted for this session and that `/zeph-unmute` re-enables them.

## If Things Go Wrong

**Problem**: "Mute doesn't work, still getting notifications"
- **Check**: Did the command complete without error?
- **Verify**: `ls -la /tmp/zeph-muted-*` (should see the mute file)
- **Fix**: 
  1. Run `/zeph-mute` again
  2. Check that /tmp exists and is writable: `touch /tmp/test-write && rm /tmp/test-write`
  3. If /tmp permission denied: check permissions `ls -ld /tmp`

**Problem**: "Command not found" or "permission denied"
- **Check**: Are you in a shell where bash/dash is available?
- **Fix**: Make sure you're in bash/zsh/sh, not another shell
  - Or run the command directly in Claude Code terminal

**Problem**: "What's the mute file path?"
- **Check**: Run this to find it:
  ```bash
  HASH=$(echo -n "$(pwd)" | cksum | cut -d' ' -f1)
  echo "/tmp/zeph-muted-$HASH"  # shows the exact path
  ```
- To see if it exists: `[ -f "/tmp/zeph-muted-$HASH" ] && echo "Muted" || echo "Active"`
