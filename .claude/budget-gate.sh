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
# HARVEST UNIT HAZARD ([9.1]) ──────────────────────────────────────────────────
# Burn and setpoint are only comparable if both are denominated in the same unit.
# The meter's pre-dedupe harvest counted usage once per transcript LINE rather
# than once per API response, so those entries overstate by the response's
# content-block count — by a factor that varies with the shape of the work, which
# is why no single divisor converts them. Entries harvested after the fix
# self-describe with `harvest_basis: per_response`; earlier ones carry no such
# field. A setpoint carries no unit at all — it is an integer — so its unit must be
# DECLARED: `budgets.initiative.harvest_basis`, written by the same commit that
# sets the ceiling. Absent, the setpoint half of the check stays OFF and silent
# (ratified 2026-07-26): the gate cannot tell what unit an undeclared ceiling was
# chosen in, and a banner that fires for every project that never set the field is
# not a warning.
#
# ONE banner covers three kinds of the same hazard, carried as a `hazard:` FIELD:
#   mixed     — the burn window spans both vintages, so the total is in no unit
#   mismatch  — the window is uniformly one vintage and the setpoint declares the
#               other (initiative 004 sat exactly here: one pre-dedupe entry,
#               186,946,906, against a post-fix ceiling — read as ~18.7% of budget
#               where the truth was ~3-4%, with nothing printed at either boundary)
#   malformed — the declaration is not a legal unit, so the check is off
# A burn vintage of `unknown` (a degraded harvest) supports no direction at all and the
# banner says so rather than picking one.
# It was three separate banners until 2026-07-26, each carrying its own copy of the
# direction, the remedy, and the persistence note; the copies drifted, every review
# pass finding a fresh contradiction between them. One derivation, one banner, one
# place for each statement.
#
# The DIRECTION is what makes it actionable, and it follows the CEILING's unit:
# pre-dedupe burn under a post-fix ceiling reads HIGH and stops early (a phantom
# BREACH — wasteful, never leaky); post-fix burn under a pre-dedupe ceiling reads
# LOW and stops late (PHANTOM HEADROOM — the dangerous one). Undeclared, headroom
# is carried as an explicitly-labelled PRIOR, never as a reading of the manifest.
# MALFORMED derives no direction at all and outranks the other two: offering a unit
# remedy against a known-broken instrument is how an operator moves a setpoint that
# was never wrong.
#
# It is a disclosure — not a conversion and not a stop. Re-denominating a setpoint
# is a human commit to project.json, exactly like raising one. The vintage scan and
# the burn sum read ONE shared projection of the log (`contrib_jq` below) rather
# than two filters that have to be kept in agreement, so a vintage can only be
# raised by an entry that actually contributes burn and the per-vintage subtotals
# reconcile to the printed total by construction. And it never clears: the log is
# append-only, so a window that has once spanned the seam carries it for its whole
# life — a standing property of the initiative, not a task to work off.
#
# SETPOINT DENOMINATION HAZARD ([28.5]) ────────────────────────────────────────
# The SECOND way burn and setpoint fail to be comparable, and independent of the
# first: `harvest_basis` above says HOW a reading was harvested, never WHAT UNIT
# the number is in. Burn is unambiguous — `burn` below adds input + output +
# cache_read + cache_creation unweighted, in code — so the burn side is a raw
# four-class count by construction and this axis needs no scan of the log. The
# setpoint side carries nothing at all, so a ceiling chosen in COST-WEIGHTED
# tokens (base-input-equivalents: cache_read 0.1x, cache_creation 2x, output 5x)
# was compared against raw burn with nothing able to detect it. Cache reads
# dominate a coding session and are discounted hardest, so the gap is large and
# one-directional: 3.9x, 6.0x and 6.8x measured on guv's own record, with the
# CEILING always the SMALLER side. So burn OVERSTATES against it and the gate
# stops EARLY — a PHANTOM BREACH, the conservative error, wasteful but not leaky.
# Unlike the vintage phantom breach, WAIT is not a rung: that one decays as
# post-fix entries accumulate, whereas burn is a raw four-class sum in code
# permanently, so the two sides never drift back into agreement on their own.
#
# Same contract as the vintage axis, for the same reasons: DECLARED by a person
# (`budgets.initiative.denomination`), ABSENT MEANS THE CHECK IS OFF rather than
# an assumed unit, an out-of-enum value reports MALFORMED rather than guessing,
# and the remedy DISCLOSES rather than converts — the ratio moves with each
# session's output and cache mix, so any single divisor would be fabricated.
# Carried in its own state variable (DENOM_HAZARD) because the two axes fire
# together — the live 004 manifest is a mixed vintage window AND a cost-weighted
# ceiling — and one variable can hold only one state. They share the banner and
# each pays for its own headline clause and its own remedy paragraph; the title
# names whichever axis fired, so a denomination-only hazard never sends an
# operator to inspect a vintage window that is uniform.
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
# "BREACH" names the exit-3 stop alone). A unit hazard prints its own declaration and
# exits 0, headed "[budget-gate] HARVEST UNIT HAZARD …" for the vintage axis and
# "[budget-gate] SETPOINT DENOMINATION HAZARD …" for the denomination axis — both when
# both fire. It rides ALONGSIDE whichever
# burn outcome the window produced, because it says the comparison is in no single
# unit, not what the comparison came out to. Torn (unparseable) metering lines are
# skipped rather than failing the whole read, and announced so the burn is read as a
# floor, headed "[budget-gate] TORN METERING LINES …". (Keep every headline whole on
# ONE line, here and everywhere: the [15.6] drift guard greps this file for them, and a
# headline wrapped across a comment break registers as a second, phantom headline that
# the handoff can never capture.) Within budget / absent budget / no log: silent, exit 0.
#
# Exit: 0 within budget, absent budget, no measurable burn, a FORESEEN breach
#         ([13.5] — declared on stdout for the handoff, never a stop), or a HARVEST
#         UNIT HAZARD disclosure ([9.1] — likewise declared, never a stop)
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

