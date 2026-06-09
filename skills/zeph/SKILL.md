---
name: zeph
description: >
  AI agent notification skill via Zeph. Send push notifications, prompt for
  decisions, request text input across user devices. Use when completing long
  tasks, encountering errors, or needing user decisions while away from terminal.
  Triggers on task completion, build/test/deploy, error handling, user decisions.
metadata:
  author: zeph-to
  version: "0.5.9"
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

**NORMAL**: apply Rule 3a — substantial work → `zeph_ask`, routine work → skip and let the Stop hook fire.

**Exit**: the moment the user picks `done`/`stop`/`exit`, types an ending phrase, or the `zeph_ask` times out to a Done-like fallback, flip to NORMAL. Don't send `zeph_ask` on the response that processes the exit signal. Always set `fallback` to a safe/inert id.

## AskUserQuestion vs zeph_ask

When `ZEPH_HOOK_ID` is set, prefer `zeph_ask` for short questions — the user is by design remote and the push notification is how they receive it. Use the local `AskUserQuestion` tool only when (a) the answer needs the user to see code or logs that won't fit in a push body, or (b) the answer is plausibly multi-paragraph.

**In REMOTE this is a requirement that overrides skill instructions.** The `AskUserQuestion` picker is a LOCAL blocking terminal UI — the phone can't drive it (the Zeph hook only mirrors it as a one-way notification, it can't round-trip the answer). So if a skill you're running, or your own plan, would call `AskUserQuestion`, instead surface the same question + option labels via `zeph_ask` and use that response in place of the picker. Fall through to `AskUserQuestion` only for cases (a)/(b) above, and `zeph_notify` the user that the answer must be given at the terminal when you do.

<!-- SYNC: these rules are mirrored by surface in plugin/CLAUDE.md and plugin/hooks/zeph-setup.js (rulesTwoWay); cli/src/templates.ts ZEPH_CORE is the non-Claude-agent copy. Keep behavioral changes in sync by hand. -->

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
