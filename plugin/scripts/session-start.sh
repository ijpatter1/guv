#!/bin/bash
# .claude/hooks/session-start.sh
# SessionStart hook ([8.3] §3.3, "session-open dispatch") — surface the routing
# decision (route.sh) and the ready frontier (resolve-ready.sh) as session-open
# context, so a session that begins WITHOUT invoking an entry-door skill still
# opens with the door + frontier already in context. The entry-door skills stay
# authoritative: they re-run route/resolve to ACT on the decision; this hook only
# SURFACES it (convenience, never a dependency — the same contract as the render
# hook). It fires on every source (startup/resume/clear/compact); re-surfacing
# the frontier after a compaction is a feature, not noise.
#
# ALWAYS exits 0. A SessionStart hook that exits 2 BLOCKS the session from
# starting (hooks reference), so every degradation rung here is a clean exit-0
# with reduced context — a missing or MALFORMED tracker, a non-phased or
# pre-scaffold project, or absent helpers all degrade to whatever context could
# be gathered (possibly none), never to a session-blocking failure (rule 15).
set -u

# Resolve the sibling shared-lib scripts in BOTH install modes. Plugin mode ships
# this wrapper and the libs together under ${CLAUDE_PLUGIN_ROOT}/scripts/, so they
# sit in $0's own directory; project mode keeps the wrapper in .claude/hooks/ and
# the libs one level up in .claude/. Probe for a known sibling to pick the base.
DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || exit 0
if [ -f "$DIR/route.sh" ]; then BASE="$DIR"; else BASE="$DIR/.."; fi

cat >/dev/null 2>&1   # drain the hook payload on stdin (unused)

# route (default mode) emits door= + reason= on stdout; resolve-ready emits the
# name=value frontier. Both are captured stdout-only — their non-zero exits (a
# pre-scaffold dir, a non-phased project, a missing/MALFORMED tracker) carry an
# explanatory stderr we deliberately discard, leaving the captured value empty.
ROUTE="$(bash "$BASE/route.sh" 2>/dev/null)"
FRONTIER="$(bash "$BASE/resolve-ready.sh" 2>/dev/null)"

# Nothing to surface (pre-scaffold, non-git, helpers absent) — inject nothing.
[ -z "$ROUTE$FRONTIER" ] && exit 0

CTX="guv session-open dispatch (advisory — the entry-door skill remains authoritative):"
[ -n "$ROUTE" ]    && CTX="$CTX"$'\n\n'"$ROUTE"
[ -n "$FRONTIER" ] && CTX="$CTX"$'\n'"$FRONTIER"

# Emit the documented SessionStart context-injection envelope. jq escapes the
# text safely; if jq is somehow absent, degrade to no injection (still exit 0).
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$CTX" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
fi
exit 0
