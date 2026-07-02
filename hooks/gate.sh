# Push-gate decision function — sourced by zeph-stop.sh, no shebang, no exit.
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
