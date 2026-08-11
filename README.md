# Zeph — notifications & remote control for AI coding agents

[![release](https://img.shields.io/github/v/release/zeph-to/plugin?label=plugin&sort=semver)](https://github.com/zeph-to/plugin/releases)
[![marketplace](https://img.shields.io/badge/claude--code-plugin-blueviolet)](https://github.com/zeph-to/plugin)
[![cli](https://img.shields.io/npm/v/@zeph-to/cli?label=%40zeph-to%2Fcli)](https://www.npmjs.com/package/@zeph-to/cli)
[![mcp-server](https://img.shields.io/npm/v/@zeph-to/mcp-server?label=%40zeph-to%2Fmcp-server)](https://www.npmjs.com/package/@zeph-to/mcp-server)
[![license](https://img.shields.io/github/license/zeph-to/plugin)](./LICENSE)
[![docs](https://img.shields.io/badge/docs-docs.zeph.to-1f6feb)](https://docs.zeph.to)

**Your agent finishes a build or hits a decision → your phone buzzes → you tap an answer → the session keeps going.** No walking back to the terminal.

Zeph turns any AI coding agent into something you can supervise from your pocket. Get a push the moment Claude finishes real work or needs a call, then answer right there — a button tap or a typed reply flows straight back into the live session.

<p align="center">
  <img src="https://zeph.to/readme/demo.gif" alt="Claude asks 'Deploy to prod?' on your phone; you tap Deploy; the session ships" width="560"><br>
  <sub><em>Claude asks on your phone → you tap <b>Deploy</b> → the session ships. No terminal.</em></sub>
</p>

Works with **Claude Code, Cursor, Windsurf, Gemini CLI, Codex, and more.** Built on [`@zeph-to/cli`](https://github.com/zeph-to/cli) (installer, hooks, tmux remote control) and [`@zeph-to/mcp-server`](https://github.com/zeph-to/mcp-server) (the `zeph_ask` family of tools), paired with the [Zeph app](https://zeph.to) on your phone.

> **New here?** [docs.zeph.to](https://docs.zeph.to) walks the whole setup — one command on your machine, the app on your phone, and a restart. The reference below assumes that is already done.

---

## Quick start

```bash
# 1. Add the Claude Code plugin
claude plugin marketplace add zeph-to/plugin
claude plugin install zeph@zeph

# 2. Install the CLI and wire everything up (opens a browser sign-in)
npm install -g @zeph-to/cli
zeph install
```

Restart Claude Code — notifications start automatically. That's it. `zeph install` signs you in once, issues a matched API key + hook, and configures every AI agent it finds on your machine. Not near a browser? See [headless setup](#other-agents).

> **Why global, not `npx`?** A global `zeph` powers `zeph cc` (drive a session from your phone) and lets agent hooks skip an npx cold-start on every push. `npx @zeph-to/cli install` still works for a notifications-only setup.

---

## What you get

**Two things, out of the box:**

### 1. Notifications that just work — no prompting, 100% reliable

| You get a push when… | Fires on |
|----------------------|----------|
| Claude **asks you a question** | any `AskUserQuestion` |
| A session **has been idle for five minutes** (it's done) | the session going quiet, not each turn |
| Claude flags a turn as **important** | a `high` Push Signal on that response |
| Claude **finishes real work**, every turn | only after `/zeph-normal` — see below |

These ride on hooks — shell commands that fire on Claude events, independent of whether the model "remembers" to notify you. Out of the box the per-turn push is off (`quiet`), so a long session pings you when it asks something and when it's actually finished, not thirty times along the way. They fire in **every** Claude Code session, not only ones launched with `zeph cc` — that command is the phone-control bridge, not the notification switch. Dial the volume any time, per project or machine-wide (see [Mute & Push Mode](#mute--push-mode)).

### 2. Reply from your phone, straight into the session

With a Hook ID configured (`zeph install` sets one up automatically), Claude ends a turn by **asking you** — buttons *and* a text field, together. Tap **Continue** / **Review** / **Done**, or type `commit and push` / `/ship` / `fix the tests`. Your answer runs immediately, then Claude asks again. This is the **Ask Loop**, and it keeps going until you tap **Done**.

<p align="center">
  <img src="https://zeph.to/readme/ask-phone.png" alt="A Zeph hook on the phone: a question with tappable answer buttons and a text field" width="300">
</p>

| Tool | What it shows | When Claude reaches for it |
|------|---------------|----------------------------|
| `zeph_ask` | buttons **+** text input | decisions, next steps, custom instructions |
| `zeph_prompt` | 2–4 buttons | simple yes/no / pick-one |
| `zeph_input` | text field | free-form input only |
| `zeph_notify` · `zeph_clipboard` · `zeph_file` | one-way push | when you explicitly ask |

> `zeph_ask` / `zeph_prompt` / `zeph_input` need a Hook ID — issued for you during sign-in and saved to `~/.zeph/config.json`. No env vars.

---

## Drive a session end-to-end from your phone

Launch Claude through `zeph cc` and the phone's **Active Agents** picker can type directly into the running session — even after a `zeph_ask` window has closed. Start a refactor from the couch, answer follow-ups over lunch, come back to a finished branch.

```bash
zeph cc          # claude in a named tmux session the phone can reach
zeph codex       # same for Codex
zeph gemini      # same for Gemini
```

One-step setup and the full architecture live in [cli → Remote Control](https://github.com/zeph-to/cli#remote-control).

---

## Autonomous mode

Hand Claude a time budget and walk away:

```
/zeph-auto 2h fix the flaky tests
```

Claude loops explore → plan → implement → verify → commit until the budget runs out, committing each verified unit on a work branch. Questions arrive on your phone as `zeph_ask` buttons **with a stated default** — answer to steer, or ignore and the run proceeds on the safe default after the timeout. Irreversible actions (push, deploy, delete) never happen on a timeout; they wait for an explicit tap. The run ends with a report of what was committed, skipped, and auto-defaulted — plus buttons to extend, review, or finish.

Duration takes `2h`, `90m`, `1h30m`, or plain minutes (default `1h`). `/zeph-status` shows the remaining budget mid-run.

---

## Mute & Push Mode

Pushes fire for **every** Claude Code session, not only ones launched with `zeph cc` — `zeph cc` is the remote-control bridge, not the notification switch. Silence or dial the volume, per project:

```
/zeph-mute      Disable all notifications for this project
/zeph-unmute    Re-enable them
/zeph-status    Show current state (mute + push mode, and where it came from)

/zeph-quiet     Only high-priority pushes reach you  ← the default
/zeph-loud      Push on every turn
/zeph-normal    Push on every turn that did real work, quiet on reads
```

**Quiet is the default.** An install with no dial pushes only on high-priority signals, so a long session doesn't turn into a stream of per-turn notifications. What still reaches you: questions (the agent asking you something is never suppressed) and the completion push when a session has been idle for five minutes. If you'd rather hear about every working turn, `/zeph-normal` — that was the old default.

Add `--global` to any of the three dials to set the **machine-wide default** for every project that has no dial of its own. A per-project dial always outranks it, so `/zeph-normal` opts a single project back into per-turn pushes and `/zeph-normal --global` does it everywhere.

State lives in a file under `${XDG_STATE_HOME:-~/.local/state}/zeph`, keyed by project directory (`pushmode-default` for the global one) — it survives reboots and new sessions until you undo it. Mute silences both hooks and CLI calls and overrides any push mode; mute stays per-project by design, since a global mute could never be lifted for a single project.

---

## Other agents

`zeph install` isn't Claude-only — it detects **every** agent on your machine and configures each one (MCP server + notification hooks + a behavioral rule file in that agent's native always-on location):

```bash
npm install -g @zeph-to/cli
zeph install
```

| Agent | Auto notify | MCP tools | How |
|-------|:-----------:|:---------:|-----|
| Claude Code | ✓ Stop hook | ✓ | Plugin |
| Cursor | ✓ stop hook | ✓ | MCP + hook + rules |
| Windsurf | ✓ response hook | ✓ | MCP + hook + rules |
| Gemini CLI | ✓ AfterAgent hook | ✓ | MCP + hook |
| Codex CLI | ✓ Stop hook | — | Hook + rules |
| Copilot CLI | ✓ sessionEnd hook | — | Hook + rules |
| Cline | LLM-based | — | Rules file |
| Aider | LLM-based | — | Conventions file |

**Headless box (no browser):** sign in on any machine with a browser, then copy the two values from its `~/.zeph/config.json`:

```bash
zeph install --key ak_... --hook hook_...
```

<details>
<summary><b>Manual MCP setup</b> (if you'd rather not run the installer)</summary>

**Gemini CLI:**
```bash
gemini mcp add zeph -- npx -y @zeph-to/mcp-server
```

**Cursor** — add to `~/.cursor/mcp.json` (Windsurf: `~/.codeium/windsurf/mcp_config.json`, same shape):
```json
{
  "mcpServers": {
    "zeph": {
      "command": "npx",
      "args": ["-y", "@zeph-to/mcp-server"],
      "env": { "ZEPH_API_KEY": "ak_..." }
    }
  }
}
```
</details>

---

## How it works

Zeph is three cooperating layers. Hooks fire whether or not the model cooperates; MCP tools give the model a way to reach you on purpose.

```
zeph-to/plugin (Claude Code plugin)
  ├─ hooks/zeph-setup.js   → SessionStart: inject the behavioral rules
  ├─ hooks/zeph-stop.sh    → Stop: auto completion push
  ├─ hooks/zeph-ask.sh     → PreToolUse: question push
  ├─ hooks/zeph-remote.sh  → UserPromptSubmit: phone-sent message → REMOTE mode
  ├─ .mcp.json             → registers the MCP server
  └─ builds on:
      ├─ @zeph-to/cli         → hooks + notify/list/dismiss + tmux remote control
      └─ @zeph-to/mcp-server  → zeph_ask / zeph_prompt / zeph_input / clipboard / file …
```

| Layer | Package | Role | Reliability |
|-------|---------|------|-------------|
| **Hooks** | `@zeph-to/cli` | auto-fire on Claude events | 100% — no AI cooperation needed |
| **MCP server** | `@zeph-to/mcp-server` | AI-callable tools (ask, prompt, input…) | depends on the model following rules |
| **Plugin** | `zeph-to/plugin` | bundles hooks + MCP + rules | installed once |

<details>
<summary><b>Session flow & the Ask Loop</b></summary>

```
SessionStart hook
  ├─ read ~/.zeph/config.json
  ├─ HOOK_ID present → inject ask/prompt/input rules
  └─ HOOK_ID absent  → inject notify-only rules

Working…
  ├─ Choice/input needed → zeph_ask → button or text reply from mobile → continue
  ├─ Complex question    → AskUserQuestion → Ask hook push → answer at terminal
  ├─ Task complete       → zeph_ask "Done. Next?" → pick or type → execute → loop
  │                          └─ tap "Done" → session ends
  └─ Fallback: AI skipped zeph_ask → Stop hook sends a one-way push
```

When a Hook ID is set, Claude uses `zeph_ask` as its final action after real work. Your reply is treated as a direct instruction — executed without re-confirming — then Claude asks again. The loop also starts **from the phone**: send a message via the app's agent chat and the `zeph listener` records exactly what it injected; the plugin's UserPromptSubmit hook verifies the match and Claude knows you're remote (ADR-0002).
</details>

<details>
<summary><b>Notification matrix</b> — who fires what, and can it double up</summary>

| Event | Source | Reliability | Duplicates |
|-------|--------|-------------|------------|
| Task completed | Stop hook | 100% | No (skipped if AI already sent `zeph_ask`) |
| Question asked | Ask hook | 100% | No |
| Decision / input needed | `zeph_ask` | ~80% (AI must call it) | No |
| Decision only | `zeph_prompt` | ~80% | No |
| Text input only | `zeph_input` | ~80% | No |
| Manual push | `zeph_notify` | on request | No |
</details>

---

## CLI reference

```bash
zeph <command>       # or: npx @zeph-to/cli <command>
```

| Command | Description |
|---------|-------------|
| `install` | one-command setup for every detected agent |
| `login` | browser sign-in — refresh credentials into `~/.zeph/config.json` |
| `notify --title "…" --body "…"` | send a push |
| `list [--limit 5] [--type note]` | list recent pushes |
| `dismiss <id>` · `--all` | mark pushes read |
| `cc` · `codex` · `gemini` | run the agent in a phone-reachable tmux session |
| `test` | verify connection |

**Session commands (Claude Code):** `/zeph-config` (guided setup) · `/zeph-auto [duration] [task]` · `/zeph-mute` · `/zeph-unmute` · `/zeph-status` · `/zeph-quiet` · `/zeph-loud` · `/zeph-normal`.

Full CLI, SDK, and listener docs: [`@zeph-to/cli`](https://github.com/zeph-to/cli).

---

## Encryption

End-to-end encryption is **off by default** and turning it on needs Zeph Pro. The switch is in the app under Settings → E2E Encryption; until you flip it every push reaches the backend in plaintext. No config beyond that.

With it on, push bodies and attachments are encrypted with AES-256-GCM. Each machine holds its own ECDH P-256 keypair and the private half never leaves it — the backend stores public keys only and rejects a private-key upload. A push is encrypted once and its key wrapped separately for each of your devices.

**Threat model, honestly.** Against a *passive* backend — a leaked snapshot, an operator reading the table — the stored ciphertext is useless, so push contents stay private. Three things it does not do:

- **It does not stop an active operator.** Recipient public keys come from the same server, unsigned. A backend that injects a device record carrying its own key gets the message key wrapped for it. The Zeph app ships the counter-measure — compare device fingerprints, mark them verified, and strict mode then wraps only for verified devices — but it is off by default and the CLI and MCP server do not consult it (ADR-0007 Phase 4).
- **There is no forward secrecy.** The shared secret for a given sender/device pair is static, so compromising either private key opens every past push wrapped for that pair.
- **The ask loop is not encrypted.** `zeph_ask`, `zeph_prompt` and `zeph_input` travel over the hook route, which carries no sender key: the question's title and body are plaintext, and so is your answer. The server refuses an encrypted file on an answer outright rather than handing the agent bytes it cannot open. (A file the *agent* attaches to a question is the one exception — it carries its own wrapped key.)

Your agent's machine is also **send-only** under encryption: it registers no public key and the listener does not decrypt, so nothing is encrypted *to* it.

---

## Uninstall

```bash
zeph uninstall              # remove Zeph from every detected agent
zeph uninstall --dry-run    # preview first
zeph uninstall --purge      # also delete ~/.zeph/config.json
```

Reverses `zeph install` everywhere — MCP entries, hooks, and rule files. It only touches Zeph's own artifacts: shared rule files keep your content, with just the `<!-- ZEPH:START -->…<!-- ZEPH:END -->` block stripped. Remove the Claude Code plugin with `claude plugin uninstall zeph@zeph`.

---

## Deep dives

- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) — how the plugin, CLI, and MCP server fit together
- [docs/CORE_RULES.md](./docs/CORE_RULES.md) — the authoritative behavioral rules injected at session start
- [docs/HOOKS-EXPLAINED.md](./docs/HOOKS-EXPLAINED.md) — what each hook does and why

## License

Apache 2.0
