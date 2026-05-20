#!/usr/bin/env node
'use strict';

// SessionStart hook — injects Zeph remote-control rules into the session.
// Emits JSON with hookSpecificOutput.additionalContext so the rules land in
// Claude's context, not just the user's transcript.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync } = require('child_process');

const configFile = path.join(os.homedir(), '.zeph', 'config.json');
let config = {};
try { config = JSON.parse(fs.readFileSync(configFile, 'utf-8')); } catch {}

const envOr = (key) => {
    const v = process.env[key];
    if (!v) return undefined;
    if (v.startsWith('${')) return undefined; // unresolved ${VAR} placeholder
    if (v.length === 0) return undefined;
    return v;
};

const apiKey = envOr('ZEPH_API_KEY') || config.apiKey;
const hookId = envOr('ZEPH_HOOK_ID') || config.hookId;

const hasJq = (() => {
    try { execSync('command -v jq', { stdio: 'pipe' }); return true; } catch { return false; }
})();

const emit = (additionalContext) => {
    process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
            hookEventName: 'SessionStart',
            additionalContext,
        },
    }));
};

if (!apiKey) {
    emit(
        '# System note (Zeph plugin — internal, do not surface unless asked)\n\n' +
        'Zeph is installed but not configured. The user can run ' +
        '`npx @zeph-to/hook-sdk setup` to enable cross-device notifications and remote control. ' +
        'Until configured, do NOT call any zeph_* MCP tools.'
    );
    process.exit(0);
}

const mode = hookId ? 'two-way (notify + ask + prompt + input)' : 'one-way (notify only)';

