# Shared hook library — sourced by zeph-stop.sh and zeph-ask.sh, no shebang,
# no exit. Two halves, mirroring cli/src/gate.ts:
#   1. zeph_gate_decide — the pure decision function (vector-locked, below)
#   2. state-file resolution + CLI bounding helpers (mirrored by convention)
#
# This is the PORTABLE half of the Stop hook: a pure function from turn facts
# to a push verdict. Its semantics are locked to cli/src/gate.ts (@zeph-to/cli)
# by the shared vector file tests/fixtures/gate-vectors.json — both this bash
# implementation and the TS twin run the exact same cases in CI, so a change
# to one that isn't mirrored in the other fails a build. Edit semantics ONLY
# together with the vectors.
#
# zeph_gate_decide <tool_count> <nonreadonly_count> <already_asked> <marker> <pushmode>
#   tool_count        — total tool_use blocks this turn
#   nonreadonly_count — tools that are NOT read-only (Read/Grep/Glob)
#   already_asked     — count of zeph_ask/zeph_prompt this turn (>0 = notified)
#   marker            — skip | push | high | anything else = none
#   pushmode          — quiet | loud | anything else (incl. missing) = normal
# Prints exactly one of: "push high" | "push normal" | "silent".
#
# This function decides NOTHING about what an install with no dial gets — that
# is zeph_read_pushmode's job, below. Keeping it out of here is what lets the
# vector file stay a complete contract: every input this function accepts, the
# TS twin's decidePush answers identically, so any case can become a vector.
#
# Ordering is contractual (encoded as named vectors):
#   1. already_asked wins over EVERYTHING — even loud (dedup beats the dial).
#   2. priority is high iff marker=high, decided BEFORE the mode switch, so
#      quiet+high and loud+high both push at high priority.
#   3. quiet → only a high marker pushes; loud → always push; normal → marker
#      overrides the heuristic (skip → silent, push/high → push), no marker →
#      push iff tool_count ≥ 2 AND nonreadonly_count > 0 (B1 read-only floor).
zeph_gate_decide() {
    local tool_count="${1:-0}" nonreadonly_count="${2:-0}" already_asked="${3:-0}"
    local marker="${4:-none}" pushmode="${5:-normal}"

    [ "$already_asked" -gt 0 ] 2>/dev/null && { echo "silent"; return 0; }

    local priority="normal"
    [ "$marker" = high ] && priority="high"

    case "$pushmode" in
        quiet)
            [ "$marker" = high ] || { echo "silent"; return 0; }
            ;;
        loud) : ;;
        *)
            case "$marker" in
                skip) echo "silent"; return 0 ;;
                high|push) : ;;
                *)
                    [ "$tool_count" -lt 2 ] 2>/dev/null && { echo "silent"; return 0; }
                    [ "$nonreadonly_count" -eq 0 ] 2>/dev/null && { echo "silent"; return 0; }
                    ;;
            esac
            ;;
    esac

    echo "push $priority"
}

# ── AskUserQuestion routing (zeph-ask.sh) ────────────────────────────────────
#
# CORE_RULES rules 10/11 say a button-friendly question must go through
# `zeph_ask` rather than the local AskUserQuestion picker, and carve out two
# cases where the picker is still right: the answer needs code or logs that
# won't fit a push body (a), or the answer is plausibly multi-paragraph (b).
# Until now that rule lived only in prose, so breaking it failed silently.
# This function is the machine reading of it: `deny` means the PreToolUse hook
# blocks the picker and hands the model the same question to re-ask through
# `zeph_ask`, `allow` means the picker opens as before.
#
# zeph_ask_decide <hookid_present> <muted> <has_preview> <question_chars> <option_chars> <replay>
#   hookid_present — 1 when ZEPH_HOOK_ID is set (two-way tools exist)
#   muted          — 1 when this project is muted
#   has_preview    — 1 when any option carries a `preview` block
#   question_chars — length of the question stem
#   option_chars   — longest label+description across the options
#   replay         — 1 when this exact question was denied moments ago
# Prints exactly one of: "deny" | "allow".
#
# ALLOW IS THE SAFE DIRECTION and every uncertain input must reach it. A wrong
# `allow` costs the user one trip to the terminal; a wrong `deny` can leave a
# session with no way to ask anything at all. Hence: no hook id → allow (there
# are no two-way tools to route to), muted → allow (routing to `zeph_ask` would
# push around the mute the user set), unparseable numbers → 0 → allow via the
# hookid check.
#
# `replay` outranks everything. If the model cannot reach `zeph_ask` — MCP
# server down, tool not exposed — it will retry AskUserQuestion, and a second
# deny would trap the session. The retry gets through instead.
#
# The two limits are the carve-outs made countable. They are deliberately
# generous: the question is whether the text still fits a phone notification,
# not whether it is short.
ZEPH_ASK_MAX_QUESTION_CHARS=400
ZEPH_ASK_MAX_OPTION_CHARS=240