# The DENOMINATION axis ([28.5]) — the second, independent way burn and setpoint fail to
# be comparable. `harvest_basis` above declares HOW a reading was harvested; it cannot
# say WHAT UNIT the number is in. The burn side has no such ambiguity: `burn` sums four
# token classes unweighted, in code, so it is a raw count by construction — which is why
# this axis needs no scan of the log, only the declaration. The setpoint side is a bare
# integer and carries nothing, so a ceiling chosen in cost-weighted tokens (base-input-
# equivalents) is compared against raw burn with nothing able to detect it. Same opt-in
# contract as the vintage axis: absent means the check is OFF, never an assumed unit —
# most projects never think about denomination, and their ceilings are raw.
INITIATIVE_DENOM=$(jq -r '.budgets.initiative.denomination // empty' "$MANIFEST" 2>/dev/null)
# Same degradation as BASIS_MALFORMED, and for the same reason: an unrecognized value
# can never equal the burn's unit, so a guesser would raise a permanent alarm whose
# obvious remedy is to re-denominate a ceiling that was already right. "cost-weighted"
# with a hyphen is the realistic typo — the hyphenated spelling is legal on the OTHER
# axis — so it must read as a malformed manifest, not as evidence about units.
DENOM_MALFORMED=""
case "$INITIATIVE_DENOM" in
  ''|raw_tokens|cost_weighted) ;;
  *) DENOM_MALFORMED="$INITIATIVE_DENOM"; INITIATIVE_DENOM="" ;;
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
LOG_TORN=0
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
      # guv's own writer nulls harvest_basis exactly when it nulls tokens (meter.sh:305)
      # and the selection below drops tokens:null, so "unknown" cannot ride a contributing
      # entry written BY THE METER. The gate does not own this log, so the direction logic
      # below still refuses to claim a polarity for it (V12/V22/V28 pin that).
      def vintage: if has("harvest_basis") then (.harvest_basis // "unknown") else "pre-dedupe" end;
      # PER-LINE TOLERANT (fromjson?), not a slurp. A torn append — a partial line from a
      # killed writer — used to fail the whole parse, and because the caller redirected
      # stderr and defaulted a non-numeric result to 0, the gate's ONLY hard stop then
      # exited 0 with no output at all: a real breach, silently switched off, looking
      # exactly like "within budget". This is the same rung the lineage read above already
      # takes, and its comment there gives the reason verbatim — the blast radius decides.
      # A corrupt line drops THAT LINE and is counted in \$torn, never the whole read.
      [ inputs | fromjson? | select(type == "object") ] as \$lines
      | [ \$lines[] | select((.schema // "") | startswith("guv.meter")) ] as \$all
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
    jq -rRn "$(contrib_jq "$1") | map(.b) | add // 0" "$LOG" 2>/dev/null
  }
  # Torn lines are COUNTED, so the drop can be announced rather than absorbed. A silently
  # partial burn is the same failure the read above just fixed, one level up: the number
  # still prints, still looks like a measurement, and is now a floor of unknown depth.
  LOG_TORN=$(jq -rRn '[ inputs | select(length > 0)
                        | (fromjson? | "ok") // "torn" ]
                      | map(select(. == "torn")) | length' "$LOG" 2>/dev/null)
  case "$LOG_TORN" in ''|*[!0-9]*) LOG_TORN=0 ;; esac
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
  BURN_VINTAGES=$(jq -rRn "$(contrib_jq "$VSEL")
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

# A dropped line is announced, never absorbed. The per-line read above keeps one torn
# append from switching the whole gate off, but the burn it then reports is a FLOOR of
# unknown depth that looks exactly like a measurement. Say so, at both boundaries.
if [ "$LOG_TORN" -gt 0 ]; then
  cat <<EOF
[budget-gate] TORN METERING LINES ${WHERE} — ${LOG_TORN} line(s) in ${LOG} did not parse and were SKIPPED.

Every number below is a FLOOR, not a measurement: the burn omits whatever those lines
carried. The log is append-only, so the usual cause is a writer killed mid-append and the
damage is the tail. Inspect them before acting on any figure here:

  grep -n -v -e '^\$' ${LOG} | while IFS=: read -r n l; do printf '%s' "\$l" | jq -e . >/dev/null 2>&1 || echo "\$n"; done
EOF
fi

# --- the unit hazard, derived ONCE for every consumer below -----------------------
# The four kinds are named in the header. Derived HERE, not inside whichever banner
# needs it first, because two consumers need the same answer — the banner and the
# FORESEEN OVERRUN remedy menu — and deriving it twice is the defect this replaces:
# the menu's anti-remedy-loop qualifier was gated on N > 1 while the mismatch banner
# required N == 1, so the qualifier could never fire in the case it was written for.
#
# The mismatch arm requires an initiative SETPOINT as well as a declared basis: with no
# ceiling there is no comparison to be mis-denominated, and the headline would assert a
# setpoint that does not exist while its remedy pointed at a field nobody had set.
UNIT_HAZARD="none"
UNIT_DIR="undetermined"
UNIT_DIR_WHY=""
if [ -n "$BASIS_MALFORMED" ]; then
  UNIT_HAZARD="malformed"
elif [ "$BURN_VINTAGE_N" -gt 1 ]; then
  UNIT_HAZARD="mixed"
elif [ "$BURN_VINTAGE_N" -eq 1 ] && [ -n "$INITIATIVE_BASIS" ] && [ -n "$INITIATIVE_BUDGET" ] \
     && [ "$BURN_VINTAGE_NAMES" != "$INITIATIVE_BASIS" ]; then
  UNIT_HAZARD="mismatch"
fi

# The denomination hazard ([28.5]) is its OWN state, deliberately not folded into
# UNIT_HAZARD above: the two axes are orthogonal and fire together — the live 004
# manifest is a mixed vintage window AND a cost-weighted ceiling — and one variable can
# hold only one state, so folding them would silently drop whichever lost the precedence.
# Simpler than the vintage machine because the burn side needs no scan: `burn` sums four
# classes unweighted in code, so the comparison is decided by the declaration alone.
# `mismatch` requires a SETPOINT for the same reason the vintage arm does — with no
# ceiling there is nothing to be mis-denominated. `malformed` does not: an unreadable
# declaration is a manifest defect worth naming whether or not a ceiling is set, and it
# takes precedence for the reason argued on the vintage axis — a check believed to be
# running is worse than one known to be off.
DENOM_HAZARD="none"
if [ -n "$DENOM_MALFORMED" ]; then
  DENOM_HAZARD="malformed"
elif [ "$INITIATIVE_DENOM" = "cost_weighted" ] && [ -n "$INITIATIVE_BUDGET" ]; then
  DENOM_HAZARD="mismatch"
fi

# The direction follows the CEILING's unit (argued in the header) and holds for a MIXED
# window too: whatever the mix, the pre-dedupe portion inflates against a per_response
# ceiling and the per_response portion deflates against a pre-dedupe one. A MALFORMED
# marker derives no direction — an absent marker leaves the historical prior intact,
# whereas a marker that was WRITTEN and is unreadable means the operator made a claim the
# gate cannot recover, and asserting the prior over the top of it would answer a question
# they did try to answer.
if [ "$UNIT_HAZARD" = "malformed" ]; then
  UNIT_DIR="undetermined"; UNIT_DIR_WHY="malformed"
elif [ "$UNIT_HAZARD" != "none" ]; then
  case "$INITIATIVE_BASIS" in
    per_response) UNIT_DIR="breach" ;;
    pre-dedupe)   UNIT_DIR="headroom" ;;
    # UNDECLARED is not unknowable: the prior survives, explicitly labelled as one. What
    # was wrong before was asserting it while HOLDING a declaration that refuted it.
    *)            UNIT_DIR="headroom_prior"; UNIT_DIR_WHY="undeclared" ;;
  esac
  # An "unknown" burn vintage supports NEITHER claim, whatever the ceiling declares: an
  # unrecorded unit is not known to be inflated ~2.5x, or to be anything at all.
  case "$BURN_VINTAGE_NAMES" in
    *unknown*) UNIT_DIR="undetermined"; UNIT_DIR_WHY="unrecorded" ;;
  esac
