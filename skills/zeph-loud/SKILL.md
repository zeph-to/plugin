---
name: zeph-loud
description: >
  Set Zeph to LOUD push mode — push on every turn, overriding the usual silence
  on read-only / sub-threshold turns and `skip` Push Signals. Applies to this
  project, or to every project with `--global`. Use /zeph-normal to restore
  default, /zeph-quiet for important-only, /zeph-mute for silence.
metadata:
  author: zeph-to
  version: "0.9.0"
  relatedSkills:
    - zeph
    - zeph-quiet
    - zeph-normal
    - zeph-mute
    - zeph-status
  triggers:
    - zeph-loud
    - push everything
    - notify every turn
    - verbose pushes
    - /zeph-loud
---

Set Zeph push mode to LOUD (persists until undone).

Scope: **this project**, unless the user passed `--global` — then it becomes the
machine-wide default for every project that has no dial of its own.

Project (default) — run this bash command:

```bash
HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zeph"
mkdir -p "$STATE_DIR"
printf 'loud' > "$STATE_DIR/pushmode-$HASH"
```

Global (`/zeph-loud --global`) — run this instead:

```bash
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zeph"
mkdir -p "$STATE_DIR"
printf 'loud' > "$STATE_DIR/pushmode-default"
```

Then confirm to the user, in your own words (say which scope it applied to):
every turn now sends a push —
overriding the read-only / `<2`-tool floor and any `skip` Push Signal. A turn that
already sent a `zeph_ask` still won't double-push. `/zeph-normal` restores the
default, `/zeph-quiet` limits to important pushes, `/zeph-mute` silences all.

## If Things Go Wrong

- **Not pushing every turn**: verify — `ls -la "${XDG_STATE_HOME:-$HOME/.local/state}/zeph"/pushmode-*`
  (should contain `loud`). Re-run `/zeph-loud`, then `/zeph-status`.
- **Mode is per-project** (hashed from the directory) — confirm with `pwd`. The
  `--global` form writes `pushmode-default`, used only by projects with no file
  of their own.
