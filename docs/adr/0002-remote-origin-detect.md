# ADR-0002: Remote-origin detection — phone-sent messages enter REMOTE mode

## Status
Accepted (2026-07-12). Design from an analysis session; passed CEO review (GO)
with three refinements folded in below: the value-hypothesis premise, the
one-way branch framed as a conversion funnel, and a pinned release order.

**Premise (value hypothesis):** the "high value" call assumes phone-first
lightweight turns are common. This ADR came from an analysis session, not a
user report — the frequency of that entry pattern is still a hypothesis.
Validate by observation once shipped; if phone-initiated messages turn out to
be rare, the ROI drops accordingly.

## Context
CORE_RULES Rule 9 already defines a sticky **REMOTE** mode: once the user answers
a `zeph_ask` with a non-exit reply, the model ends every response with `zeph_ask`
until the user exits (`done`/`stop`/`exit`). That is the "ask the next task from
the phone" loop — and it works, but only when **the model asks first**.

The entry path is one-sided. When the user opens the phone's agent chat and sends
the *first* message, it travels

```
phone chat → agent.command push → listener → tmux send-keys → Claude Code
```

and arrives as plain typed text, indistinguishable from a terminal keystroke.
The model stays in NORMAL mode and applies the Rule 4 heuristic (substantial
work → ask, routine → silent). A read-only or lightweight turn therefore ends
silently: the phone user gets at most a Stop-hook push and has **no way to send
the next instruction** except composing another chat message blind. The exact
signal that would fix this — "this prompt came from the phone" — exists in the
listener at inject time and is thrown away.

Product framing: injection alone is remote *control*; origin detection upgrades
it to a remote *conversation loop* — every turn ends in actionable buttons on the
phone. That loop is the differentiator this ADR enables reliably.

## Decision
The listener records what it injects; a new **UserPromptSubmit** hook matches the
submitted prompt against that record and, on a hit, injects authoritative context
telling the model it is talking to a remote user — which enters sticky REMOTE
mode per Rule 9.

**cli (`listener.ts`)** — immediately after a successful text injection
(`tryInject`), write a one-shot state file:

```
${XDG_STATE_HOME:-$HOME/.local/state}/zeph/remote-<hash>
    content: "<epochSeconds> <sha256hex(injectedText)>\n"
```

- `<hash>` = `cksum` of the pane's cwd (`readPaneInfo().currentPath`) — the same
  keying and the same shelled-out `cksum` parity that `gate.ts` already uses for
  the muted/pushmode/auto files.
- Written with a trailing newline (bash `read -r` returns non-zero at EOF on an
  unterminated line).
- Text injections only. Key-event injections (`tryInjectKeys`: Esc/arrows/Enter)
  never produce a prompt — no file. For messages with attachments, hash the final
  composed string actually injected (body + attachment paths), not the raw body.

**plugin (new `hooks/zeph-remote.sh`, UserPromptSubmit)**:

1. Read stdin JSON, extract `.prompt`.
2. Resolve the state file via `gate.sh zeph_state_present remote <cksum of
   CLAUDE_PROJECT_DIR>` (new-location-first + owner-checked legacy, for free).
3. Match: file fresh (≤ 15 min) **and** `sha256(trim(prompt)) == recorded hash`.
   Trim on both sides is the same explicit ASCII set (`' \t\r\n\f\v'`), not
   `String.trim()` / `[[:space:]]` — those disagree on Unicode whitespace
   (U+00A0 etc.) and the digests must be computed over identical bytes. The
   window is generous on purpose: the exact-hash match already makes false
   positives impossible, and a message sent mid-turn queues until the turn
   ends — often past a minute. Stale markers are deleted on sight.