fi

# One sentence per direction, composed once. It is a COMPLETE sentence about this
# comparison — it is read in more than one place, and a fragment that only reads
# correctly after one specific prefix is not shared, it is coupled.
case "${UNIT_DIR}:${UNIT_DIR_WHY}" in
  breach:*)
    UNIT_DIR_TEXT="Against this ceiling the burn OVERSTATES — a PHANTOM BREACH. Pre-dedupe
readings run ~2.5x high, so the gate will pause on a setpoint the real work has not
reached. Conservative, not dangerous: it wastes attention, it does not leak budget." ;;
  headroom:*)
    UNIT_DIR_TEXT="Against this ceiling the burn UNDERSTATES — PHANTOM HEADROOM. The
setpoint was chosen in the inflated unit, so it admits roughly 2.5x more real work
than it was meant to before it ever raises. This is the dangerous direction." ;;
  headroom_prior:*)
    UNIT_DIR_TEXT="The likeliest direction is PHANTOM HEADROOM: a ceiling set in the
inflated unit lets far more real work through than it was meant to. Read that as a PRIOR
— ceilings get sized against whatever the meter reported at the time — and not as a
reading of this manifest, which declares nothing either way." ;;
  *:malformed)
    UNIT_DIR_TEXT="No direction is derived. The setpoint's unit was declared and cannot be
