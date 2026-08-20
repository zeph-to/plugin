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
Send a file to the user's device — `filePath` for anything on disk (images, PDFs,
logs), or `content` + `fileName` for generated text.

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
- `/zeph-normal` — push on every turn that did real work (the heuristic)

**An install with no dial is quiet.** That is the shipped default, so assume it
unless `/zeph-status` says otherwise.

Each dial also takes `--global`, which sets the machine-wide default for every
project that has no dial of its own; a per-project dial always wins over it.

## When NOT to Use

- Short responses the user can see immediately in the terminal
- Read-only operations (file search, code analysis)
- Every single tool call — only notify on meaningful milestones
- Trivial confirmations that don't need user attention

## Automatic Behavior

The Stop hook owns the end-of-turn push, so you do not need to call `zeph_notify` for completion. How much it actually sends is the user's dial: an install with no dial is **quiet** (routine per-turn pushes suppressed), `/zeph-normal` pushes after every response that did meaningful work (≥2 tool calls), `/zeph-loud` pushes every turn.

**Push Signal — steer that auto-push (NORMAL mode).** Emit ONE HTML-comment marker in your response to override the default: `<!-- zeph: skip -->` suppress, `<!-- zeph: push -->` force a push the heuristic would skip (small but important action), `<!-- zeph: high -->` force a high-priority push. No marker → the heuristic (silent if <2 tools or all read-only Read/Grep/Glob, else push). On a stock quiet install the heuristic never runs and only `high` gets through — which makes `high` the way an important completion still reaches the user, and makes a `high` on routine work the exact noise quiet exists to remove. The hook strips the marker from the body; it is ignored on any turn that already sent `zeph_ask` (so it has no effect in REMOTE). See CORE_RULES.md → "Push Signal".

**Be proactive with `zeph_notify`.** Fire a blocker/error push (`priority: "high"`) the instant it happens mid-task — before continuing — not batched to the end. On a long turn the user gets nothing until it ends.

**The Ask Loop has two states, and they owe different things.** NORMAL means nobody has driven this session from a phone — the user is at the terminal. REMOTE means they are on their phone.

**In NORMAL you owe no `zeph_ask`.** Ask questions with `AskUserQuestion` or in prose (the Ask hook still pushes them to the user's device), and let the Stop hook's push be the completion signal. A `zeph_ask` here blocks the turn until someone answers on a device or it times out — that is the cost NORMAL exists to avoid. It stays available when you actively want a device answer; it is just not owed, and never a way to mark a turn finished.

**In REMOTE, `zeph_ask` ends EVERY response** — with `actions`: the next-step candidates as 2–4 buttons plus a Done-like `fallback`, `timeout` 300–600 s. Never end on a plain-text question, and route button-friendly questions through `zeph_ask` instead of `AskUserQuestion` (CORE_RULES Rules 3, 4, 10, 11 — all REMOTE-scoped).

**Chaining is governed by a sticky REMOTE mode** ("sticky" = once entered, it stays on until the user explicitly exits — it does not reset per response). The Ask Loop has two states — REMOTE and NORMAL — and you are told which one you are in: the mode is kept in a file, so it outlives context compaction.

- **REMOTE** is reported to you two ways: `zeph_ask` results carry `zephState` (`"REMOTE"`/`"NORMAL"`), and the prompt-submit hook adds a system note — the remote-origin note on the turn a phone message lands, then a note that the session has LEFT REMOTE on the first prompt the user types at the terminal. Once in REMOTE, end EVERY response with `zeph_ask` **with `actions`** — the next-step candidates as 2–4 buttons plus a Done-like fallback; a text-only ask is for inherently free-form answers, and on a "done — what next?" turn it leaves the phone with nothing to tap (CORE_RULES Rule 5). Independent of whether the work was substantial or routine.
- **NORMAL** is the initial state and the state you return to after an exit signal. In NORMAL, apply Rule 4 (substantial work → ask, routine work → skip).
- **Exit signals**: a Done-like action id (`done`/`stop`/`exit`, case-insensitive) and a timeout fallback that resolved to one are the server's to detect — it reports them as `zephState: "NORMAL"`. A prompt the user typed at the terminal is the hook's — they are back, so the loop ends and re-entry costs them one phone message. Free-text that clearly ends the session ("thanks, that's it" / "all good") is yours: flip to NORMAL, don't send `zeph_ask` on that response, and emit `<!-- zeph: exit -->` once so the hooks agree. In REMOTE, use `timeout` 300–600 s with a Done-like fallback so an unanswered ask exits the loop quietly instead of spamming an absent user.

The response to `zeph_ask` is a direct user instruction: execute it immediately without re-confirming. See the Ask Loop section in the Zeph skill for the full pattern.

**`AskUserQuestion` vs `zeph_ask`.** The picker is a local blocking UI the phone reaches only through the terminal mirror; `zeph_ask` needs no tmux, takes one tap, and returns an `actionId` (why the mirror loses on every axis: README → "AskUserQuestion vs zeph_ask"). **While in REMOTE**, a button-friendly question (a choice among a few options and/or a short reply) MUST go through `zeph_ask`, and the PreToolUse hook denies the picker to enforce it — including against a skill's own instruction. Fall through to the picker only when the answer needs code/logs too large for a push or is plausibly multi-paragraph, and `zeph_notify` that a terminal answer is required when you do. **In NORMAL the picker is the right tool** and the hook lets it through.

**The SessionStart hook injects only the branch that applies** (muted / no hook id / REMOTE / NORMAL, with the Push Signal block matching the project's dial). Claude Code persists any hook context over 10,000 chars to a file and shows you a 2 KB preview instead, so a single unconditional rule block would silently lose most of itself.

If no hook id is configured (`ZEPH_HOOK_ID` env, else `hookId` in `~/.zeph/config.json` — see docs/HOOKS-EXPLAINED.md), two-way tools (`zeph_ask`/`zeph_prompt`/`zeph_input`) are unavailable; only `zeph_notify` works.

<!-- SYNC: See docs/CORE_RULES.md for the single source of truth. This file provides a condensed quick-reference version for system memory. The SessionStart hook (zeph-setup.js) reads CORE_RULES.md at runtime. Before publishing, sync cli/src/templates.ts ZEPH_CORE with CORE_RULES.md. Run: npm run lint:rules-sync -->
