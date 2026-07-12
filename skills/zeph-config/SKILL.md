---
name: zeph-config
description: >
  Configure Zeph API key and Hook ID for cross-device notifications and
  remote control. Guides through key creation, environment variable setup,
  and verification. Run this once during initial setup.
metadata:
  author: zeph-to
  version: "0.8.0"
  relatedSkills:
    - zeph
    - zeph-status
  triggers:
    - zeph-config
    - setup zeph
    - configure zeph
    - zeph setup
    - api key
    - hook id
    - remote control setup
    - cross-device notifications setup
    - /zeph-config
---

Help the user set up Zeph. Follow these steps **in order**; do not skip ahead.

1. Check whether `ZEPH_API_KEY` is already set: run `echo $ZEPH_API_KEY`.
   - If it prints a key → it's configured. Skip to step 6 (verify).
   - If empty → continue to step 2.

2. Guide them to create an API key:
   - Go to Zeph web app → Settings → API Keys
   - Create a key with the "MCP" preset (includes push:read, push:write,
     hook:write, channel:read)
   - Copy the key (starts with `ak_...`)

3. **[Requires a user answer]** Ask whether they want **remote two-way control**
   (tap a button on their phone to steer the session). Use `zeph_ask` if
   `ZEPH_HOOK_ID` is already set; otherwise use `AskUserQuestion` (the phone
   can't drive the terminal until a Hook ID exists). Offer two options:
   "Two-way remote control" vs "Notifications only".
   - If they pick two-way: Settings → Developer → Hooks → Create Hook, set
     hookType to "interactive", copy the Hook ID (starts with `hook_...`).
   - If they pick notifications-only: skip the Hook ID (leave `ZEPH_HOOK_ID` unset).

4. Persist the env vars in their shell profile (`~/.zshrc` or `~/.bashrc`):
   ```bash
   export ZEPH_API_KEY="ak_..."
   export ZEPH_HOOK_ID="hook_..."  # only if they chose two-way control in step 3
   ```

5. Reload and verify: `source ~/.zshrc && echo $ZEPH_API_KEY`.

6. Send a test notification using `zeph_notify` to confirm end-to-end delivery.

7. Restart Claude Code / Cursor / etc. so the SessionStart hook picks up the
   new env vars and injects the Zeph remote-control rules into the session.

## If Things Go Wrong

**Problem**: "API key is invalid"
- **Check**: Is the key format correct? Should start with `ak_`
- **Fix**: Create a new key in Zeph Settings → API Keys, copy again carefully
- **Verify**: Run `zeph test` to confirm the key works

**Problem**: "zeph_ask times out" or no response
- **Check**:
  1. Is Zeph app open on your phone?
  2. Is ZEPH_HOOK_ID set? (run `echo $ZEPH_HOOK_ID`)
  3. Did you wait long enough? (default timeout: 120 seconds)
- **Fix**: 
  - If ZEPH_HOOK_ID is missing: go to Zeph Settings → Developer → Hooks, create one
  - If app not open: open the Zeph app on phone and try again
  - If still timing out: run `zeph test` to check API connection

**Problem**: "~/.zeph/config.json not found" or "Permission denied"
- **Check**: Does the file exist? `ls -la ~/.zeph/config.json`
- **Fix**: 
  - If missing: run `/zeph-config` again to recreate it
  - If permission denied: check file ownership `ls -la ~/.zeph/`
  - Owner should be you. If not: `sudo chown $USER ~/.zeph/*`

**Problem**: "Env vars not persisting after restart"
- **Check**: Did you edit the right shell profile? `cat ~/.zshrc` or `~/.bashrc`
- **Fix**:
  1. Open the correct profile file
  2. Add these lines:
     ```bash
     export ZEPH_API_KEY="ak_..."
     export ZEPH_HOOK_ID="hook_..."  # optional
     ```
  3. Save and close
  4. Restart terminal or run `source ~/.zshrc`
  5. Verify: `echo $ZEPH_API_KEY` (should print your key, not empty)

**Problem**: "No notification received after test"
- **Check**: Is jq installed? (required for hook notifications) `command -v jq`
- **Fix**: 
  - macOS: `brew install jq`
  - Linux: `apt install jq` or `yum install jq`
  - Then restart Claude Code

**Problem**: "Settings or Developer menu not visible in Zeph app"
- **Check**: Are you logged in to the Zeph app?
- **Fix**: 
  1. Tap avatar or settings icon in app
  2. Confirm you're logged in
  3. Settings should be visible
  4. If still missing: log out and log back in
