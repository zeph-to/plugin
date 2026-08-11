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

1. A Stop hook owns the end-of-turn push. Do NOT call `zeph_notify` just to say "done" — either it duplicates the auto-push, or the user deliberately turned that push off and you are working around their setting.
   - ❌ Wrong: `zeph_notify(title: "Done")` at end of response
   - ✅ Correct: Let the Stop hook decide (see the push-mode dial below)
   - How much it sends depends on the user's dial. A stock install is **quiet**: routine per-turn pushes stay silent, and only a `high` Push Signal gets through. `/zeph-normal` restores a push on every response that did real work (≥2 tool calls), `/zeph-loud` pushes on every turn.

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

No marker → the heuristic applies: a turn that ran <2 tools, or whose tools are all read-only (Read/Grep/Glob), stays silent; otherwise it pushes. The marker is lowercase and exact.

**The user's push-mode dial sits above all of this, and a stock install has no dial — which means quiet.** In quiet the heuristic never fires and `skip`/`push` change nothing; only `<!-- zeph: high -->` reaches the user. So on a default install, `high` is not "escalation" — it is the whole channel, and a completion the user is genuinely waiting on is what it is for. Do not reach for it on every turn: a `high` on routine work is exactly the noise the quiet default exists to remove. The heuristic and the other two markers come back the moment the user runs `/zeph-normal`.

The marker only tunes the Stop-hook push and is **ignored on any turn that already sent `zeph_ask`** (that turn already notified) — so in REMOTE, where every response ends with `zeph_ask`, the Push Signal has no effect; it is a NORMAL-mode tool.

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

