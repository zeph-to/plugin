# Zeph Core Behavioral Rules

**SOURCE OF TRUTH** for all Zeph agents (Claude Code, Cursor, Windsurf, Gemini, Codex, Copilot, etc.)

This file is read by:
- `plugin/hooks/zeph-setup.js` — SessionStart hook (Claude Code)
- `plugin/CLAUDE.md` — system memory (Claude Code)
- `plugin/skills/zeph/SKILL.md` — skill documentation
- `cli/src/templates.ts` → `ZEPH_CORE` — shared across 7 agents

**Do NOT edit multiple copies — edit here and sync via build script.**

---

## Two-Way Mode (with ZEPH_HOOK_ID)

Zeph lets the user drive this session from their phone. You are talking to a user who may not be at the terminal. Buttons sent via `zeph_ask` are how they steer you.

### Notification discipline

**Why this matters:** The user gets a notification for every meaningful response. Manual notifications at the end create duplicates and spam.

1. A Stop hook already sends an automatic push on every response that did real work (≥2 tool calls). Do NOT call `zeph_notify` just to say "done" — it duplicates the auto-push.
   - ❌ Wrong: `zeph_notify(title: "Done")` at end of response
   - ✅ Correct: Let the Stop hook fire automatically (one push)

2. Use `zeph_notify` only for: mid-task errors that block progress, explicit long-running progress milestones, or multi-session signals ("session A finished, session B still building"). Set `priority: "high"` for blockers.
   - ✅ Example 1: Mid-task blocker → `zeph_notify(title: "Build failed", priority: "high")`
   - ✅ Example 2: Long-running operation checkpoint → `zeph_notify(title: "Tests 50% done", body: "Running for 5 min...")`
   - ✅ Example 3: Multi-session signal → `zeph_notify(title: "Session A done, Session B still building")`

   **Be proactive — fire it the instant it happens, mid-task, before you continue.** On a long turn the user gets nothing until the turn ends; a blocker they learn about ten minutes late is one they couldn't act on. The moment a build breaks, a test suite goes red, or you hit something that stops progress, send the `priority: "high"` push *then* — do not batch it to the end of the response.

### Push Signal — steer the end-of-turn auto-push (Stop hook)

The Stop hook decides the automatic end-of-turn push by tool volume, which
misfires both ways (spams on read-only exploration, stays silent on a small but
important action). Override it for the current turn by emitting ONE marker
anywhere in your response — an HTML comment, invisible in the terminal, which the
hook strips from the push body before sending. Emit at most one; omit it to accept
the default.

- `<!-- zeph: skip -->` — suppress the push. Use when a ≥2-tool turn was not worth a ping (read several files, changed nothing the user is waiting on).
- `<!-- zeph: push -->` — force a push the heuristic would otherwise skip. Use for a small but important action (a single force-push, a one-line deploy trigger).
- `<!-- zeph: high -->` — force a push AND mark it high priority. Use for an important completion the user should see prominently.

No marker → the default applies: a turn that ran <2 tools, or whose tools are all read-only (Read/Grep/Glob), stays silent; otherwise it pushes. The marker is lowercase and exact. It only tunes the Stop-hook push and is **ignored on any turn that already sent `zeph_ask`** (that turn already notified) — so in REMOTE, where every response ends with `zeph_ask`, the Push Signal has no effect; it is a NORMAL-mode tool.

### Common Mistakes to Avoid

**Mistake 1: Manual completion notifications**
```javascript
// ❌ WRONG — duplicates Stop hook
zeph_notify(title: "Build done")  // at end of response

// ✅ CORRECT — let Stop hook fire
// (no zeph_notify needed)
```

**Mistake 2: Plain-text questions**
```
// ❌ WRONG — invisible to remote user
"Tests look good. Deploy?"

// ✅ CORRECT
zeph_ask({
  title: "Deploy to production?",
  actions: [{ id: "yes", label: "Deploy" }, { id: "no", label: "Cancel" }],
  fallback: "no"
})
```

**Mistake 3: Using AskUserQuestion in REMOTE**
```javascript
// ❌ WRONG in REMOTE — phone can't drive terminal UI
AskUserQuestion({ prompt: "Which option?" })

// ✅ CORRECT in REMOTE
zeph_ask({
  title: "Which option?",
  actions: [
    { id: "a", label: "Option A" },
    { id: "b", label: "Option B" }
  ]
})
```

### When zeph_ask is MANDATORY

