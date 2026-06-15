#!/bin/bash
# .claude/budget-gate.sh — budget setpoints and the escalation path ([9.3]).
#
# choosing a setpoint is the person's first act, never the machine's; the machinery never raises a setpoint
#
# That rationale is the whole design. Budgets are OPTIONAL setpoints in
# project.json at two granularities — initiative and session. ABSENT MEANS
# UNLIMITED: a governor with no setpoint chosen spins free, so an absent budget
# gates NOTHING, anywhere. This gate is the TENSION GATE: it runs at session
# ENTRY and EXIT, compares BURN (summed mechanically from the [9.1] metering log)
# to the chosen budget, and raises a decision gate ON TENSION ONLY. Within budget
# it is SILENT — no green banner, no per-session recap; silence within budget is
# the spec, not an oversight. (Projection vs. budget joins burn here once [9.7]
# exists; today the gate compares measured burn alone.)
#
# THE ESCALATION PATH (Rule 15 — designed degradation, loud stop) ──────────────
# A BREACH (burn ≥ budget) PAUSES and escalates with work PRESERVED: the gate
# emits a loud decision gate that names the breach, surfaces the BURN PROFILE
# (the burn figure and the budget it crossed), and offers the PERSON'S choices —
# extend, harvest, or kill. The choice is the person's; the machine improvises no
# higher ceiling. A breach exits NON-ZERO so the session pauses for that decision
# rather than sliding silently past the setpoint. THE MACHINERY NEVER RAISES A
# SETPOINT: a headless breach stays paused, loud, and state-intact — the gate
# writes NOTHING (no manifest edit, no sidecar state), so the worktree the breach
# pauses over is left byte-identical. Raising the ceiling is a human commit to
# project.json, never an act of this script.
#
# PROVENANCE ───────────────────────────────────────────────────────────────────
# Budget edits are COMMITS — project.json's git history IS the provenance. There
# is NO approval flow and NO side channel: a budget is set, raised, or lowered by
# editing project.json and committing it, full stop. Budgets have NO STORAGE
# outside project.json — this gate reads the setpoint from the manifest and from
# nothing else (no state file, no dotfile, no env var). The single source keeps
# the provenance auditable in one git history.
#
# BURN ─────────────────────────────────────────────────────────────────────────
# Burn is MECHANICAL, never agent-reported: it is summed from the [9.1] metering
# log (.claude/metering/metering.ndjson), each line of which carries a per-class
# `tokens` object the [9.1] meter harvested from the runtime transcript. The
# SESSION burn is the sum over entries tagged with the current session (the
# newest docs/sessions/session-*.md — the same state siblings read); the
# INITIATIVE burn is the cumulative sum across the whole log. Burn is denominated
# in tokens: [9.1]'s Spike C ladder keeps dollars null (no guessed price table),
# so tokens are the mechanical burn evidence the boundary affords. A degraded
# metering entry (tokens:null) contributes 0 — a missing measurement is never a
# fabricated breach (Rule 15).
#
# SETPOINTS ────────────────────────────────────────────────────────────────────
# project.json → budgets.{initiative,session}.tokens — positive integer token
# counts, schema-validated, person-adjustable, ABSENT MEANS UNLIMITED (not "off"
# — there is no off, an absent setpoint simply does not gate). The schema closes
# additionalProperties at every level so a mistyped granularity or setpoint fails
# validation rather than silently doing nothing.
#
# Usage:
#   bash .claude/budget-gate.sh <entry|exit> [--log <path>] [--manifest <path>]
#
#   <entry|exit>  the session boundary this run gates. The gate runs at BOTH;
#                 the phase is named so the raised gate can say where it fired.
#   --log         override the metering-log path (tests; default root-relative).
#   --manifest    override the manifest path (tests; default .claude/project.json).
#
# Output: a breach prints the decision gate to stdout (the burn profile + the
# extend/harvest/kill choice) and exits 3 — the PAUSE. Within budget / absent
# budget / no log: silent, exit 0.
#
# Exit: 0 within budget, absent budget, or no measurable burn (silent path)
#       2 usage (unknown phase, unknown flag, or jq missing)
#       3 BREACH — the loud pause (a budget setpoint was crossed; the decision
#         gate is on stdout for the person; raising the ceiling is their commit)
#       4 no/corrupt manifest (cwd must be the project root)
#
# This script ships in both install modes: build-plugin.sh glob-derives it into
# plugin/scripts/, and the session-entry / session-close paths invoke it by the
# rewritten path. cwd is the project root in both modes, so the project.json read
# is identical.
set -u

err() { echo "budget-gate: $1" >&2; }
die() { err "$2"; exit "$1"; }

command -v jq >/dev/null 2>&1 || die 2 "requires jq, which is not on PATH — install jq"

[ $# -ge 1 ] || die 2 "usage: bash .claude/budget-gate.sh <entry|exit> [--log path] [--manifest path]"
PHASE="$1"; shift
case "$PHASE" in
  entry|exit) ;;
  *) die 2 "unknown phase '$PHASE' — expected 'entry' or 'exit'" ;;
esac

LOG=""
MANIFEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --log)      LOG="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    *) die 2 "unknown argument '$1'" ;;
  esac
done

# --- manifest (the ONLY budget store) -----------------------------------------
# cwd must be the project root — the same contract the sibling scripts carry. The
# setpoint lives in project.json and NOWHERE ELSE; there is no fallback store.
[ -n "$MANIFEST" ] || MANIFEST=".claude/project.json"
[ -f "$MANIFEST" ] || die 4 "no manifest at $MANIFEST (cwd must be the project root)"
jq -e . "$MANIFEST" >/dev/null 2>&1 \
  || die 4 "$MANIFEST exists but is not valid JSON — fix the manifest"

