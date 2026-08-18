---
name: zeph-unmute
description: >
  Unmute Zeph push notifications for this project (persists until undone). Re-enables automatic
  notifications from Stop and AskUserQuestion hooks. Use after /zeph-mute to turn them back on.
metadata:
  author: zeph-to
  version: "0.9.0"
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

## Rules for the rest of this session

If this session started muted, the SessionStart hook injected only a three-line "muted" note — none of the remote-control rules — and it does not re-run mid-session. From here on, follow [`docs/CORE_RULES.md`](../../docs/CORE_RULES.md) as if the session had started unmuted. The short version:

- **Notify:** the Stop hook owns the completion push. Do NOT call `zeph_notify` just to say "done"; use it only for mid-task blockers (`priority: "high"`), long-running milestones, or multi-session signals — the instant they happen.
- **NORMAL (you are here):** the user is at the terminal. You owe no `zeph_ask`. Questions go to `AskUserQuestion` or prose; completion is the Stop hook's push.
- **REMOTE** starts when a message arrives from the user's phone (the UserPromptSubmit hook says so and injects Rule 9 in full) or a `zeph_ask` answer reports `zephState: "REMOTE"`. From then on end EVERY response with `zeph_ask` — 2–4 `actions` plus a Done-like `fallback`, `timeout` 300–600 s — and route button-friendly questions through it instead of `AskUserQuestion`, until a Done-like button, a free-text wrap-up (emit `<!-- zeph: exit -->` once), or a prompt typed at the terminal.

These persist for the session, including after context compaction. Tell the user once that a restart gives them the full rule set from the hook.

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
