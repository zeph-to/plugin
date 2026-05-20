---
name: zeph-config
description: >
  Configure Zeph API key and Hook ID for cross-device notifications and
  remote control. Guides through key creation, environment variable setup,
  and verification.
metadata:
  author: zeph-to
  version: "0.5.0"
---

Help the user set up Zeph. Follow these steps:

1. Check whether `ZEPH_API_KEY` is already set (`echo $ZEPH_API_KEY`). If set,
   send a `zeph_notify` test push to confirm the key works.

2. If not set, guide them:
   - Go to Zeph web app → Settings → API Keys
   - Create a key with the "MCP" preset (includes push:read, push:write,
     hook:write, channel:read)
   - Copy the key (starts with `ak_...`)

3. Ask if they want **remote two-way control** (tap a button on phone to
   steer the session via `zeph_ask` / `zeph_prompt` / `zeph_input`):
   - If yes: Settings → Developer → Hooks → Create Hook
   - Set hookType to "interactive"
   - Copy the Hook ID (starts with `hook_...`)

4. Persist the env vars in their shell profile:
   ```bash
   export ZEPH_API_KEY="ak_..."
   export ZEPH_HOOK_ID="hook_..."  # optional, enables remote two-way control
   ```

5. Reload and verify: `source ~/.zshrc && echo $ZEPH_API_KEY`.

6. Send a test notification using `zeph_notify` to confirm end-to-end delivery.

7. Restart Claude Code / Cursor / etc. so the SessionStart hook picks up the
   new env vars and injects the Zeph remote-control rules into the session.