4. On match: delete the file (one-shot), emit `hookSpecificOutput.additionalContext`:
   - `ZEPH_HOOK_ID` set → "This message arrived from the user's phone via zeph.
     You are in sticky REMOTE mode (CORE_RULES Rule 9): end every response with
     `zeph_ask` until the user exits."
   - `ZEPH_HOOK_ID` unset → one-way variant. This branch is not dead code —
     it is a **conversion funnel**. The injection path (phone → listener →
     tmux) authenticates on the API key alone and never touches
     `ZEPH_HOOK_ID`, so "listener set up, two-way not enabled" is a real,
     reachable user state — and one where the user has just *proven* they
     drive sessions from their phone. That is the best possible moment to
     surface `npx @zeph-to/cli setup` (once per session; the context text
     instructs the model to self-dedup). Keep the branch a string-level
     variation of the same mechanism — no separate hook, no separate state.
5. Muted project (`zeph_state_present muted`) → exit silently without consuming
   the file. Mute outranks everything (Rule 12).
6. Always exit 0. This hook only adds context; it must never block a prompt.

**CORE_RULES.md** — extend Rule 9's state-detection list: a user message flagged
by the remote-detect hook's system-reminder counts as entry condition **(a)**,
equal to a non-exit `zeph_ask` reply. Exit conditions are unchanged. (Editing
CORE_RULES.md requires regenerating the cli rules-sync manifest — `lint:rules-sync`.)

**mcp-server / zeph app** — no changes. `zeph_ask` and the agent chat already
provide everything downstream of detection.

## Consequences
- **Good:** Deterministic detection at the hook layer (system-reminder), not an
  LLM inference — consistent with the "hooks over prose rules" principle. Zero
  prompt/transcript pollution. Every building block is already deployed: the XDG
  state-file pattern, bash↔TS `cksum` parity, `zeph_state_present`, and the
  plugin's hook registration (this is its 4th hook). The exact-text hash makes
  false positives structurally impossible — a terminal keystroke racing a phone
  injection simply doesn't match.
- **Good (recovery):** every phone message re-fires the hook, so sticky REMOTE
  self-heals across context compaction without relying on the model's memory.
- **Cost (coupled release):** unlike ADR-0001 this spans two repos — the cli
  writes, the plugin reads. Version skew degrades gracefully in both directions:
  old cli + new plugin → no file, hook is a no-op; new cli + old plugin → stray
  state file that the next new-plugin session consumes or ignores stale.
  **Release order is pinned: cli first, plugin second** — the cli-first window
  only produces harmless unconsumed files, while plugin-first would ship a hook
  that can never fire.
- **Cost (scope):** at acceptance this covered Claude Code panes only —
  codex/gemini injections had no hook system to read the file. **Phase 2 is a
  named roadmap goal, not a footnote:** the 10-star version of this feature is
  "the phone is a first-class driver for *every* agent from the first message".
  *Phase 2 update (2026-07): delivered via native hooks, not the visible-marker
  fallback — both agents grew CC-compatible prompt-submit hooks in 2026
  (Gemini CLI `BeforeAgent`, Codex CLI `UserPromptSubmit`, same
  `hookSpecificOutput.additionalContext` contract). The reader ships as
  `zeph remote-hook <agent>` in the cli and `zeph setup` registers it; the
  marker format and write site are unchanged. Alternative A is no longer
  needed for these agents and remains an option only for hook-less ones.*
- **Edge (same-cwd sessions):** two CC sessions in one cwd share the hash key.
  The session that received the injection consumes the file on its next prompt;
  the other session would need the user to type the byte-identical text within
  the freshness window to mis-consume it — negligible. If it ever matters, add the tmux session
  name to the file name; the pane cwd keying is accepted for now.
- **Edge (unconsumed files):** a message injected into a pane whose Claude is
  mid-turn still becomes the *next* prompt, so the file is consumed late but
  correctly — the 15-minute window exists precisely to survive that queueing
  gap. A turn that outlasts even that simply doesn't enter the loop (same as
  today) and the next phone message retries. The hook deletes any stale
  marker it encounters, so dead files don't accumulate.
- **Edge (message burst):** two phone messages in quick succession overwrite
  the same marker — the first prompt then has no matching digest and only the
  second flags. Net effect is identical (REMOTE is sticky once entered on the
  second), so this is accepted rather than engineered around.

