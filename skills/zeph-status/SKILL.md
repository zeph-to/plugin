---
name: zeph-status
description: >
  Check Zeph notification status for this session. Shows whether notifications
  are currently muted or active. Use before muting/unmuting to see current state.
metadata:
  author: zeph-to
  version: "0.4.0"
  relatedSkills:
    - zeph
    - zeph-mute
    - zeph-unmute
  triggers:
    - zeph-status
    - check zeph status
    - notification status
    - mute status
    - /zeph-status
---

Check Zeph mute status.

Run this bash command:

```bash
HASH=$(echo -n "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
if [ -f "/tmp/zeph-muted-$HASH" ]; then echo "MUTED"; else echo "ACTIVE"; fi
```

Report the result in your own words:
- If the command printed `MUTED`: tell the user Zeph notifications are muted for this project and that `/zeph-unmute` re-enables them.
- If it printed `ACTIVE`: tell the user Zeph notifications are active and that `/zeph-mute` silences them.

## If Things Go Wrong

**Problem**: "Command returns nothing"
- **Check**: Run the command again, piece by piece:
  ```bash
  pwd  # shows your current directory
  HASH=$(echo -n "$(pwd)" | cksum | cut -d' ' -f1)
  echo "Checking: /tmp/zeph-muted-$HASH"
  [ -f "/tmp/zeph-muted-$HASH" ] && echo "MUTED" || echo "ACTIVE"
  ```
- **Fix**: One of the pieces should show the issue (directory, hash, or file check)

**Problem**: "Shows ACTIVE but /zeph-mute should have muted it"
- **Check**: Did `/zeph-mute` complete successfully? Did it say "muted"?
- **Verify**: Look for the file manually:
  ```bash
  ls -la /tmp/zeph-muted-*  # shows all mute files
  ```
- **Fix**: Run `/zeph-mute` again, then `/zeph-status` to confirm

**Problem**: "Shows MUTED but I ran /zeph-unmute"
- **Check**: Is the mute file still there after /zeph-unmute?
  ```bash
  HASH=$(echo -n "$(pwd)" | cksum | cut -d' ' -f1)
  ls -la /tmp/zeph-muted-$HASH  # should NOT exist after unmute
  ```
- **Fix**: Run `/zeph-unmute` again, then check that the file is gone

**Problem**: "Mute status different between terminals"
- **Note**: Mute is based on project directory (hashed). If you're in different directories, each has its own mute state.
- **Check**: Are you in the same directory? `pwd`
- **Fix**: 
  - Use absolute path: `cd /exact/path/to/project`
  - Or set `CLAUDE_PROJECT_DIR=/exact/path` in environment
