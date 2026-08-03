---
name: zeph-normal
description: >
  Set Zeph to NORMAL push mode — a push on every turn that did real work, silent
  on read-only turns, with the model's per-turn Push Signal deciding the edge
  cases. This is what you want if the shipped quiet default is too quiet, or to
  undo /zeph-quiet or /zeph-loud. Applies to this project, or to every project
  with `--global`.
metadata:
  author: zeph-to
  version: "0.10.0"
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

Set Zeph push mode to NORMAL (persists until undone).

Scope: **this project**, unless the user passed `--global` — then it becomes the
machine-wide default for every project that has no dial of its own.

> Normal is no longer the shipped default. An install with no dial anywhere is
> **quiet**: only high-priority pushes arrive from the Stop hook. This skill is
> how a user opts back into a push on every working turn.

Project (default) — run this bash command:

```bash
HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zeph"
mkdir -p "$STATE_DIR"
rm -f "/tmp/zeph-pushmode-$HASH"                 # legacy /tmp location
printf 'normal' > "$STATE_DIR/pushmode-$HASH"    # explicit — outranks a --global default
```

Global (`/zeph-normal --global`) — run this instead:

```bash
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zeph"
mkdir -p "$STATE_DIR"
printf 'normal' > "$STATE_DIR/pushmode-default"
```

The global form **writes** `normal` rather than deleting the file: deleting it
now falls back to the built-in quiet, which is the opposite of what the user
asked for. To go the other way — every project back to the shipped quiet — use
`/zeph-quiet --global`.

Then confirm to the user, in your own words (say which scope it applied to):
pushes now fire on every turn that did meaningful work, stay silent on read-only
/ sub-threshold turns, and the per-turn Push Signal (`skip`/`push`/`high`)
decides the edge cases. The project form writes an explicit `normal` so it also
overrides a machine-wide `--global` dial; per-project files elsewhere are
untouched by the global form.

> Note: this does not change mute. If the session is muted, run `/zeph-unmute`.

## If Things Go Wrong

- **Still quiet/loud**: check both files — `ls -la "${XDG_STATE_HOME:-$HOME/.local/state}/zeph"/pushmode-*`.
  This project's file should read `normal`; a leftover `pushmode-default` only
  matters for *other* projects. Re-run `/zeph-normal`, then `/zeph-status`.
- **Mode is per-project** (hashed from the directory) — confirm with `pwd`. The
  `--global` form writes `pushmode-default`, which every project without its own
  file falls back to. With no file there either, the built-in default is quiet.
