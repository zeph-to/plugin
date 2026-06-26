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
        '`npx @zeph-to/cli setup` to enable cross-device notifications and remote control. ' +
        'Until configured, do NOT call any zeph_* MCP tools.'
    );
    process.exit(0);
}

const mode = hookId ? 'two-way (notify + ask + prompt + input)' : 'one-way (notify only)';

// Read rules from plugin/docs/CORE_RULES.md (single source of truth)
// This file is synced to: CLAUDE.md, skills/zeph/SKILL.md, cli/src/templates.ts
let coreRules = '';
try {
    coreRules = fs.readFileSync(path.join(__dirname, '..', 'docs', 'CORE_RULES.md'), 'utf-8');
} catch (err) {
    // Fallback: embedded rules (should not happen in normal setup).
    // Surface the real cause on stderr so a broken install is visible, not silent.
    process.stderr.write(`[zeph-setup] Could not read docs/CORE_RULES.md: ${err.message}\n`);
    coreRules = `# Zeph — Remote-Control Rules

Unable to load Zeph rules from plugin/docs/CORE_RULES.md — the plugin may be
corrupted or partially installed. Reinstall with:
  claude plugin uninstall zeph@zeph && claude plugin marketplace add zeph-to/plugin`;
}

const mode_label = hookId ? 'Mode: two-way (notify + ask + prompt + input)' : 'Mode: one-way (notify only)';

// Extract the appropriate section from CORE_RULES.md
const extractRulesSection = (isTwoWay) => {
    const lines = coreRules.split('\n');
    const startMarker = isTwoWay ? '## Two-Way Mode' : '## One-Way Mode';
    const endMarker = isTwoWay ? '## One-Way Mode' : '## Environment Notes';

    let inSection = false;
    let result = [];

    for (const line of lines) {
        if (line.includes(startMarker)) inSection = true;
        if (inSection && line.includes(endMarker)) break;
        if (inSection) result.push(line);
    }

    return (result.join('\n').trim() + '\n\nMode: ' + mode_label).trim();
};

const rulesTwoWay = `# Zeph — Remote-Control Rules (active every response)

${extractRulesSection(true)}`;

const rulesOneWay = `# Zeph — Notification Rules (active every response)

${extractRulesSection(false)}

\`ZEPH_HOOK_ID\` is not set, so two-way (\`zeph_ask\` / \`zeph_prompt\` / \`zeph_input\`) is unavailable. Only \`zeph_notify\` works.`;

const rules = hookId ? rulesTwoWay : rulesOneWay;

// Without jq the Stop/Ask shell hooks exit early and send nothing — warn once.
const jqWarning =
    '\n\n## Environment note\n\n`jq` is not installed on this machine, so the ' +
    'Stop and Ask shell hooks exit early without sending pushes. Tell the user ' +
    'once: install with `brew install jq` (macOS) or `apt install jq` (Linux).';

emit(hasJq ? rules : rules + jqWarning);