read, so the gate will not fall back to the historical prior: you answered this question,
and overriding an unreadable answer with an assumption would hide that the answer failed
to parse." ;;
  *)
    UNIT_DIR_TEXT="The direction is UNDETERMINED. One side of this comparison is an
unrecorded unit, so neither overstatement nor headroom can be claimed — the size of
the error is unknown, not small." ;;
esac

# THE REMEDY IS DERIVED ONCE, exactly as the direction is. It used to be written three
# times — once per banner — and all three drifted: one told an operator whose log was
# degraded to declare a setpoint basis (the log is what is broken, not the marker), one
# told an operator who had already declared to declare again, and one issued the
# evidence-backed imperative on the strength of a mere prior. A remedy that contradicts
# the state that produced it is worse than no remedy, because this banner is STANDING
# and gets re-read at every boundary for the rest of the initiative.
#
# The hedge must survive into the remedy. Where the direction is only a PRIOR, the
# remedy is conditional too — naming an unconditional commit off an assumption is the
# same guess wearing a different hat, and the population most likely to hit it is the
# one that has ALREADY re-denominated (they just have no marker to say so).
case "$UNIT_HAZARD:$UNIT_DIR" in
  malformed:*)
    UNIT_REMEDY="Correct the value or remove the field — an absent marker is a supported state
and simply leaves the check off. Nothing else here is actionable while the marker is
unreadable: no unit remedy is offered against an instrument known to be broken." ;;
  *:breach)
    UNIT_REMEDY="Three responses, and for THIS direction the first is usually right:

  WAIT (no commit) — the ceiling is already in the unit you want; it is the BURN that is
    stale. Nothing is owed from you.
  RE-DENOMINATE budgets.initiative.tokens — only if the ceiling was in fact chosen in the
    burn's unit and the setpoint basis named above is what is wrong.
  CORRECT budgets.initiative.harvest_basis — only if the setpoint is right and the marker
    misdescribes it.

Read the burn above as an over-count of unknown tightness meanwhile, not as a
measurement — but note that over-counting is the SAFE direction, and waiting is a
designed rung here, not an unfixed defect." ;;
  *:headroom)
    UNIT_REMEDY="Waiting does NOT clear this one — a setpoint does not decay, and the ceiling is
the side in the wrong unit. Two remedies, both a person's commit: re-denominate
budgets.initiative.tokens into the unit this window is actually recorded in, or — if the
setpoint is right and the marker is wrong — correct budgets.initiative.harvest_basis. Do
not treat the burn above as a measurement against this ceiling until one of them is done,
and treat any headroom it appears to show as unearned." ;;
  *:headroom_prior)
    UNIT_REMEDY="No remedy is named, because the direction above is a prior rather than a
reading. IF the ceiling was chosen in the inflated unit, re-denominating
budgets.initiative.tokens is the fix; if it was chosen post-fix, that same commit would
break a ceiling that is already correct. Declare budgets.initiative.harvest_basis and
this stops being a coin-flip: the direction becomes DERIVED and the remedy names the
side that is actually wrong." ;;
  *)
    UNIT_REMEDY="Neither remedy can be chosen from this evidence. The burn's unit is unrecorded,
