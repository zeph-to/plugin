#!/usr/bin/env bash
# Vector tests for hooks/gate.sh — which commands wait for approval.
#
# Not a cross-repo contract (no TS twin); the approval gate lives only in the
# Claude Code plugin. Keep it out of cli/scripts/sync-from-plugin.mjs.
#
# The false-negative rows matter as much as the positives: a list that fires on
# `grep -rn deploy src/` teaches people to approve without reading, which is
# worse than having no gate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_LIB="$SCRIPT_DIR/../hooks/gate.sh"
VECTORS="$SCRIPT_DIR/fixtures/approve-vectors.json"

[ -f "$GATE_LIB" ] || { echo "gate lib not found: $GATE_LIB" >&2; exit 1; }
[ -f "$VECTORS" ]  || { echo "vectors not found: $VECTORS" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

. "$GATE_LIB"

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()

record() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$desc")
    fi
}

echo "[approve-vectors — zeph_approve_needed]"
# IFS=tab collapses runs of tabs, so an empty `command` field would shift every
# column after it and silently test the wrong thing. A sentinel byte keeps the
# field non-empty on the wire and is stripped back off here.
while IFS=$'\t' read -r name expected command; do
    command=${command#$'\001'}
    if zeph_approve_needed "$command"; then actual=yes; else actual=no; fi
    record "$name" "$expected" "$actual"
done < <(jq -r '.[] | [ .name, .expect, ("\u0001" + .command) ] | @tsv' "$VECTORS")

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
