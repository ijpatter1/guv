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
# the spec, not an oversight.
#
# TENSION ON THE FORECAST ([13.5]) ──────────────────────────────────────────────
# Beyond the ACTUAL-burn breach, the gate reads the [9.7]/[13.3] projection and adds
# its cost-to-COMPLETE to burn-to-date: if the projected INITIATIVE total would
# exceed the initiative setpoint, the breach is FORESEEN. A deliverable-budget breach
# is fuzzy (the projection is a range, not a fact), so a foreseen breach is DECLARED
# loudly for the handoff and exits 0 — a signal for a person at the boundary, NEVER a
# mid-flight hard stop. The hard stop stays the actual-burn breach (exit 3). Absent a
# projection (no tracker / projection error) the foreseen check degrades silently to
# burn-only (Rule 15) — never a fabricated forecast.
#
# MIXED HARVEST VINTAGE ([9.1]) ────────────────────────────────────────────────
# Burn and setpoint are only comparable if both are denominated in the same unit.
# The meter's pre-dedupe harvest counted usage once per transcript LINE rather
# than once per API response, so those entries overstate by the response's
# content-block count — by a factor that varies with the shape of the work, which
# is why no single divisor converts them. Entries harvested after the fix
# self-describe with `harvest_basis: per_response`; earlier ones carry no such
# field. When the burn WINDOW spans both, the gate prints a DECLARATION naming
# the vintages and the likely direction (phantom headroom — a ceiling chosen in
# the inflated unit lets more real work through than it was meant to) and exits
# 0. It is a disclosure, not a conversion and not a stop: re-denominating a
# setpoint is a human commit to project.json, exactly like raising one. The scan
# reads the SAME entries the burn sums — same lineage window, and same
# contributing set (bounded slices plus the differenced legacy cumulatives) — so
# neither a closed initiative's vintage nor an entry that contributes no burn at
# all can raise a warning about the live figure. Note what the banner does NOT
# do: nothing clears it. A window that has once spanned both vintages spans them
# for its whole life, because the log is append-only — so the disclosure is a
# standing property of this initiative, not a task to work off.
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
# INITIATIVE burn is scoped to the LIVE initiative by the [13.4] lineage: the
# calibration record's lifecycle entries mark the window — it opens at the
# initiative's opening `--at plan` forecast (or, between initiatives, at the
# `grade` that closed the last one; phase-boundary banks never move it), and
# only meter entries stamped at/after that boundary count. A record with no
# lifecycle entry to read (pre-[13.4], or no calibration record) degrades to
# the whole-log cumulative sum — the pre-window behavior, a designed
# degradation, never a guessed boundary (Rule 15). Burn is denominated
# in tokens: [9.1]'s Spike C ladder keeps dollars null (no guessed price table),
# so tokens are the mechanical burn evidence the boundary affords. A degraded
# metering entry (tokens:null) contributes 0 — a missing measurement is never a
# fabricated breach (Rule 15). Burn is summed SLICE-AWARE ([13.5], the [13.6]
# migration): bounded per-session slices (slice_basis per_deliverable /
# since_process_start) sum directly; LEGACY cumulative entries are differenced over
# the FULL per-runtime_session series at read time (so a runtime_session spanning
# sessions keeps its baseline), and only THEN scoped to the axis being summed;
# unbounded_cumulative is excluded — so a cumulative snapshot never inflates burn.
# The INITIATIVE read is projection.sh observed_rate()'s slice-aware sample sum
# with the lineage window applied on top (observed_rate itself stays whole-record
# — the calibration blend reads full history deliberately); the SESSION read
# differences-then-filters (observed_rate never session-scopes).
#
# SETPOINTS ────────────────────────────────────────────────────────────────────
# project.json → budgets.{initiative,session}.tokens — positive integer token
# counts, schema-validated, person-adjustable, ABSENT MEANS UNLIMITED (not "off"
# — there is no off, an absent setpoint simply does not gate). The schema closes
# additionalProperties at every level so a mistyped granularity or setpoint fails
# validation rather than silently doing nothing.
#
# Usage:
#   bash .claude/budget-gate.sh <entry|exit> [--log <path>] [--manifest <path>] [--calibration <path>]
#
#   <entry|exit>  the session boundary this run gates. The gate runs at BOTH;
#                 the phase is named so the raised gate can say where it fired.
#   --log         override the metering-log path (tests; default root-relative).
#   --manifest    override the manifest path (tests; default .claude/project.json).
#   --calibration override the calibration-record path the initiative window is
#                 read from (tests; default root-relative).
#
# Output: an ACTUAL-burn breach prints the decision gate to stdout (the burn profile
# + the extend/harvest/kill choice) and exits 3 — the PAUSE, headed "[budget-gate]
# BREACH …". A FORESEEN overrun ([13.5]) prints a declaration to stdout and exits 0
# — a signal, not a stop, headed "[budget-gate] FORESEEN OVERRUN …" ([15.6]: the
# signal header leads with words distinct from the stop's so a skim tells them apart;
# "BREACH" names the exit-3 stop alone). A MIXED HARVEST VINTAGE window prints its
# own declaration and exits 0, headed "[budget-gate] MIXED HARVEST VINTAGE …" — it
# rides ALONGSIDE whichever of the three burn outcomes the window produced, because
# it says the comparison is in no single unit, not what the comparison came out to.
# Within budget / absent budget / no log: silent, exit 0.
#
# Exit: 0 within budget, absent budget, no measurable burn, a FORESEEN breach
#         ([13.5] — declared on stdout for the handoff, never a stop), or a MIXED
#         HARVEST VINTAGE disclosure ([9.1] — likewise declared, never a stop)
#       2 usage (unknown phase, unknown flag, or jq missing)
#       3 ACTUAL-BURN BREACH — the loud pause (a setpoint was crossed by real burn;
#         the decision gate is on stdout for the person; raising the ceiling is their commit)
#       4 no/corrupt manifest (cwd must be the project root)
#
# This script ships in both install modes: build-plugin.sh glob-derives it into
# plugin/scripts/, and the two session boundaries invoke it by the rewritten path.
# ENTRY: the SessionStart hook (.claude/hooks/session-start.sh) fires the gate at
# `entry` and SURFACES a breach as session-open context — it deliberately does NOT
# propagate the gate's exit 3, because a non-zero SessionStart exit blocks the
# session from starting (a breach is a decision to pause for, not a denied start).
# EXIT: the session-close path the handoff skill drives (Step 6c, beside [9.1]'s
# meter.sh capture) fires the gate at `exit`, where a breach is the loud pause.
# cwd is the project root in both modes, so the project.json read is identical.
set -u

