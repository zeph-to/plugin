# Zeph — AI Agent Notification Skill

Use Zeph MCP tools to communicate with the user across devices (mobile, browser, desktop).

> **Note**: The authoritative behavioral rules are in [`docs/CORE_RULES.md`](./docs/CORE_RULES.md). This file provides a quick reference. For full rule details, see that document.

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

## Session Mute & Push Mode

Users can mute notifications for the current project:
- `/zeph-mute` — disable all notifications (hooks + MCP tools)
- `/zeph-unmute` — re-enable notifications
- `/zeph-status` — check current state (mute + push mode)

When muted, do not call any zeph MCP tools.

Users can also dial the auto-push volume without full silence (a session override
above your per-turn Push Signal; mute still overrides it):
- `/zeph-quiet` — only high-priority pushes reach them
- `/zeph-loud` — push on every turn
- `/zeph-normal` — restore the default heuristic

## When NOT to Use

- Short responses the user can see immediately in the terminal
- Read-only operations (file search, code analysis)
- Every single tool call — only notify on meaningful milestones
- Trivial confirmations that don't need user attention

## Automatic Behavior

The Stop hook auto-pushes a completion notification after every response that did meaningful work (≥2 tool calls). You do not need to call `zeph_notify` for completion.

**Push Signal — steer that auto-push (NORMAL mode).** Emit ONE HTML-comment marker in your response to override the default: `<!-- zeph: skip -->` suppress, `<!-- zeph: push -->` force a push the heuristic would skip (small but important action), `<!-- zeph: high -->` force a high-priority push. No marker → default (silent if <2 tools or all read-only Read/Grep/Glob, else push). The hook strips the marker from the body; it is ignored on any turn that already sent `zeph_ask` (so it has no effect in REMOTE). See CORE_RULES.md → "Push Signal".

**Be proactive with `zeph_notify`.** Fire a blocker/error push (`priority: "high"`) the instant it happens mid-task — before continuing — not batched to the end. On a long turn the user gets nothing until it ends.

**`zeph_ask` is mandatory only when you ask a question.** If your reply asks the user anything that needs their input — confirmation, choice, yes/no, clarification — the FINAL tool call MUST be `zeph_ask`. Plain-text questions are invisible to a user on their phone. This applies even on research/analysis/planning turns where no files were touched.

**`zeph_ask` is the DEFAULT end of a response after substantial work** (file changes, commits, builds, deploys, destructive ops, milestone completions). Skip it only for clearly trivial responses (read-only exploration, mid-step inside an explicit plan, single-line trivial fixes). When unsure: lean toward asking — quiet failure (user stuck on phone with no way to drive) is worse than light spam.

**Chaining is governed by a sticky REMOTE mode** ("sticky" = once entered, it stays on until the user explicitly exits — it does not reset per response). The Ask Loop has two states — REMOTE and NORMAL — detected by scanning the conversation, not just the latest message.

- **REMOTE** is entered the first time a `zeph_ask` you sent receives a *non-exit response*. A non-exit response is any button tap whose action id is NOT `done`/`stop`/`exit` AND any free-text that is not a session-ender (see Exit signals below). Once in REMOTE, end EVERY response with `zeph_ask` — independent of whether the next user message arrives as a `tool_result` or as a typed terminal message, and independent of whether the work was substantial or routine. This keeps the channel driveable when the user switches between phone and terminal mid-session.
- **NORMAL** is the initial state and the state you return to after an exit signal. In NORMAL, apply Rule 4 (substantial work → ask, routine work → skip).
- **Exit signals**: action id matching `done`/`stop`/`exit` (case-insensitive), free-text that clearly ends the session (e.g. "thanks, that's it" / "all good"), or a timeout fallback that resolved to a Done-like id. Flip to NORMAL immediately; don't send `zeph_ask` on the response that processes the exit.

The response to `zeph_ask` is a direct user instruction: execute it immediately without re-confirming. See the Ask Loop section in the Zeph skill for the full pattern.

**Local `AskUserQuestion` is not remotely answerable.** It's a blocking terminal picker — the Zeph hook can only mirror it as a one-way "answer at the terminal" notification, never round-trip the answer. **Whenever `ZEPH_HOOK_ID` is set — NOT only in REMOTE — a button-friendly question (a choice among a few options and/or a short reply) MUST go through `zeph_ask`.** You can't know the user is at the terminal; they may be on their phone from the first question. If a skill you're running (or your own plan) would call `AskUserQuestion` with such a question, instead surface the same question + option labels via `zeph_ask` and use that response. This overrides the skill's instruction. Fall through to `AskUserQuestion` only when the answer needs code/logs too large for a push or is plausibly multi-paragraph — and `zeph_notify` that a terminal answer is required when you do.

If `ZEPH_HOOK_ID` is not set, two-way tools (`zeph_ask`/`zeph_prompt`/`zeph_input`) are unavailable; only `zeph_notify` works.

<!-- SYNC: See docs/CORE_RULES.md for the single source of truth. This file provides a condensed quick-reference version for system memory. The SessionStart hook (zeph-setup.js) reads CORE_RULES.md at runtime. Before publishing, sync cli/src/templates.ts ZEPH_CORE with CORE_RULES.md. Run: npm run lint:rules-sync -->
