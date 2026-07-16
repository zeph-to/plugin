---
name: zeph-config
description: >
  Set up Zeph in one command. Runs the CLI installer (browser sign-in,
  credentials saved to ~/.zeph/config.json), then verifies with a test push.
  No environment variables, no manual key copying.
metadata:
  author: zeph-to
  version: "0.9.0"
  relatedSkills:
    - zeph
    - zeph-status
  triggers:
    - zeph-config
    - setup zeph
    - configure zeph
    - zeph setup
    - api key
    - hook id
    - remote control setup
    - cross-device notifications setup
    - /zeph-config
---

Set up Zeph for the user. **The entire setup is install the CLI, then run
`zeph install`** — everything else in this skill is verification.

## The setup

```bash
npm install -g @zeph-to/cli
zeph install
```

The installer is interactive (browser sign-in + agent picker), so it must run
in the user's own terminal, not through your Bash tool. Ask them to run it —
inside a Claude Code session they can type it with a `!` prefix:

```
! npm install -g @zeph-to/cli && zeph install
```

**Install globally, not `npx`.** `zeph cc` (drive a session from the phone)
needs `zeph` on `PATH`, and the agent hooks the installer writes are
`$(command -v zeph || npx …)` — a global binary skips an npx cold-start on
every notification. `npx -y @zeph-to/cli install` still works for a
notifications-only setup with no phone control, but default to the global
install.

What `zeph install` does:
- **Fresh machine**: opens a browser sign-in. The web app issues an API key
  and an interactive Hook **as a matched pair, automatically** — no copying
  keys from Settings. The CLI saves everything (`apiKey`, `hookId`,
  `baseUrl`, `wsUrl`) to `~/.zeph/config.json`.
- **Already signed in**: keeps the saved credentials and just (re)installs
  agent integrations. Safe to re-run any time.
- Installs hooks/MCP for every detected agent (Claude Code, Gemini CLI,
  Codex CLI, Cursor, …).

## Verify (after the user says it finished)

1. `cat ~/.zeph/config.json` — must contain `apiKey` and `hookId`.
2. Send a test push: use `zeph_notify`, or
   `zeph notify --title "Zeph connected ✅"`.
3. Phone buzzed → done. Tell the user to restart their agent session so the
   SessionStart hook injects the remote-control rules.

## Rules — do NOT re-introduce the old manual flow

- **Single source of truth: `~/.zeph/config.json`.** Every Zeph component
  (CLI, MCP server, plugin hooks) reads it. Do NOT add `ZEPH_API_KEY` /
  `ZEPH_HOOK_ID` to `~/.zshrc`, `~/.bashrc`, or `~/.claude/settings.json` —
  shell exports are unnecessary and create a second, drift-prone copy.
- Env vars exist only as **advanced overrides** (multi-account, CI). Never
  suggest them during normal setup.
- Never walk the user through creating keys or hooks by hand in the web app
  unless the machine is headless (below).

## Headless machine (no browser)

Sign in on any machine WITH a browser and copy the two values from its
`~/.zeph/config.json`, then on the headless machine:

```bash
npm install -g @zeph-to/cli
zeph install --key ak_... --hook hook_...
```

## If things go wrong

**`zeph_ask` 403 Forbidden** — stale key/hook pairing. Re-run
`zeph install`; a fresh sign-in issues a consistent pair.

**No notification received** — `command -v jq` (hooks need jq:
`brew install jq` / `apt install jq`), and confirm the phone app is signed
in to the SAME account the browser sign-in used.

**`zeph_ask` times out** — phone app open? Answered within the timeout
(default 120 s)? `zeph verify` checks installation health.

**config.json missing or corrupt** — re-run `zeph install`; it rewrites
the file.
