---
name: zeph-normal
description: >
  Restore Zeph's DEFAULT push mode — clears /zeph-quiet or /zeph-loud so the
  normal heuristic (push on real work, silent on read-only) and the model's
  per-turn Push Signal decide again. Applies to this project, or clears the
  machine-wide default with `--global`.
metadata:
  author: zeph-to
  version: "0.8.0"
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

Restore Zeph's default push mode (persists until undone).

Scope: **this project**, unless the user passed `--global` — then it clears the
machine-wide default set by `/zeph-quiet --global` or `/zeph-loud --global`.

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
rm -f "$STATE_DIR/pushmode-default"
```

Then confirm to the user, in your own words (say which scope it applied to): push
mode is back to default — pushes fire on meaningful work, stay silent on
read-only / sub-threshold turns, and the per-turn Push Signal
(`skip`/`push`/`high`) decides as usual. The project form writes an explicit
`normal` so it also overrides a machine-wide `--global` dial; per-project files
elsewhere are untouched by the global form.

> Note: this does not change mute. If the session is muted, run `/zeph-unmute`.

## If Things Go Wrong

- **Still quiet/loud**: check both files — `ls -la "${XDG_STATE_HOME:-$HOME/.local/state}/zeph"/pushmode-*`.
  This project's file should read `normal`; a leftover `pushmode-default` only
  matters for *other* projects. Re-run `/zeph-normal`, then `/zeph-status`.
- **Mode is per-project** (hashed from the directory) — confirm with `pwd`. The
  `--global` form writes/clears `pushmode-default`, which every project without
  its own file falls back to.
