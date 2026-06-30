---
name: zeph-normal
description: >
  Restore Zeph's DEFAULT push mode for this session — clears /zeph-quiet or
  /zeph-loud so the normal heuristic (push on real work, silent on read-only)
  and the model's per-turn Push Signal decide again.
metadata:
  author: zeph-to
  version: "0.5.9"
  relatedSkills:
    - zeph
    - zeph-quiet
    - zeph-loud
    - zeph-mute
    - zeph-status
  triggers:
    - zeph-normal
    - reset push mode
    - default notifications
    - clear quiet loud
    - /zeph-normal
---

Restore Zeph's default push mode for this session.

Run this bash command:

```bash
HASH=$(echo -n "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
rm -f "/tmp/zeph-pushmode-$HASH"
```

Then confirm to the user, in your own words: push mode is back to default — pushes
fire on meaningful work, stay silent on read-only / sub-threshold turns, and the
per-turn Push Signal (`skip`/`push`/`high`) decides as usual.

> Note: this does not change mute. If the session is muted, run `/zeph-unmute`.

## If Things Go Wrong

- **Still quiet/loud**: confirm the file is gone — `ls -la /tmp/zeph-pushmode-*`
  (should not exist for this project). Re-run `/zeph-normal`, then `/zeph-status`.
- **Mode is per-project** (hashed from the directory) — confirm with `pwd`.
