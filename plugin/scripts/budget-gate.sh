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
# and the burn sum read ONE shared projection of the log (`contrib_jq` below)
# rather than two filters that have to be kept in agreement — so a vintage can
# only be raised by an entry that actually contributes burn, and the per-vintage
# subtotals reconcile to the printed total by construction rather than by care.
#
# One thing the banner does NOT do: it never clears. A window that has once
# spanned both vintages spans them for its whole life, because the log is
# append-only — the disclosure is a standing property of this initiative, not a
# task to work off.
#
# SETPOINT UNIT MISMATCH ([9.1], 2026-07-26) ───────────────────────────────────
# The banner above keys off the BURN's vintages, and for a long time that was the
# whole check — which left its exact mirror silent by construction. A window that
# is uniformly ONE vintage raises nothing there (correctly: nothing about it is
# mixed), yet if the setpoint was chosen in the OTHER vintage the comparison is
# just as invalid. Initiative 004 sat in that hole: one pre-dedupe entry
# (186,946,906) against a ceiling re-denominated post-fix, reported as ~18.7% of
# budget consumed where the truth was ~3-4%, with nothing printed at either
# boundary.
#
# The missing evidence was never in the log — a setpoint is an integer and
# integers carry no unit, so no amount of scanning recovers it. It has to be
# DECLARED: `budgets.initiative.harvest_basis` ("per_response" | "pre-dedupe"),
# written by the same person's commit that sets the ceiling. With it present the
# gate compares units and raises its own declaration when they differ, naming a
# DERIVED direction — pre-dedupe burn under a post-dedupe ceiling reads HIGH and
# stops early (a phantom BREACH: wasteful, never leaky), post-dedupe burn under a
# pre-dedupe ceiling reads LOW and stops late (PHANTOM HEADROOM: the dangerous
# one), and an `unknown` burn vintage supports neither claim so it says so.
#
# Absent, the check stays OFF and silent (ratified 2026-07-26). The gate genuinely
# cannot tell what unit an undeclared ceiling was chosen in, and a banner that
# fires for every project that never set the field is not a warning — the same
# reasoning that keeps the mixed banner meaningful. Declaring the basis is what
# buys the check. A MALFORMED value is worse than an absent one and is treated
# accordingly: it can equal no vintage, so acting on it would raise a mismatch
# forever and the obvious remedy for a permanent alarm is to move a setpoint that
# was never wrong — so it is named once with the legal values and degrades to
# undeclared. The two banners are mutually exclusive: a mixed window matches no
# single declared basis by construction, and two headlines with two different
# remedies for one defect is worse than one.
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

# The unit the initiative setpoint was CHOSEN in — the half of the comparison a
# number cannot carry. A setpoint is an integer; integers record no unit, so the
# mixed-vintage scan below can describe the burn's harvest unit precisely and still
# have nothing to compare it TO. That gap is not theoretical: a window that is
# uniformly one vintage raises no mixed banner by design, and if the setpoint was
# chosen in the OTHER vintage the gate compares across the seam in total silence.
#
# Person-supplied and OPT-IN (ratified 2026-07-26). An absent marker means the unit
# is genuinely unknown, and the gate stays silent about it rather than nagging every
# project that never set the field — a warning that fires unconditionally is not a
# warning, the same principle that keeps the mixed banner meaningful. Declaring the
# basis is what buys the check. Like every setpoint field it is written by a person's
# commit; nothing here ever writes it, and it never changes an exit code.
INITIATIVE_BASIS=$(jq -r '.budgets.initiative.harvest_basis // empty' "$MANIFEST" 2>/dev/null)
# Validated against the vintage vocabulary the scan actually emits, because an
# unrecognized value is the expensive failure here rather than a harmless one: it can
# never equal any vintage, so the mismatch banner would fire forever, and the obvious
# remedy for a permanent mismatch alarm is to re-denominate a setpoint that was already
# correct. A typo must read as a malformed manifest, not as evidence about units. So it
# is named once, with the legal values, and then degrades to undeclared (Rule 15 — the
# designed rung is "unknown", which is exactly what an unparseable declaration leaves
# behind). "unknown" itself is not legal: it is what the scan emits for a DEGRADED
# harvest, and a setpoint whose unit is declared unknown declares nothing.
BASIS_MALFORMED=""
case "$INITIATIVE_BASIS" in
  ''|per_response|pre-dedupe) ;;
  *) BASIS_MALFORMED="$INITIATIVE_BASIS"; INITIATIVE_BASIS="" ;;
