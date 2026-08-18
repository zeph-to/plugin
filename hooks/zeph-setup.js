#!/usr/bin/env node
'use strict';

// SessionStart hook — injects Zeph's rules into the session as
// hookSpecificOutput.additionalContext, so they land in Claude's context and
// not just the user's transcript.
//
// STATE-CONDITIONAL, and it has to be. Claude Code persists a hook's
// additionalContext to a file the moment it exceeds 10,000 chars and replaces
// it with a 2,000-char preview (cli.js: `Pyt(e,t,r,n=k$d)`, `k$d=1e4`,
// preview `hFr=2000`). The unconditional full text was 15,483 bytes, so every
// rule below the first 2KB — the whole Ask Loop, sticky REMOTE, the
// AskUserQuestion override — never reached the model at all. Shrinking the
// text is therefore not an optimisation; it is what makes the rules exist.
//
// The hook already knows the state it is injecting into, so it reads it and
// emits that branch only:
//
//   muted        → three lines; the hooks are silent anyway
//   no hookId    → one-way notify discipline; zeph_ask/prompt/input do not exist
//   REMOTE       → sticky REMOTE in full, no Push Signal (REMOTE ignores markers)
//   NORMAL       → the default branch, with a two-line pointer to REMOTE
//
// A session that transitions into REMOTE on a phone message gets the full
// contract from the UserPromptSubmit hook (hooks/zeph-remote.sh) on that turn.
// Any state read that fails resolves to the NORMAL branch.

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
        '`npx @zeph-to/cli setup` to enable cross-device notifications and remote control. ' +
        'Until configured, do NOT call any zeph_* MCP tools.'
    );
    process.exit(0);
}

// ── State ───────────────────────────────────────────────────────────────────
//
// The JS twin of hooks/gate.sh's state resolution — same paths, same legacy
// /tmp ownership check, same TTL, same push-mode fallbacks. Kept in one
// try/catch: an unreadable state dir must resolve to the NORMAL branch, never
// to "emit everything" (which is the failure this rewrite exists to remove).

const STATE_DIR = path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state'), 'zeph');
const REMOTE_TTL_SEC = 14400;
const PUSHMODE_DEFAULT = 'quiet';

// cksum of the project dir, exactly as every shell hook computes it — shelled
// out rather than reimplemented so the two can never disagree on a hash.
const projectHash = () => {
    const dir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
    return execSync('cksum', { input: dir, encoding: 'utf-8' }).trim().split(/\s+/)[0];
};

// gate.sh zeph_state_present: XDG path, then a legacy /tmp copy but only when
// the current user owns it (a planted file must not be able to mute someone).
const statePresent = (kind, hash) => {
    const xdg = path.join(STATE_DIR, `${kind}-${hash}`);
    if (fs.existsSync(xdg)) return xdg;
    const legacy = `/tmp/zeph-${kind}-${hash}`;
    try {
        if (fs.statSync(legacy).uid === process.getuid()) return legacy;
    } catch {}
    if (kind === 'pushmode') {
        const fallback = path.join(STATE_DIR, 'pushmode-default');
        if (fs.existsSync(fallback)) return fallback;
    }
    return null;
};

// gate.sh zeph_remote_active. Deliberately no /tmp branch (that kind never had
// a /tmp writer) and the TTL is enforced here too — without it a crashed
// session would latch the REMOTE branch for every later session in the project.
const remoteActive = (hash) => {
    const file = path.join(STATE_DIR, `remote-active-${hash}`);
    let ts;
    try { ts = fs.readFileSync(file, 'utf-8').split('\n')[0].trim(); } catch { return false; }
    if (!/^\d+$/.test(ts)) return false;
    return Math.floor(Date.now() / 1000) - Number(ts) <= REMOTE_TTL_SEC;
};

// gate.sh zeph_read_pushmode: no hash → normal, no dial file → quiet,
// empty/garbage → normal.
const readPushmode = (hash) => {
    if (!hash) return 'normal';
    const file = statePresent('pushmode', hash);
    if (!file) return PUSHMODE_DEFAULT;
    let mode = '';
    try { mode = fs.readFileSync(file, 'utf-8').replace(/\s/g, ''); } catch {}
    return ['quiet', 'loud', 'normal'].includes(mode) ? mode : 'normal';
};

const readState = () => {
    try {
        const hash = projectHash();
        return { muted: !!statePresent('muted', hash), remote: remoteActive(hash), pushmode: readPushmode(hash) };
    } catch (err) {
        process.stderr.write(`[zeph-setup] state unreadable, falling back to NORMAL: ${err.message}\n`);
        return { muted: false, remote: false, pushmode: 'normal' };
    }
};

// ── CORE_RULES.md slicing ───────────────────────────────────────────────────

let coreRules = '';
try {
    coreRules = fs.readFileSync(path.join(__dirname, '..', 'docs', 'CORE_RULES.md'), 'utf-8');
} catch (err) {
    // Surface the real cause on stderr so a broken install is visible, not silent.
    process.stderr.write(`[zeph-setup] Could not read docs/CORE_RULES.md: ${err.message}\n`);
    coreRules = `# Zeph — Remote-Control Rules

Unable to load Zeph rules from plugin/docs/CORE_RULES.md — the plugin may be
corrupted or partially installed. Reinstall with:
  claude plugin uninstall zeph@zeph && claude plugin marketplace add zeph-to/plugin`;
}

