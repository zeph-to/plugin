# Rules Synchronization

## Single Source of Truth

All behavioral rules for Zeph agents are now centralized in **`CORE_RULES.md`**.

This file is the authoritative source and is read by:

1. **SessionStart Hook** (`plugin/hooks/zeph-setup.js`)
   - Reads `CORE_RULES.md` at runtime
   - Extracts the appropriate section (two-way or one-way)
   - Injects rules into Claude Code session context

2. **System Memory** (`plugin/CLAUDE.md`)
   - Should reference or mirror `CORE_RULES.md`
   - Serves as fallback documentation

3. **Skill Documentation** (`plugin/skills/zeph/SKILL.md`)
   - Should reference or mirror `CORE_RULES.md`
   - User-discoverable documentation

4. **CLI Templates** (`cli/src/templates.ts` → `ZEPH_CORE`)
   - Shared across 7 agents (Cursor, Windsurf, Gemini, Codex, Copilot, Cline, Aider)
   - Needs manual sync during releases

## Why This Matters

**Before**: Rules were duplicated in 4 locations. Manual sync required. Bugs from divergence:
- SessionStart hook outdated → old rules injected
- CLAUDE.md drifts → conflicting guidance
- SKILL.md lags → user confusion
- cli/templates.ts forgotten → agent behavior diverges

**After**: Single edit point. Hook reads at runtime. Automatic consistency.

## Maintenance

### When you change rules

1. **Edit `CORE_RULES.md`** — this is the only file you need to change
2. **Verify the change**:
   ```bash
   node plugin/scripts/lint-rules-sync.js
   ```
3. **Update CLAUDE.md & SKILL.md** — these should reference the new rule, not duplicate it
   - Add a link: "See Rule 3 in [CORE_RULES.md](../docs/CORE_RULES.md)"
   - Or, if skill-specific: extract the relevant rule with attribution
4. **Update cli/src/templates.ts** — manual sync needed for multi-agent support
   - Extract `CORE_RULES.md` sections into `ZEPH_CORE`
   - This happens during release prep
5. **Update "Last updated" timestamp** in CORE_RULES.md

### CI/Release Checklist

Before publishing a new version:

```bash
# Validate sync
npm run lint:rules-sync

# Verify CLAUDE.md references CORE_RULES.md (not hardcoded)
grep -n "See.*CORE_RULES" plugin/CLAUDE.md

# Verify cli/src/templates.ts mirrors current rules
diff <(node -e "console.log(require('./plugin/docs/CORE_RULES.md'))") \
     <(grep -A 100 "ZEPH_CORE =" cli/src/templates.ts)

# Update version & changelog
npm version patch
```

## Migration Status

- ✅ CORE_RULES.md created (single source)
- ✅ zeph-setup.js reads from CORE_RULES.md at runtime
- ⏳ CLAUDE.md — needs review for mirroring vs. referencing
- ⏳ SKILL.md — needs review for mirroring vs. referencing
- ⏳ cli/src/templates.ts — needs sync during next release
- ✅ lint-rules-sync.js script added for validation

## Example: Adding a New Rule

1. Edit `CORE_RULES.md`:
   ```markdown
   ## Two-Way Mode
   
   ### [New Section]
   
   12. New rule text here...
   ```

2. The next Claude Code session will automatically inject the updated rule.

3. Update CLAUDE.md to reference it:
   ```markdown
   See Rule 12 in [CORE_RULES.md](../docs/CORE_RULES.md)
   ```

4. Update SKILL.md similarly.

5. Before next release, sync cli/src/templates.ts:
   ```typescript
   const ZEPH_CORE = `
   ...
   12. New rule text here...
   `;
   ```

## Files Modified

- **Created**: `plugin/docs/CORE_RULES.md` (authoritative rules)
- **Created**: `plugin/scripts/lint-rules-sync.js` (validation script)
- **Created**: `plugin/docs/RULES-SYNC.md` (this file)
- **Modified**: `plugin/hooks/zeph-setup.js` (now reads CORE_RULES.md)

## Next Steps

1. Test that zeph-setup.js properly reads and injects rules
2. Update CLAUDE.md to reference CORE_RULES.md instead of duplicating
3. Update SKILL.md similarly
4. During next release: sync cli/src/templates.ts with CORE_RULES.md
5. Add CI check: `npm run lint:rules-sync` (exit 1 if divergence detected)
