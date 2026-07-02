#!/usr/bin/env bash
# Vector tests for hooks/gate.sh — the pure push-gate decision function.
#
# fixtures/gate-vectors.json is the CANONICAL cross-repo contract: the same
# file is vendored into @zeph-to/cli and run against the TS twin
# (cli/src/gate.ts), so any semantic change here that isn't mirrored there
# fails the other repo's CI. Edit gate.sh, the vectors, and gate.ts together.
#
# Exit code 0 = all pass; non-zero = some failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_LIB="$SCRIPT_DIR/../hooks/gate.sh"
VECTORS="$SCRIPT_DIR/fixtures/gate-vectors.json"

[ -f "$GATE_LIB" ] || { echo "gate lib not found: $GATE_LIB" >&2; exit 1; }
[ -f "$VECTORS" ]  || { echo "vectors not found: $VECTORS" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

. "$GATE_LIB"

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()

# One compact line per vector: name<TAB>tool<TAB>nonreadonly<TAB>asked<TAB>marker<TAB>mode<TAB>expected
# alreadyAsked is a boolean in the JSON contract; the bash function takes the
# per-turn count, so true → 1, false → 0.
while IFS=$'\t' read -r name tool nonreadonly asked marker mode expected; do
    TOTAL=$((TOTAL + 1))
    actual=$(zeph_gate_decide "$tool" "$nonreadonly" "$asked" "$marker" "$mode")
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
done < <(jq -r '.[] |
    [ .name,
      (.input.toolCount | tostring),
      (.input.nonReadonlyCount | tostring),
      (if .input.alreadyAsked then "1" else "0" end),
      .input.marker,
      .input.pushMode,
      (if .expect.push then "push \(.expect.priority)" else "silent" end)
    ] | @tsv' "$VECTORS")

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
[ "$TOTAL" -gt 0 ] || { echo "no vectors ran" >&2; exit 1; }
