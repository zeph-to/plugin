# Plugin tests

Fixture-based tests for the bash hooks under `hooks/`. No external test
framework — plain bash with a small assert helper. The hook itself
requires `jq` and `python3`; the tests inherit the same requirements.

## Running

```bash
# From the repo root
bash tests/test-zeph-stop.sh
```

Exits 0 when all tests pass, non-zero otherwise. CI runs it on every PR
via `.github/workflows/test.yml`.

## What's covered

The tests target scenarios that broke in the 0.5.0–0.5.3 hotfix cycle —
each one would have failed before the corresponding fix landed:

| Test | Catches |
|------|---------|
| `string-content system message doesn't crash jq` | The 0.5.1 hotfix — every real Claude Code transcript starts with a system message whose `.content` is a string, not an array. Earlier `map(.type)` calls crashed on it. |
| `subagent transcript silenced` | The 0.5.2 hotfix — Claude Code fires the Stop hook for sub-agent terminations too. |
| `observer transcript silenced` | The 0.5.2 hotfix — claude-mem and other observer-style plugins spin up Claude sessions whose Stop event also fires our hook. |
| `multi-turn scoping respects the LAST real user turn` | The 0.5.1 jq scoping change. Older grep-based counts leaked across turns. |
| `long Korean summary >512B triggers CLI file-upload path` | The 0.5.3 hotfix — earlier 280-char trim collapsed summaries below the CLI's 512-byte threshold, suppressing file attachment. |
| `empty SUMMARY falls back to default body` | Safety-net that 0.5.3 amend re-added. |
| `body stays under 15000-byte safety cap` | The 5000-codepoint upper bound, matching 0.4.0 behavior. |
| `1-tool turn stays silent` | The basic `TOOL_COUNT < 2` gate. |
| `turn with zeph_ask silenced` | The basic dedup that lets `zeph_ask` replace the Stop push. |
| `muted project skips push` | The `/tmp/zeph-muted-<hash>` opt-out. |

## Fixtures

JSONL transcripts in `fixtures/` match the shape Claude Code writes —
JSONL, one event per line, `.message.content` either an array of content
blocks (real interactive turns) or a string (system prompts). The
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
