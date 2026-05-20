# Zeph — AI Agent Notification Skill

Use Zeph MCP tools to communicate with the user across devices (mobile, browser, desktop).

## Core Tools

### zeph_notify
Send a one-way push notification.

**When to use:**
- Mid-task error or blocker (use `priority: "high"`)
- Explicit progress milestone during a long-running operation
- Multi-session workflow: signal which session finished

**Do NOT use** to announce normal task completion — the Stop hook handles that automatically, so a manual `zeph_notify` at the end produces a duplicate push.

**Format:** title under 50 chars, body under 200 chars. Include `url` for actionable links.

### zeph_ask (requires ZEPH_HOOK_ID) — Preferred
Ask the user with quick-reply buttons AND a text input field combined. Blocks until response or timeout.

**When to use:**
- Need user decision with option for custom input
- Task completion → offer next action choices + free-text option
- Prefer over `zeph_prompt`/`zeph_input` — handles both in one notification

### zeph_prompt (requires ZEPH_HOOK_ID)
Ask the user to choose from 2-4 options. Blocks until response or timeout.

### zeph_input (requires ZEPH_HOOK_ID)
Request free-form text input. Blocks until response or timeout.

### zeph_clipboard
Copy text to the user's device clipboard.

### zeph_file
Send a text file to the user's device.

## Utility Tools

- `zeph_list` — List recent push notifications
- `zeph_dismiss` — Mark a specific push as read
- `zeph_dismiss_all` — Clear all notifications
- `zeph_broadcast` — Send notification to a channel's subscribers

## Session Mute

Users can mute notifications for the current project:
- `/zeph-mute` — disable all notifications (hooks + MCP tools)
- `/zeph-unmute` — re-enable notifications
- `/zeph-status` — check current state

When muted, do not call any zeph MCP tools.

## When NOT to Use

- Short responses the user can see immediately in the terminal
- Read-only operations (file search, code analysis)
- Every single tool call — only notify on meaningful milestones
- Trivial confirmations that don't need user attention

## Automatic Behavior

The Stop hook already sends a push notification after every response that did meaningful work (≥2 tool calls), so you do not need to call `zeph_notify` to announce completion.

After completing work that involved file changes, builds, deploys, or destructive ops, end with `zeph_ask` offering next actions — this replaces the auto Stop push (no duplicate) and gives the user a way to drive the next step from their phone. Include a `fallback` action id that is safe/inert. The response to `zeph_ask` is a direct user instruction: execute it immediately without re-confirming. See the Ask Loop section in the Zeph skill for the full pattern.

If `ZEPH_HOOK_ID` is not set, two-way tools (`zeph_ask`/`zeph_prompt`/`zeph_input`) are unavailable; only `zeph_notify` works.
