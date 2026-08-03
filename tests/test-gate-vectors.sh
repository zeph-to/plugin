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

# Single definition of the pass/fail bookkeeping — the vector loop and the
# resolver cases below both report through it, so the two halves of this file
# can never print in different formats.
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

# One compact line per vector: name<TAB>tool<TAB>nonreadonly<TAB>asked<TAB>marker<TAB>mode<TAB>expected
# alreadyAsked is a boolean in the JSON contract; the bash function takes the
# per-turn count, so true → 1, false → 0.
while IFS=$'\t' read -r name tool nonreadonly asked marker mode expected; do
    record "$name" "$expected" "$(zeph_gate_decide "$tool" "$nonreadonly" "$asked" "$marker" "$mode")"
done < <(jq -r '.[] |
    [ .name,
      (.input.toolCount | tostring),
      (.input.nonReadonlyCount | tostring),
      (if .input.alreadyAsked then "1" else "0" end),
      .input.marker,
      .input.pushMode,
      (if .expect.push then "push \(.expect.priority)" else "silent" end)
    ] | @tsv' "$VECTORS")

# ── zeph_gate_decide stays symmetric with its TS twin ───────────────────────
#
# The pure function must answer every input the way decidePush does, including
# the ones the vector file never sends. A mode it does not recognise — absent,
# empty, or garbage — is `normal` on both sides, so a vector could be written
# for any of these and both CIs would still agree. The shipped default is NOT
# decided here; it lives one layer down, in zeph_read_pushmode.
echo
echo "[zeph_gate_decide — inputs outside the vector file]"
record "a missing mode argument is normal, like decidePush's fallthrough" \
    "push normal" "$(zeph_gate_decide 2 1 0 none)"
record "an empty mode argument is normal" \
    "push normal" "$(zeph_gate_decide 2 1 0 none "")"
record "an unrecognised mode is normal (and its floors still apply)" \
    silent "$(zeph_gate_decide 1 1 0 none banana)"

# ── zeph_read_pushmode — where the shipped default actually lives ───────────
#
# The bash twin of cli/src/gate.ts readPushMode, and the reason the vectors
# cannot reach the default: neither side's PURE function decides it. Both
# resolvers answer the same four shapes the same way, and this block is the
# mirror of gate.test.ts's "the default: no dial file" cases.
echo
echo "[zeph_read_pushmode — dial resolution]"
STATE_TMP=$(mktemp -d)
XDG_STATE_HOME="$STATE_TMP" ZEPH_STATE_DIR="$STATE_TMP/zeph"
mkdir -p "$ZEPH_STATE_DIR"
DIAL="$ZEPH_STATE_DIR/pushmode-testhash"

record "no dial file anywhere is the shipped quiet default" \
    quiet "$(zeph_read_pushmode testhash)"
record "an unhashable project is normal, not the default" \
    normal "$(zeph_read_pushmode "")"

printf 'loud\n' > "$DIAL"
record "a readable dial wins over the default" loud "$(zeph_read_pushmode testhash)"
printf ' quiet ' > "$DIAL"
record "surrounding whitespace is stripped" quiet "$(zeph_read_pushmode testhash)"
printf '' > "$DIAL"
record "an empty dial file is normal, not the default" normal "$(zeph_read_pushmode testhash)"
printf '  \n' > "$DIAL"
record "a whitespace-only dial file is normal too" normal "$(zeph_read_pushmode testhash)"
printf 'banana' > "$DIAL"
record "an unrecognised dial value is normal — a garbled dial stays debuggable" \
    normal "$(zeph_read_pushmode testhash)"

rm -rf "$STATE_TMP"

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