esac

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
BURN_VINTAGE_NAMES=""
if [ -f "$LOG" ]; then
  # Burn is summed SLICE-AWARE ([13.5] — the [13.6] migration budget-gate was
  # disclosed as owing). An entry's tokens is a BOUNDED per-session slice only when
  # slice_basis is per_deliverable or since_process_start — those are summed
  # DIRECTLY. LEGACY entries (pre-[13.6], no slice_basis key) are cumulative running
  # totals: DIFFERENCED per runtime_session at READ time (the log stays append-only).
  # unbounded_cumulative (the disclosed degradation) and tokens:null are NOT burn
  # samples. A negative legacy delta (out-of-order / pruned) is dropped, never a
  # fabricated burn (Rule 15). The differencing is the unit honesty that keeps a
  # cumulative snapshot from inflating burn ~4.6× (the forensic bug found during guv's
  # own development; the analysis is a maintainer artifact, not a doc shipped in this
  # code repo — [15.6]). A raw sum of cumulative snapshots is exactly the over-count
  # that bug produced.
  #
  # This is NOT the same read projection.sh observed_rate() performs, and saying so was
  # false from the moment [9.7]'s vintage filter landed. The two readers diverge on
  # purpose: a BURN legitimately sums every entry in its window and then DISCLOSES the
  # mix, because the question is "what has this cost". A RATE cannot average across two
  # harvest units at all, so observed_rate() EXCLUDES pre-fix entries outright rather
  # than differencing them in. Same log, two questions, two correct answers.
  #
  # THE CONTRIBUTING SET IS DEFINED ONCE, HERE. Two readers need it — the burn sum
  # and the vintage scan that describes the burn's unit — and when they were written
  # as two filters sixty lines apart they drifted within a single commit ([9.1] round
  # 2: an unbounded_cumulative entry, excluded from burn by design, announced a mixed
  # window against a burn that was entirely per_response). So the projection is
  # written once and both readers consume it. It emits one {v, b} per CONTRIBUTING
  # entry — v the harvest vintage, b the tokens that entry actually contributes — so
  # a vintage can only be raised by an entry the burn sum reads, and the per-vintage
  # subtotals sum to the burn exactly rather than approximately.
  contrib_jq() {  # $1 = a jq boolean selecting the entries (post-schema)
    cat <<JQ
      def burn: (.input // 0) + (.output // 0) + (.cache_read // 0) + (.cache_creation // 0);
      # The vintage axis. An ABSENT harvest_basis is pre-fix by construction — the
      # field did not exist when those entries were written. An explicit null is
      # different: the harvest ran and could not record its basis, so the unit is
      # unknown rather than old, and calling it "pre-dedupe" would be a guess.
      def vintage: if has("harvest_basis") then (.harvest_basis // "unknown") else "pre-dedupe" end;
      [ .[] | select((.schema // "") | startswith("guv.meter")) ] as \$all
      # Bounded slices are STANDALONE (each tagged with its own session), so the
      # selection filters them directly.
      | [ \$all[] | select($1) | select(.tokens != null)
                  | select((.slice_basis // "") as \$sb | \$sb == "per_deliverable" or \$sb == "since_process_start")
                  | {v: vintage, b: (.tokens | burn)} ] as \$direct
      # Legacy cumulatives MUST be differenced over the FULL per-runtime_session
      # series BEFORE the selection — a runtime_session can span sessions, so a
      # delta's baseline is the prior cumulative, which may sit in ANOTHER session.
      # Filtering first would drop that baseline and count a survivor's full
      # cumulative (the ~4.6× reinflation the [13.6] migration killed). So difference
      # the whole series, carry each delta on its entry, THEN apply the selection.
      | [ \$all[] | select(.tokens != null) | select(has("slice_basis") | not) ] as \$legacy
      | ( \$legacy | group_by(.runtime_session)
          | map( . as \$g
                 | [ range(0; (\$g | length)) as \$i
                     | \$g[\$i] as \$e
                     | (if \$i == 0 then (\$e.tokens | burn) else (\$e.tokens | burn) - (\$g[\$i-1].tokens | burn) end) as \$delta
                     | \$e + {_burn_delta: \$delta} ] )
          | add // [] ) as \$legacy_d
      # select the differenced deltas the SAME way, dropping negatives (out-of-order
      # / pruned series — never a fabricated burn, Rule 15).
      | [ \$legacy_d[] | select($1) | select(._burn_delta >= 0)
                       | {v: vintage, b: ._burn_delta} ] as \$legacy_c
      | ( \$direct + \$legacy_c )
JQ
  }
  burn_sum() {  # $1 = a jq boolean selecting the entries to sum (post-schema)
    jq -rs "$(contrib_jq "$1") | map(.b) | add // 0" "$LOG" 2>/dev/null
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
  # exit code, and never re-denominates a number. Re-denominating a budget is a human
  # commit to budgets.{initiative,session}.tokens; the machinery never moves a setpoint.
  # (Re-BANKING is a different operation entirely — projection.sh bank writes a forecast
  # entry and does not touch a setpoint — and naming it here once sent a reader to a
  # command that cannot perform this remedy. Keep the two verbs distinct.)
  if [ -n "$INITIATIVE_SINCE" ]; then
    VSEL="((.ts // \"\") >= \"$INITIATIVE_SINCE\")"
  else
    VSEL='true'
  fi
  # Same projection as the burn, so the vintages describe the number they ride with
  # and the subtotals below reconcile to it. Each vintage is reported with BOTH its
  # entry count and its TOKEN SUBTOTAL, because count alone answers the wrong
  # question: one pre-dedupe entry beside one per_response entry reads 1:1 by count
  # while being ~99% pre-dedupe by tokens, which is the opposite of the signal the
  # operator needs to decide whether re-denominating is urgent.
  # Three fields, pipe-separated: the COUNT, the BARE vintage names, the display
  # string. The bare names are emitted rather than recovered from the display for the
  # same reason the count is — the setpoint-unit check below compares a vintage name
  # for equality, and a name sliced back out of "pre-dedupe (1 entry, 4000 tokens)"
  # is a parse of prose that the next display tweak silently breaks.
  BURN_VINTAGES=$(jq -rs "$(contrib_jq "$VSEL")
    | group_by(.v)
    | (length | tostring) + \"|\"
      + (map(.[0].v) | join(\",\")) + \"|\"
      + (map(\"\(.[0].v) (\(length) \(if length == 1 then \"entry\" else \"entries\" end), \(map(.b) | add) tokens)\")
         | join(\", \"))
  " "$LOG" 2>/dev/null)
  # Split the count and the names off the display string. The count drives the decision
  # below — counting commas in the display would break the moment a vintage name
  # carried one.
  case "$BURN_VINTAGES" in
    *'|'*)
      BURN_VINTAGE_N=${BURN_VINTAGES%%|*}
      BURN_VINTAGE_REST=${BURN_VINTAGES#*|}
      BURN_VINTAGE_NAMES=${BURN_VINTAGE_REST%%|*}
      BURN_VINTAGES=${BURN_VINTAGE_REST#*|}
      ;;
    *) BURN_VINTAGE_N=0; BURN_VINTAGES=""; BURN_VINTAGE_NAMES="" ;;
  esac
  case "$BURN_VINTAGE_N" in ''|*[!0-9]*) BURN_VINTAGE_N=0 ;; esac
fi

# Where this gate is speaking from — needed by every declaration below, so it is
# derived once here rather than beside the first one that happened to need it.
WHERE=$([ "$PHASE" = "entry" ] && echo "at session entry" || echo "at session exit")

# --- the unit hazard, derived ONCE for every consumer below -----------------------
# Three states:
#   none     — the burn is in one unit and nothing on record contradicts it
#   mixed    — the window spans more than one harvest unit, so the total is in no unit
#   mismatch — the window is uniformly ONE unit, and the setpoint is DECLARED as the other
#
# Derived here rather than inside whichever banner needs it first, because THREE
# consumers need the same answer: the two banners AND the FORESEEN OVERRUN remedy menu.
# Deriving it separately in each is exactly the defect this replaces — the menu's
# anti-remedy-loop qualifier was gated on a mixed window (N > 1) while the mismatch
# banner required a uniform one (N == 1), so the two were mutually exclusive BY
# CONSTRUCTION and the qualifier could never fire in the case it was written for. An
# operator who had just correctly re-denominated their ceiling DOWN was met, twelve
# lines later and with no caveat, by a menu leading with EXTEND. One derivation, three
# readers, no seam for them to drift across.
#
# The mismatch arm requires an initiative SETPOINT as well as a declared basis: with no
# ceiling there is no comparison to be mis-denominated, and the headline ("the burn and
# the setpoint are denominated in different units") would assert a setpoint that does
# not exist while remedy 1 pointed at a field nobody had set.
UNIT_HAZARD="none"
UNIT_DIR="undetermined"
UNIT_DIR_WHY=""
if [ "$BURN_VINTAGE_N" -gt 1 ]; then
  UNIT_HAZARD="mixed"
elif [ "$BURN_VINTAGE_N" -eq 1 ] && [ -n "$INITIATIVE_BASIS" ] && [ -n "$INITIATIVE_BUDGET" ] \
     && [ "$BURN_VINTAGE_NAMES" != "$INITIATIVE_BASIS" ]; then
  UNIT_HAZARD="mismatch"
fi

# The DIRECTION is derived from the DECLARED setpoint basis, never fixed, and it is what
# makes the hazard actionable — "the units differ" tells an operator nothing about which
# way to move. Pre-dedupe readings are inflated ~2.5x, so the CEILING's unit decides:
#   ceiling in per_response (the true unit) → the inflated burn OVERSTATES → phantom BREACH
#     (conservative — the gate pauses on a setpoint the real work has not reached)
#   ceiling in pre-dedupe (the inflated unit) → the burn UNDERSTATES → phantom HEADROOM
#     (dangerous — the ceiling admits ~2.5x more real work than it was meant to)
# This holds for a MIXED window too: whatever the mix, the pre-dedupe portion inflates
# against a per_response ceiling and the per_response portion deflates against a
# pre-dedupe one. The mixed banner used to hardcode "the likeliest direction is PHANTOM
# HEADROOM" — a prior about how ceilings had historically been chosen, not evidence, and
# refuted the moment a manifest declares otherwise. It held the evidence and guessed anyway.
if [ "$UNIT_HAZARD" != "none" ]; then
  case "$INITIATIVE_BASIS" in
    per_response) UNIT_DIR="breach" ;;
    pre-dedupe)   UNIT_DIR="headroom" ;;
    # UNDECLARED is not the same as unknowable, and collapsing the two costs the operator
    # the only actionable half of the disclosure. With no declaration there is still a
    # defensible PRIOR — ceilings have historically been sized against whatever the meter
    # reported at the time, which was the inflated unit — so headroom remains the likeliest
    # direction. It is carried as an explicitly-labelled prior, never as a reading of the
    # manifest, and the banner says which it is. What was wrong before was asserting this
    # prior while HOLDING a declaration that refuted it; the fix is to prefer the evidence
    # when it exists, not to go silent when it does not.
    *)            UNIT_DIR="headroom_prior"; UNIT_DIR_WHY="undeclared" ;;
  esac
  # An "unknown" burn vintage (a degraded harvest) supports NEITHER claim no matter what
  # the ceiling is declared in: an unrecorded unit is not known to be inflated ~2.5x, or
  # to be anything at all. Naming a direction there would state an inference as evidence —
  # the same error V12 pins one layer down, on the vintage axis itself.
  case "$BURN_VINTAGE_NAMES" in
    *unknown*) UNIT_DIR="undetermined"; UNIT_DIR_WHY="unrecorded" ;;
  esac
fi

# One sentence per direction, composed once and shared by both banners so they cannot
# contradict each other about the same window — which is exactly what happened while
# each carried its own copy.
case "${UNIT_DIR}:${UNIT_DIR_WHY}" in
  breach:*)
    UNIT_DIR_TEXT="the burn OVERSTATES against this ceiling — a PHANTOM BREACH. Pre-dedupe
readings run ~2.5x high, so the gate will pause on a setpoint the real work has not
reached. Conservative, not dangerous: it wastes attention, it does not leak budget." ;;
  headroom:*)
    UNIT_DIR_TEXT="the burn UNDERSTATES against this ceiling — PHANTOM HEADROOM. The
setpoint was chosen in the inflated unit, so it admits roughly 2.5x more real work
than it was meant to before it ever raises. This is the dangerous direction." ;;
  headroom_prior:*)
    UNIT_DIR_TEXT="the likeliest direction is PHANTOM HEADROOM: a ceiling set in the
inflated unit lets far more real work through than it was meant to. Read that as a PRIOR
— ceilings get sized against whatever the meter reported at the time — and not as a
reading of this manifest, which declares nothing either way. Declare
budgets.initiative.harvest_basis and this is DERIVED instead of assumed." ;;
  *:unrecorded)
    UNIT_DIR_TEXT="the direction is UNDETERMINED. One side of this comparison is an
unrecorded unit, so neither overstatement nor headroom can be claimed — the size of
the error is unknown, not small." ;;
  *)
    UNIT_DIR_TEXT="the direction is UNDETERMINED — neither overstatement nor headroom can
be claimed from the record as it stands." ;;
esac

# The remedy follows from the DIRECTION, and naming the wrong one is worse than naming
# none: the banner is standing (nothing clears it), so an operator re-reads it at every
# boundary for the rest of the initiative. Telling someone to re-denominate a ceiling
# that is already correct is a standing instruction to break a working state. WAIT is a
# first-class rung here, not the absence of a remedy — when the ceiling is already in the
# post-fix unit the inflated side is the burn, and the burn is self-correcting because
# every new entry is post-fix. Composed out here because a heredoc cannot hold a
# conditional.
case "$UNIT_DIR" in
  headroom|headroom_prior)
    MX_REMEDY="The remedy is one commit by a person: re-denominate budgets.{initiative,session}.tokens
in .claude/project.json into the post-fix unit. The machinery never moves a setpoint." ;;
  breach)
    MX_REMEDY="There is nothing to re-denominate. The ceiling is ALREADY declared in the post-fix
unit — it is the BURN side that is inflated, and that side is self-correcting: every new
entry is harvested post-fix, so the window's mixed total converges on the true unit as
work continues. WAIT is the remedy here. Moving the setpoint now would break a ceiling
that is already right. The machinery never moves one either." ;;
  *)
    MX_REMEDY="No remedy can be chosen yet: while the setpoint's own unit is undeclared there is
nothing to say which side is wrong. Declare budgets.initiative.harvest_basis first — the
direction above follows from it, and so does which side needs correcting (if either)." ;;
esac

# The instruction to declare a basis must not print to someone who already has. Complying
# and then being told to comply again is the acknowledgment-path defect in a new costume,
# and it teaches an operator that the banner is not reading their manifest.
if [ -n "$INITIATIVE_BASIS" ]; then
  MX_DECLARE="
The setpoint's unit is declared as \"${INITIATIVE_BASIS}\" (budgets.initiative.harvest_basis),
so the direction named above was DERIVED from your manifest, not assumed from how ceilings
are usually chosen."
else
  MX_DECLARE="
This banner reads the burn's vintages. To have the SETPOINT's unit read too, declare
it: budgets.initiative.harvest_basis, \"per_response\" or \"pre-dedupe\". With it set, the
direction above stops being a guess, the remedy names the side that is actually wrong,
and a window that is uniformly one vintage but denominated against the other raises its
own setpoint-unit declaration — the case this banner structurally cannot reach, since
there is nothing mixed about it. Undeclared, that comparison stays silent.

(Lowercase there deliberately: the other banner's headline is the exact uppercase
string, and repeating it in prose makes every grep for that headline match this
paragraph instead — which is precisely how a caller ends up reporting the wrong
declaration. Name it, do not quote it.)"
fi

# --- vintage disclosure: is this comparison apples-to-apples? ------------------
# Printed BEFORE any breach or overrun, because it qualifies every number below it.
if [ "$BURN_VINTAGE_N" -gt 1 ]; then
  cat <<EOF
[budget-gate] MIXED HARVEST VINTAGE ${WHERE} — the burn window spans more than one harvest unit.

  vintages in window:  ${BURN_VINTAGES}
  burn window:         ${INITIATIVE_WINDOW}
  initiative burn:     ${INITIATIVE_BURN} tokens
  initiative setpoint: ${INITIATIVE_BUDGET:-<none set — session setpoint only>} tokens
EOF
  # The profile above prints at BOTH boundaries; the prose below does not, and the
  # asymmetry is deliberate. Nothing clears this banner, so once a window has spanned
  # the seam it fires at every entry and every exit for the initiative's whole life —
  # and the SessionStart hook pipes the gate's full stdout into every session's
  # additionalContext. Paying ~25 lines of standing context twice a session, for
  # dozens of sessions, to re-read a remedy that is the same every time is a real cost
  # charged against the work the disclosure exists to protect.
  #
  # So the boundary decides the depth. At ENTRY the reader is an agent about to act on
  # a burn figure and needs one thing — do not trust this number as a measurement.
  # At EXIT the reader is a person at the extend/harvest/kill decision, writing the
  # handoff that carries it forward, and needs the whole statement. Neither boundary
  # is silent: the header, the vintages, and the burn print at both. It is the
  # explanation that is paid for once, where it is acted on.
  if [ "$PHASE" != "exit" ]; then
    cat <<'EOF'

Pre-dedupe entries over-count by roughly 2.5x, so the burn above is a total in no
single unit — an upper bound of unknown tightness, not a measurement. Against a
ceiling chosen in the inflated unit it OVERSTATES remaining headroom. Do not size,
compare, or forecast off it. The full statement — the remedy, and the case it
cannot cover — prints at the session-exit gate.
EOF
  else
    cat <<EOF

Entries harvested "pre-dedupe" counted token usage once per transcript LINE rather
than once per API response, which over-counts by roughly 2.5x and varies with the
shape of the work. Summing them beside "per_response" entries produces a total in no
single unit, and comparing that total to a setpoint chosen in one unit is not a
measurement. Against this ceiling, ${UNIT_DIR_TEXT}

This is a DECLARATION, not a stop, and nothing here has been changed or converted.
${MX_REMEDY}

Nothing clears this banner — not even the remedy. The log is append-only, so a window
that has once spanned both vintages spans them for the rest of its life. Expect it at
every boundary until the initiative closes, read the burn above as a mixed total
throughout, and do NOT read its reappearance as the re-denomination having failed.
${MX_DECLARE}
EOF
  fi
fi

# --- setpoint-unit disclosure: the case the mixed banner cannot reach --------------
# Fires only when the mixed banner did NOT. The two describe the same hazard from
# opposite sides — that banner says the burn is in no single unit, this one says the
# burn is in a single unit that is not the setpoint's — and printing both for one
# window would be two names for one defect. When the window IS mixed it already
# cannot match any single declared basis, so the mixed banner subsumes this.
#
# Requires a declared basis: with none, the gate has one unit and no second unit to
# compare it against, and inventing the missing half is the guess this whole section
# exists to refuse.
if [ "$UNIT_HAZARD" = "mismatch" ]; then
  # The headline must not out-claim the body. When the burn's vintage is UNRECORDED the
  # body correctly says the direction is undetermined — but "the burn and the setpoint
  # are denominated in different harvest units" asserts they are KNOWN to differ, which
  # is a stronger claim than an unrecorded unit can support. An unrecorded unit is not a
  # known-different unit, and the headline is the half most readers act on.
  if [ "$UNIT_DIR_WHY" = "unrecorded" ]; then
    MM_HEAD="the burn's harvest unit is UNRECORDED, so this comparison cannot be validated."
  else
    MM_HEAD="the burn and the setpoint are denominated in different harvest units."
  fi
  # The remedy menu is direction-specific because the CORRECT action genuinely differs,
  # and the standing-banner problem makes naming the wrong one expensive: this fires at
  # every boundary until the window changes, so a wrong instruction is re-read dozens of
  # times. Under a phantom BREACH the ceiling is already right and the burn is the stale
  # side — WAIT is correct and both "fix it" moves would damage a working state. Under
  # phantom HEADROOM the ceiling itself is wrong and waiting fixes nothing, because a
  # setpoint does not decay. Offering the same two remedies for both was how the live 004
  # case ended up with a menu whose every option was wrong.
  case "$UNIT_DIR" in
    breach)
      MM_REMEDY="Three responses, and for THIS direction the first is usually right:

  WAIT (no commit) — the ceiling is already in the unit you want; it is the BURN that is
    stale. Every new entry is harvested post-fix, so this clears itself as work continues.
    When the first post-fix entry lands, the window stops being uniform and this banner is
    replaced by MIXED HARVEST VINTAGE. Nothing is owed from you meanwhile.
  RE-DENOMINATE budgets.initiative.tokens — only if the ceiling was in fact chosen in the
    burn's unit and the setpoint basis named above is what is wrong.
  CORRECT budgets.initiative.harvest_basis — only if the setpoint is right and the marker
    misdescribes it.

Read the burn above as an over-count of unknown tightness in the meantime, not as a
measurement — but note that over-counting is the safe direction, and waiting is a
designed rung here, not an unfixed defect." ;;
    headroom)
      MM_REMEDY="Waiting does NOT clear this one — a setpoint does not decay, and the ceiling is the
