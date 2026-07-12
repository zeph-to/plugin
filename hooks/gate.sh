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
#   pushmode          — quiet | loud | anything else = normal
# Prints exactly one of: "push high" | "push normal" | "silent".
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
zeph_state_present() {
    if [ -f "$ZEPH_STATE_DIR/$1-$2" ]; then
        echo "$ZEPH_STATE_DIR/$1-$2"
    elif [ -f "/tmp/zeph-$1-$2" ] && [ -O "/tmp/zeph-$1-$2" ]; then
        echo "/tmp/zeph-$1-$2"
    else
        return 1
    fi
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