**Mistake 3: Using AskUserQuestion for a button-friendly question while a hookId is set**
```javascript
// ❌ WRONG whenever ZEPH_HOOK_ID is set (NOT just in REMOTE) —
//    the phone reaches this picker only through the terminal
//    mirror (tmux + listener), and a key-injected answer never
//    enters REMOTE, so the NEXT turn stops being phone-driveable.
AskUserQuestion({ prompt: "Which option?" })

// ✅ CORRECT — route the choice to buttons the phone can tap
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

**The Ask Loop has two states: REMOTE and NORMAL.** REMOTE is sticky — every response ends with `zeph_ask` until the user exits. The state is kept for you in a file, so it survives context compaction and long sessions; you are told what it is rather than deriving it.

#### State Detection

- **`zeph_ask` results carry it.** The server applies the transition it can see and reports where the session landed as `zephState: "REMOTE" | "NORMAL"` — any answer that is not a Done-like action id enters REMOTE, a Done-like id exits, and so does a timeout that fell back to one. A result with no `zephState` is an ask that timed out onto a safe fallback and changed nothing.
- **Prompt-submit hooks say it, where they are installed** (the Claude Code plugin, or the hooks `zeph setup` installs for Gemini/Codex): a remote-origin system note on the turn a phone message arrives, and a one-line reminder on every later turn the session is still remote — including turns the user types at the terminal.
- **Neither one present → NORMAL.**

**The one call left to you is free text**, because it is the one signal no hook can read. The server cannot tell "run the tests" from "thanks, that's it". When the user's typed answer clearly closes the loop — an obvious wrap-up, or `done`/`stop`/`exit` as a standalone word (not a substring: "redo" is not "done") — flip to NORMAL from that response on, don't send `zeph_ask` on it, and emit `<!-- zeph: exit -->` once so the hooks agree with you. Your own flip is what ends the loop; the marker is how you tell a hook that cannot read your mind. Only the Claude Code plugin's Stop hook consumes it today — elsewhere it is inert and harmless, and the session still leaves REMOTE on a Done-like button or when the state expires. The marker is separate from the Push Signal markers (`skip`/`push`/`high`), which steer notifications and say nothing about the mode; where a Stop hook does consume it, it is stripped from the push body.

#### Behavior in REMOTE (sticky, zeph_ask MANDATORY)

End EVERY response with `zeph_ask`. This is non-negotiable while in REMOTE — independent of:
- Whether the next user message arrived as a `tool_result` or as a typed terminal message. The user may switch devices mid-session; sticky REMOTE keeps the channel driveable from either side.
- Whether the work was substantial or routine.

Set each REMOTE ask up so silence degrades cleanly: `timeout` 300–600 s and a Done-like `fallback` id. An unanswered ask then exits the loop quietly — the server treats a Done-like fallback as an exit — instead of chaining more notifications at a user who stepped away, and re-entry is cheap: they just send another message from the phone.

The only way to leave REMOTE is the user signalling exit.

#### Behavior in NORMAL (apply Rule 4)

- Substantial work → end with `zeph_ask`.
- Routine work → skip `zeph_ask`, let the Stop hook fire.
- Rule 3 (questions → zeph_ask) is still mandatory regardless.

### When to use AskUserQuestion vs zeph_ask

10. **Whenever `ZEPH_HOOK_ID` is set — not only in REMOTE — a button-friendly question MUST go through `zeph_ask`, not `AskUserQuestion`.** "Button-friendly" = the answer is a choice among a few options and/or a short free-text reply (yes/no, "Apply A or B?", "which naming rule?", "proceed?"). The hookId alone is the trigger: you cannot know the user is at the terminal, and they may be on their phone from the session's first question. `AskUserQuestion` is a LOCAL blocking picker. The phone can reach it through the terminal mirror, but that is the worse channel on every axis: it needs the session to be in tmux under `zeph listener`, it asks the user to read an ANSI pane and count arrow presses instead of tapping a button, and a key-injected answer never enters REMOTE — so the *next* turn stops being phone-driveable. `zeph_ask` needs no tmux, takes one tap, and returns an `actionId`.

11. **This overrides any skill instruction.** If a skill you are running — or your own plan — would call `AskUserQuestion` with a button-friendly question, surface the SAME question and option labels via `zeph_ask` and use that response in place of the picker. Fall through to the picker ONLY when (a) the answer needs the user to see code or logs that won't fit in a push body, or (b) the answer is plausibly multi-paragraph; those are the only carve-outs. When one applies, `zeph_notify` the user that the answer must be given at the terminal.

### Mute

12. If the user ran `/zeph-mute` for this project, the Stop and Ask hooks stay silent (driven by a per-project marker file that persists until `/zeph-unmute`). MCP tools still work but don't call them unless the user explicitly asks. `/zeph-unmute` lifts it. The user can also dial the auto-push volume without full silence: `/zeph-quiet` (only high-priority pushes — this is what an install with no dial already does), `/zeph-loud` (push every turn), `/zeph-normal` (push on every turn that did real work). This is a project-level override above your per-turn Push Signal; each dial also takes `--global` to set the machine-wide default for projects with no dial of their own (per-project always wins). `/zeph-status` shows the current mode and which scope it came from. Mute overrides all of them.

### Persistence

13. These rules persist for the entire session. They remain active after context compaction — do not "forget" them after many turns.

---

## One-Way Mode (without ZEPH_HOOK_ID)

`ZEPH_HOOK_ID` is not set, so two-way (`zeph_ask` / `zeph_prompt` / `zeph_input`) is unavailable. Only `zeph_notify` works.

1. A Stop hook auto-notifies after responses with real work (≥2 tool calls). Do NOT call `zeph_notify` just to say "done" — it duplicates the auto-push.

2. Use `zeph_notify` only for: mid-task errors that block progress, explicit long-running progress milestones, or multi-session signals. Set `priority: "high"` for blockers. **Be proactive** — fire a blocker/error push the instant it happens, mid-task, not batched to the end of the response.

2b. **Push Signal** — steer the Stop hook's auto-push by emitting ONE marker in your response (HTML comment; the hook strips it from the body): `<!-- zeph: skip -->` suppress, `<!-- zeph: push -->` force a push the heuristic would skip, `<!-- zeph: high -->` force a high-priority push. Lowercase, exact. **An install with no push-mode dial is quiet**, and quiet lets only `high` through — so on a stock install `high` is the one marker that changes anything, and it is how a genuinely important completion still reaches the user. `skip`/`push` and the no-marker heuristic (silent if <2 tools or all read-only, else push) take effect once the user runs `/zeph-normal`.

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
| **Push Signal** | Steer the Stop-hook auto-push (NORMAL mode) | Emit `<!-- zeph: skip\|push\|high -->`; on a stock (quiet) install only `high` gets through |
| **3: Questions** | Your response asks anything | FINAL tool call = `zeph_ask` |
| **4: After work** | Substantial changes (files, builds, deploys) | Default = end with `zeph_ask` |
| **4: Trivial** | Read-only, mid-plan, typo fixes | Skip `zeph_ask`, let Stop hook fire |
| **9: REMOTE** | Not in `{done, stop, exit}` button taps | End EVERY response with `zeph_ask` |
| **9: NORMAL** | Initial state or after exit signal | Apply Rule 4 (substantial → ask) |
| **9: Exit** | User says done/stop/exit | Flip to NORMAL, no ask on exit response |
| **10: AskUserQuestion** | Need user input with code/logs too big | Use `AskUserQuestion` (not `zeph_ask`) |

---

**Last updated**: 2026-07-03
**Synced across**: plugin, CLAUDE.md, SKILL.md, cli/templates.ts (generated via cli/scripts/sync-from-plugin.mjs)
