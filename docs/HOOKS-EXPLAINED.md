# Zeph Hooks — Deep Dive

How the four Claude Code hooks work, what they do, and how to debug them.

---

## Overview

The plugin installs 4 hooks that fire automatically on Claude Code events:

| Hook | Event | File | Purpose |
|------|-------|------|---------|
| **SessionStart** | Session begins | zeph-setup.js | Inject behavioral rules into context |
| **Stop** | Response ends | zeph-stop.sh | Send completion notification if work was done |
| **PreToolUse** (Ask) | Before AskUserQuestion | zeph-ask.sh | Send notification when Claude asks user a question |
| **UserPromptSubmit** | Prompt submitted | zeph-remote.sh | Flag phone-sent messages, and hold sticky REMOTE mode across later turns (ADR-0002) |

---

## SessionStart Hook (zeph-setup.js)

**What it does:**
- Runs once at the start of every Claude Code session
- Reads `CORE_RULES.md` to check configuration
- Injects behavioral rules into the session context
- Emits JSON output (not stdout) so the rules land in Claude's context, not just the user's transcript

**When it runs:**
- Every time you start Claude Code (`claude` command)
- Once per session (does not re-run mid-session)

**What it injects:**
- If `ZEPH_API_KEY` is set: rules for two-way or one-way mode (depending on `ZEPH_HOOK_ID`)
- If `ZEPH_API_KEY` is NOT set: helper message suggesting `npx @zeph-to/cli setup`

**Example output:**

```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "# Zeph — Remote-Control Rules (active every response)\n\nZeph lets the user drive this session from their phone...\n[full rules from CORE_RULES.md]"
  }
}
```

**Debugging:**

Check if rules are injected:
```bash
# Look at the end of your first Claude response — the rules should appear
# in the system context (not user-visible unless you ask)
grep -i "remote-control" ~/.claude/transcripts/latest.jsonl
```

If rules are missing:
```bash
# Verify CORE_RULES.md exists and is readable
ls -la /path/to/plugin/docs/CORE_RULES.md

# Check if config file is readable
ls -la ~/.zeph/config.json
echo $ZEPH_API_KEY
```

---

## Stop Hook (zeph-stop.sh)

**What it does:**
- Fires after every Claude Code response
- Decides whether to push using a layered gate (most-specific first):
  1. **Muted** (`/zeph-mute`) → always silent
  2. **Push mode** (user dial): `/zeph-quiet` → push only on a `high` marker;
     `/zeph-loud` → push every turn; `/zeph-normal` (default) → fall through.
     Read from this project's dial file, else the machine-wide default written
     by `--global` (e.g. `/zeph-quiet --global`), else normal
  3. **Push Signal marker** the model may emit in its response —
     `<!-- zeph: skip -->` suppress, `<!-- zeph: push -->` force, `<!-- zeph: high -->`
     force + high priority (the marker is stripped from the push body)
  4. **Volume heuristic** (no marker): push only if ≥ 2 tool calls AND not all
     read-only (Read/Grep/Glob); otherwise stay silent (avoids exploration spam)