so re-denominating the ceiling \"into the unit this window is recorded in\" names a unit that
does not exist, and the marker is not necessarily wrong either — the LOG is what is degraded.
Repair the harvest (or discard the unrecorded entries) before treating any comparison against
this ceiling as a measurement." ;;
esac

# What a person can expect to happen to this banner, stated per direction because the
# honest answer differs and the wrong answer is expensive.
#
# The old text said a phantom breach "clears itself as work continues". That is
# relative-true and absolute-false, and the ceiling comparison is absolute. The log is
# APPEND-ONLY, so the inflated pre-dedupe entries are a fixed addend: the RATIO error
# decays toward 1 as post-fix work accumulates, while the absolute over-count never
# decays at all. Telling someone it self-corrects invites them to wait for a correction
# that never arrives. The gate already holds the per-vintage subtotal, so it can say how
# much is stranded rather than implying the answer is zero.
UNIT_PERSIST=""
case "$UNIT_HAZARD:$UNIT_DIR" in
  malformed:*) ;;
  *:breach)
    UNIT_PERSIST="

Nothing clears this. The log is append-only, so the pre-dedupe tokens above stay in the
window permanently — as work continues the RATIO error shrinks toward 1, but the
ABSOLUTE over-count does not shrink at all, and the ceiling comparison is absolute. The
pre-dedupe subtotal named in the profile is roughly 2.5x its real value; the difference
is ceiling permanently consumed by an artifact, and no rung here recovers it. Waiting is
still the right move (the alternatives break a correct ceiling) — it is just not a
repair. If that stranded fraction matters, it is a re-plan input, not a gate action." ;;
  *)
    UNIT_PERSIST="

Nothing clears this banner — not even the remedy. The log is append-only, so a window
that has once spanned the seam carries it for the rest of its life. Expect this at every
boundary until the initiative closes, and do NOT read its reappearance as the remedy
having failed." ;;
esac

# The instruction to declare a basis must not print to someone who already has: complying
# and then being told to comply again teaches an operator that the banner is not reading
# their manifest. Suppressed entirely when the marker is malformed — there the operator
# HAS declared, and the malformed report above is already telling them what to do.
UNIT_DECLARE=""
if [ "$UNIT_HAZARD" = "malformed" ]; then
  UNIT_DECLARE=""
elif [ -n "$INITIATIVE_BASIS" ]; then
  UNIT_DECLARE="

The setpoint's unit is declared as \"${INITIATIVE_BASIS}\" (budgets.initiative.harvest_basis),
so the direction above was DERIVED from your manifest, not assumed from how ceilings are
usually chosen."
else
  UNIT_DECLARE="

This banner reads the burn's vintages. To have the SETPOINT's unit read too, declare it:
budgets.initiative.harvest_basis, \"per_response\" or \"pre-dedupe\". With it set the
direction stops being a guess, the remedy names the side that is actually wrong, and a
window that is uniformly one vintage but denominated against the other is detected at
all — undeclared, that comparison stays silent."
fi

