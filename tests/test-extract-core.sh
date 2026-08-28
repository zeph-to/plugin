#!/usr/bin/env bash
# Tests for scripts/extract-core.js (the CLI-bound core extractor).
#
# Guards these regressions:
#   - the extracted core must not steer by a mechanism the CLI harnesses never
#     receive. The manifest drops rules 1-2 (Push Signal) and rule 12 (the
#     /zeph-* dial), so surviving prose that says "your Push Signal" or "the
#     user's dial" is an unfollowable instruction on all eight of them
#     (PI-RULES-AUDIT F1, measured against a live pi install).
#   - the disambiguation those sentences carried must survive the rewrite:
#     `<!-- zeph: exit -->` is a marker the CLI core DOES tell agents to emit,
#     and Rule 9 has to keep saying it is not a mode signal.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR="$SCRIPT_DIR/../scripts/extract-core.js"

[ -f "$EXTRACTOR" ] || { echo "extractor not found: $EXTRACTOR" >&2; exit 1; }
command -v node >/dev/null || { echo "node required" >&2; exit 1; }

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()

assert() {
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    if "$@"; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$desc")
    fi
}

assert_not() {
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    if ! "$@"; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$desc")
    fi
}

# Both cores in one blob: they are assembled from the same manifest and every
# assertion below has to hold for each, so a single grep target keeps a
# regression from hiding in whichever one the test forgot to check.
CORES=$(node -e '
const { extractCore } = require(process.argv[1]);
const c = extractCore();
process.stdout.write(c.hookDriven + "\n" + c.ruleOnly);
' "$EXTRACTOR") || { echo "extractor failed" >&2; exit 1; }

core_has() { printf '%s' "$CORES" | grep -qF "$1"; }
# Word-boundary variant: "dial" as a bare substring would also fire on a
# legitimate future "dialog", and a false red here reads like a real one.
core_has_re() { printf '%s' "$CORES" | grep -qE "$1"; }

echo "── extracted core: no dangling references to sliced-out mechanisms ──"
assert_not "no Push Signal reference"    core_has "Push Signal"
assert_not "no push-mode dial reference" core_has_re "dial\b"
assert_not "no /zeph-* slash command"    core_has "/zeph-"

echo "── extracted core: the rewrite kept what it was disambiguating ──"
assert "still names the exit marker"     core_has "zeph: exit"
assert "still carries sticky REMOTE"     core_has "Sticky REMOTE mode"
assert "still carries the NORMAL branch" core_has "no zeph_ask is owed"

echo
echo "Extract-core: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    printf 'Failed: %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
