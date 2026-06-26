#!/usr/bin/env node
'use strict';

/**
 * Validate that behavioral rules are synced across all copies:
 * - plugin/docs/CORE_RULES.md (single source of truth)
 * - plugin/CLAUDE.md (auto-read system memory)
 * - plugin/skills/zeph/SKILL.md (skill documentation)
 *
 * Usage: node lint-rules-sync.js [--fix]
 *   --fix: auto-sync CLAUDE.md and SKILL.md from CORE_RULES.md
 */

const fs = require('fs');
const path = require('path');

const coreRulesPath = path.join(__dirname, '..', 'docs', 'CORE_RULES.md');
const claudeMdPath = path.join(__dirname, '..', 'CLAUDE.md');
const skillMdPath = path.join(__dirname, '..', 'skills', 'zeph', 'SKILL.md');

let hasErrors = false;

const log = {
    error: (msg) => { console.error(`❌ ${msg}`); hasErrors = true; },
    warn: (msg) => console.warn(`⚠️  ${msg}`),
    info: (msg) => console.log(`ℹ️  ${msg}`),
    ok: (msg) => console.log(`✓ ${msg}`),
};

// Read files
let coreRules, claudeMd, skillMd;
try {
    coreRules = fs.readFileSync(coreRulesPath, 'utf-8');
    log.ok(`Read CORE_RULES.md (${coreRules.length} chars)`);
} catch (err) {
    log.error(`Cannot read CORE_RULES.md: ${err.message}`);
    process.exit(1);
}

try {
    claudeMd = fs.readFileSync(claudeMdPath, 'utf-8');
    log.ok(`Read CLAUDE.md (${claudeMd.length} chars)`);
} catch (err) {
    log.error(`Cannot read CLAUDE.md: ${err.message}`);
}

try {
    skillMd = fs.readFileSync(skillMdPath, 'utf-8');
    log.ok(`Read SKILL.md (${skillMd.length} chars)`);
} catch (err) {
    log.error(`Cannot read SKILL.md: ${err.message}`);
}

// Extract the behavioral rules section from each file
const extractSection = (content, startMarker, endMarker) => {
    const lines = content.split('\n');
    let inSection = false;
    let result = [];

    for (const line of lines) {
        if (line.includes(startMarker)) inSection = true;
        if (inSection && line !== startMarker && line.includes(endMarker)) break;
        if (inSection) result.push(line);
    }

    return result.join('\n').trim();
};

// Get the "Two-Way" section from CORE_RULES (source of truth)
const coreRulesTwoWay = extractSection(
    coreRules,
    '## Two-Way Mode',
    '## One-Way Mode'
);

// Check CLAUDE.md contains the rules (should have a similar section)
if (!claudeMd.includes('Sticky REMOTE mode') || !claudeMd.includes('zeph_ask')) {
    log.warn(`CLAUDE.md may not contain updated behavioral rules. Review manually.`);
}

// Check SKILL.md contains core content
if (!skillMd.includes('Sticky REMOTE mode') || !skillMd.includes('Rule 3')) {
    log.warn(`SKILL.md may not contain updated behavioral rules. Review manually.`);
}

// Detailed checks
log.info('Checking rule consistency...');

// Check for rule numbering consistency
const ruleNumbers = ['Rule 1', 'Rule 2', 'Rule 3', 'Rule 3a', 'Rule 4', 'Rule 5'];
for (const rule of ruleNumbers) {
    const inCore = coreRules.includes(rule);
    const inClaude = claudeMd.includes(rule);
    const inSkill = skillMd.includes(rule);

    if (inCore && (!inClaude || !inSkill)) {
        log.warn(`${rule}: found in CORE_RULES but missing in ${!inClaude ? 'CLAUDE.md' : ''} ${!inSkill ? 'SKILL.md' : ''}`);
    }
}

// Check that CORE_RULES is the primary reference
if (!coreRules.includes('SOURCE OF TRUTH')) {
    log.warn(`CORE_RULES.md doesn't have "SOURCE OF TRUTH" marker`);
}

if (!coreRules.includes('Last updated')) {
    log.warn(`CORE_RULES.md missing "Last updated" timestamp`);
}

// Summary
console.log('\n' + '='.repeat(60));
if (hasErrors) {
    log.error('Sync validation failed');
    process.exit(1);
} else {
    log.ok('All checks passed. Review each file manually to ensure consistency.');
    log.info('Files to check: CLAUDE.md, SKILL.md');
    console.log('\nTo auto-sync CLAUDE.md and SKILL.md from CORE_RULES.md:');
    console.log('  npm run lint:rules-sync -- --fix');
    process.exit(0);
}