# --- the harvest-unit hazard: ONE banner ------------------------------------------
# Printed BEFORE any breach or overrun, because it qualifies every number below it. The
# three-banners-to-one collapse and the malformed precedence are argued in the header.
if [ "$UNIT_HAZARD" != "none" ] || [ "$DENOM_HAZARD" != "none" ]; then
  HAZ_HEAD=""
  case "$UNIT_HAZARD" in
    malformed) HAZ_HEAD="budgets.initiative.harvest_basis is \"${BASIS_MALFORMED}\", which is not a harvest unit." ;;
    mixed)     HAZ_HEAD="the burn window spans more than one harvest unit." ;;
    # The headline must not out-claim the body: an UNRECORDED unit is not a
    # known-different unit, and the headline is the half most readers act on.
    mismatch)
      if [ "$UNIT_DIR_WHY" = "unrecorded" ]; then
        HAZ_HEAD="the burn's harvest unit is UNRECORDED, so this comparison cannot be validated."
      else
        HAZ_HEAD="the burn and the setpoint are denominated in different harvest units."
      fi ;;
  esac
  # The second axis contributes its own clause. Appended rather than merged so a reader
  # can tell which axis is which — two hazards stated as one sentence read as one
  # problem, and they have different remedies.
  DENOM_HEAD=""
  case "$DENOM_HAZARD" in
    malformed) DENOM_HEAD="budgets.initiative.denomination is \"${DENOM_MALFORMED}\", which is not a denomination." ;;
    mismatch)  DENOM_HEAD="the setpoint is declared cost_weighted while burn is summed as a raw token count." ;;
  esac
  # The title names whichever axis actually fired — a denomination-only hazard under a
  # HARVEST UNIT heading sends the operator to inspect a vintage that is uniform. Both
  # headlines are written out WHOLE and LITERAL here, per the convention stated at the top
  # of this file: the [15.6] drift guard greps this source for the bracketed tag followed
  # by an all-caps headline to derive what the handoff must capture, and it cannot see
  # through a `${VAR}` (nor, being a plain grep, tell prose from output — so do not write
  # a specimen headline into a comment either). Building
  # the title by interpolation alone silently emptied that guard's subject list.
  #
  # When BOTH axes fire, both names are emitted rather than demoting the second to a
  # comma clause: the guard's capture list is keyed by headline string, so a title that
  # never appears is a banner the session record never learns to carry — and on a project
  # sitting in both states (guv itself) the denomination axis is the one that never
  # decays, so it is precisely the wrong one to leave nameless.
  DENOM_TITLE_LINE=""
  if [ "$UNIT_HAZARD" != "none" ]; then
    HAZ_TITLE="[budget-gate] HARVEST UNIT HAZARD"
    if [ -n "$DENOM_HEAD" ]; then
      HAZ_HEAD="${HAZ_HEAD} Also, ${DENOM_HEAD}"
      DENOM_TITLE_LINE="[budget-gate] SETPOINT DENOMINATION HAZARD ${WHERE} — ${DENOM_HEAD}"
    fi
  else
    HAZ_TITLE="[budget-gate] SETPOINT DENOMINATION HAZARD"
    HAZ_HEAD="$DENOM_HEAD"
  fi
  # Same three-state report as the basis line below: declared, malformed (check off), or
  # absent (also off, but a supported state rather than a mistake).
  if [ -n "$INITIATIVE_DENOM" ]; then
    HAZ_DENOM="${INITIATIVE_DENOM} (declared in budgets.initiative.denomination)"
  elif [ -n "$DENOM_MALFORMED" ]; then
    HAZ_DENOM="\"${DENOM_MALFORMED}\" — MALFORMED, the denomination check is OFF; legal values: raw_tokens, cost_weighted"
  else
    HAZ_DENOM="<undeclared — the denomination check is off>"
  fi
  # The basis line reports the DECLARATION's state, which is a third thing beyond the two
  # legal values: declared, malformed (so the check is off), or absent (also off, but a
  # supported state rather than a mistake). Composed here so the heredoc stays readable.
  if [ -n "$INITIATIVE_BASIS" ]; then
    HAZ_BASIS="${INITIATIVE_BASIS} (declared in budgets.initiative.harvest_basis)"
  elif [ -n "$BASIS_MALFORMED" ]; then
    HAZ_BASIS="\"${BASIS_MALFORMED}\" — MALFORMED, the setpoint-unit check is OFF; legal values: per_response, pre-dedupe"
  else
    HAZ_BASIS="<undeclared — the setpoint-unit check is off>"
  fi
  # The kind field carries BOTH axes. It used to be UNIT_HAZARD alone, which was total
  # over its old state space and became partial the moment a second axis could fire on
  # its own: a denomination-only banner printed `hazard: none` under a title ending in
  # HAZARD, and for any project whose meter only ever ran post-[9.1] that is the ONLY
  # reading it can produce. Each state keeps its axis label, and the value still follows
  # `hazard:` immediately so the field stays greppable exactly as before.
  cat <<EOF
${HAZ_TITLE} ${WHERE} — ${HAZ_HEAD}${DENOM_TITLE_LINE:+
${DENOM_TITLE_LINE}}

  hazard:              ${UNIT_HAZARD} (harvest) / ${DENOM_HAZARD} (denomination)
  vintages in window:  ${BURN_VINTAGES:-<none — no metering entries in this window>}
  setpoint basis:      ${HAZ_BASIS}
  denomination:        ${HAZ_DENOM}
  burn window:         ${INITIATIVE_WINDOW}
  initiative burn:     ${INITIATIVE_BURN} tokens
  initiative setpoint: ${INITIATIVE_BUDGET:-<none set — session setpoint only>} tokens
EOF
  # The boundary decides the depth. Nothing clears this banner, so it fires at every
  # entry and every exit for the initiative's whole life — and the SessionStart hook
  # pipes the gate's stdout into every session's additionalContext. At ENTRY the reader
  # is an agent about to act on a burn figure and needs one thing: do not trust this
  # number as a measurement. At EXIT the reader is a person at the extend/harvest/accept
  # decision, writing the handoff that carries it forward. The profile prints at both;
  # it is the explanation that is paid for once, where it is acted on.
  if [ "$PHASE" != "exit" ]; then
    cat <<'EOF'

