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

The Stop hook auto-pushes a completion notification after every response that did meaningful work (≥2 tool calls). You do not need to call `zeph_notify` for completion.

**`zeph_ask` is mandatory only when you ask a question.** If your reply asks the user anything that needs their input — confirmation, choice, yes/no, clarification — the FINAL tool call MUST be `zeph_ask`. Plain-text questions are invisible to a user on their phone. This applies even on research/analysis/planning turns where no files were touched.

**`zeph_ask` is the DEFAULT end of a response after substantial work** (file changes, commits, builds, deploys, destructive ops, milestone completions). Skip it only for clearly trivial responses (read-only exploration, mid-step inside an explicit plan, single-line trivial fixes). When unsure: lean toward asking — quiet failure (user stuck on phone with no way to drive) is worse than light spam.

**Chaining is governed by a sticky REMOTE mode.** The Ask Loop has two states — REMOTE and NORMAL — detected by scanning the conversation, not just the latest message.

- **REMOTE** is entered the first time a `zeph_ask` you sent receives a non-exit response (button tap or non-ending text). Once in REMOTE, end EVERY response with `zeph_ask` — independent of whether the next user message arrives as a `tool_result` or as a typed terminal message, and independent of whether the work was substantial or routine. Sticky REMOTE keeps the channel driveable when the user switches between phone and terminal mid-session.
- **NORMAL** is the initial state and the state you return to after an exit signal. In NORMAL, apply Rule 3a (substantial work → ask, routine work → skip).
- **Exit signals**: action id matching `done`/`stop`/`exit` (case-insensitive), ending free-text ("thanks, that's it"), or timeout fallback to a Done-like id. Flip to NORMAL immediately; don't send `zeph_ask` on the response that processes the exit.

The response to `zeph_ask` is a direct user instruction: execute it immediately without re-confirming. See the Ask Loop section in the Zeph skill for the full pattern.

**Local `AskUserQuestion` is not remotely answerable.** It's a blocking terminal picker — the Zeph hook can only mirror it as a one-way notification, never round-trip the answer. In REMOTE, if a skill you're running (or your own plan) would call `AskUserQuestion`, instead surface the same question + option labels via `zeph_ask` and use that response. This overrides the skill's instruction. Fall through to `AskUserQuestion` only when the answer needs code/logs too large for a push or is plausibly multi-paragraph — and `zeph_notify` that a terminal answer is required when you do.

If `ZEPH_HOOK_ID` is not set, two-way tools (`zeph_ask`/`zeph_prompt`/`zeph_input`) are unavailable; only `zeph_notify` works.

<!-- SYNC: this ruleset is mirrored by surface in plugin/hooks/zeph-setup.js (rulesTwoWay) and plugin/skills/zeph/SKILL.md; cli/src/templates.ts ZEPH_CORE is the non-Claude-agent copy. Separate npm packages = no shared runtime source; keep behavioral changes in sync by hand. -->