err() { echo "budget-gate: $1" >&2; }
die() { err "$2"; exit "$1"; }

# Sibling spine scripts travel with this one in BOTH install modes (build-plugin.sh
# glob-derives them into plugin/scripts/ together) — locate them relative to THIS
# script, never cwd (cwd is the project root, for reading state). [13.5] reads the
# projection through its sibling producer.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

command -v jq >/dev/null 2>&1 || die 2 "requires jq, which is not on PATH — install jq"

[ $# -ge 1 ] || die 2 "usage: bash .claude/budget-gate.sh <entry|exit> [--log path] [--manifest path] [--calibration path]"
PHASE="$1"; shift
case "$PHASE" in
  entry|exit) ;;
  *) die 2 "unknown phase '$PHASE' — expected 'entry' or 'exit'" ;;
esac

LOG=""
MANIFEST=""
CALIB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --log)         LOG="${2:-}"; shift 2 ;;
    --manifest)    MANIFEST="${2:-}"; shift 2 ;;
    --calibration) CALIB="${2:-}"; shift 2 ;;
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

# --- the initiative window (the [13.4] lineage boundary) ----------------------
# The initiative setpoint governs the LIVE initiative, not the whole record —
# an all-time sum breaches any correctly forecast-derived budget the moment a
# mature log outgrows it. The calibration record's lifecycle entries mark where
# the live initiative begins: its opening `--at plan` forecast — or, between
# initiatives (a grade with no new plan bank yet), the `grade` that closed the
# last one, so a still-set setpoint gates burn-since-close rather than a closed
# initiative's history. Phase-boundary banks are mid-initiative snapshots and
# never move the window. This is the same lineage read projection.sh's
# bank-dedup slices by ("forecasts before the most recent grade belong to a
# CLOSED initiative"), and the same post-bank ts bound its close-time grade
# puts on outcomes. No lifecycle entry / no record → INITIATIVE_SINCE stays
# empty and the burn read below degrades to the whole-log cumulative sum.
[ -n "$CALIB" ] || CALIB=".claude/metering/calibration.ndjson"
INITIATIVE_SINCE=""
if [ -f "$CALIB" ]; then
  # Per-line-tolerant read (fromjson?): a corrupt record line (a torn append)
  # drops THAT LINE alone, never the whole lineage. The sibling slurp in
  # projection.sh can afford all-or-nothing (its blast radius is a missing
  # forecast); here losing the window would silently resurrect the spurious
  # cumulative breach this window exists to kill, so the read survives
  # partial corruption.
  # The anchor is `last` in FILE ORDER — append order is lineage order, the
  # same convention as projection.sh's rindex("grade") slice — not
  # max-banked_at. Lifecycle entries land in lifecycle order by construction;
  # if a hand-edited record ever appends one out of order, the older boundary
  # widens the window and over-counts — an earlier, basis-disclosed breach,
  # never a silent under-gate (pinned by the suite's W11).
  INITIATIVE_SINCE=$(jq -rRn '
    [ inputs | fromjson? | select(type == "object")
      | select(((.kind // "") == "grade")
            or (((.kind // "") == "forecast") and ((.boundary // "") == "plan"))) ]
    | last | .banked_at // empty' "$CALIB" 2>/dev/null)
  # exact ISO-8601 UTC shape or it is no boundary (a malformed stamp never
  # windows, and never reaches the burn jq below as anything but this vetted
  # literal). The glob's job is INJECTION SAFETY — shape-vetting the string
  # before interpolation — not semantic time validation: projection.sh stamps
  # boundaries with `date -u`, so a digit-shaped non-time cannot arrive from
  # the real writer.
  case "$INITIATIVE_SINCE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) INITIATIVE_SINCE="" ;;
  esac
fi

# The window basis, named in every initiative figure the gate prints: a windowed
# read and a degraded-cumulative read are DIFFERENT CLAIMS, and the person at an
# extend/harvest/kill pause (or reading a foreseen declaration) must see which
# one the figure is — on a mature record the degraded read is exactly the
# spurious-breach shape, and only this line makes that visible in the output.
if [ -n "$INITIATIVE_SINCE" ]; then
  INITIATIVE_WINDOW="the live initiative (entries since the lineage boundary ${INITIATIVE_SINCE})"
else
  INITIATIVE_WINDOW="the whole metering log (no lineage boundary to window by)"
fi

# Sum burn from the log. A missing/empty log → burn 0 (a missing measurement is
# never a fabricated breach — Rule 15). tokens:null entries contribute 0. Burn is
# the sum of the four token classes; the session burn filters to the current
# session, the initiative burn is windowed to the live lineage (or every entry
# when no boundary exists — the degradation above).
SESSION_BURN=0
INITIATIVE_BURN=0
# Declared out here with the burns, not inside the log branch: with no log there is
# no vintage to report, and `set -u` must not turn "nothing to disclose" into an abort.
BURN_VINTAGES=""
BURN_VINTAGE_N=0
if [ -f "$LOG" ]; then
  # Burn is summed SLICE-AWARE ([13.5] — the [13.6] migration budget-gate was
  # disclosed as owing). An entry's tokens is a BOUNDED per-session slice only when
  # slice_basis is per_deliverable or since_process_start — those are summed
  # DIRECTLY. LEGACY entries (pre-[13.6], no slice_basis key) are cumulative running
  # totals: DIFFERENCED per runtime_session at READ time (the log stays append-only).
  # unbounded_cumulative (the disclosed degradation) and tokens:null are NOT burn
  # samples. A negative legacy delta (out-of-order / pruned) is dropped, never a
  # fabricated burn (Rule 15). This is the SAME read projection.sh observed_rate()
  # uses — the unit honesty that keeps a cumulative snapshot from inflating burn
  # ~4.6× (the forensic bug found during guv's own development; the analysis is a
  # maintainer artifact, not a doc shipped in this code repo — [15.6]). A raw sum of
  # cumulative snapshots is exactly the over-count that bug produced.
  burn_sum() {  # $1 = a jq boolean selecting the entries to sum (post-schema)
    jq -rs "
      def burn: (.input // 0) + (.output // 0) + (.cache_read // 0) + (.cache_creation // 0);
      [ .[] | select((.schema // \"\") | startswith(\"guv.meter\")) ] as \$all
      # Bounded slices are STANDALONE (each tagged with its own session), so the
      # selection filters them directly.
      | [ \$all[] | select($1) | select(.tokens != null)
                  | select((.slice_basis // \"\") as \$sb | \$sb == \"per_deliverable\" or \$sb == \"since_process_start\")
                  | (.tokens | burn) ] as \$direct
      # Legacy cumulatives MUST be differenced over the FULL per-runtime_session
      # series BEFORE the selection — a runtime_session can span sessions, so a
      # delta's baseline is the prior cumulative, which may sit in ANOTHER session.
      # Filtering first would drop that baseline and count a survivor's full
      # cumulative (the ~4.6× reinflation the [13.6] migration killed). So difference
      # the whole series, carry each delta on its entry, THEN apply the selection.
      | [ \$all[] | select(.tokens != null) | select(has(\"slice_basis\") | not) ] as \$legacy
      | ( \$legacy | group_by(.runtime_session)
          | map( . as \$g
                 | [ range(0; (\$g | length)) as \$i
                     | \$g[\$i] as \$e
                     | (if \$i == 0 then (\$e.tokens | burn) else (\$e.tokens | burn) - (\$g[\$i-1].tokens | burn) end) as \$delta
                     | \$e + {_burn_delta: \$delta} ] )
          | add // [] ) as \$legacy_d
      # select the differenced deltas the SAME way, dropping negatives (out-of-order
      # / pruned series — never a fabricated burn, Rule 15).
      | [ \$legacy_d[] | select($1) | ._burn_delta | select(. >= 0) ] as \$legacy_deltas
      | ( \$direct + \$legacy_deltas ) | add // 0
    " "$LOG" 2>/dev/null
  }
  # The INITIATIVE sum is windowed to the live lineage (INITIATIVE_SINCE above);
  # with no boundary to read, the selection degrades to every entry — the
  # pre-[13.4] cumulative read. The ts bound composes with the legacy
  # differencing because selection happens AFTER the full-series differencing
  # (the baseline survives). An entry with no ts cannot enter a windowed sum —
  # a missing stamp is a missing measurement, never fabricated burn (the same
  # Rule-15 rung as tokens:null).
  if [ -n "$INITIATIVE_SINCE" ]; then
    INITIATIVE_BURN=$(burn_sum "((.ts // \"\") >= \"$INITIATIVE_SINCE\")")
  else
    INITIATIVE_BURN=$(burn_sum 'true')
  fi
  SESSION_BURN=$(burn_sum "(.session == \"$CURRENT_SESSION\")")
  case "$INITIATIVE_BURN" in ''|*[!0-9]*) INITIATIVE_BURN=0 ;; esac
  case "$SESSION_BURN" in    ''|*[!0-9]*) SESSION_BURN=0 ;; esac

  # Is the windowed burn even in ONE unit? harvest_basis says HOW a reading was
  # harvested — the axis orthogonal to slice_basis's unit — and until now it was
  # written by the meter and read by nobody. That gap is the phantom-HEADROOM mirror
  # of a phantom breach: sum pre-dedupe entries (inflated ~2.5x by counting usage per
  # transcript line instead of per API response) into the same window as post-dedupe
  # ones and the total is in no unit at all, while this gate compares it against a
  # setpoint chosen in exactly one of them — and stays SILENT, because silence is what
  # within-budget looks like. Slicing does not catch it: slice_basis's vintage guard
  # only refuses a DELTA across the seam inside one runtime_session; a new
  # runtime_session's first post-fix entry is summed straight in beside the old ones.
  #
  # So this is the one case where the gate's own silence is the defect, and it
  # discloses instead. DISCLOSURE ONLY — it never adjusts a setpoint, never changes an
  # exit code, and never re-denominates a number. Re-banking a budget is a human commit
  # to budgets.{initiative,session}.tokens; the machinery never moves a setpoint.
  if [ -n "$INITIATIVE_SINCE" ]; then
    VSEL="((.ts // \"\") >= \"$INITIATIVE_SINCE\")"
  else
    VSEL='true'
  fi
  # The scan must read the entries burn_sum CONTRIBUTES FROM, not merely the ones
  # sharing its ts window — a vintage raised by an entry that adds nothing to the
  # figure is a false alarm about a number it never touched. So the same structural
  # filter applies here: bounded slices, plus the legacy cumulatives burn_sum
  # differences. unbounded_cumulative is excluded there (the disclosed degradation,
  # never a burn sample), so it must not raise a vintage here. Not modelled: a legacy
  # entry whose differenced delta lands negative and is dropped contributes zero on
  # that pass while remaining a burn sample by shape — it still counts as a vintage,
  # which is the conservative direction (disclose) rather than the silent one.
  BURN_VINTAGES=$(jq -rs "
    [ .[] | select((.schema // \"\") | startswith(\"guv.meter\"))
          | select(.tokens != null)
          | select($VSEL)
          | select( ((.slice_basis // \"\") as \$sb | \$sb == \"per_deliverable\" or \$sb == \"since_process_start\")
                    or (has(\"slice_basis\") | not) )
          | (if has(\"harvest_basis\") then (.harvest_basis // empty) else \"pre-dedupe\" end) ]
    | group_by(.)
    | (length | tostring) + \"|\"
      + (map(\"\(.[0]) (\(length) \(if length == 1 then \"entry\" else \"entries\" end))\") | join(\", \"))
  " "$LOG" 2>/dev/null)
  # Split the count off the display string. The count drives the decision below —
  # counting commas in the display would break the moment a vintage name carried one.
  case "$BURN_VINTAGES" in
    *'|'*) BURN_VINTAGE_N=${BURN_VINTAGES%%|*}; BURN_VINTAGES=${BURN_VINTAGES#*|} ;;
    *)     BURN_VINTAGE_N=0; BURN_VINTAGES="" ;;
  esac
  case "$BURN_VINTAGE_N" in ''|*[!0-9]*) BURN_VINTAGE_N=0 ;; esac
fi

# Where this gate is speaking from — needed by every declaration below, so it is
# derived once here rather than beside the first one that happened to need it.
WHERE=$([ "$PHASE" = "entry" ] && echo "at session entry" || echo "at session exit")

# --- vintage disclosure: is this comparison apples-to-apples? ------------------
# Printed BEFORE any breach or overrun, because it qualifies every number below it.
if [ "$BURN_VINTAGE_N" -gt 1 ]; then
  cat <<EOF
[budget-gate] MIXED HARVEST VINTAGE ${WHERE} — the burn window spans more than one harvest unit.

  vintages in window:  ${BURN_VINTAGES}
  burn window:         ${INITIATIVE_WINDOW:-<unwindowed — every entry>}
  initiative burn:     ${INITIATIVE_BURN} tokens

Entries harvested "pre-dedupe" counted token usage once per transcript LINE rather
than once per API response, which over-counts by roughly 2.5x and varies with the
shape of the work. Summing them beside "per_response" entries produces a total in no
single unit, and comparing that total to a setpoint chosen in one unit is not a
measurement. The likeliest direction is PHANTOM HEADROOM: a ceiling set in the
inflated unit lets far more real work through than it was meant to.

This is a DECLARATION, not a stop, and nothing here has been changed or converted.
The remedy is one commit by a person: re-denominate budgets.{initiative,session}.tokens
in .claude/project.json into the post-fix unit. The machinery never moves a setpoint.

Nothing clears this banner. The log is append-only, so a window that has once spanned
both vintages spans them for the rest of its life — expect this at every boundary
until the initiative closes, and read the burn above as a mixed total throughout.
EOF
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

# An initiative breach names its window basis in the profile (a session breach
# has no window to name — its basis is the session id already in the label).
BREACH_WINDOW_LINE=""
[ "$BREACH_KIND" = "initiative" ] && BREACH_WINDOW_LINE="
    burn window:           ${INITIATIVE_WINDOW}"

# No ACTUAL-burn breach. [13.5] before the silent exit, check the FORESEEN breach —
# tension on the FORECAST, not just the burn. Read the live projection's cost to
# COMPLETE (the [9.7]/[13.3] central estimate, remaining_sessions × the blended rate)
# and add burn-to-date; if the projected INITIATIVE total would exceed the initiative
# setpoint, DECLARE it loudly for the handoff — but do NOT stop. A deliverable-budget
# breach is fuzzy (the projection is a range, not a fact), so a foreseen breach is a
# human signal at this boundary, never a mid-flight hard stop; the hard stop stays the
# ACTUAL-burn breach below. Degrades SILENTLY (Rule 15) when no projection is available
# (no tracker, or the projection errors) — burn-only, never a fabricated forecast.
if [ -z "$BREACH_KIND" ]; then
  if [ -n "$INITIATIVE_BUDGET" ]; then
    PROJ=$(bash "$SCRIPT_DIR/projection.sh" project 2>/dev/null)
    if [ -n "$PROJ" ]; then
      CTC=$(printf '%s' "$PROJ" | jq -r '((.spine.quantity.remaining_sessions // 0) * (.spine.unit_rate.blended_tokens // 0))' 2>/dev/null)
      PLOW=$(printf '%s' "$PROJ" | jq -r '.range.low_tokens // empty' 2>/dev/null)
      PHIGH=$(printf '%s' "$PROJ" | jq -r '.range.high_tokens // empty' 2>/dev/null)
      case "$CTC" in ''|*[!0-9]*) CTC="" ;; esac
      if [ -n "$CTC" ] && [ "$CTC" -gt 0 ]; then
        PROJECTED_TOTAL=$((INITIATIVE_BURN + CTC))
        if [ "$PROJECTED_TOTAL" -ge "$INITIATIVE_BUDGET" ]; then
          cat <<EOF
[budget-gate] FORESEEN OVERRUN ${WHERE} — the initiative is PROJECTED to exceed its budget.

  forecast profile
    burn to date:          ${INITIATIVE_BURN} tokens
    projected to complete: ${CTC} tokens (range ${PLOW:-?}–${PHIGH:-?})
    projected total:       ${PROJECTED_TOTAL} tokens
    initiative budget:     ${INITIATIVE_BUDGET} tokens
    projected over by:     $((PROJECTED_TOTAL - INITIATIVE_BUDGET)) tokens
    burn window:           ${INITIATIVE_WINDOW}

This is a DECLARATION, not a stop. A deliverable-budget breach is fuzzy — the
projection is a RANGE, not a fact — so the session is NOT paused and NOTHING is
changed (the machinery never raises a setpoint). It is a signal for a person at
this boundary: EXTEND the initiative budget (a commit to budgets.initiative.tokens
in ${MANIFEST}), HARVEST and re-plan the remaining work, or accept the forecast and
continue. Surface it in the handoff for that decision.
EOF
        fi
      fi
    fi
  fi
  # SILENCE within budget (and after any foreseen declaration): exit 0. A foreseen
  # breach declared above is a signal, never a stop — the session continues.
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════════════
# ACTUAL-BURN BREACH — the loud pause (Rule 15). Surface the burn profile and the
# person's choices. Write NOTHING: the machinery never raises a setpoint, so the
# worktree the breach pauses over stays byte-identical. Raising the ceiling is the
# person's commit to project.json, never this script's act. (Distinct from the
# [13.5] FORESEEN breach above, which DECLARES without stopping — this is the hard
# stop for burn that has ALREADY crossed the setpoint.)
# ════════════════════════════════════════════════════════════════════════════════
cat <<EOF
[budget-gate] BREACH ${WHERE} — the ${BREACH_KIND} budget is exhausted.

  burn profile
    ${BREACH_KIND} burn:   ${BREACH_BURN} tokens
    ${BREACH_KIND} budget: ${BREACH_BUDGET} tokens
    over by:               $((BREACH_BURN - BREACH_BUDGET)) tokens${BREACH_WINDOW_LINE}

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