The burn above is not a measurement against this ceiling: do not size, compare, or
forecast off it. The direction, the remedy, and what clears it print at the
session-exit gate.
EOF
  else
    # Each axis pays for its own explanation, and only when it fired. The vintage prose
    # below describes a harvest seam; printing it for a denomination-only hazard would
    # send the operator to inspect a window that is uniform.
    if [ "$UNIT_HAZARD" != "none" ]; then
      # Conditional on a pre-dedupe entry actually being in the window: it used to print
      # unconditionally, describing a vintage that was not present.
      case "$BURN_VINTAGE_NAMES" in
        *pre-dedupe*) cat <<'EOF'

Entries harvested "pre-dedupe" counted token usage once per transcript LINE rather than
once per API response, which over-counts by roughly 2.5x and varies with the shape of the
work. A total that mixes them with "per_response" entries is in no single unit.
EOF
        ;;
      esac
      cat <<EOF

${UNIT_DIR_TEXT}

This is a DECLARATION, not a stop. Nothing has been changed or converted, and the
machinery never moves a setpoint.

${UNIT_REMEDY}${UNIT_PERSIST}${UNIT_DECLARE}
EOF
    fi
    case "$DENOM_HAZARD" in
      mismatch) cat <<'EOF'

The burn above is a RAW token count: input + output + cache_read + cache_creation, added
unweighted. Your ceiling is declared cost_weighted — base-input-equivalents, where
cache_read counts 0.1x, cache_creation 2x and output 5x. Cache reads dominate a coding
session's token count and are the class discounted hardest, so the raw figure runs
several times the cost-weighted one: 3.9x, 6.0x and 6.8x measured on guv's own record
(one initiative window and two single sessions).

The CEILING is therefore the SMALLER side, and the direction follows from that: the burn
above OVERSTATES against it, so this gate reports more consumed than your ceiling's own
unit implies and will pause on a setpoint the real work has not reached. That is a
PHANTOM BREACH — the conservative error. It wastes attention; it does not leak budget.
Do not read the gap as work you have spent.

WAIT is NOT the rung here, and this is where the denomination axis differs from the
harvest seam: a vintage phantom breach decays on its own as post-fix entries accumulate,
but burn is a raw four-class sum in code, permanently, so nothing about waiting moves
these two numbers into the same unit.

Nothing is converted here, and that is deliberate: the ratio moves with each session's
output and cache mix, so a single divisor would have to be invented — the same reason
the harvest-vintage axis refuses one. The remedy is a person's commit: re-denominate
budgets.initiative.tokens into raw tokens, or — if the ceiling is right and the marker is
wrong — correct budgets.initiative.denomination. This is a DECLARATION, not a stop; the
machinery never moves a setpoint.
EOF
      ;;
      malformed) cat <<'EOF'

While budgets.initiative.denomination is unreadable the denomination check is OFF: the
gate cannot tell whether an initiative ceiling — this one, or the next one set — is in
the same unit as the raw burn it would be compared to. Set it to raw_tokens or
cost_weighted; the value is a declaration about a past human decision, and setting it
changes no number.
EOF
      ;;
    esac
    # Both axes at once. Each paragraph above is correct alone and they point OPPOSITE
    # ways, so an operator who reads either one in isolation acts wrong in a known
    # direction — and both remedies name the same integer. Reconciling is not converting:
    # no net direction is claimed and no divisor is offered. What is stated is the one
    # thing both paragraphs agree on, which is what the single number has to end up being.
    if [ "$UNIT_HAZARD" != "none" ] && [ "$DENOM_HAZARD" = "mismatch" ]; then
      cat <<'EOF'

BOTH AXES ARE LIVE, AND THEY POINT OPPOSITE WAYS. The harvest paragraph and the
denomination paragraph above are each correct on their own axis, and each names
budgets.initiative.tokens — the SAME integer — as its remedy. Read either one alone and
you will move that number the wrong way. No net direction is claimed here: the two
effects do not cancel to anything this gate can compute, because one of them has no
fixed ratio.

What both agree on is the destination. One ceiling, sized in RAW per-response tokens —
the unit the burn above is already summed in — satisfies both axes at once. Sizing it is
a person's judgment against the initiative's forecast, not an arithmetic conversion of
the number currently there.
EOF
    fi
  fi
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
            # The direction decides whether EXTEND is merely premature or actively
            # backwards, and they are not the same warning.
            case "$UNIT_DIR" in
              breach)
                # "some or all", never "wholly": in a MIXED window only the pre-dedupe
                # portion is inflated, and the profile above says what that portion is.
                MIXADVICE="EXTEND is the wrong first move here. The BURN side is inflated against this ceiling,
