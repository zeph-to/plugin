# Zeph — AI Agent Notifications

[![release](https://img.shields.io/github/v/release/zeph-to/plugin?label=plugin&sort=semver)](https://github.com/zeph-to/plugin/releases)
[![marketplace](https://img.shields.io/badge/claude--code-plugin-blueviolet)](https://github.com/zeph-to/plugin)
[![cli](https://img.shields.io/npm/v/@zeph-to/cli?label=%40zeph-to%2Fcli)](https://www.npmjs.com/package/@zeph-to/cli)
[![mcp-server](https://img.shields.io/npm/v/@zeph-to/mcp-server?label=%40zeph-to%2Fmcp-server)](https://www.npmjs.com/package/@zeph-to/mcp-server)
[![license](https://img.shields.io/github/license/zeph-to/plugin)](./LICENSE)

Get push notifications on your phone when your AI coding agent finishes work or needs input — and **reply from the phone straight back into your CC session** without touching your terminal.

Works with Claude Code, Gemini CLI, Cursor, Windsurf, and more.

## Quick Start (Claude Code)

```bash
# Step 1: Install plugin (both commands required)
claude plugin marketplace add zeph-to/plugin
claude plugin install zeph@zeph

# Step 2: Configure — pick one:
npx @zeph-to/cli install                              # interactive
npx @zeph-to/cli install --key ak_... --hook hook_... # non-interactive (from Zeph app)
```

Restart Claude Code after setup. Notifications will start automatically.

> **Remote control bonus.** Launch Claude through `zeph cc` (from `@zeph-to/cli`) and the phone's "Active Agents" picker can type into the session directly — no terminal context-switch required. See [cli Remote Control](https://github.com/zeph-to/cli#remote-control) for the one-step setup.

## What You Get

### Automatic — always works, no prompting needed

| What happens | When |
|-------------|------|
| Push: task completion summary | Claude finishes real work (≥2 tool calls, not just reads) |
| Push: question text | Claude asks you a question |

These use hooks — shell commands that fire on Claude events. 100% reliable.

Read-only exploration turns stay quiet, and Claude can fine-tune any single push
with a Push Signal (force an important one through, or skip a noisy one). You can
also dial the overall volume — see [Mute & Push Mode](#mute--push-mode).

### On request — Claude calls when appropriate

With `ZEPH_HOOK_ID` configured, Claude prefers `zeph_ask` for decisions and input — showing buttons and a text field together. You can answer from your phone without returning to the terminal.

| Tool | What it does | When Claude uses it |
|------|-------------|---------------------|
| `zeph_ask` | Buttons + text input combined | Decisions, next steps, custom input |
| `zeph_prompt` | Pick from 2-4 options | Simple yes/no choices |
| `zeph_input` | Free-form text input | Text-only input |
| `zeph_notify` | Manual push notification | When explicitly asked |
| `zeph_clipboard` | Copy to clipboard | When explicitly asked |
| `zeph_file` | Send a file | When explicitly asked |

> `zeph_ask`, `zeph_prompt`, and `zeph_input` require `ZEPH_HOOK_ID` — enter it during `zeph install`.

## Mute & Push Mode

Too many notifications? Mute them, or dial the volume, for the current session:

```
/zeph-mute      — Disable all notifications for this project
/zeph-unmute    — Re-enable notifications
/zeph-status    — Check current state (mute + push mode)

/zeph-quiet     — Only high-priority pushes reach you
/zeph-loud      — Push on every turn
/zeph-normal    — Restore the default (push on real work, quiet on reads)
```

These create a temp file in `/tmp` — cleared on reboot. Mute silences both hooks
(auto-notifications) and CLI calls, and overrides any push mode.

## Autonomous Mode

Hand Claude a time budget and walk away:

```
/zeph-auto 2h fix the flaky tests
```

Claude loops explore → plan → implement → verify → commit until the budget runs
out, committing each verified unit on a work branch. Questions arrive on your
phone as `zeph_ask` buttons with a stated default — answer to steer, or ignore
and the run proceeds on the safe default after the timeout. Irreversible actions
(push, deploy, deletion) are never taken on a timeout; they wait for an explicit
tap. The run ends with a report of what was committed, what was skipped, and
which decisions were auto-defaulted — plus buttons to extend, review, or finish.

Duration accepts `2h`, `90m`, `1h30m`, or plain minutes (default `1h`).
`/zeph-status` shows the remaining budget mid-run.

## How It Works

### Session Flow

```
SessionStart hook
  ├─ Read ~/.zeph/config.json
  ├─ HOOK_ID present → inject ask/prompt/input rules
  └─ HOOK_ID absent  → inject notify-only rules

Working...
  │
  ├─ Choices + input needed → zeph_ask → button or text reply from mobile
  │   Button tap or custom input → Claude continues working
  │
  ├─ Complex question → AskUserQuestion → Ask hook auto-push
  │   "Can you see the Xcode logs?" → mobile notification → switch to terminal
  │
  ├─ Task complete → zeph_ask "Done. Next?" → user picks or types
  │   Response treated as direct instruction → execute → loop
  │   Select "Done" → session ends
  │
  └─ Fallback: if AI skipped zeph_ask → Stop hook sends notify
```

### Ask Loop

When `ZEPH_HOOK_ID` is configured, Claude uses `zeph_ask` as its final action after completing work. The user can respond from their phone:

- **Tap a button** — e.g. "Continue", "Review", "Done"
- **Type text** — e.g. "commit and push", "/ship", "fix the tests"

The response is executed immediately without confirmation, then Claude sends another `zeph_ask`. This loop continues until the user selects "Done". If the AI skips `zeph_ask`, the Stop hook sends a one-way notification as fallback.

### Notification Summary

| Event | Source | Reliability | Duplicates |
|-------|--------|-------------|------------|
| Task completed | Stop hook | 100% | No (skipped if AI sent zeph_ask) |
| Question asked | Ask hook | 100% | No |
| Decision/input needed | MCP zeph_ask | ~80% (depends on AI calling the tool) | No |
| Decision only | MCP zeph_prompt | ~80% (depends on AI calling the tool) | No |
| Text input only | MCP zeph_input | ~80% (depends on AI calling the tool) | No |
| Manual notification | MCP zeph_notify | On request | No |

### Three Layers

```
zeph-to/plugin (Claude Code plugin)
  ├─ hooks/zeph-setup.js    → SessionStart: inject rules
  ├─ hooks/zeph-stop.sh     → Stop: auto completion notification
  ├─ hooks/zeph-ask.sh      → PreToolUse: question notification
  ├─ .mcp.json              → MCP server registration
  └─ uses:
      ├─ @zeph-to/cli     → CLI (notify/list/dismiss/test/setup)
      └─ @zeph-to/mcp-server   → MCP tools (ask/prompt/input/clipboard/file...)
```

| Layer | Package | What it does | Reliability |
|-------|---------|-------------|-------------|
| **Hooks** | `@zeph-to/cli` (CLI) | Auto-fires on Claude events | 100% — no AI cooperation needed |
| **MCP Server** | `@zeph-to/mcp-server` | AI-callable tools (ask, prompt, input...) | Depends on AI following rules |
| **Plugin** | `zeph-to/plugin` | Bundles hooks + MCP + behavior rules | Installed once |

### Config Priority

```
--key flag  →  ZEPH_API_KEY env var  →  ~/.zeph/config.json
    (CLI)         (shell)               (zeph setup)
```

## Setup Details

### `zeph install` — One-Command Setup

```bash
npx @zeph-to/cli install
```

Detects installed agents, prompts for credentials, installs hooks + MCP + rules for each agent.

- **API Key** (required) — Open Zeph app → Settings → API Keys → Create new key
- **Hook ID** (optional, for `zeph_ask`/`zeph_prompt`/`zeph_input`) — Settings → Developer → Hooks → Create new hook

Saves to `~/.zeph/config.json`. All Zeph tools (CLI, MCP server, plugin hooks) read this file.

### Dependencies

- **Node.js** (required) — for MCP server and CLI
- **jq** (recommended) — for auto-notifications (Stop/Ask hooks). Without jq, hooks are disabled silently. A warning is shown at session start. Install: `brew install jq` (macOS) or `apt install jq` (Linux)

### Encryption

Push bodies are encrypted with AES-256-GCM. The wrapping key is derived via ECDH P-256 and synced across your own devices on first run so all your devices can read the same push. Toggle encryption in the Zeph app (Settings → Encryption); when disabled, the MCP server and CLI send plaintext.

**Threat model honesty:** keys are persisted on the Zeph backend to enable cross-device sync, so this is *device-shared* encryption — it protects push contents from passive network observers and from a leaked database snapshot taken without the key store, but it does **not** protect against the Zeph backend itself (it has the keys it serves to your devices). A true E2E mode (per-device keypairs, server stores only public keys, no key escrow) is on the roadmap. Until then, treat push bodies as sensitive-but-not-secret.

## Other Agents

### One-command setup (all agents)

```bash
npx @zeph-to/cli install
```

Detects every installed agent (Cursor, Windsurf, Gemini CLI, Codex CLI, Copilot CLI, Cline, Aider) and configures each one — MCP server, notification hooks, and the behavioral rule file in that agent's native always-on location. This is the single supported installer.

### Manual MCP setup (if you prefer)

**Gemini CLI:**

```bash
gemini mcp add zeph -- npx -y @zeph-to/mcp-server
```

**Cursor** — add to `~/.cursor/mcp.json`:

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

**Windsurf** — add to `~/.codeium/windsurf/mcp_config.json` (same format as Cursor).

## CLI Reference

```bash
npx @zeph-to/cli <command>
```

| Command | Description |
|---------|-------------|
| `install` | One-command setup for all agents |
| `notify --title "..." --body "..."` | Send a push |
| `list [--limit 5] [--type note]` | List recent pushes |
| `dismiss <push-id>` or `--all` | Dismiss pushes |
| `test` | Verify connection |

**Session commands (Claude Code only):**

| Command | Description |
|---------|-------------|
| `/zeph-auto [duration] [task]` | Time-boxed autonomous work session |
| `/zeph-mute` | Mute notifications for this project |
| `/zeph-unmute` | Re-enable notifications |
| `/zeph-status` | Check mute + push-mode status |
| `/zeph-quiet` | Push mode: only high-priority pushes |
| `/zeph-loud` | Push mode: push on every turn |
| `/zeph-normal` | Push mode: restore the default |

## Agent Support Matrix

| Agent | Auto Notify | MCP Tools | How |
|-------|:-----------:|:---------:|-----|
| Claude Code | Yes (Stop hook) | Yes | Plugin |
| Cursor | Yes (stop hook) | Yes | MCP + hook + rules |
| Windsurf | Yes (response hook) | Yes | MCP + hook |
| Gemini CLI | Yes (AfterAgent hook) | Yes | MCP + hook |
| Codex CLI | Yes (Stop hook) | — | Hook |
| Copilot CLI | Yes (sessionEnd hook) | — | Hook |
| Cline | LLM-based | — | Skills |
| Aider | LLM-based | — | Skills |

Run `npx @zeph-to/cli install` to configure every detected agent at once — MCP server, notification hooks, and behavioral rules.

## Uninstall

**All agents at once:**

```bash
npx @zeph-to/cli uninstall          # remove Zeph from every detected agent
npx @zeph-to/cli uninstall --dry-run  # preview first
npx @zeph-to/cli uninstall --purge    # also delete ~/.zeph/config.json
```

This reverses `zeph install` for every detected agent — removing MCP entries, hooks, and rule files. It only touches Zeph's own artifacts: shared rule files (Windsurf/Gemini/Codex) keep your content, with just the `<!-- ZEPH:START -->` / `<!-- ZEPH:END -->` block stripped. The Claude Code plugin is removed via `claude plugin uninstall zeph@zeph`.

**Claude Code only:**

```bash
claude plugin uninstall zeph@zeph
rm ~/.zeph/config.json
```

## License

Apache 2.0
