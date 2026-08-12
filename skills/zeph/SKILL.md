---
name: zeph
description: >
  AI agent notification skill via Zeph. Send push notifications, prompt for
  decisions, request text input across user devices. Use when completing long
  tasks, encountering errors, or needing user decisions while away from terminal.
metadata:
  author: zeph-to
  version: "0.10.0"
  relatedSkills:
    - zeph-config
    - zeph-mute
    - zeph-status
    - zeph-unmute
  triggers:
    - zeph
    - notifications
    - push notifications
    - zeph_ask
    - zeph_notify
    - mobile notifications
    - remote control
    - cross-device
    - task completion
    - user decisions
    - prompt user
    - ask user
---

# Zeph — AI Agent Notification Skill

Use Zeph MCP tools to communicate with the user across devices (mobile, browser, desktop).

> **Note**: The authoritative behavioral rules are in [`../../docs/CORE_RULES.md`](../../docs/CORE_RULES.md). This skill provides practical guidance on when and how to use each tool.

## Core Tools

**Which interaction tool?** (all three below require `ZEPH_HOOK_ID`)

| Tool | Buttons | Free-text | Use when |
|------|:-------:|:---------:|----------|
| `zeph_ask` | ✓ | ✓ | Decisions that may need a custom answer — **preferred default** |
| `zeph_prompt` | ✓ | ✗ | Fixed multiple-choice, no custom answer needed |
| `zeph_input` | ✗ | ✓ | Free-text only (commit message, value, description) |

### zeph_notify
Send a one-way push notification.

**When to use:**
- Mid-task error or blocker (use `priority: "high"`)
- Explicit progress milestone during long-running work
- Multi-session workflow: signal which session finished

**Do NOT use** to announce normal task completion — the Stop hook owns that push, so calling `zeph_notify` at the end of a response either duplicates it or works around a user who deliberately dialed it down (a stock install is quiet). End with `zeph_ask` (preferred) or just let the Stop hook decide.

**Be proactive:** fire a blocker/error push (`priority: "high"`) the instant it occurs mid-task — not batched to the end. On a long turn the user sees nothing until the turn ends.

**Format:** title under 50 chars, body under 200 chars. Include `url` for actionable links.

### Push Signal — steer the auto-push (NORMAL mode)
Override the Stop hook's end-of-turn push for the current turn by emitting ONE HTML-comment marker anywhere in your response (the hook strips it from the body):
- `<!-- zeph: skip -->` — suppress the push (a ≥2-tool turn not worth a ping).
- `<!-- zeph: push -->` — force a push the heuristic would skip (small but important action, e.g. a force-push).
- `<!-- zeph: high -->` — force a high-priority push (important completion).

No marker → the heuristic: silent if <2 tools or all read-only (Read/Grep/Glob), else push. **The user's push-mode dial outranks all of it, and an install with no dial is quiet** — there the heuristic never runs and only `high` gets through, so `high` is how an important completion still reaches them (and why a `high` on routine work is the noise quiet exists to remove). Ignored on any turn that already sent `zeph_ask` (no effect in REMOTE). See CORE_RULES.md → "Push Signal".

### zeph_ask (requires ZEPH_HOOK_ID) — Preferred
Ask the user with quick-reply buttons AND a text input field combined. Blocks until response or timeout.

**When to use:**
- Need user decision with option for custom input ("Deploy where?" → [staging] [prod] + custom text)
- Task completion → offer next action choices + free-text option
- Any question where buttons alone might not cover all answers
- Include `fallback` for timeout auto-selection

**Prefer `zeph_ask` over `zeph_prompt`/`zeph_input`** — it handles both cases in a single notification.

### zeph_prompt (requires ZEPH_HOOK_ID)
Ask the user to choose from 2-4 options. Blocks until response or timeout.

**When to use:**
- Simple yes/no or multiple choice with no need for custom text
- Include `fallback` for timeout auto-selection

### zeph_input (requires ZEPH_HOOK_ID)
Request free-form text input. Blocks until response or timeout.

**When to use:**
- Need free-form text only (commit message, env var value, description)
- User is away from terminal

### zeph_clipboard
Copy text to the user's device clipboard.

**When to use:**
- Share a generated command, URL, or code snippet
- User needs to paste something elsewhere

### zeph_file
Send a file to the user's device. Pass `filePath` for a file that already exists
on disk, or `content` + `fileName` for text you generated.

