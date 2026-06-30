---
name: zeph-quiet
description: >
  Set Zeph to QUIET push mode for this session — only high-priority pushes
  (blockers and `high` Push Signals) reach you; routine completion pushes are
  suppressed. Use /zeph-normal to restore default, /zeph-loud for everything,
  /zeph-mute for full silence.
metadata:
  author: zeph-to
  version: "0.5.9"
  relatedSkills:
    - zeph
    - zeph-loud
    - zeph-normal
    - zeph-mute
    - zeph-status
  triggers:
    - zeph-quiet
    - quiet pushes
    - only important pushes
    - fewer notifications
    - /zeph-quiet
---

Set Zeph push mode to QUIET for this session.

Run this bash command:

```bash
HASH=$(echo -n "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
printf 'quiet' > "/tmp/zeph-pushmode-$HASH"
```

Then confirm to the user, in your own words: only high-priority pushes (blockers
and `high` Push Signals) will arrive — routine completion pushes are suppressed.
`/zeph-normal` restores the default, `/zeph-loud` pushes every turn, `/zeph-mute`
silences everything.

> Scope: this dials the automatic Stop-hook push. Explicit `zeph_notify` calls the
> agent makes for blockers still go through.

## If Things Go Wrong

- **Still getting routine pushes**: verify the file — `ls -la /tmp/zeph-pushmode-*`
  (should contain `quiet`). Re-run `/zeph-quiet`, then `/zeph-status`.
- **`/tmp` not writable**: `touch /tmp/test && rm /tmp/test` to check; inspect
  `ls -ld /tmp`.
- **Mode is per-project** (hashed from the directory). If you switch folders, each
  has its own mode — confirm with `pwd`.
