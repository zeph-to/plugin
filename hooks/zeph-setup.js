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

## The Ask Loop (core remote-control pattern)

3. After any response that involved file changes, builds, deploys, or
   destructive ops, end with a \`zeph_ask\` offering next actions. This both
   delivers the completion notification AND lets the user steer the next step
   from their phone. When you send \`zeph_ask\`, the Stop hook stays silent —
   no duplicate.
4. Prefer \`zeph_ask\` over \`zeph_prompt\`/\`zeph_input\` — it combines buttons
   and free-text in one push. Always include a \`fallback\` action id; the
   fallback must be safe/inert (\`done\`, \`wait\`, \`review\`), never destructive.
5. Example final action:
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
8. After executing the response, send the next \`zeph_ask\` to continue the
   loop. End the loop ONLY when the user picks an action id matching
   \`done\`/\`stop\`/\`exit\` (case-insensitive) or types free-text that clearly
   ends the session (e.g., "thanks, that's it"). Treat the timeout fallback
   the same as the user picking the fallback id.

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