- Skips notification if the response already sent a `zeph_ask`/`zeph_prompt`
  (that already notified — no double-push; a `push`/`high` marker can't override this)

**When it runs:**
- After every response Claude makes
- But also after sub-agent sessions (Task tool) and observer sessions (claude-mem)

**Filtering logic:**

The hook is smart about WHAT to count:

1. **Project scope**: Only looks at the main interactive transcript
   - Skips sub-agent transcripts (`*/subagents/*`)
   - Skips background observer sessions (`*observer*`)
   - Result: Only notifies when the USER's main turn ends, not internal tool calls

2. **Tool call scope**: Counts from the last REAL user message
   - "Real user message" = user typed something (string content)
   - NOT a tool_result (array of blocks, no text)
   - Result: Counts only work done SINCE the user's last input

3. **Mute check**: Skips if project is muted
   - Checks for `${XDG_STATE_HOME:-~/.local/state}/zeph/muted-{hash}` (legacy
     `/tmp/zeph-muted-{hash}` still honored when owned by the current user)
   - Hash = `cksum(project-dir)`
   - Result: `/zeph-mute` command silences notifications

**Example execution flow:**

```
User types: "build and commit"
  ↓
Claude runs: [call tool 1] [call tool 2] → response "Built and committed."
  ↓
Stop hook fires:
  1. Check mute file → not muted ✓
  2. Check push mode → normal (no project dial, no --global default) ✓
  3. Check jq installed → yes ✓
  4. Read transcript; find last real user message (index N)
  5. Count zeph_ask calls → 0 (no duplicate) ✓
  6. Read the Push Signal marker → none
  7. Count tool_use from index N → 2 tools, ≥1 non-read-only ✓
  8. Run: `zeph notify --title "Task done" --body "build · main"`
  ↓
User gets push on phone: "Task done — build · main"
```

**Debugging:**

Check if tool count is correct:
```bash
# Manually count tool_use entries in your transcript
tail -20 ~/.claude/transcripts/latest.jsonl | grep '"type":"tool_use"' | wc -l

# Should be ≥ 2 for a notification to fire
```

Check if jq is installed:
```bash
command -v jq && echo "✓ jq installed" || echo "✗ jq missing (install: brew install jq)"
```

Check if mute file exists:
```bash
HASH=$(printf '%s' "$(pwd)" | cksum | cut -d' ' -f1)
ls -la "${XDG_STATE_HOME:-$HOME/.local/state}/zeph/muted-$HASH"

# If file exists, notifications are silenced. Remove to unmute:
# rm "${XDG_STATE_HOME:-$HOME/.local/state}/zeph/muted-$HASH"
```

Test the hook manually:
```bash
# Simulate what the hook does (count tools since last real user message)
jq -r '.[] | select(.role=="assistant") | .message.content? // empty' \
  ~/.claude/transcripts/latest.jsonl | tail -1 | grep -o '"type":"tool_use"' | wc -l
```

**Why sometimes silent:**
- Tool count < 2, or all tools were read-only (Read/Grep/Glob), with no marker
- The response emitted a `<!-- zeph: skip -->` Push Signal
- Push mode is `/zeph-quiet` and the turn had no `high` marker — set for this
  project, or inherited from a `/zeph-quiet --global` default (`/zeph-status`
  says which)
- jq not installed (hook exits early)
- Project is muted (`/zeph-mute` was run)
- Mute file still exists (stale from previous session)
- Response already sent a `zeph_ask` (Stop hook deduplicates)

---

## Ask Hook (zeph-ask.sh)

**What it does:**
- Fires when Claude calls `AskUserQuestion` tool
- Extracts the question text from the tool call
- Sends it as a push notification via the CLI
- User must answer at the terminal (can't answer from phone)

**When it runs:**
- Only when Claude explicitly calls `AskUserQuestion`
- Not automatic (depends on Claude's behavior)

**Example flow:**

```
Claude thinks: "I need to ask the user to choose between A and B"
  ↓
Claude calls: AskUserQuestion({ prompt: "Choose A or B?" })
  ↓
PreToolUse hook fires (before the tool actually executes):
  1. Extract the question: "Choose A or B?"
  2. Run: `zeph notify --title "Claude question" --body "Choose A or B?"`
  ↓
User gets push on phone
  ↓
User switches to terminal and answers the question locally
```

**Debugging:**

Check if tool was called:
```bash
# Look for AskUserQuestion in the transcript
grep -i "askyserquestion" ~/.claude/transcripts/latest.jsonl
```

Check the notification was sent:
```bash
# List recent pushes
zeph list --limit 5
```

Check for errors:
```bash
# If the hook silently failed, check:
# 1. Is zeph CLI installed? 
command -v zeph || echo "npx -y @zeph-to/cli" 

# 2. Is ZEPH_API_KEY set?
echo $ZEPH_API_KEY

# 3. Is the project muted?
HASH=$(printf '%s' "$(pwd)" | cksum | cut -d' ' -f1)
ls "${XDG_STATE_HOME:-$HOME/.local/state}/zeph/muted-$HASH"
```

---

## Remote-Origin Hook (zeph-remote.sh)

**What it does (ADR-0002):** two jobs — entering REMOTE, and staying there.

*Entry:*
- Fires on every prompt submit, and enters REMOTE only when the prompt matches
  a marker the `zeph listener` wrote as it injected a phone message into this
  project's tmux pane
- Match = same project (cksum of dir) + fresh (≤15 min) + byte-identical
  sha256 of the trimmed text — a terminal keystroke can never false-match
- On match: consumes the marker (one-shot), records the mode in the state file
  below, and injects context telling the model the user is remote → sticky
  REMOTE mode (every response ends with an answerable `zeph_ask`)
- Without `ZEPH_HOOK_ID`: one-way variant — tells the model to make the
  Stop-hook push self-contained and mention `npx @zeph-to/cli setup` once. No
  state is recorded: without `zeph_ask` there is no mode to stay in

*Staying there:*
- The marker is one-shot, but REMOTE is not. A user who answers from the phone
  and then types at the terminal produces turns with no marker and no
  `zeph_ask` result — the mode used to run out of evidence exactly there
- So every later prompt re-reads the state file and re-states the mode in one
  sentence. Living in a file is also what makes it survive context compaction,
  which is what Rule 13 promises
- Mute still outranks both jobs, and neither ever blocks a prompt (always
  exit 0, including on state-file IO failure)

**Marker file** — entry signal, written by cli `listener.ts`, consumed here:

```
${XDG_STATE_HOME:-$HOME/.local/state}/zeph/remote-<hash>
content: "<epochSeconds> <sha256hex-of-trimmed-text>\n"
```

**State file** — the mode itself, written and read here (`gate.sh`
`zeph_remote_active` / `zeph_remote_touch`; TS twin `cli/src/gate.ts`):

```
${XDG_STATE_HOME:-$HOME/.local/state}/zeph/remote-active-<hash>
content: "<epochSeconds it was last confirmed>\n"
```

It expires 4 hours after its last refresh, and every phone prompt or answered
`zeph_ask` refreshes it. The TTL is the only thing that ends a session nobody
exited: there is no SessionEnd hook, so without it a crash would leave REMOTE
latched and later sessions in this project would keep asking an absent phone.

**Example flow:**

```
User (on phone) sends "fix the login bug" via agent chat
  ↓
listener injects into tmux pane + writes remote-<hash> marker
  ↓
Claude Code submits the prompt → UserPromptSubmit hook fires:
  1. marker exists, fresh, sha256 matches → rm marker
  2. write remote-active-<hash>
  3. emit additionalContext: "user is remote → sticky REMOTE mode"
  ↓
Claude does the work, ends the response with zeph_ask
  ↓
User answers with a button tap — the loop continues from the phone
  ↓
...later the user types at the terminal instead. No marker, no zeph_ask
result — but remote-active-<hash> is still live, so the hook emits:
  "still in sticky REMOTE mode — end this response with zeph_ask"
```

**Debugging:**

```bash
# Is a marker present for this project?
HASH=$(printf '%s' "$(pwd)" | cksum | cut -d' ' -f1)
cat "${XDG_STATE_HOME:-$HOME/.local/state}/zeph/remote-$HASH"

# Verify what the hook would compute for a given prompt
printf '%s' "fix the login bug" | shasum -a 256

# Requires the cli listener new enough to write markers (release order:
# cli ships first) and jq on PATH; without either the hook no-ops.
```

---

## Full Event Timeline

Here's what happens during a typical Claude Code session:

```
TimelineEvent                            | Hook      | Output
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. $ claude (start session)              | START     | Rules injected into context
2. User types: "fix bug in X.ts"         |           | (no hook)
3. Claude responds + calls 2 tools       | STOP      | Push: "Task done — fix · main"
4. $ (user reads push on phone)          |           | (no hook)
5. User types: "actually, also Y too"   |           | (no hook)
6. Claude calls AskUserQuestion          | ASK       | Push: "Claude question: deploy now?"
7. (user sees phone push)                |           | (no hook)
8. User answers at terminal              |           | (no hook)
9. Claude processes answer + runs tools  | STOP      | Push: "Task done — deploy · main"
10. User types: "done" → Claude exits    | STOP      | (exit, no push — hook sees 0 tools)
```

---

## Common Issues & Fixes

| Issue | Cause | Fix |
|-------|-------|-----|
| No notifications at all | `jq` not installed | `brew install jq` (macOS) or `apt install jq` (Linux) |
| Duplicate notifications | zeph_ask was called + Stop hook fired | Claude is following rules correctly; Ask loop working |
| Notifications muted | `/zeph-mute` was run | Run `/zeph-unmute` to re-enable |
| Question notifications missing | Claude didn't call AskUserQuestion | Check: is Claude asking plainly instead? (rule violation) |
| Wrong project name in push | `CLAUDE_PROJECT_DIR` not set | Set env var or hooks use `git rev-parse --show-toplevel` |

---

## Testing Hooks Offline

You can test the logic without running Claude Code:

```bash
# Test zeph-stop.sh: count tools in a sample transcript
echo '{"type":"tool_use"}{"type":"tool_use"}' | jq . | grep tool_use | wc -l

# Test zeph-ask.sh: extract question from tool call
echo '{"type":"tool_use","name":"AskUserQuestion","input":{"prompt":"Test?"}}' | jq '.input.prompt'

# Test mute check
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zeph"; mkdir -p "$STATE_DIR"
HASH=$(printf '%s' "." | cksum | cut -d' ' -f1)
touch "$STATE_DIR/muted-$HASH" && echo "✓ Mute file created"
[ -f "$STATE_DIR/muted-$HASH" ] && echo "✓ Mute check works"
rm "$STATE_DIR/muted-$HASH"
```

---

## Extending Hooks

To add custom behavior (e.g., call an external API, log to file):

1. **Do NOT modify** `zeph-stop.sh` or `zeph-ask.sh` directly (they're from the plugin)
2. **Instead**, add a custom hook in your project's `.claude/hooks/` directory
3. **Example**: Create `~/.claude/hooks/stop.sh` in YOUR project to run alongside the plugin hook

Plugin hooks + custom hooks both fire in order.

---

**Last updated**: 2026-06-26
**Relevant**: All Zeph users experiencing hook issues or debugging notifications