## Alternatives considered
- **A. Visible text marker** (listener appends `<!-- zeph: remote -->` to the
  injected text): plugin-only precedent exists (ADR-0001), works for any agent —
  but it pollutes the prompt and transcript, the model may quote it back, and
  compliance is soft (a rule, not a mechanism). Honest trade-off acknowledged:
  A would have been the *faster demand-validation* path (one repo, every agent
  immediately); we chose zero-pollution product quality over validation speed.
  Kept as the phase-2 fallback for non-Claude agents; rejected as the primary
  mechanism.
- **B-lite. Timestamp-only state file** (no text hash): simpler, but a terminal
  keystroke landing within the freshness window of a phone injection false-flags
  REMOTE. The hash costs one `shasum` call and eliminates the race entirely.
- **C. Model self-detection via `zeph_list`**: per-turn MCP call, LLM-driven
  inference, non-deterministic. Rejected.

## Amendment (2026-08-12) — a terminal-typed prompt leaves REMOTE

0.11.0 gave REMOTE a home (`remote-active-<hash>`) so it survives compaction,
and decided that a turn the user types at the terminal *keeps* the mode: the
user might switch back to the phone, and the reminder keeps the channel
driveable from either side.

In use that reads as the session refusing to let go. The user is sitting at the
terminal, typing, watching the pane — and every answer still comes back as a
phone-shaped `zeph_ask`. Rule 9's three exits (Done-like button, the model's
free-text call, the 4-hour TTL) all miss that case, and a non-Done button tap
*renews* the TTL, so an active session never ages out.

So a prompt with no marker now ends REMOTE. The signal is as deterministic as
entry: the only way text becomes a prompt without a listener marker is the
user's own keyboard — a phone answer to a `zeph_ask` comes back as a
`tool_result` and never reaches a prompt hook at all. The hook clears the state
and says so once; later terminal turns are silent no-ops, which also drops the
per-turn context cost the reminder was paying.

- **Cost:** re-entry is one phone message (the next injection writes a fresh
  marker). The device-switch case the original design protected is not free
  anymore, but it was protecting the rarer direction.
- **Not every miss is a keyboard.** The matcher returns three verdicts, not a
  boolean: a *fresh* marker left unmatched means a phone message is in flight
  (queued behind a long turn, or a digest the two sides compute differently),
  and reading that as "the user is back" would drop them out of REMOTE while
  they are still holding the phone — with no answerable push left, the quiet
  failure Rule 4 calls worse than light spam. Only "no marker this prompt could
  have matched" ends the mode; ambiguity leaves it exactly as it was. A stale
  or unparseable marker can never match and counts as no marker.
- Shipped in `hooks/zeph-remote.sh`, `cli/src/remote-hook.ts`, and Rule 9.

## Amendment (2026-08-21) — the hook id resolves from config.json too

The decision above keyed the two branches on `ZEPH_HOOK_ID` alone. `zeph setup`
never exports that variable — it writes `hookId` to `~/.zeph/config.json`, and
the SessionStart hook and the MCP server read it from there. So a stock
install got the conversion-funnel note on every phone message while `zeph_ask`
itself worked, and the one-way branch reached a user it was never meant for.

Both hooks now resolve the id through gate.sh `zeph_hook_id` (env when it
carries a real value, else the config file); the TS twin does the same via
cli `config.ts`. The funnel branch keeps its purpose — it fires only when no
hook id exists anywhere.

## Related
- ADR-0001 (Push Signal): the marker precedent and the "plugin-only vs coupled
  release" trade-off this ADR consciously takes the other side of.
- CORE_RULES.md Rule 9 (sticky REMOTE), Rule 12 (mute); `hooks/gate.sh`
  (`zeph_state_present`); cli `gate.ts` (cksum parity, state dir).
- cli `listener.ts` `tryInject` / `readPaneInfo` — the write site.
