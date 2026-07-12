# Plugin tests

Fixture-based tests for the bash hooks under `hooks/`. No external test
framework — plain bash with a small assert helper. The hook itself
requires `jq` and `python3`; the tests inherit the same requirements.

## Running

```bash
# Run every suite
bash tests/run-all.sh

# Or one suite at a time
bash tests/test-zeph-stop.sh
bash tests/test-zeph-ask.sh
bash tests/test-zeph-remote.sh
```

Exits 0 when all tests pass, non-zero otherwise. CI runs `run-all.sh` on
every PR via `.github/workflows/test.yml`.

## What's covered

The tests target scenarios that broke in the 0.5.0–0.5.3 hotfix cycle —
each one would have failed before the corresponding fix landed:

| Test | Catches |
|------|---------|
| `string-content turn detection` | The 0.5.8 fix — current Claude Code logs typed user messages with `.message.content` as a string. The 0.5.1 crash guard turned strings into `[]`, so `is_real_user` stopped detecting real turns and `since_last_user` silently scoped every check to the whole transcript. |
| `legacy array-form user message` | `is_real_user` still matches the older array-of-blocks user-message shape (the `or` branch). |
| `off-by-one — turn-2 push must not leak turn-1 text` | The 0.5.8 fix — with turn detection broken, a Stop hook that fired before the final text flushed produced a push carrying the *previous* turn's answer. |
| `subagent transcript silenced` | The 0.5.2 hotfix — Claude Code fires the Stop hook for sub-agent terminations too. |
| `observer transcript silenced` | The 0.5.2 hotfix — claude-mem and other observer-style plugins spin up Claude sessions whose Stop event also fires our hook. |
| `multi-turn scoping respects the LAST real user turn` | Per-turn `TOOL_COUNT` must not leak across turns — regresses if string-content turn detection breaks. |
| `long Korean summary >512B triggers CLI file-upload path` | The 0.5.3 hotfix — earlier 280-char trim collapsed summaries below the CLI's 512-byte threshold, suppressing file attachment. |
| `empty SUMMARY falls back to default body` | Safety-net that 0.5.3 amend re-added. |
| `body stays under 15000-byte safety cap` | The 5000-codepoint upper bound, matching 0.4.0 behavior. |
| `1-tool turn stays silent` | The basic `TOOL_COUNT < 2` gate. |
| `turn with zeph_ask silenced` | The basic dedup that lets `zeph_ask` replace the Stop push. |
| `muted project skips push` | The `<stateDir>/muted-<hash>` opt-out (plus the user-owned legacy `/tmp` fallback). |
| `read-only floor stays silent` | The B1 floor — a turn whose tools are all Read/Grep/Glob is exploration noise and is suppressed. |
| `marker skip / push / high` | The Push Signal — `<!-- zeph: skip\|push\|high -->` overrides the heuristic (suppress / force / force+`--priority high`); the marker is stripped from the body. |
| `no-space + newline-split marker leak guard` | Detect and strip share one `[[:blank:]]`-based pattern, so a malformed marker can't be detected-but-not-stripped (no leak) and a newline-split marker is honoured by neither. |
| `push mode quiet / loud` | The `pushmode-<hash>` dial — quiet keeps only high pushes, loud pushes every turn (still respecting dedup), cleared restores the default. |

### zeph-ask.sh

| Test | Catches |
|------|---------|
| `single .tool_input.question` | The standard Claude Code AskUserQuestion shape. |
| `multi-question .tool_input.questions[0].question` | The newer AskUserQuestion format with parallel questions. |
| `no question field → 'Question pending' fallback` | Defends against schema changes. |
| `Korean ≤ 200 codepoints (UTF-8 safe)` | The python3 trim; old `head -c 200` cut mid-byte and produced mojibake. |
| `muted project skips push` | Same `<stateDir>/muted-<hash>` opt-out. |
| `title carries project basename` | Verifies CLAUDE_PROJECT_DIR plumbing. |
| `invalid JSON input doesn't crash` | `jq` errors are absorbed; fallback text still fires. |

### zeph-remote.sh (ADR-0002)

| Test | Catches |
|------|---------|
| `fresh marker + matching prompt → REMOTE context` | The happy path: additionalContext emitted, marker consumed one-shot. |
| `ZEPH_HOOK_ID unset → one-way conversion CTA` | The funnel branch — no two-way claim, `cli setup` mentioned. |
| `text mismatch → silent, marker kept` | The exact-hash guarantee: a terminal keystroke racing a phone message can't false-flag REMOTE. |
| `stale marker (>15 min) → silent, marker deleted` | The freshness window survives long mid-turn queueing; dead markers are cleaned up on sight. |
| `muted project → marker left unconsumed` | Mute outranks detection (Rule 12). |
| `whitespace-padded / multi-line / NBSP prompts` | Both sides trim the same explicit ASCII whitespace set (Unicode spaces like U+00A0 stay in the digest); multi-line bodies match byte-for-byte. |
| `malformed marker → silent, exit 0` | The hook must never block a prompt. |
| `legacy /tmp marker honored` | Same `zeph_state_present` resolution (user-owned legacy fallback) as every other state file. |

## Fixtures

JSONL transcripts in `fixtures/` match the shape Claude Code writes —
one event per line. `.message.content` is a **string** for typed user
messages and system prompts, and an **array of content blocks** for
assistant turns and tool results. (`main-array-user-2-tools.jsonl`
keeps the legacy array-wrapped user-message shape covered.) The
`gen-long-summary.sh` script regenerates the >512-byte Korean fixture
deterministically; the long fixture is also checked in so CI doesn't
need python3 at fixture-generation time (only at test-run time, which it
already needs for the trim helper).

## Adding tests

1. Write or generate a `.jsonl` fixture under `fixtures/`.
2. In `test-zeph-stop.sh` add a `run_hook` + `assert` / `assert_not`
   block describing the expected behaviour.
3. Run the suite locally before pushing.

Keep one fixture per scenario rather than reusing — readability beats
DRY for transcripts, since the failure mode is usually "this exact
shape of input".