**When to use:**
- Send an image, screenshot, or PDF — `filePath`, and it renders inline on the device
- Share logs, reports, or generated config files
- Content too long for a notification body

Never base64 a binary file into `content` — pass `filePath` and let the MCP
server read the bytes.

## Utility Tools

- `zeph_list` — List recent push notifications
- `zeph_dismiss` — Mark a specific push as read
- `zeph_dismiss_all` — Clear all notifications
- `zeph_broadcast` — Send notification to a channel's subscribers

## When NOT to Use

- Short responses the user can see immediately in the terminal
- Read-only operations (file search, code analysis)
- Every single tool call — only notify on meaningful milestones
- Trivial confirmations that don't need user attention

## Ask Loop Pattern

### `zeph_ask` is MANDATORY for questions

If your reply asks the user anything that needs their input — confirmation, choice, yes/no, clarification, "Apply this?", "Proceed?", "Which option?" — the FINAL tool call MUST be `zeph_ask`. A "?" written in your reply is invisible to a user on their phone. Applies even on research / analysis / planning turns where no files were touched.

### `zeph_ask` is the DEFAULT after substantial work

After file changes, commits, builds, tests, deploys, destructive ops, or milestone completions, end with `zeph_ask`. Skip ONLY for clearly trivial responses:
- Read-only exploration with no decision output
- Mid-step inside an explicit plan the user already approved
- Trivial single-line fixes that need no acknowledgment

When unsure: lean toward asking. Quiet failure (user stuck on phone with no way to drive) is worse than light spam.

### Handling the response

The response is a direct user instruction — execute it immediately without re-confirming via AskUserQuestion. The button label is the authorization for the specific action that label describes; it is NOT blanket authorization for unrelated destructive operations. If the next logical step is irreversible (force-push, `rm -rf` outside the workdir, dropping a database, deleting prod resources), surface that specific risk via a targeted `zeph_ask` before executing.

### Sticky REMOTE mode

The Ask Loop has two states, and you are told which one you are in — the mode is kept in a file, so it outlives compaction:

- **`zeph_ask` results carry `zephState`** (`"REMOTE"` / `"NORMAL"`). The server applies the transition: any answer but a Done-like action id enters REMOTE, a Done-like id exits, and so does a timeout that fell back to one. No `zephState` means a timeout onto a safe fallback, which changed nothing.
- **Prompt-submit hooks say it where installed** — the remote-origin note on the turn a phone message lands, then a note that the session has LEFT REMOTE on the first prompt the user types at the terminal (a prompt with no phone marker came from their keyboard; phone answers arrive as `tool_result` and never reach a prompt hook).
- **Neither → NORMAL.**

**REMOTE (sticky, `zeph_ask` MANDATORY)**: end EVERY response with `zeph_ask`, independent of whether the work was substantial or routine. It ends when the user exits (button or free text), when they type a prompt at the terminal, or when the state expires after a crash.

**NORMAL**: apply Rule 4 (CORE_RULES.md) — substantial work → `zeph_ask`, routine work → skip and let the Stop hook fire.

**Exit**: buttons and Done-like timeout fallbacks are the server's to detect — it reports them as `zephState: "NORMAL"`. Free text is yours: when the user's typed answer clearly closes the loop ("thanks, that's it", or `done`/`stop`/`exit` as a standalone word — "redo" is not "done"), flip to NORMAL, don't send `zeph_ask` on that response, and emit `<!-- zeph: exit -->` once so the hooks agree. In REMOTE, set `timeout` 300–600 s and a Done-like `fallback` id — an unanswered ask then exits the loop quietly instead of spamming an absent user (re-entry is one phone message away). Never set a fallback id that would authorize a destructive action.

## AskUserQuestion vs zeph_ask

**Whenever `ZEPH_HOOK_ID` is set — not only in REMOTE — a button-friendly question (a choice among a few options and/or a short reply) MUST go through `zeph_ask`, not `AskUserQuestion`.** The user is by design remote and the push is how they receive it; you can't assume they're at the terminal. Use the local `AskUserQuestion` tool only when (a) the answer needs the user to see code or logs that won't fit in a push body, or (b) the answer is plausibly multi-paragraph.