side in the wrong unit. Two remedies, both a person's commit: re-denominate
budgets.initiative.tokens into the unit this window is actually recorded in, or — if the
setpoint is right and the marker is wrong — correct budgets.initiative.harvest_basis. Do
not treat the burn above as a measurement against this ceiling until one of them is done,
and treat any headroom it appears to show as unearned." ;;
    *)
      MM_REMEDY="Neither remedy can be chosen from this evidence. The burn's unit is unrecorded, so
re-denominating the ceiling \"into the unit this window is recorded in\" names a unit that
does not exist, and the marker is not necessarily wrong either — the LOG is what is
degraded. Repair the harvest (or discard the unrecorded entries) before treating any
comparison against this ceiling as a measurement." ;;
  esac
  cat <<EOF
[budget-gate] SETPOINT UNIT MISMATCH ${WHERE} — ${MM_HEAD}

  burn vintage:        ${BURN_VINTAGES}
  setpoint basis:      ${INITIATIVE_BASIS} (declared in budgets.initiative.harvest_basis)
  burn window:         ${INITIATIVE_WINDOW}
  initiative burn:     ${INITIATIVE_BURN} tokens
  initiative setpoint: ${INITIATIVE_BUDGET} tokens
EOF
  # Same entry/exit economy the mixed banner above is built on, and for the same reason:
  # nothing clears this until the window itself changes, the SessionStart hook pipes the
  # gate's stdout into every session's context, and the direction/remedy paragraphs are
  # identical every time. At ENTRY the reader is an agent about to act on a burn figure
  # and needs one fact — this number is not a measurement. At EXIT the reader is a person
  # at the extend/harvest/accept decision, writing the handoff that carries it forward.
  if [ "$PHASE" != "exit" ]; then
    cat <<'EOF'

