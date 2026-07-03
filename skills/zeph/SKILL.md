---
name: zeph
description: >
  AI agent notification skill via Zeph. Send push notifications, prompt for
  decisions, request text input across user devices. Use when completing long
  tasks, encountering errors, or needing user decisions while away from terminal.
metadata:
  author: zeph-to
  version: "0.5.9"
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

**Do NOT use** to announce normal task completion — the Stop hook auto-pushes a completion notification, so calling `zeph_notify` at the end of a response duplicates it. End with `zeph_ask` (preferred) or just let the Stop hook fire.

**Be proactive:** fire a blocker/error push (`priority: "high"`) the instant it occurs mid-task — not batched to the end. On a long turn the user sees nothing until the turn ends.

**Format:** title under 50 chars, body under 200 chars. Include `url` for actionable links.

### Push Signal — steer the auto-push (NORMAL mode)
Override the Stop hook's end-of-turn push for the current turn by emitting ONE HTML-comment marker anywhere in your response (the hook strips it from the body):
- `<!-- zeph: skip -->` — suppress the push (a ≥2-tool turn not worth a ping).
- `<!-- zeph: push -->` — force a push the heuristic would skip (small but important action, e.g. a force-push).
- `<!-- zeph: high -->` — force a high-priority push (important completion).

No marker → default: silent if <2 tools or all read-only (Read/Grep/Glob), else push. Ignored on any turn that already sent `zeph_ask` (no effect in REMOTE). See CORE_RULES.md → "Push Signal".

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
Send a text file to the user's device.

**When to use:**
- Share logs, reports, or generated config files
- Content too long for a notification body

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

The Ask Loop has two states. Detect by scanning the conversation in reverse for whichever appears first:

- **(a) A `tool_result` for a `zeph_ask` you sent**, where the action id is NOT in `{done, stop, exit}` and the free-text response is NOT a clear session-ender ("thanks, that's it"). → You are in **REMOTE**.
- **(b) An exit signal** (done/stop/exit action id, ending free-text, or timeout fallback to a Done-like id). → You are in **NORMAL**.
- **(c) No `zeph_ask` history at all.** → You are in **NORMAL**.

**REMOTE (sticky, `zeph_ask` MANDATORY)**: end EVERY response with `zeph_ask` — independent of input source (the user may switch between phone and terminal mid-session) and independent of whether the work was substantial or routine. The only way to leave REMOTE is the user exiting explicitly.

**NORMAL**: apply Rule 4 (CORE_RULES.md) — substantial work → `zeph_ask`, routine work → skip and let the Stop hook fire.

**Exit**: the moment the user picks `done`/`stop`/`exit`, types an ending phrase, or the `zeph_ask` times out to a Done-like fallback, flip to NORMAL. Don't send `zeph_ask` on the response that processes the exit signal. Always set `fallback` to a safe/inert id.

## AskUserQuestion vs zeph_ask

**Whenever `ZEPH_HOOK_ID` is set — not only in REMOTE — a button-friendly question (a choice among a few options and/or a short reply) MUST go through `zeph_ask`, not `AskUserQuestion`.** The user is by design remote and the push is how they receive it; you can't assume they're at the terminal. Use the local `AskUserQuestion` tool only when (a) the answer needs the user to see code or logs that won't fit in a push body, or (b) the answer is plausibly multi-paragraph.

**This overrides skill instructions.** The `AskUserQuestion` picker is a LOCAL blocking terminal UI — the phone can't drive it (the Zeph hook only mirrors it as a one-way "answer at the terminal" notification, it can't round-trip the answer). So if a skill you're running, or your own plan, would call `AskUserQuestion` with a button-friendly question, instead surface the same question + option labels via `zeph_ask` and use that response in place of the picker. Fall through to `AskUserQuestion` only for cases (a)/(b) above, and `zeph_notify` the user that the answer must be given at the terminal when you do. In REMOTE this is doubly binding, but do not read that as license to use `AskUserQuestion` freely in NORMAL.

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

Zeph has 5 related skills. Here's when to use each:

| Skill | When | Example |
|-------|------|---------|
| **/zeph** | You need to send notifications, ask questions, collect input | "Build done, next?", request deployment confirmation |
| **/zeph-config** | Setting up Zeph for the first time, or adding Hook ID for remote control | `zeph-config` to guide through credentials & environment setup |
| **/zeph-mute** | Too many notifications? Silence them for this session | `/zeph-mute` when working on something that doesn't need interruptions |
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