3. **NEVER end a response with a plain-text question.** If your reply asks the user anything that needs their input — confirmation, choice, yes/no, clarification, "Apply this?", "Proceed?", "Which option?" — the FINAL tool call MUST be `zeph_ask`. A "?" written in your reply is invisible to a user on their phone. This applies even on research / analysis / planning turns where no files were touched.

   Anti-pattern (wrong):
   ```
   "...build/commit on hold. Apply A?"
   ```
   Correct:
   ```
   zeph_ask({
     title: "Apply solution A?",
     body: "<short context comparing options>",
     actions: [
       { id: "apply_a", label: "Apply A" },
       { id: "apply_b", label: "Apply B" },
       { id: "cancel",  label: "Cancel" }
     ],
     placeholder: "or describe a different approach...",
     fallback: "cancel"
   })
   ```

### When zeph_ask is the DEFAULT (substantial work)

4. After substantial work, `zeph_ask` is the DEFAULT end of the response — not optional. "Substantial" means: file changes, commits, builds, tests, deploys, destructive ops, or milestone completions. When unsure, treat the work as substantial — do not try to guess what the user would find "reasonable" to confirm.

    SKIP `zeph_ask` only when the response is clearly trivial:
    - Read-only exploration ("let me check this file") with no decision output.
    - Mid-step inside a clearly-defined plan the user already approved ("step 3 of 5, no decisions involved here").
    - Trivial change (typo fix, single-line tweak) that needs no ack.

    When unsure: LEAN TOWARD ASKING. Quiet failure (no ask, user stuck on phone with no way to drive) is worse than light spam.

5. Prefer `zeph_ask` over `zeph_prompt`/`zeph_input` — it combines buttons and free-text in one push. Always include a `fallback` action id; the fallback must be safe/inert (`done`, `wait`, `review`), never destructive.

6. Example `zeph_ask` shape — use sparingly per Rule 4 (only at natural pause points; NOT after every response — see Rule 9):
   ```
   zeph_ask({
     title: "Done. Next?",
     actions: [
       { id: "continue", label: "Continue" },
       { id: "review",   label: "Review"   },
       { id: "done",     label: "Done"     }
     ],
     placeholder: "or type a command...",
     fallback: "done"
   })
   ```

### Handling the response

7. A `zeph_ask` response IS a direct user instruction. Execute it immediately — do NOT re-ask via AskUserQuestion to confirm. The button label is the authorization for the specific action that label describes.

8. Important caveat: a generic button like "Continue" authorizes the next logical step, NOT arbitrary destruction. If the next logical step would destroy user code, data, or infrastructure (e.g., force-push to a shared branch, `rm -rf` outside the workdir, dropping a database, deleting prod resources), surface that specific risk via a targeted `zeph_ask` before executing — e.g., title "About to force-push main — proceed?", actions `[ok, cancel]`, fallback `cancel`.

### Sticky REMOTE mode (Rule 9)

**The Ask Loop has two states: REMOTE and NORMAL.** You detect the current state by scanning the conversation, not just the most recent message.

**State in one line:** you are in REMOTE if the most recent `zeph_ask` response was a non-exit reply; otherwise (no `zeph_ask` history, or the last one was an exit signal) you are in NORMAL. REMOTE is sticky — every response ends with `zeph_ask` until the user exits.

#### State Detection

Scan the conversation in reverse, looking for whichever appears first (most recent):

- **(a)** A `tool_result` for a `zeph_ask` you sent where the action id is NOT in `{done, stop, exit}` (case-insensitive) AND the free-text response is NOT a session-ender. A session-ender is free-text that either contains `done`/`stop`/`exit` as a standalone word, or is an obvious wrap-up like "thanks, that's it" / "all good" — judge by whether the user is clearly closing the loop, not by partial substring matches (e.g. "redo" does not count as "done").
- **(b)** An exit signal: action id in `{done, stop, exit}`, ending free-text, or a timeout fallback that resolved to a Done-like fallback id.
- **(c)** No `zeph_ask` history at all.

If the first hit is **(a)** → you are in **REMOTE**.
If the first hit is **(b)** or **(c)** → you are in **NORMAL**.

#### Behavior in REMOTE (sticky, zeph_ask MANDATORY)

End EVERY response with `zeph_ask`. This is non-negotiable while in REMOTE — independent of:
- Whether the next user message arrived as a `tool_result` or as a typed terminal message. The user may switch devices mid-session; sticky REMOTE keeps the channel driveable from either side.
- Whether the work was substantial or routine.

The only way to leave REMOTE is the user signalling exit (per the **(b)** list above).

#### Behavior in NORMAL (apply Rule 4)

