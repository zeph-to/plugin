---
name: zeph-mode
description: >
  Show or change Zeph push notifications for this project: quiet (default),
  normal, loud, mute, unmute; --global sets the default dial.
argument-hint: "[quiet|normal|loud|mute|unmute] [--global]"
metadata:
  author: zeph-to
  version: "0.18.0"
  relatedSkills:
    - zeph
    - zeph-auto
  triggers:
    - zeph-mode
    - mute zeph
    - unmute zeph
    - zeph status
    - push mode
    - /zeph-mode
---

Run this, exactly as written — the arguments go on the heredoc's second line,
never onto the command itself, on one line, and only the words `quiet` `normal`
`loud` `mute` `unmute` `--global`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/zeph-mode.sh" <<'ZEPH_MODE_INPUT'
${CLAUDE_PROJECT_DIR}
$ARGUMENTS
ZEPH_MODE_INPUT
```

Exit 2 means a bad argument — show the user the usage line it printed. Otherwise
report the status lines in your own words:

- `NOTIFICATIONS: muted` → the Stop and Ask hooks are silent here; `zeph_*` tools
  still work but are not called unless the user asks. Mute beats every dial.
- `PUSH MODE: quiet` → only high-priority pushes (blockers, `high` Push Signal)
  while the user is at the terminal, plus a completion push once they have been
  away (`ZEPH_AWAY_SEC`, default 300 s). The shipped default.
- `PUSH MODE: normal` → a push on every turn that did real work, silent on
  read-only turns; the Push Signal markers decide the edge cases.
- `PUSH MODE: loud` → every turn pushes, overriding `skip`.
- The parenthesis says where the dial came from: `this project`, `global default`
  (set with `--global`, inherited by projects without their own dial), or the
  built-in default. A project dial always beats the global one.
- `AUTO MODE: …` → a `/zeph-auto` session is running with that much budget left.

Questions (`zeph_ask`, the AskUserQuestion mirror) push under every dial except mute.

If the output ends with a `=== Zeph rules — replace the Zeph rules from session start ===`
block, the state changed and the rules the SessionStart hook gave this session are
stale: follow that block instead for the rest of the session, including after
compaction. A `could not refresh` line means the change still applies but the
rules did not update — tell the user a new session picks them up.
