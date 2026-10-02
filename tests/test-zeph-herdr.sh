#!/usr/bin/env bash
# Fixture-based tests for hooks/zeph-herdr.sh.
#
# `tmux` and `herdr` are stubs: tmux answers the session's herdr options from
# $OPTS, herdr appends its argv to a log. The rows that matter most are the
# no-op ones — outside tmux, outside herdr, a tool call that changes nothing —
# because the hook runs on every tool call of every session.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/zeph-herdr.sh"
[ -f "$HOOK_SCRIPT" ] || { echo "hook script not found: $HOOK_SCRIPT" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STUB_DIR="$WORK/stub"
LOG="$WORK/herdr.log"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/tmux" <<'EOF'
#!/bin/bash
printf '%b\n' "$OPTS"
EOF
cat > "$STUB_DIR/herdr" <<EOF
#!/bin/bash
echo "\$HERDR_SOCKET_PATH \$*" >> "$LOG"
EOF
chmod +x "$STUB_DIR/tmux" "$STUB_DIR/herdr"

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()
check() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then echo "  ✓ $desc"; PASS=$((PASS + 1));
    else echo "  ✗ $desc"; echo "      expected: $expected"; echo "      actual:   $actual"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc"); fi
}

IN_HERDR="wF:p1\t/sock\t$STUB_DIR/herdr"

# Run the hook, then wait for the detached herdr call (or give up quietly).
run() {
    local before after i
    before=$(wc -l < "$LOG")
    echo '{}' | env PATH="$STUB_DIR:/usr/bin:/bin" CLAUDE_CODE_ENTRYPOINT="${CLAUDE_CODE_ENTRYPOINT:-cli}" TMPDIR="$WORK/tmp" TMUX="${T-/tmp/tmux,1,0}" TMUX_PANE="${P:-%1}" OPTS="$OPTS" \
        bash "$HOOK_SCRIPT" "$1"
    for i in $(seq 1 20); do
        after=$(wc -l < "$LOG")
        [ "$after" -gt "$before" ] && break
        sleep 0.05
    done
}
last() { tail -1 "$LOG" | sed -E 's/--seq [0-9]+/--seq N/'; }
calls() { wc -l < "$LOG" | tr -d ' '; }
reset() { rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"; : > "$LOG"; }

echo "no-ops"
reset
OPTS="$IN_HERDR" T='' run working
check "outside tmux: nothing sent" 0 "$(calls)"
OPTS="\t\t" run working
check "tmux session without herdr options: nothing sent" 0 "$(calls)"
OPTS="$IN_HERDR" run tool
check "tool call with nothing blocked: nothing sent" 0 "$(calls)"
CLAUDE_CODE_ENTRYPOINT=sdk-cli OPTS="$IN_HERDR" run start
check "headless claude -p in the pane: nothing sent" 0 "$(calls)"

echo "lifecycle"
reset
OPTS="$IN_HERDR" run start
check "start claims the pane as idle" "/sock pane report-agent wF:p1 --source zeph --agent zeph cc --state idle --seq N" "$(last)"
OPTS="$IN_HERDR" run working
check "prompt -> working" "/sock pane report-agent wF:p1 --source zeph --agent zeph cc --state working --seq N" "$(last)"
OPTS="$IN_HERDR" run working
check "same state again: not resent" 2 "$(calls)"
OPTS="$IN_HERDR" run tool
check "tool call while working: not resent" 2 "$(calls)"
OPTS="$IN_HERDR" run blocked
check "permission prompt -> blocked" "/sock pane report-agent wF:p1 --source zeph --agent zeph cc --state blocked --seq N" "$(last)"
OPTS="$IN_HERDR" run tool
check "tool runs after the prompt -> working" "/sock pane report-agent wF:p1 --source zeph --agent zeph cc --state working --seq N" "$(last)"
OPTS="$IN_HERDR" run idle
check "stop -> idle" "/sock pane report-agent wF:p1 --source zeph --agent zeph cc --state idle --seq N" "$(last)"
OPTS="$IN_HERDR" run end
check "session end releases the pane" "/sock pane release-agent wF:p1 --source zeph --agent zeph cc --seq N" "$(last)"

echo "seq"
seqs=$(grep -oE -- '--seq [0-9]+' "$LOG" | awk '{print $2}')
check "seq strictly increases" "$(printf '%s\n' "$seqs" | sort -n | uniq)" "$seqs"

echo "reattach"
reset
OPTS="$IN_HERDR" run working
OPTS="wF:p9\t/sock\t$STUB_DIR/herdr" run working
check "same state, new herdr pane: reported there" "/sock pane report-agent wF:p9 --source zeph --agent zeph cc --state working --seq N" "$(last)"

echo
echo "$PASS/$TOTAL passed"
[ "$FAIL" -eq 0 ] || { printf '  failed: %s\n' "${FAILED_TESTS[@]}"; exit 1; }