so some or all of this overrun may be an artifact of the old unit rather than real work, and
raising a ceiling to accommodate tokens that were never spent is the one move waiting cannot
undo. Expect this declaration to keep firing for the rest of the initiative even after you
act: the log is append-only, so the inflated entries never leave the window. That is the
arithmetic working, not the remedy failing." ;;
              headroom|headroom_prior)
                # headroom_prior has NOT read a ceiling unit — it assumed one. Saying
                # "the CEILING is the side in the inflated unit" flatly there states the
                # prior as evidence, and the population most likely to be reading it is
                # the one that already re-denominated and never declared a basis.
                MIXADVICE=""
                [ "$UNIT_DIR" = "headroom_prior" ] && MIXADVICE="The setpoint's unit is UNDECLARED, so what
follows rests on the historical prior, not on a reading of your manifest. If your ceiling is
already in the post-fix unit, none of it applies — declare budgets.initiative.harvest_basis
and this paragraph becomes a derivation instead of a guess.

"
                MIXADVICE="${MIXADVICE}EXTEND is the wrong first move here, and for the dangerous reason: the CEILING is the
side in the inflated unit, so the real overrun is likely LARGER than the figure above, not
smaller. Waiting does not clear it — a setpoint does not decay. Re-denominate the ceiling
into the post-fix unit first, then read this line again. And once you have: expect this
declaration to keep firing for the rest of this initiative, because the burn side is still
counted in the old unit and the log is append-only. That is the arithmetic working, not
the remedy failing." ;;
              *)
                MIXADVICE="No move can be chosen from this evidence. The setpoint's declared unit is
unreadable, so whether this overrun is real or an artifact is not knowable from the record as
it stands. Settle the units before acting on any option below." ;;
            esac
            MIXNOTE="
READ THE HARVEST UNIT HAZARD BANNER ABOVE FIRST — it qualifies both figures in this forecast, and
they are not qualified the same way. Burn-to-date is summed from the entries that banner
describes. The cost-to-complete is NOT: the observed rate excludes pre-fix entries
outright, so it either rests on post-fix samples or falls back to the structural estimate
named in the forecast basis above. The projected total therefore ADDS TWO NUMBERS THAT ARE
NOT IN THE SAME UNIT AS EACH OTHER, and no single divisor converts one into the other.

${MIXADVICE}
"
          fi
          # The denomination axis reaches this menu on its OWN, and it must not simply
          # inherit the vintage advice above: that text argues the ceiling is in the
          # INFLATED unit, and on this axis the ceiling is the SMALLER side — opposite
          # direction, opposite first move. Same principle as the vintage qualifier
          # though: the menu is where the wrong move gets made, so the correction belongs
          # AT the menu rather than left to the banner. Appended (not substituted) when
          # both fire, so neither axis's direction is silently dropped.
          if [ "$DENOM_HAZARD" = "mismatch" ]; then
            MIXNOTE="${MIXNOTE}
READ THE SETPOINT DENOMINATION HAZARD BANNER ABOVE FIRST — the ceiling in this forecast is
declared cost_weighted while every token figure above it is a raw four-class count. The
ceiling is the SMALLER side, so this overrun is OVERSTATED: expressed in the unit the burn
is actually counted in, the real gap is several times narrower than the figure above, and
may not be an overrun at all.

HARVEST is the wrong first move here — it is the mirror of the EXTEND trap on the vintage
axis. Do not descope real work to fit a ceiling that only looks close because it is
denominated in smaller units. Re-denominate budgets.initiative.tokens into raw tokens
first, then read this forecast again. Waiting does not clear it either: burn is a raw sum
in code, so the two sides never converge on their own.
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
            # The structural per-session constant carries a vintage of its own, and it is
            # the OLD one: it was fitted against pre-[9.1] per-session burns, so a MODELED
            # cost-to-complete reads high by roughly the meter error until [28.4] re-fits
            # it. Without this line the operator reads an inflated projection as evidence
            # for EXTEND — the same phantom the banner above exists to stop, arriving from
            # the other side of the sum.
            BASISNOTE="
    forecast basis:        MODELED — ${PN:-0} observed sessions contributed. The cost-to-complete
                           above is the structural estimate (remaining sessions x a per-session
                           constant): a statement about the PLAN'S SHAPE, not about how this
                           project has actually been burning. The range is the honest width.
                           The constant itself was fitted against PRE-DEDUPE per-session burns,
                           so this figure reads high by roughly the meter error until [28.4]
                           re-derives it. Do not treat a MODELED overrun as grounds to EXTEND."
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