Every entry in this window shares one harvest unit, so nothing here is MIXED — which is
exactly why this was silent before the check existed. The burn above is not a measurement
against this ceiling: do not size, compare, or forecast off it. The direction, the remedy,
and what clears it print at the session-exit gate.
EOF
  else
    cat <<EOF

Every entry in this window shares one harvest unit, so nothing here is MIXED — and
that is exactly why it was silent before this check existed. The comparison is still
invalid: ${UNIT_DIR_TEXT}

This is a DECLARATION, not a stop. Nothing has been changed or converted, and the
machinery never moves a setpoint.

${MM_REMEDY}
EOF
  fi
fi

# --- a malformed basis marker is reported, then ignored ---------------------------
# Printed whether or not any other banner fired, because it describes the INSTRUMENT
# rather than the reading: while it stands, the setpoint-unit check silently does not
# run, and a check believed to be running is worse than one known to be off.
if [ -n "$BASIS_MALFORMED" ]; then
  cat <<EOF
[budget-gate] MALFORMED SETPOINT BASIS ${WHERE} — budgets.initiative.harvest_basis is "${BASIS_MALFORMED}", which is not a harvest unit.

  legal values:        per_response (post-dedupe) | pre-dedupe
  effect:              the setpoint-unit check is OFF for this initiative

