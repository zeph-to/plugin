---
name: zeph-status
description: >
  Check Zeph notification status for this session. Shows whether notifications
  are muted or active, and the current push mode (normal/quiet/loud). Use before
  muting or changing push mode to see current state.
metadata:
  author: zeph-to
  version: "0.5.9"
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
HASH=$(echo -n "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
if [ -f "/tmp/zeph-muted-$HASH" ]; then echo "MUTED"; else echo "ACTIVE"; fi
MODE=$( [ -f "/tmp/zeph-pushmode-$HASH" ] && cat "/tmp/zeph-pushmode-$HASH" || echo "normal" )
echo "PUSH MODE: $MODE"
```

Report the result in your own words:
- `MUTED` → notifications are muted for this project; `/zeph-unmute` re-enables them.
- `ACTIVE` → notifications are active; `/zeph-mute` silences them.
- `PUSH MODE: normal` → default (push on real work, silent on read-only).
- `PUSH MODE: quiet` → only high-priority pushes; `/zeph-normal` restores default.
- `PUSH MODE: loud` → every turn pushes; `/zeph-normal` restores default.

(Push mode only applies when not muted — mute overrides everything.)

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
