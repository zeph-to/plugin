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

# zeph_hook_decision <allow|deny> <reason> — emit a PreToolUse decision.
#
# One definition of the envelope. It was written out by hand in three places
# (the ask hook's deny, and both branches of the approval hook), so the field
# names lived in three places too and a fourth field would have had to be added
# to all of them without drifting.
#
# `jq -n --arg` does the escaping: a reason carries a user's question verbatim,
# quotes, newlines and all.
zeph_hook_decision() {
    jq -n --arg decision "$1" --arg reason "$2" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $decision, permissionDecisionReason: $reason}}' \
        2>/dev/null
}

# ── Per-project state + CLI bounding (shared by both hooks) ──────────────────

# Mute/push-mode/auto state lives under a per-user dir. It used to sit at
# predictable names in world-writable /tmp, where any local user could
# pre-create a victim's mute file (sticky /tmp makes it un-deletable by the
# victim). Legacy /tmp files are honored during migration, but only when
# owned by the current user (-O), which neutralizes planted files. The TS
# twin is cli/src/gate.ts findStateFile — keep them behaviorally in sync.
ZEPH_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zeph"

# zeph_state_present <kind> <hash> — kind is muted|pushmode|auto|remote. Echoes
# the live state-file path, rc 1 if none. (`remote` is the one-shot phone-origin
# marker the listener writes and zeph-remote.sh consumes — see ADR-0002.)
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

# ── Sticky REMOTE state ─────────────────────────────────────────────────────
#
# `remote-<hash>` above is a ONE-SHOT entry signal — zeph-remote.sh consumes it
# the moment a prompt matches. REMOTE outlives that turn, so the mode itself
# needs somewhere to live: `remote-active-<hash>`, holding the epoch second it
# was last confirmed. Keeping it in a file (rather than re-deriving it from the
# conversation) is what makes it survive context compaction.
#
# Deliberately NOT routed through zeph_state_present. That helper also honors a
# legacy /tmp copy, which exists so files written by older versions keep working
# — this kind has never had a /tmp writer, so the branch could only ever match
# something stale, and the refresh below always writes the XDG path, so such a
# file would never expire.
#
# The TTL exists because nothing owns "this session ended" — there is no
# SessionEnd hook — so a crash or Ctrl-C would otherwise latch REMOTE forever
# and every later session in the project would keep asking a phone nobody is
# holding. Four hours is generous on purpose: the file is refreshed on every
# phone prompt and every answered zeph_ask, so it only has to outlive a working
# session, never an idle user. The TS twin is cli/src/gate.ts REMOTE_TTL_SEC.
ZEPH_REMOTE_TTL=14400

zeph_remote_state_file() { echo "$ZEPH_STATE_DIR/remote-active-$1"; }

# zeph_remote_active <hash> — rc 0 while REMOTE is live for this project.
# Expired or unparseable state is deleted on sight, the same housekeeping a
# stale entry marker gets: state that can never flag again is dead weight.
zeph_remote_active() {
    local file ts
    file=$(zeph_remote_state_file "$1")
    [ -f "$file" ] || return 1
    read -r ts < "$file" 2>/dev/null || ts=""
    case "$ts" in '' | *[!0-9]*) rm -f "$file"; return 1 ;; esac
    if [ $(( $(date +%s) - ts )) -gt "$ZEPH_REMOTE_TTL" ]; then
        rm -f "$file"
        return 1
    fi
    return 0
}

# zeph_remote_touch <hash> — enter REMOTE, or push its expiry back. Always rc 0:
# a state dir that cannot be written must never fail the hook that called this.
zeph_remote_touch() {
    mkdir -p "$ZEPH_STATE_DIR" 2>/dev/null || return 0
    date +%s > "$(zeph_remote_state_file "$1")" 2>/dev/null || return 0
}

# zeph_remote_clear <hash> — leave REMOTE. Always rc 0, and an absent file is
# success: the callers are hooks that have their own job to finish.
zeph_remote_clear() {
    rm -f "$(zeph_remote_state_file "$1")" 2>/dev/null
    return 0
}