Ignored rather than guessed at: the value matches no vintage the meter records, so
acting on it would raise a mismatch against every window forever, and the obvious fix
for a permanent alarm is to move a setpoint that was never wrong. Correct the value or
remove the field — an absent marker is a supported state and simply leaves the check
off.
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
          # A mixed-vintage record poisons BOTH sides of this forecast, and the
          # standing banner above is not enough on its own: this block's remedy menu
          # leads with EXTEND, so an operator who has just done the right thing —
          # re-denominated the ceiling down into the post-fix unit — is met by a gate
          # demanding they raise it back. That loop is the reason this qualifier is
          # inline rather than left to the banner: the menu is where the wrong move
          # gets made, so the correction has to be at the menu. Composed before the
          # heredoc because a heredoc cannot hold a conditional.
          MIXNOTE=""
          # Fires on ANY unit hazard, not only a mixed window. Gating this on N > 1 while
          # the mismatch banner required N == 1 made the two mutually exclusive by
          # construction, so the qualifier was unreachable in precisely the case it was
          # written for — see the derivation of UNIT_HAZARD above. The menu is where the
          # wrong move gets made, so the correction has to be AT the menu.
          if [ "$UNIT_HAZARD" != "none" ]; then
            # Which banner to send them back to, so the pointer cannot name a banner that
            # did not print.
            case "$UNIT_HAZARD" in
              mixed) MIXBANNER="MIXED HARVEST VINTAGE" ;;
              *)     MIXBANNER="SETPOINT UNIT MISMATCH" ;;
            esac
            # The direction decides whether EXTEND is merely premature or actively
            # backwards, and they are not the same warning.
            case "$UNIT_DIR" in
              breach)
                MIXADVICE="EXTEND is the wrong first move here. The BURN side is inflated against this ceiling,
