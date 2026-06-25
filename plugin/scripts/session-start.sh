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

# The [9.3] tension gate at the ENTRY boundary: it compares burn to the chosen
# budget and, ON TENSION ONLY, prints a loud decision gate (exit 3). We capture
# its stdout and SURFACE it as session-open context — but the gate's non-zero exit
# is deliberately NOT propagated: a SessionStart hook that exits non-zero BLOCKS
# the session from starting (hooks reference), and a budget breach is a decision
# to PAUSE for, not a reason to deny the session its start. So entry-tension is
# surfaced before more work is done (the gate's purpose) while the hook stays at
# exit 0 (its load-bearing invariant). Absent budget / within budget → silent →
# nothing surfaced; a missing manifest or absent jq → empty, same as the siblings.
GATE_ENTRY=""
[ -f "$BASE/budget-gate.sh" ] && GATE_ENTRY="$(bash "$BASE/budget-gate.sh" entry 2>/dev/null)"

# Load the local friction log ([20.7]) as session-open working context: surface the
# count of OPEN guv-feedback entries together with the capture posture (local-only,
# never phones home; submitting upstream is opt-in / user-gated), so a session opens
# already aware of pending friction without an explicit feedback/status invocation.
# The log is consumer-OWNED data living in the PROJECT's .claude/feedback/ — NOT beside
# this hook (in plugin mode $BASE points into the install, which has no log), so it is
# CLAUDE_PROJECT_DIR-anchored ([19.4]) with a cwd fallback. The load is OPTIONAL: absent
# log, zero open, or jq absent → nothing surfaced (no noise on a clean log). A malformed
# log degrades to silent (the jq count fails → empty), never a session-blocking error
# (rule 15). No slash-commands in the surfaced text (it stays mode-agnostic, like the
# frontier above — a plugin namespaces command names, and a script's literal text is
# not rewritten, so the surfaced line names the skill in prose instead).
FEEDBACK=""
FB_LOG="${CLAUDE_PROJECT_DIR:-.}/.claude/feedback/feedback.ndjson"
if [ -f "$FB_LOG" ] && command -v jq >/dev/null 2>&1; then
  FB_OPEN="$(jq -s '[.[] | select(.status=="open")] | length' "$FB_LOG" 2>/dev/null)" || FB_OPEN=""
  if [ -n "$FB_OPEN" ] && [ "$FB_OPEN" -gt 0 ] 2>/dev/null; then
    FB_W="entries"; [ "$FB_OPEN" -eq 1 ] && FB_W="entry"
    FEEDBACK="guv-feedback: $FB_OPEN open local friction $FB_W — capture is local-only and never phones home (logging, listing, and triaging transmit nothing and add or remove no telemetry); submitting upstream is opt-in and user-gated, never auto-filed. Open the feedback skill to triage or submit."
  fi
fi

# Surface the context-wall posture ([16.2]) as session-open context: a fresh
# headless scaffold's loud 'context-wall mode UNSET' marker, or a one-time,
# non-blocking migration nudge for a block-less in-field project. The
# discriminator (block presence is the scaffold-provenance signal) and the nudge
# once-ness live in context-management.sh; this hook only SURFACES what surface
# emits — watch-item a: the marker reaches a person, not a file no one reads. The
# manifest is consumer-OWNED in the PROJECT, so it is CLAUDE_PROJECT_DIR-anchored
# ([19.4]) with a cwd fallback (in plugin mode $BASE points into the install,
# whose project.json is not the consumer's). surface is read-mostly and never
# blocks: absent helper, absent/unparseable manifest, or a configured mode →
# nothing surfaced (rule 15).
CTXWALL=""
PROJ_MANIFEST="${CLAUDE_PROJECT_DIR:-.}/.claude/project.json"
{ [ -f "$BASE/context-management.sh" ] && [ -f "$PROJ_MANIFEST" ]; } \
  && CTXWALL="$(bash "$BASE/context-management.sh" surface "$PROJ_MANIFEST" 2>/dev/null)"

# Nothing to surface (pre-scaffold, non-git, helpers absent, within budget, clean log, configured posture) — inject nothing.
[ -z "$ROUTE$FRONTIER$GATE_ENTRY$FEEDBACK$CTXWALL" ] && exit 0

CTX="guv session-open dispatch (advisory — the entry-door skill remains authoritative):"
[ -n "$ROUTE" ]      && CTX="$CTX"$'\n\n'"$ROUTE"
[ -n "$FRONTIER" ]   && CTX="$CTX"$'\n'"$FRONTIER"
[ -n "$GATE_ENTRY" ] && CTX="$CTX"$'\n\n'"$GATE_ENTRY"
[ -n "$FEEDBACK" ]   && CTX="$CTX"$'\n\n'"$FEEDBACK"
[ -n "$CTXWALL" ]    && CTX="$CTX"$'\n\n'"$CTXWALL"

# Emit the documented SessionStart context-injection envelope. jq escapes the
# text safely; if jq is somehow absent, degrade to no injection (still exit 0).
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$CTX" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
fi
exit 0