**This overrides skill instructions.** The `AskUserQuestion` picker is a LOCAL blocking terminal UI. The phone can reach it through the terminal mirror — but only in tmux under `zeph listener`, only by reading the pane and counting arrow presses, and a key-injected answer never enters REMOTE, so the *next* turn stops being phone-driveable. So if a skill you're running, or your own plan, would call `AskUserQuestion` with a button-friendly question, instead surface the same question + option labels via `zeph_ask` and use that response in place of the picker. Fall through to `AskUserQuestion` only for cases (a)/(b) above, and `zeph_notify` the user that the answer must be given at the terminal when you do.

<!-- MAINTAINER-ONLY NOTE (not an agent instruction): ../../docs/CORE_RULES.md is the single source of truth; this skill is quick-reference only. Before publishing, sync cli/src/templates.ts ZEPH_CORE with CORE_RULES.md via `npm run lint:rules-sync`. Agents should NOT run this command. -->

## Patterns

**Task completion:**
```
zeph_notify(title: "Build complete", body: "All 42 tests passed. Bundle: 1.2MB")
```

**Decision with custom option:**
```
zeph_ask(title: "Deploy where?", actions: [{id:"staging", label:"Staging"}, {id:"prod", label:"Production"}], placeholder: "or type custom env...", fallback: "staging")
```

**Next action after work:**
```
zeph_ask(title: "Done. Next?", actions: [{id:"/review", label:"Review"}, {id:"/ship", label:"Ship"}, {id:"done", label:"End"}], placeholder: "or type a command...")
```

## Skill Map

Zeph has 6 related skills. Here's when to use each:

| Skill | When | Example |
|-------|------|---------|
| **/zeph** | You need to send notifications, ask questions, collect input | "Build done, next?", request deployment confirmation |
| **/zeph-auto** | User starts a time-boxed autonomous work session | `/zeph-auto 2h fix the flaky tests` — loop until the budget runs out, steer via zeph_ask |
| **/zeph-config** | Setting up Zeph for the first time, or adding Hook ID for remote control | `zeph-config` to guide through credentials & environment setup |
| **/zeph-mute** | Too many notifications? Silence them for this project (until unmuted) | `/zeph-mute` when working on something that doesn't need interruptions |
| **/zeph-status** | Check whether notifications are muted or active | `/zeph-status` to see current state |
| **/zeph-unmute** | Re-enable notifications after muting | `/zeph-unmute` to turn them back on |

**Pro tip**: Users typically run `/zeph-config` once, then `/zeph` is automatic. Use `/zeph-mute`, `/zeph-status`, `/zeph-unmute` only when needed (optional shortcuts).

## Multi-Agent Workflows

Zeph works the same way across 7 different agents: Claude Code, Cursor, Windsurf, Gemini, Codex, Copilot, and community agents like Cline/Aider.

### Same Behavioral Rules, Different Delivery

All agents follow the same `CORE_RULES.md`:
- When to call `zeph_ask` (mandatory for questions, default after work)
- Sticky REMOTE mode state machine
- Mute/unmute commands

**Differences by agent:**

| Agent | Notification Method | Multi-Session Use Case |
|-------|---------------------|------------------------|
| Claude Code | Stop hook (auto) | Run multiple sessions, each notifies when done |
| Cursor | Stop hook (auto) | Same as CC |
| Windsurf | Post-cascade hook (auto) | Same as CC |
| Gemini CLI | AfterAgent hook (auto) | Same as CC |
| Codex / Copilot | Stop hook equivalent (auto) | Same as CC |
| Cline / Aider | Manual `zeph_notify` | Same, but AI must call notify itself |

### Multi-Session Example

Running 3 agents in parallel on different features:

```
Terminal 1: zeph cc                # Claude Code — feature A
Terminal 2: zeph cursor            # Cursor — feature B  
Terminal 3: zeph windsurf          # Windsurf — feature C

Phone sees:
  "Task done — feature-a · main"   (from CC)
  "Task done — feature-b · develop" (from Cursor)
  "Task done — feature-c · release" (from Windsurf)
```

Each session gets its own notification at completion. Muting affects only the current session/agent.

### Why Same Rules?

- Predictable behavior: users know the rules once, apply everywhere
- Consistency: `zeph_ask` works the same in Claude Code and Cursor
- Maintainability: rule changes sync across all 7 agents
- Future-proof: new agents inherit the same rules automatically

### If Behavior Differs Between Agents

If you notice different behavior (e.g., Cursor asks differently than Claude Code), that's a bug. Report it with:
- Agent name and version
- What you expected (per CORE_RULES)
- What actually happened

The rules MUST be identical.