// One `###`/`####` section, heading included, up to the next heading of the
// same or a higher level. Missing heading → empty string: a rename in
// CORE_RULES.md must drop one section, not crash the session's first turn.
const section = (heading) => {
    const level = heading.match(/^#+/)[0].length;
    const lines = coreRules.split('\n');
    const start = lines.findIndex((l) => l.trim() === heading);
    if (start === -1) return '';
    let end = lines.length;
    for (let i = start + 1; i < lines.length; i++) {
        const m = lines[i].match(/^(#+) /);
        if (m && m[1].length <= level) { end = i; break; }
    }
    return lines.slice(start, end).join('\n').replace(/\n+---\s*$/, '').trim();
};

// Resolve the `<!-- zeph-branch: NAME -->` blocks a section carries: keep the
// one that matches this session's state, drop the rest and every marker.
// `<!-- zeph-doc-only -->` blocks explain the branching to a human reading
// CORE_RULES.md and are never injected.
const pickBranch = (text, keep) => text
    .replace(/<!-- zeph-branch: ([\w-]+) -->\n([\s\S]*?)\n<!-- \/zeph-branch -->\n?/g,
        (_, name, body) => (name === keep ? `${body}\n` : ''))
    .replace(/<!-- zeph-doc-only -->\n[\s\S]*?\n<!-- \/zeph-doc-only -->\n?/g, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();

const pushSignal = (pushmode) => pickBranch(
    section('### Push Signal — steer the end-of-turn auto-push (Stop hook)'),
    pushmode === 'quiet' ? 'pushmode-quiet' : 'pushmode-normal-loud'
);

// ── Branches ────────────────────────────────────────────────────────────────

const join = (parts) => parts.filter(Boolean).join('\n\n');

const MUTED = `# Zeph — muted for this project

Push notifications are muted here, so the Stop and Ask hooks stay silent. The \`zeph_*\` MCP tools still work, but do NOT call them unless the user explicitly asks.

\`/zeph-unmute\` lifts it.`;

const oneWay = (pushmode) => {
    const body = coreRules.slice(coreRules.indexOf('## One-Way Mode'), coreRules.indexOf('## Environment Notes'))
        .replace(/^## One-Way Mode[^\n]*\n/, '')
        .replace(/\n+---\s*$/, '');
    return `# Zeph — Notification Rules (active every response)\n\n${pickBranch(body, pushmode === 'quiet' ? 'pushmode-quiet' : 'pushmode-normal-loud')}`;
};

// The NORMAL branch owes no `zeph_ask` at all, so it does not carry Rules
// 3/4/5/6/10/11 — every one of them is REMOTE-scoped. What it needs is the
// trigger: what flips the session, and what that turns on. The turn a phone
// message arrives, the UserPromptSubmit hook injects Rule 9 in full from
// CORE_RULES.md; a `zeph_ask` answer that reports `zephState: "REMOTE"` flips
// it mid-turn, which is why the obligation is stated here rather than pointed at.
const REMOTE_STUB = `### What starts REMOTE

The user sending a message from their phone starts sticky REMOTE — the UserPromptSubmit hook says so on that turn and injects the contract in full. A \`zeph_ask\` result reporting \`zephState: "REMOTE"\` starts it mid-turn.

From that response on: end EVERY response with \`zeph_ask\` (2–4 \`actions\` plus a Done-like \`fallback\`, \`timeout\` 300–600s), route button-friendly questions through it instead of \`AskUserQuestion\`, and never end on a plain-text question — until the user exits with a Done-like button, a free-text wrap-up you read as one (emit \`<!-- zeph: exit -->\` once), or a prompt they type at the terminal.`;

const normal = (pushmode) => join([
    '# Zeph — Notification Rules (active every response)',
    '## NORMAL — the user is at the terminal',
    'Zeph can hand this session to the user\'s phone, but nobody has done that yet. **You owe no `zeph_ask`**: ask questions with `AskUserQuestion` or in prose, and let the Stop hook\'s push be the completion signal. A `zeph_ask` here blocks the turn until someone answers on a device or it times out.',
    section('### Notification discipline'),
    pushSignal(pushmode),
    section('### Handling the response'),
    REMOTE_STUB,
    section('### Persistence'),
]);

// No Push Signal here: the markers are ignored on any turn that already sent
// `zeph_ask`, and in REMOTE every turn does. Rules 4/5/6 are likewise left out
// — Rule 9 supersedes Rule 4 while REMOTE holds, and the `actions` requirement
// it turns on is restated inside the sticky-REMOTE text itself.
const remote = () => join([
    '# Zeph — Remote-Control Rules (active every response)',
    '## Two-Way Mode — **this session is in REMOTE**',
    "The user is driving this session from their phone and is NOT at the terminal. Buttons sent via `zeph_ask` are how they steer you; a plain-text question is invisible to them.",
    section('### Notification discipline'),
    section('### When zeph_ask is MANDATORY'),
    section('### Handling the response'),
    section('### Sticky REMOTE mode (Rule 9)'),
    section('### When to use AskUserQuestion vs zeph_ask'),
    section('### Persistence'),
]);

// ── Emit ────────────────────────────────────────────────────────────────────

const state = readState();

if (state.muted) {
    emit(MUTED); // no jq note: a muted project's hooks are silent by design
    process.exit(0);
}

const rules = !hookId ? oneWay(state.pushmode)
    : state.remote ? remote()
    : normal(state.pushmode);

// Without jq the Stop/Ask/UserPromptSubmit shell hooks exit early and send
// nothing — which also means the REMOTE full text never arrives. Warn once.
const jqWarning =
    '\n\n## Environment note\n\n`jq` is not installed on this machine, so the ' +
    'Zeph shell hooks exit early: no pushes, and no remote-mode notes. Tell the user ' +
    'once: install with `brew install jq` (macOS) or `apt install jq` (Linux).';

const mode = hookId ? 'two-way (notify + ask + prompt + input)' : 'one-way (notify only)';

emit(`${rules}\n\nMode: ${mode}${hasJq ? '' : jqWarning}`);