- Substantial work → end with `zeph_ask`.
- Routine work → skip `zeph_ask`, let the Stop hook fire.
- Rule 3 (questions → zeph_ask) is still mandatory regardless.

#### Exiting REMOTE

The moment the user picks an action id matching `done`/`stop`/`exit` (case-insensitive), types free-text that clearly ends the session, or the zeph_ask times out and falls back to a Done-like id, you flip to NORMAL. Don't send `zeph_ask` on the response that processes the exit signal.

### When to use AskUserQuestion vs zeph_ask

10. Prefer `zeph_ask` for short remote-friendly questions. Use the local AskUserQuestion tool only when (a) the answer needs the user to see code or logs that won't fit in a push body, or (b) the answer is plausibly multi-paragraph. `zeph_ask` should be the default while a hookId is set.

11. **In REMOTE this is a requirement, not a preference — and it overrides any skill instruction.** The `AskUserQuestion` picker is a LOCAL blocking terminal UI; the phone cannot drive it (the Zeph hook can only mirror it as a one-way notification, never round-trip the answer). So if a skill you are running — or your own plan — would call `AskUserQuestion`, instead surface the SAME question and option labels via `zeph_ask` and use that response in place of the picker. Fall through to `AskUserQuestion` only for the (a)/(b) cases above; when you do, `zeph_notify` the user that the answer must be given at the terminal.

### Mute / persistence

12. If the user ran `/zeph-mute` for this project, the Stop and Ask hooks stay silent (driven by a tmp marker file). MCP tools still work but don't call them unless the user explicitly asks. `/zeph-unmute` lifts it.

13. These rules persist for the entire session. They remain active after context compaction — do not "forget" them after many turns.

---

## One-Way Mode (without ZEPH_HOOK_ID)

`ZEPH_HOOK_ID` is not set, so two-way (`zeph_ask` / `zeph_prompt` / `zeph_input`) is unavailable. Only `zeph_notify` works.

1. A Stop hook auto-notifies after responses with real work (≥2 tool calls). Do NOT call `zeph_notify` just to say "done" — it duplicates the auto-push.

2. Use `zeph_notify` only for: mid-task errors that block progress, explicit long-running progress milestones, or multi-session signals. Set `priority: "high"` for blockers. **Be proactive** — fire a blocker/error push the instant it happens, mid-task, not batched to the end of the response.

2b. **Push Signal** — steer the Stop hook's auto-push by emitting ONE marker in your response (HTML comment; the hook strips it from the body): `<!-- zeph: skip -->` suppress, `<!-- zeph: push -->` force a push the heuristic would skip, `<!-- zeph: high -->` force a high-priority push. No marker → default (silent if <2 tools or all read-only, else push). Lowercase, exact.

3. To enable remote control (buttons + free-text from the phone), the user should set `ZEPH_HOOK_ID` via `npx @zeph-to/cli setup`. You may mention this once if relevant — don't repeat it.

4. These rules persist for the entire session, including after context compaction.

---

## Environment Notes

- If `jq` is not installed on the user's machine, the Stop and Ask shell hooks exit early without sending pushes. This should be mentioned once: install with `brew install jq` (macOS) or `apt install jq` (Linux).

---

## Quick Reference

| Rule | When | Action |
|------|------|--------|
| **1-2: Notify** | End of response with real work | Skip `zeph_notify` (auto-push) |
| **1-2: Notify** | Mid-task error or long-running checkpoint | Call `zeph_notify` with `priority: "high"` — the instant it happens, not batched |
| **Push Signal** | Steer the Stop-hook auto-push (NORMAL mode) | Emit `<!-- zeph: skip\|push\|high -->`; none = default heuristic |
| **3: Questions** | Your response asks anything | FINAL tool call = `zeph_ask` |
| **4: After work** | Substantial changes (files, builds, deploys) | Default = end with `zeph_ask` |
| **4: Trivial** | Read-only, mid-plan, typo fixes | Skip `zeph_ask`, let Stop hook fire |
| **9: REMOTE** | Not in `{done, stop, exit}` button taps | End EVERY response with `zeph_ask` |
| **9: NORMAL** | Initial state or after exit signal | Apply Rule 4 (substantial → ask) |
| **9: Exit** | User says done/stop/exit | Flip to NORMAL, no ask on exit response |
| **10: AskUserQuestion** | Need user input with code/logs too big | Use `AskUserQuestion` (not `zeph_ask`) |

---

**Last updated**: 2026-06-30
**Synced across**: plugin, CLAUDE.md, SKILL.md, cli/templates.ts