zeph_ask_decide() {
    local hookid="${1:-0}" muted="${2:-0}" has_preview="${3:-0}"
    local question_chars="${4:-0}" option_chars="${5:-0}" replay="${6:-0}"

    [ "$replay" = 1 ]      && { echo allow; return 0; }
    [ "$hookid" != 1 ]     && { echo allow; return 0; }
    [ "$muted" = 1 ]       && { echo allow; return 0; }
    [ "$has_preview" = 1 ] && { echo allow; return 0; }

    # Anything non-numeric means the measurement failed, and a failed
    # measurement must not become a deny: `[ x -gt 400 ]` errors, the `&&`
    # below never fires, and control would fall through to deny — the one
    # direction this function is not allowed to guess in.
    case "$question_chars$option_chars" in
        ''|*[!0-9]*) echo allow; return 0 ;;
    esac

    [ "$question_chars" -gt "$ZEPH_ASK_MAX_QUESTION_CHARS" ] && { echo allow; return 0; }
    [ "$option_chars" -gt "$ZEPH_ASK_MAX_OPTION_CHARS" ] && { echo allow; return 0; }

    echo deny
}

# ── Per-project state + CLI bounding (shared by both hooks) ──────────────────

# Mute/push-mode/auto state lives under a per-user dir. It used to sit at
# predictable names in world-writable /tmp, where any local user could
# pre-create a victim's mute file (sticky /tmp makes it un-deletable by the
# victim). Legacy /tmp files are honored during migration, but only when
# owned by the current user (-O), which neutralizes planted files. The TS
# twin is cli/src/gate.ts findStateFile — keep them behaviorally in sync.
ZEPH_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zeph"

# zeph_state_present <kind> <hash> — kind is muted|pushmode|auto. Echoes the
# live state-file path, rc 1 if none.
#
# `pushmode` alone has a machine-wide default (`pushmode-default`, written by
# `/zeph-quiet --global`), consulted last so a per-project dial always wins.
# `cksum` emits digits only, so `-default` can never collide with a real hash.
# Mute is deliberately project-only: a global mute file would have no way to be
# lifted for one project (presence, not content, is the signal), and a global
# `quiet` already covers "stop the routine pushes everywhere".
zeph_state_present() {
    if [ -f "$ZEPH_STATE_DIR/$1-$2" ]; then
        echo "$ZEPH_STATE_DIR/$1-$2"
    elif [ -f "/tmp/zeph-$1-$2" ] && [ -O "/tmp/zeph-$1-$2" ]; then
        echo "/tmp/zeph-$1-$2"
    elif [ "$1" = pushmode ] && [ -f "$ZEPH_STATE_DIR/pushmode-default" ]; then
        echo "$ZEPH_STATE_DIR/pushmode-default"
    else
        return 1
    fi
}

# Push mode for an install that has never set a dial. The TS twin is
# cli/src/gate.ts PUSHMODE_DEFAULT — the vector file cannot lock this, because
# neither side's pure decision function is where it lives, so both sides pin it
# in their own tests.
ZEPH_PUSHMODE_DEFAULT=quiet

# zeph_read_pushmode <hash> — the effective dial for a project. The bash twin of
# cli/src/gate.ts readPushMode; keep them behaviorally in sync.
#
# Three failure shapes, and only one of them gets the quiet default:
#   - no hash (cksum unavailable, so no state file can be keyed) → normal
#   - no dial file anywhere                                      → the default
#   - a dial that is empty, unreadable, or not one of the three
#     recognised words                                           → normal
# The two `normal` rows are the same judgment: a broken setting is not an
# expression of intent, and resolving breakage to silence leaves the user with
# the one symptom they cannot tell apart from working correctly. The TS twin
# reaches the same answers — `if (!hash) return 'normal'` and
# `normalizePushMode`, which maps both '' and garbage to normal.
zeph_read_pushmode() {
    local hash="$1" file mode
    [ -n "$hash" ] || { echo normal; return 0; }
    file=$(zeph_state_present pushmode "$hash") || { echo "$ZEPH_PUSHMODE_DEFAULT"; return 0; }
    mode=$(tr -d '[:space:]' < "$file" 2>/dev/null)
    case "$mode" in
        quiet|loud|normal) echo "$mode" ;;
        *)                 echo normal ;;
    esac
}