so this overrun may be wholly an artifact of the old unit rather than real work, and raising
a ceiling to accommodate tokens that were never spent is the one move waiting cannot undo.
If you have JUST re-denominated the setpoint down into the post-fix unit, expect this
declaration to keep firing for the rest of this initiative: the log is append-only, so the
inflated entries never leave the window. That is the arithmetic working, not the remedy
failing." ;;
              headroom|headroom_prior)
                MIXADVICE="EXTEND is the wrong first move here, and for the dangerous reason: the CEILING is the
side in the inflated unit, so the real overrun is likely LARGER than the figure above, not
smaller. Waiting does not clear it — a setpoint does not decay. Re-denominate the ceiling
into the post-fix unit first, then read this line again. And once you have: expect this
declaration to keep firing for the rest of this initiative, because the burn side is still
counted in the old unit and the log is append-only. That is the arithmetic working, not
the remedy failing." ;;
              *)
                MIXADVICE="No move can be chosen from this evidence. One side of the comparison is in an
undetermined unit, so whether this overrun is real or an artifact is not knowable from the
record as it stands. Settle the units before acting on any option below." ;;
            esac
            MIXNOTE="
READ THE ${MIXBANNER} BANNER ABOVE FIRST — it qualifies both figures in this forecast, and
they are not qualified the same way. Burn-to-date is summed from the entries that banner
describes. The cost-to-complete is NOT: the observed rate excludes pre-fix entries
outright, so it either rests on post-fix samples or falls back to the structural estimate
named in the forecast basis above. The projected total therefore ADDS TWO NUMBERS THAT ARE
NOT IN THE SAME UNIT AS EACH OTHER, and no single divisor converts one into the other.