# --- ABSENT MEANS UNLIMITED ---------------------------------------------------
# No budgets block at all → the governor spins free. Gate nothing, say nothing.
# This is the load-bearing default: silence, exit 0, never a default ceiling.
HAS_BUDGETS=$(jq -r 'has("budgets") and (.budgets | type == "object") and (.budgets | length > 0)' "$MANIFEST" 2>/dev/null)
[ "$HAS_BUDGETS" = "true" ] || exit 0

# Read the two optional setpoints. An absent granularity is unlimited for that
# axis (empty here), so it never gates — only a present, positive integer does.
SESSION_BUDGET=$(jq -r '.budgets.session.tokens // empty' "$MANIFEST" 2>/dev/null)
INITIATIVE_BUDGET=$(jq -r '.budgets.initiative.tokens // empty' "$MANIFEST" 2>/dev/null)
case "$SESSION_BUDGET" in    ''|*[!0-9]*) SESSION_BUDGET="" ;; esac
case "$INITIATIVE_BUDGET" in ''|*[!0-9]*) INITIATIVE_BUDGET="" ;; esac

# Both granularities absent/invalid → nothing to gate (still unlimited).
[ -z "$SESSION_BUDGET" ] && [ -z "$INITIATIVE_BUDGET" ] && exit 0

# --- the metering log (the mechanical burn source) ----------------------------
[ -n "$LOG" ] || LOG=".claude/metering/metering.ndjson"

# The current session id — the newest docs/sessions/session-*.md, derived exactly
# as meter.sh derives it (never hand-supplied). Used to scope the SESSION burn.
CURRENT_SESSION=$(ls docs/sessions/session-*.md 2>/dev/null \
  | sed -E 's#.*/(session-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3})\.md#\1#' \
  | grep -E '^session-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3}$' \
  | sort | tail -1)

# Sum burn from the log. A missing/empty log → burn 0 (a missing measurement is
# never a fabricated breach — Rule 15). tokens:null entries contribute 0. Burn is
# the sum of the four token classes; the session burn filters to the current
# session, the initiative burn is cumulative across every entry.
SESSION_BURN=0
INITIATIVE_BURN=0
if [ -f "$LOG" ]; then
  burn_sum() {  # $1 = jq filter selecting the entries to sum
    jq -rs --argjson f "true" "
      [ .[] | $1 | (.tokens // {})
        | ((.input // 0) + (.output // 0) + (.cache_read // 0) + (.cache_creation // 0)) ]
      | add // 0
    " "$LOG" 2>/dev/null
  }
  INITIATIVE_BURN=$(burn_sum '.')
  SESSION_BURN=$(burn_sum "select(.session == \"$CURRENT_SESSION\")")
  case "$INITIATIVE_BURN" in ''|*[!0-9]*) INITIATIVE_BURN=0 ;; esac
  case "$SESSION_BURN" in    ''|*[!0-9]*) SESSION_BURN=0 ;; esac
fi

# --- the tension decision: a breach is burn ≥ a chosen setpoint ----------------
# On tension ONLY do we raise. Each present granularity is checked; the first
# breach found is the one we pause on (a single loud stop, not a stacked report).
BREACH_KIND=""
BREACH_BURN=""
BREACH_BUDGET=""
if [ -n "$SESSION_BUDGET" ] && [ "$SESSION_BURN" -ge "$SESSION_BUDGET" ]; then
  BREACH_KIND="session"
  BREACH_BURN="$SESSION_BURN"
  BREACH_BUDGET="$SESSION_BUDGET"
elif [ -n "$INITIATIVE_BUDGET" ] && [ "$INITIATIVE_BURN" -ge "$INITIATIVE_BUDGET" ]; then
  BREACH_KIND="initiative"
  BREACH_BURN="$INITIATIVE_BURN"
  BREACH_BUDGET="$INITIATIVE_BUDGET"
fi

# Within budget → SILENCE. No green banner, no per-session recap. The tension
# gate says nothing when there is no tension — at entry and at exit alike.
[ -z "$BREACH_KIND" ] && exit 0

# ════════════════════════════════════════════════════════════════════════════════
# BREACH — the loud pause (Rule 15). Surface the burn profile and the person's
# choices. Write NOTHING: the machinery never raises a setpoint, so the worktree
# the breach pauses over stays byte-identical. Raising the ceiling is the person's
# commit to project.json, never this script's act.
# ════════════════════════════════════════════════════════════════════════════════
WHERE=$([ "$PHASE" = "entry" ] && echo "at session entry" || echo "at session exit")
cat <<EOF
[budget-gate] BREACH ${WHERE} — the ${BREACH_KIND} budget is exhausted.

  burn profile
    ${BREACH_KIND} burn:   ${BREACH_BURN} tokens
    ${BREACH_KIND} budget: ${BREACH_BUDGET} tokens
    over by:               $((BREACH_BURN - BREACH_BUDGET)) tokens

This is a PAUSE for a decision, not a stop the machine recovers from. Work is
preserved — nothing has been changed. The ${BREACH_KIND} setpoint stays as you
set it; the machinery never raises a setpoint. The decision is yours:

  • EXTEND   — raise the ${BREACH_KIND} budget by editing budgets.${BREACH_KIND}.tokens
               in ${MANIFEST} and committing it (the commit IS the provenance —
               no approval flow, no side channel).
  • HARVEST  — wrap up now: /handoff (/guv:handoff under the plugin) to capture
               state, then end within budget.
  • KILL     — stop here; the worktree is intact for a later pickup.

A headless run stays paused here, loud, with state intact — it does not choose
for you and never raises the ceiling on its own.
EOF
exit 3