# zeph_wrap_timeout <cmd> — bound a CLI invocation below the 10s hooks.json
# cap, so a cold `npx -y` resolve or a hung network can't eat the whole hook
# budget. macOS ships no `timeout` in the base system (gtimeout comes from
# coreutils); with neither present the hooks.json cap is the only bound.
# ── Dangerous-command approval (zeph-approve.sh) ─────────────────────────────
#
# zeph_approve_needed <command> — rc 0 when this command should wait for the
# user's approval, rc 1 when it should just run.
#
# ⚠️ THIS IS A SPEED BUMP, NOT A SECURITY BOUNDARY. It matches text in a command
# string, so anything deliberately trying to get past it will
# (`r''m -rf`, a shell variable, a script that wraps the real call). What it
# actually protects against is the accident: an agent reaching for `rm -rf` or a
# prod deploy while the user is away from the terminal and would never have seen
# the confirmation. Do not describe it as a sandbox, and do not let its presence
# justify loosening anything that is one.
#
# The list is deliberately short. Gating everything trains people to approve
# without reading, which is worse than not gating at all; gating too little is
# theatre. These are the operations that are hard to undo:
#   1. recursive force delete
#   2. history/working-tree destruction (force push, hard reset, clean -fd)
#   3. anything that reaches deployed infrastructure
#   4. destructive database statements
zeph_approve_needed() {
    local cmd="$1"
    [ -n "$cmd" ] || return 1

    # Builtin pre-filter. This runs on EVERY Bash tool call, and without it an
    # ordinary `ls` pays for the whole grep chain below — a dozen forks to
    # conclude nothing matches. Every pattern further down contains one of these
    # keywords, so anything reaching the greps is at least plausible.
    # Written as character classes rather than `shopt -s nocasematch` because
    # gate.sh is SOURCED into the hooks: flipping a shell option here would
    # change matching for the rest of the calling script. Character classes are
    # also bash 3.2 safe (macOS /bin/bash), which `${cmd,,}` is not.
    case "$cmd" in
        *[Rr][Mm]*|*[Gg][Ii][Tt]*|*[Dd][Ee][Pp][Ll][Oo][Yy]*|*[Tt][Ee][Rr][Rr][Aa][Ff][Oo][Rr][Mm]*) ;;
        *[Dd][Rr][Oo][Pp]*|*[Tt][Rr][Uu][Nn][Cc][Aa][Tt][Ee]*|*[Dd][Ee][Ll][Ee][Tt][Ee]*|*[Ff][Ll][Uu][Ss][Hh]*) ;;
        *) return 1 ;;
    esac

    # 1. rm carrying BOTH recursive and force, however they are spelled.
    #    Collapsing every short flag into one string is what makes `-rf`,
    #    `-fr` and `-r -f` the same question instead of three patterns.
    #
    #    The hyphen goes LAST in the tr delete set. Written as ' -\n' it reads
    #    as a RANGE from space (0x20) to newline (0x0A) — reversed, so GNU tr
    #    aborts with "range-endpoints ... in reverse collating sequence order"
    #    and prints nothing. BSD tr takes the same three bytes literally, so on
    #    macOS it worked and on Linux `flags` came back empty and every
    #    `rm -rf` walked straight through this gate.
    if grep -Eqi '(^|[^[:alnum:]_./-])rm[[:space:]]' <<< "$cmd"; then
        local flags
        flags=$(sed -e 's/--recursive/-r/g' -e 's/--force/-f/g' <<< "$cmd" \
            | grep -Eo -- '(^|[[:space:]])-[[:alnum:]]+' \
            | tr -d ' \n-' | tr 'A-Z' 'a-z')
        case "$flags" in *r*f*|*f*r*) return 0 ;; esac
    fi

    # 2. Git operations that discard work or rewrite a published history.
    #    The second push alternative is NOT redundant with the first: `^` anchors
    #    to the start of the whole string, so once `push[[:space:]]` has eaten the
    #    only space, `-f`'s own `(^|[[:space:]])` branch has nothing left to match
    #    and bare `git push -f` slips through. Removing it fails a vector.
    grep -Eqi 'git[[:space:]]+push[[:space:]].*(--force|--force-with-lease|(^|[[:space:]])-f([[:space:]]|$))|git[[:space:]]+push[[:space:]]+-f([[:space:]]|$)|git[[:space:]]+reset[[:space:]]+--hard|git[[:space:]]+clean[[:space:]]+-[[:alnum:]]*[fd]' <<< "$cmd" && return 0

    # 3. Anything that reaches deployed infrastructure. The last alternative is a
    #    package script whose NAME says deploy (`yarn server:deploy:prod`), kept
    #    behind a runner prefix so `grep -rn deploy src/` is not a deploy.
    grep -Eqi '(^|[^[:alnum:]_-])(cdk|serverless|sls)[[:space:]]+deploy|(^|[^[:alnum:]_-])terraform[[:space:]]+(apply|destroy)|(^|[^[:alnum:]_-])(npm[[:space:]]+run|yarn|pnpm[[:space:]]+run|bun[[:space:]]+run)[[:space:]]+[[:alnum:]:_-]*deploy' <<< "$cmd" && return 0

    # 4. Statements that drop data rather than change it.
    grep -Eqi 'drop[[:space:]]+(table|database|schema)|truncate[[:space:]]+table|delete-table|flushall|flushdb' <<< "$cmd" && return 0

    return 1
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
        read -r stamp < "$file" 2>/dev/null || stamp=""
        case "$stamp" in
            ''|*[!0-9]*) rm -f "$file" 2>/dev/null; continue ;;
        esac
        [ $((now - stamp)) -ge "$ZEPH_ASK_REPLAY_WINDOW_SEC" ] && rm -f "$file" 2>/dev/null
    done
    printf '%s\n' "$now" > "$ZEPH_STATE_DIR/askdeny-$1" 2>/dev/null || true
}

# zeph_wrap_timeout <cmd> [seconds] — bound a CLI invocation below the calling
# hook's cap in plugin.json, so a cold `npx -y` resolve or a hung network can't
# eat the whole hook budget. macOS ships no `timeout` in the base system
# (gtimeout comes from coreutils); with neither present the plugin.json cap is
# the only bound.
#
# The bound is a parameter because the two callers have very different budgets:
# the ask hook has 10s and wants 8, while the approval hook deliberately waits
# on a human for over a minute. A single hardcoded 8 would have made the
# approval gate unwrappable — and an unwrapped CLI call there is not a slow
# hook, it is a SILENT ALLOW of the exact commands the gate exists to hold,
# because Claude Code fails open when it kills a hook.
zeph_wrap_timeout() {
    local seconds="${2:-8}"
    if command -v timeout >/dev/null 2>&1; then
        echo "timeout $seconds $1"
    elif command -v gtimeout >/dev/null 2>&1; then
        echo "gtimeout $seconds $1"
    else
        echo "$1"
    fi
}
