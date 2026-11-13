# Sunset gate — sourced by every bash hook, no shebang, no exit.
#
# Zeph's AI-agent features end on 2026-11-01 and the server refuses agent calls
# from then on. This plugin must be harmless forever after: each hook sources
# this file FIRST and runs `zeph_sunset_ended && exit 0`, so nothing past that
# line (no `zeph`/`npx`/`curl`, no waiting, no deny) ever runs on or after D.
#
# Kept separate from gate.sh on purpose: zeph-herdr.sh does not use gate.sh and
# runs on every tool call, so it must not pay to parse that 28 KB library. The
# Node SessionStart hook (zeph-setup.js) cannot source bash and carries its own
# copy of the same three-line comparison; tests/test-sunset.sh locks both.
#
# ZEPH_SUNSET_TODAY (YYYY-MM-DD) overrides "today" for tests.
ZEPH_SUNSET_DATE="2026-11-01"

# Succeeds (0) once the UTC date has reached D; D itself counts as ended. An
# unreadable clock reads as "not ended" — the hooks then behave as before.
zeph_sunset_ended() {
    local today="${ZEPH_SUNSET_TODAY:-$(date -u +%Y-%m-%d 2>/dev/null)}"
    [ -n "$today" ] && [[ ! "$today" < "$ZEPH_SUNSET_DATE" ]]
}
