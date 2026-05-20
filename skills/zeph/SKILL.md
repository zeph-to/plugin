---
name: zeph
description: >
  AI agent notification skill via Zeph. Send push notifications, prompt for
  decisions, request text input across user devices. Use when completing long
  tasks, encountering errors, or needing user decisions while away from terminal.
  Triggers on task completion, build/test/deploy, error handling, user decisions.
metadata:
  author: zeph-to
  version: "0.4.0"
---

# Zeph — AI Agent Notification Skill

Use Zeph MCP tools to communicate with the user across devices (mobile, browser, desktop).

## Core Tools

### zeph_notify
Send a one-way push notification.

**When to use:**
- Mid-task error or blocker (use `priority: "high"`)
- Explicit progress milestone during long-running work
- Multi-session workflow: signal which session finished

**Do NOT use** to announce normal task completion — the Stop hook auto-pushes a completion notification, so calling `zeph_notify` at the end of a response duplicates it. End with `zeph_ask` (preferred) or just let the Stop hook fire.

**Format:** title under 50 chars, body under 200 chars. Include `url` for actionable links.

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

Use `zeph_ask` as your FINAL action after responses that involved file changes, builds, deploys, or destructive ops. This delivers the completion notification AND lets the user steer the next step from their phone. When you send `zeph_ask`, the Stop hook stays silent — no duplicate.

The response is a direct user instruction — execute it immediately without re-confirming via AskUserQuestion. The button label is the authorization for the specific action that label describes; it is NOT blanket authorization for unrelated destructive operations. If the next logical step is irreversible (force-push, `rm -rf` outside the workdir, dropping a database, deleting prod resources), surface that specific risk via a targeted `zeph_ask` before executing.

After executing the response, send the next `zeph_ask` to continue the loop. End the loop ONLY when the user picks an action id matching `done`/`stop`/`exit` (case-insensitive) or types free-text that clearly ends the session. Treat the timeout fallback the same as the user picking the fallback id — so always set `fallback` to a safe/inert id.

## AskUserQuestion vs zeph_ask

When `ZEPH_HOOK_ID` is set, prefer `zeph_ask` for short questions — the user is by design remote and the push notification is how they receive it. Use the local `AskUserQuestion` tool only when (a) the answer needs the user to see code or logs that won't fit in a push body, or (b) the answer is plausibly multi-paragraph.

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