${MIXADVICE}
"
          fi
          # The forecast's own basis, disclosed. projection.sh emits claim/n/observed_weight
          # precisely so an n=0 read is legible, and this gate — the only consumer that
          # prints a forecast to a PERSON — read the spine and the range and never the
          # basis. A modeled number and a measured one look identical once they are both
          # just digits, and the extend/harvest/accept call is made off these digits.
          BASISNOTE=""
          PCLAIM=$(printf '%s' "$PROJ" | jq -r '.basis.claim // empty' 2>/dev/null)
          PN=$(printf '%s' "$PROJ" | jq -r '.basis.n // empty' 2>/dev/null)
          case "$PN" in ''|*[!0-9]*) PN="" ;; esac
          if [ "$PCLAIM" = "structural" ] || { [ -n "$PN" ] && [ "$PN" -eq 0 ]; }; then
            BASISNOTE="
    forecast basis:        MODELED — ${PN:-0} observed sessions contributed. The cost-to-complete
                           above is the structural estimate (remaining sessions x a per-session
                           constant): a statement about the PLAN'S SHAPE, not about how this
                           project has actually been burning. The range is the honest width."
          elif [ -n "$PCLAIM" ]; then
            BASISNOTE="
    forecast basis:        ${PCLAIM} — ${PN:-?} observed session(s) contributed."
          fi
          cat <<EOF
[budget-gate] FORESEEN OVERRUN ${WHERE} — the initiative is PROJECTED to exceed its budget.

  forecast profile
    burn to date:          ${INITIATIVE_BURN} tokens
    projected to complete: ${CTC} tokens (range ${PLOW:-?}–${PHIGH:-?})
    projected total:       ${PROJECTED_TOTAL} tokens
    initiative budget:     ${INITIATIVE_BUDGET} tokens
    projected over by:     $((PROJECTED_TOTAL - INITIATIVE_BUDGET)) tokens
    burn window:           ${INITIATIVE_WINDOW}${BASISNOTE}
${MIXNOTE}
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