const rulesTwoWay = `# Zeph — Remote-Control Rules (active every response)

Zeph lets the user drive this Claude Code session from their phone. You
are talking to a user who may not be at the terminal. Buttons sent via
\`zeph_ask\` are how they steer you.

Mode: ${mode}

## Notification discipline

1. A Stop hook already sends an automatic push on every response that did real
   work (≥2 tool calls). Do NOT call \`zeph_notify\` just to say "done" — it
   duplicates the auto-push.
2. Use \`zeph_notify\` only for: mid-task errors that block progress, explicit
   long-running progress milestones, or multi-session signals ("session A
   finished, session B still building"). Set \`priority: "high"\` for blockers.

## When zeph_ask is MANDATORY

3. **NEVER end a response with a plain-text question.** If your reply
   asks the user anything that needs their input — confirmation, choice,
   yes/no, clarification, "Apply this?", "Proceed?", "Which option?" —
   the FINAL tool call MUST be \`zeph_ask\`. A "?" written in your reply
   is invisible to a user on their phone. This applies even on research
   / analysis / planning turns where no files were touched.

   Anti-pattern (wrong):
   \`\`\`
   "...build/commit on hold. Apply A?"
   \`\`\`
   Correct:
   \`\`\`
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
   \`\`\`

## When zeph_ask is the DEFAULT (substantial work)

3a. After substantial work, \`zeph_ask\` is the DEFAULT end of the
    response — not optional. "Substantial" means: file changes, commits,
    builds, tests, deploys, destructive ops, milestone completions, or
    anything the user might reasonably want to confirm or redirect.

    SKIP \`zeph_ask\` only when the response is clearly trivial:
    - Read-only exploration ("let me check this file") with no decision
      output.
    - Mid-step inside a clearly-defined plan the user already approved
      ("step 3 of 5, no decisions involved here").
    - Trivial change (typo fix, single-line tweak) that needs no ack.

    When unsure: LEAN TOWARD ASKING. Quiet failure (no ask, user stuck
    on phone with no way to drive) is worse than light spam.
4. Prefer \`zeph_ask\` over \`zeph_prompt\`/\`zeph_input\` — it combines buttons
   and free-text in one push. Always include a \`fallback\` action id; the
   fallback must be safe/inert (\`done\`, \`wait\`, \`review\`), never destructive.
5. Example \`zeph_ask\` shape — use sparingly per Rule 3a (only at natural
   pause points; NOT after every response — see Rule 8):
   \`\`\`
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
   \`\`\`

## Handling the response

6. A \`zeph_ask\` response IS a direct user instruction. Execute it
   immediately — do NOT re-ask via AskUserQuestion to confirm. The button
   label is the authorization for the specific action that label describes.
7. Important caveat: a generic button like "Continue" authorizes the next
   logical step, NOT arbitrary destruction. If the next logical step is
   irreversible (force-push, \`rm -rf\` outside the workdir, dropping a
   database, deleting prod resources), surface that specific risk via a
   targeted \`zeph_ask\` before executing — e.g., title "About to force-push
   main — proceed?", actions \`[ok, cancel]\`, fallback \`cancel\`.
8. **Chaining is governed by a sticky REMOTE mode.** The Ask Loop has
   two states — REMOTE and NORMAL — and you detect the current state by
   scanning the conversation, not just the most recent message.

   ### Detecting state
   Scan the conversation in reverse, looking for whichever appears
   first (most recent):
   - (a) A \`tool_result\` for a \`zeph_ask\` you sent where the action id
         is NOT in \`{done, stop, exit}\` (case-insensitive) and the
         free-text response is NOT a clear session-ending phrase like
         "thanks, that's it" / "all good, done".
   - (b) An exit signal: action id in \`{done, stop, exit}\`, ending
         free-text, or a timeout fallback that resolved to a Done-like
         fallback id.
   - (c) No \`zeph_ask\` history at all.

   If the first hit is (a) → you are in REMOTE.
   If the first hit is (b) or (c) → you are in NORMAL.

   ### Behavior in REMOTE (sticky, zeph_ask MANDATORY)
   End EVERY response with \`zeph_ask\`. This is non-negotiable while in
   REMOTE — independent of:
   - Whether the next user message arrived as a \`tool_result\` or as a
     typed terminal message. The user may switch devices mid-session;
     sticky REMOTE keeps the channel driveable from either side.
   - Whether the work was substantial or routine.

   The only way to leave REMOTE is the user signalling exit (per the
   (b) list above).

   ### Behavior in NORMAL (apply Rule 3a)
   - Substantial work → end with \`zeph_ask\`.
   - Routine work → skip \`zeph_ask\`, let the Stop hook fire.
   - Rule 3 (questions → zeph_ask) is still mandatory regardless.

   ### Exiting REMOTE
   The moment the user picks an action id matching
   \`done\`/\`stop\`/\`exit\` (case-insensitive), types free-text that
   clearly ends the session, or the zeph_ask times out and falls back
   to a Done-like id, you flip to NORMAL. Don't send \`zeph_ask\` on the
   response that processes the exit signal.

## When to use AskUserQuestion vs zeph_ask

9. Prefer \`zeph_ask\` for short remote-friendly questions. Use the local
   AskUserQuestion tool only when (a) the answer needs the user to see code
   or logs that won't fit in a push body, or (b) the answer is plausibly
   multi-paragraph. \`zeph_ask\` should be the default while a hookId is set.

## Mute / persistence

10. If the user ran \`/zeph-mute\` for this project, the Stop and Ask hooks
    stay silent (driven by a tmp marker file). MCP tools still work but
    don't call them unless the user explicitly asks. \`/zeph-unmute\` lifts it.
11. These rules persist for the entire session. They remain active after
    context compaction — do not "forget" them after many turns.`;

const rulesOneWay = `# Zeph — Notification Rules (active every response)

Mode: ${mode} — \`ZEPH_HOOK_ID\` is not set, so two-way (\`zeph_ask\` /
\`zeph_prompt\` / \`zeph_input\`) is unavailable. Only \`zeph_notify\` works.

1. A Stop hook auto-notifies after responses with real work (≥2 tool calls).
   Do NOT call \`zeph_notify\` just to say "done" — it duplicates the auto-push.
2. Use \`zeph_notify\` only for: mid-task errors that block progress, explicit
   long-running progress milestones, or multi-session signals. Set
   \`priority: "high"\` for blockers.
3. To enable remote control (buttons + free-text from the phone), the user
   should set \`ZEPH_HOOK_ID\` via \`npx @zeph-to/hook-sdk setup\`. You may
   mention this once if relevant — don't repeat it.
4. These rules persist for the entire session, including after context
   compaction.`;

const rules = hookId ? rulesTwoWay : rulesOneWay;

const finalContext = hasJq
    ? rules
    : rules + '\n\n## Environment note\n\n`jq` is not installed on this machine, so the Stop and Ask shell hooks exit early without sending pushes. Tell the user once: install with `brew install jq` (macOS) or `apt install jq` (Linux).';

emit(finalContext);
