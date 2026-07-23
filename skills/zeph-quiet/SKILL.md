---
name: zeph-quiet
description: >
  Set Zeph to QUIET push mode — only high-priority pushes (blockers and `high`
  Push Signals) reach you; routine completion pushes are suppressed. Applies to
  this project, or to every project with `--global`. Use /zeph-normal to restore
  default, /zeph-loud for everything, /zeph-mute for full silence.
metadata:
  author: zeph-to
  version: "0.9.0"
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

Set Zeph push mode to QUIET (persists until undone).

Scope: **this project**, unless the user passed `--global` — then it becomes the
machine-wide default for every project that has no dial of its own.

Project (default) — run this bash command:

```bash
HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zeph"
mkdir -p "$STATE_DIR"
printf 'quiet' > "$STATE_DIR/pushmode-$HASH"
```

Global (`/zeph-quiet --global`) — run this instead:

```bash
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zeph"
mkdir -p "$STATE_DIR"
printf 'quiet' > "$STATE_DIR/pushmode-default"
```

Then confirm to the user, in your own words: only high-priority pushes (blockers
and `high` Push Signals) will arrive — routine completion pushes are suppressed.
Say which scope it applied to (this project vs every project). `/zeph-normal`
restores the default, `/zeph-loud` pushes every turn, `/zeph-mute` silences
everything. A per-project dial always wins over the global default.

> Scope: this dials the automatic Stop-hook push. Explicit `zeph_notify` calls the
> agent makes for blockers still go through.

## If Things Go Wrong

- **Still getting routine pushes**: verify the file — `ls -la "${XDG_STATE_HOME:-$HOME/.local/state}/zeph"/pushmode-*`
  (should contain `quiet`). Re-run `/zeph-quiet`, then `/zeph-status`.
- **Mode is per-project** (hashed from the directory). If you switch folders, each
  has its own mode — confirm with `pwd`. The `--global` form writes
  `pushmode-default`, which only applies to projects with no file of their own.
- **Quiet never swallows questions**: `zeph_ask` mirrors are gated on mute only,
  so a question still reaches the phone in quiet mode — global or not.