# ── AskUserQuestion replay markers ───────────────────────────────────────────
#
# A deny is only safe if the same question can get through on its next try —
# see `replay` in zeph_ask_decide. These two record and read that fact.
#
# The key must be the whole tool_input, not the question stem: "Proceed?" and
# "Continue?" recur constantly within one session, so hashing the stem would
# make unrelated questions collide and silently allow the second one.
#
# The window separates a retry from a legitimate repeat. A model that cannot
# reach `zeph_ask` retries within seconds; a user genuinely being asked the same
# thing again is minutes away. 60 seconds sits between the two.
#
# The timestamp lives in the file's CONTENTS rather than its mtime: `stat` takes
# different flags on macOS and GNU, and `find -newermt` isn't portable either.
# Reading an integer we wrote ourselves works the same everywhere.
ZEPH_ASK_REPLAY_WINDOW_SEC=60

# zeph_ask_now — epoch seconds. Bash 5 has it as a builtin; older bash (macOS
# ships 3.2 as /bin/bash) falls back to the `date` binary.
zeph_ask_now() {
    if [ -n "${EPOCHSECONDS:-}" ]; then
        echo "$EPOCHSECONDS"
    else
        date +%s
    fi
}

# zeph_ask_replay_seen <key> — rc 0 when this question was denied recently.
#
# `key` is project-scoped by the caller, matching how every other state file
# here is keyed (`muted-<project>`, `pushmode-<project>`). Keying on the
# question alone would let a deny in one project allow the identical question
# in another — two sessions asking "Proceed?" within the window is ordinary.
zeph_ask_replay_seen() {
    local file="$ZEPH_STATE_DIR/askdeny-$1" stamp now
    stamp=$(cat "$file" 2>/dev/null) || return 1
    case "$stamp" in
        ''|*[!0-9]*) return 1 ;;
    esac
    now=$(zeph_ask_now)
    [ $((now - stamp)) -lt "$ZEPH_ASK_REPLAY_WINDOW_SEC" ] 2>/dev/null
}

# zeph_ask_replay_mark <key> — record that this question was just denied, and
# drop markers that have aged out.
#
# The sweep matters: every denied question leaves a file, and a marker is dead
# to `zeph_ask_replay_seen` the moment its window closes. Without it the state
# dir accretes one file per question forever. It runs here rather than on a
# timer because this is the only place that creates them, and the expiry test
# is the same integer compare — no `stat`, no `find -newermt`.
#
# Best-effort throughout: a state dir we cannot write means the next retry is
# denied too, which would trap that one session. That is worth neither failing
# the hook nor blocking on.
zeph_ask_replay_mark() {
    mkdir -p "$ZEPH_STATE_DIR" 2>/dev/null || return 0
    local now file stamp
    now=$(zeph_ask_now)
    for file in "$ZEPH_STATE_DIR"/askdeny-*; do
        [ -f "$file" ] || continue
        stamp=$(cat "$file" 2>/dev/null)
        case "$stamp" in
            ''|*[!0-9]*) rm -f "$file" 2>/dev/null; continue ;;
        esac
        [ $((now - stamp)) -ge "$ZEPH_ASK_REPLAY_WINDOW_SEC" ] && rm -f "$file" 2>/dev/null
    done
    printf '%s\n' "$now" > "$ZEPH_STATE_DIR/askdeny-$1" 2>/dev/null || true
}

# zeph_wrap_timeout <cmd> — bound a CLI invocation below the 10s hooks.json
# cap, so a cold `npx -y` resolve or a hung network can't eat the whole hook
# budget. macOS ships no `timeout` in the base system (gtimeout comes from
# coreutils); with neither present the hooks.json cap is the only bound.
zeph_wrap_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        echo "timeout 8 $1"
    elif command -v gtimeout >/dev/null 2>&1; then
        echo "gtimeout 8 $1"
    else
        echo "$1"
    fi
}
