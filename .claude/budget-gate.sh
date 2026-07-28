#!/bin/bash
# .claude/budget-gate.sh — the budget tension gate ([9.3]).
#
# Runs at both session boundaries, sums burn from the [9.1] metering log, and speaks
# ONLY on tension. Within budget it is silent. An absent setpoint gates nothing —
# absent means unlimited, not "off". THE MACHINERY NEVER MOVES A SETPOINT: raising,
# lowering, or re-denominating a ceiling is a human commit to project.json, which is
# also its only storage and its whole provenance. The gate writes nothing, anywhere.
#
# Four things it can say, each with its own headline (keep every headline on ONE
# line — [15.6]'s drift guard greps this file for them):
#
#   BREACH                       burn >= setpoint. The loud pause: exit 3, work intact.
#   FORESEEN OVERRUN             burn + [13.3] cost-to-complete > setpoint. A range, not
#                                a fact, so it DECLARES for the handoff and exits 0.
#   HARVEST UNIT HAZARD          burn and setpoint disagree on VINTAGE ([9.1] counted
#                                per transcript line, not per response).
#   SETPOINT DENOMINATION HAZARD burn and setpoint disagree on UNIT (burn is a raw
#                                four-class sum in code; a ceiling may be cost-weighted).
#
# The two hazard axes are independent and fire together. Both follow one contract:
# DECLARED by a person (budgets.initiative.{harvest_basis,denomination}), absent means
# the check is off, out-of-enum reports malformed, and the remedy DISCLOSES rather than
# converts. They refuse conversion for DIFFERENT reasons and must never be given a
# shared one ([28.4]): on denomination the raw/cost ratio moves with each session's
# shape, so any divisor would be fabricated; on vintage a ~2.55x divisor is
# arithmetically admissible and what refuses it is that the pre-fix transcripts no
# longer survive to validate one. Neither hazard ever clears — the log is append-only.
#
# Usage:
#   bash .claude/budget-gate.sh <entry|exit> [--log <path>] [--manifest <path>] [--calibration <path>]
#
#   The path flags exist for tests; each defaults root-relative.
#
# Exit: 0  within budget, absent budget, no measurable burn, or any declaration above
#       2  usage (unknown phase, unknown flag, or jq missing)
#       3  ACTUAL-BURN BREACH — the loud pause
#       4  no/corrupt manifest (cwd must be the project root)
#
# Invoked at ENTRY by the SessionStart hook, which deliberately does not propagate
# exit 3 (a non-zero SessionStart blocks the session from starting, and a breach is a
# decision to pause for, not a denied start); at EXIT by the handoff skill's Step 6c.
#
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

# The unit the setpoint was chosen in — the half of the comparison an integer cannot
# carry. Validated against the vocabulary the vintage scan emits: an out-of-enum value
# can never equal any vintage, so a guesser would alarm forever and the obvious remedy
# for a permanent alarm is to re-denominate a ceiling that was already right. "unknown"
# is not legal here — it is what the scan emits for a degraded harvest, and a setpoint
# declared unknown declares nothing.
INITIATIVE_BASIS=$(jq -r '.budgets.initiative.harvest_basis // empty' "$MANIFEST" 2>/dev/null)
BASIS_MALFORMED=""
case "$INITIATIVE_BASIS" in
  ''|per_response|pre-dedupe) ;;
  *) BASIS_MALFORMED="$INITIATIVE_BASIS"; INITIATIVE_BASIS="" ;;
esac

# The DENOMINATION axis ([28.5]). Needs no scan of the log: `burn` below sums four
# classes unweighted in code, so the burn side is raw by construction and only the
# declaration can vary. "cost-weighted" with a hyphen is the realistic typo, since the
# hyphenated spelling is legal on the OTHER axis — hence the same malformed rung.
INITIATIVE_DENOM=$(jq -r '.budgets.initiative.denomination // empty' "$MANIFEST" 2>/dev/null)
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
# The setpoint governs the LIVE initiative: an all-time sum breaches any correctly
# forecast-derived budget the moment a mature log outgrows it. The window opens at the
# initiative's `--at plan` forecast, or at the `grade` that closed the last one when no
# new plan is banked yet. Phase-boundary banks never move it. No lifecycle entry → the
# burn read degrades to the whole-log cumulative sum.
[ -n "$CALIB" ] || CALIB=".claude/metering/calibration.ndjson"
INITIATIVE_SINCE=""
if [ -f "$CALIB" ]; then
  # Per-line-tolerant (fromjson?): losing the window would silently resurrect the
  # spurious cumulative breach it exists to kill, so a torn line drops alone.
  # The anchor is `last` in FILE ORDER, not max-banked_at — append order is lineage
  # order. An out-of-order hand edit widens the window and over-counts: an earlier,
  # basis-disclosed breach, never a silent under-gate (pinned by W11).
  INITIATIVE_SINCE=$(jq -rRn '
    [ inputs | fromjson? | select(type == "object")
      | select(((.kind // "") == "grade")
            or (((.kind // "") == "forecast") and ((.boundary // "") == "plan"))) ]
    | last | .banked_at // empty' "$CALIB" 2>/dev/null)
  # The glob's job is INJECTION SAFETY — shape-vetting the string before it is
  # interpolated into the burn jq below — not semantic time validation.
  case "$INITIATIVE_SINCE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) INITIATIVE_SINCE="" ;;
  esac
fi

# Named in every initiative figure the gate prints: a windowed read and a degraded
# cumulative read are different claims, and the degraded one is the spurious-breach
# shape on a mature record.
if [ -n "$INITIATIVE_SINCE" ]; then
  INITIATIVE_WINDOW="the live initiative (entries since the lineage boundary ${INITIATIVE_SINCE})"
else
  INITIATIVE_WINDOW="the whole metering log (no lineage boundary to window by)"
fi

# A missing/empty log → burn 0; a missing measurement is never a fabricated breach.
# The vintage vars are declared out here, not inside the log branch, so `set -u` does
# not turn "no log, nothing to disclose" into an abort.
SESSION_BURN=0
INITIATIVE_BURN=0
BURN_VINTAGES=""
BURN_VINTAGE_N=0
BURN_VINTAGE_NAMES=""
LOG_TORN=0
if [ -f "$LOG" ]; then
  # Burn is summed SLICE-AWARE. Bounded slices (per_deliverable / since_process_start)
  # sum directly; LEGACY entries with no slice_basis are cumulative running totals and
  # are differenced per runtime_session at read time; unbounded_cumulative and
  # tokens:null are not burn samples. Summing cumulative snapshots raw inflates burn
  # ~4.6x — that is the bug the differencing exists to prevent.
  #
  # This is NOT projection.sh observed_rate()'s read. A BURN sums everything in its
  # window and DISCLOSES the mix; a RATE cannot average across harvest units at all, so
  # observed_rate() excludes pre-fix entries outright. Same log, two questions.
  #
  # THE CONTRIBUTING SET IS DEFINED ONCE, HERE, because two readers need it — the burn
  # sum and the vintage scan describing that burn's unit — and as two filters sixty
  # lines apart they drifted inside a single commit. One {v, b} per contributing entry,
  # so a vintage can only be raised by an entry the burn sum actually reads.
  contrib_jq() {  # $1 = a jq boolean selecting the entries (post-schema)
    cat <<JQ
      def burn: (.input // 0) + (.output // 0) + (.cache_read // 0) + (.cache_creation // 0);
      # An ABSENT harvest_basis is pre-fix by construction — the field did not exist
      # when those entries were written. An explicit null is different: the harvest ran
      # and could not record its basis, so the unit is unknown rather than old and
      # calling it "pre-dedupe" would be a guess.
      def vintage: if has("harvest_basis") then (.harvest_basis // "unknown") else "pre-dedupe" end;
      # PER-LINE TOLERANT, not a slurp: a torn append used to fail the whole parse, and
      # since the caller defaults a non-numeric result to 0, the gate's only hard stop
      # then exited 0 with no output — a real breach looking exactly like within-budget.
      [ inputs | fromjson? | select(type == "object") ] as \$lines
      | [ \$lines[] | select((.schema // "") | startswith("guv.meter")) ] as \$all
      | [ \$all[] | select($1) | select(.tokens != null)
                  | select((.slice_basis // "") as \$sb | \$sb == "per_deliverable" or \$sb == "since_process_start")
                  | {v: vintage, b: (.tokens | burn)} ] as \$direct
      # Difference the FULL per-runtime_session series BEFORE selecting: a
      # runtime_session can span sessions, so a delta's baseline may sit in another
      # one. Filtering first drops that baseline and counts a survivor's full
      # cumulative — the ~4.6x reinflation again.
      | [ \$all[] | select(.tokens != null) | select(has("slice_basis") | not) ] as \$legacy
      | ( \$legacy | group_by(.runtime_session)
          | map( . as \$g
                 | [ range(0; (\$g | length)) as \$i
                     | \$g[\$i] as \$e
                     | (if \$i == 0 then (\$e.tokens | burn) else (\$e.tokens | burn) - (\$g[\$i-1].tokens | burn) end) as \$delta
                     | \$e + {_burn_delta: \$delta} ] )
          | add // [] ) as \$legacy_d
      # Negatives (out-of-order / pruned series) drop rather than fabricate burn.
      | [ \$legacy_d[] | select($1) | select(._burn_delta >= 0)
                       | {v: vintage, b: ._burn_delta} ] as \$legacy_c
      | ( \$direct + \$legacy_c )
JQ
  }
  burn_sum() {  # $1 = a jq boolean selecting the entries to sum (post-schema)
    jq -rRn "$(contrib_jq "$1") | map(.b) | add // 0" "$LOG" 2>/dev/null
  }
  # Counted so the drop can be announced: a silently partial burn still prints, still
  # looks like a measurement, and is a floor of unknown depth.
  LOG_TORN=$(jq -rRn '[ inputs | select(length > 0)
                        | (fromjson? | "ok") // "torn" ]
                      | map(select(. == "torn")) | length' "$LOG" 2>/dev/null)
  case "$LOG_TORN" in ''|*[!0-9]*) LOG_TORN=0 ;; esac
  # An entry with no ts cannot enter a windowed sum — a missing stamp is a missing
  # measurement, the same rung as tokens:null.
  if [ -n "$INITIATIVE_SINCE" ]; then
    INITIATIVE_BURN=$(burn_sum "((.ts // \"\") >= \"$INITIATIVE_SINCE\")")
  else
    INITIATIVE_BURN=$(burn_sum 'true')
  fi
  SESSION_BURN=$(burn_sum "(.session == \"$CURRENT_SESSION\")")
  case "$INITIATIVE_BURN" in ''|*[!0-9]*) INITIATIVE_BURN=0 ;; esac
  case "$SESSION_BURN" in    ''|*[!0-9]*) SESSION_BURN=0 ;; esac

  # Is the windowed burn even in ONE unit? Slicing does not catch this: slice_basis's
  # vintage guard only refuses a DELTA across the seam inside one runtime_session, so a
  # new runtime_session's first post-fix entry sums straight in beside the old ones.
  if [ -n "$INITIATIVE_SINCE" ]; then
    VSEL="((.ts // \"\") >= \"$INITIATIVE_SINCE\")"
  else
    VSEL='true'
  fi
  # Each vintage carries its TOKEN SUBTOTAL, not just its entry count: one pre-dedupe
  # entry beside one per_response entry reads 1:1 by count while being ~99% pre-dedupe
  # by tokens, which is the opposite of the signal the operator needs.
  # Three pipe-separated fields — count, bare vintage names, display string. The bare
  # names are emitted rather than sliced back out of the display, because the check
  # below compares them for equality and a parse of prose breaks on the next reword.
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

# ONE text, said ONCE per run, wherever the contradiction actually surfaces: the exit
# banner states both remedies, and the FORESEEN OVERRUN menu restates them at BOTH
# boundaries (at entry the banner states none, so the menu is the only site). There were
# two versions of this and at exit both printed in the same output. RECONCILED is what
# keeps the second site quiet once the first has spoken.
RECONCILED=0
emit_reconciler() {
  [ "$RECONCILED" = 1 ] && return 0
  RECONCILED=1
  cat <<'EOF'

BOTH AXES ARE LIVE AND THEY POINT OPPOSITE WAYS on budgets.initiative.tokens — the same
integer both remedies above name. Acting on either one alone moves it the wrong way, and
no net direction exists for this gate to compute. The destination both agree on is ONE
ceiling sized in RAW per-response tokens, RE-DERIVED in that unit — not scaled from the
figure currently there.
EOF
}

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
# Two consumers need the same answer — the banner and the FORESEEN OVERRUN menu — and
# when it was derived twice they disagreed on the arm's condition, so the menu's
# qualifier could never fire in the case it was written for.
#
# The mismatch arm requires a SETPOINT as well as a declared basis: with no ceiling
# there is nothing to be mis-denominated.
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

# Its OWN state, not folded into UNIT_HAZARD: the axes are orthogonal and fire together
# (004 is a mixed vintage window AND a cost-weighted ceiling), so one variable would
# silently drop whichever lost precedence. `malformed` needs no setpoint — an unreadable
# declaration is a manifest defect either way, and a check believed to be running is
# worse than one known to be off.
DENOM_HAZARD="none"
if [ -n "$DENOM_MALFORMED" ]; then
  DENOM_HAZARD="malformed"
elif [ "$INITIATIVE_DENOM" = "cost_weighted" ] && [ -n "$INITIATIVE_BUDGET" ]; then
  DENOM_HAZARD="mismatch"
fi

# The direction follows the CEILING's unit, and holds for a mixed window too. MALFORMED
# derives none: an ABSENT marker leaves the historical prior intact, but a marker that
# was written and cannot be read means the operator answered this question, and
# asserting a prior over the top of it would hide that their answer failed to parse.
if [ "$UNIT_HAZARD" = "malformed" ]; then
  UNIT_DIR="undetermined"; UNIT_DIR_WHY="malformed"
elif [ "$UNIT_HAZARD" != "none" ]; then
  case "$INITIATIVE_BASIS" in
    per_response) UNIT_DIR="breach" ;;
    pre-dedupe)   UNIT_DIR="headroom" ;;
    # UNDECLARED is not unknowable: the prior survives, explicitly labelled as one.
    *)            UNIT_DIR="headroom_prior"; UNIT_DIR_WHY="undeclared" ;;
  esac
  # An "unknown" burn vintage supports NEITHER claim, whatever the ceiling declares.
  case "$BURN_VINTAGE_NAMES" in
    *unknown*) UNIT_DIR="undetermined"; UNIT_DIR_WHY="unrecorded" ;;
  esac
fi

# A COMPLETE sentence per direction: it is read in more than one place, and a fragment
# that only parses after one specific prefix is coupled, not shared.
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

# DERIVED ONCE, like the direction. Written per-banner it drifted every time — one arm
# told an operator whose LOG was degraded to fix the marker; another told one who had
# already declared to declare again. This banner is STANDING, re-read at every boundary
# for the rest of the initiative, so a remedy that contradicts its own state is worse
# than none. Where the direction is only a PRIOR the remedy stays conditional too: the
# population most likely to hit it has ALREADY re-denominated and just has no marker.
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

# What a person can expect to happen to this banner. The log is APPEND-ONLY, so the
# inflated entries are a fixed addend: the RATIO error decays toward 1 as post-fix work
# accumulates while the ABSOLUTE over-count never decays. Saying it self-corrects
# invites waiting for a correction that never arrives.
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
  # Both headlines are written WHOLE and LITERAL: the [15.6] drift guard greps this
  # source for them and cannot see through a `${VAR}` — nor, being a plain grep, tell
  # prose from output, so never write a specimen headline into a comment either. When
  # both axes fire both names are emitted, because a title that never appears literally
  # is a banner the session record never learns to carry.
  DENOM_TITLE_LINE=""
  if [ "$UNIT_HAZARD" != "none" ]; then
    HAZ_TITLE="[budget-gate] HARVEST UNIT HAZARD"
    if [ -n "$DENOM_HEAD" ]; then
      # A POINTER, not a restatement: appending DENOM_HEAD here printed the second
      # axis's sentence verbatim twice, back to back, in the first two lines read.
      HAZ_HEAD="${HAZ_HEAD} A second axis also fired — see the SETPOINT DENOMINATION HAZARD line below."
      DENOM_TITLE_LINE="[budget-gate] SETPOINT DENOMINATION HAZARD ${WHERE} — ${DENOM_HEAD}"
    fi
  else
    HAZ_TITLE="[budget-gate] SETPOINT DENOMINATION HAZARD"
    HAZ_HEAD="$DENOM_HEAD"
  fi
  if [ -n "$INITIATIVE_DENOM" ]; then
    HAZ_DENOM="${INITIATIVE_DENOM} (declared in budgets.initiative.denomination)"
  elif [ -n "$DENOM_MALFORMED" ]; then
    HAZ_DENOM="\"${DENOM_MALFORMED}\" — MALFORMED, the denomination check is OFF; legal values: raw_tokens, cost_weighted"
  else
    HAZ_DENOM="<undeclared — the denomination check is off>"
  fi
  # Three states, not two: declared, malformed (check off), or absent (also off, but a
  # supported state rather than a mistake). Composed here to keep the heredoc readable.
  if [ -n "$INITIATIVE_BASIS" ]; then
    HAZ_BASIS="${INITIATIVE_BASIS} (declared in budgets.initiative.harvest_basis)"
  elif [ -n "$BASIS_MALFORMED" ]; then
    HAZ_BASIS="\"${BASIS_MALFORMED}\" — MALFORMED, the setpoint-unit check is OFF; legal values: per_response, pre-dedupe"
  else
    HAZ_BASIS="<undeclared — the setpoint-unit check is off>"
  fi
  # Both axes, each with its label. UNIT_HAZARD alone printed `hazard: none` under a
  # title ending in HAZARD whenever only the denomination axis fired — the only reading
  # possible for a project whose meter only ever ran post-[9.1].
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
  # The boundary decides the depth. Nothing clears this banner and SessionStart pipes
  # the gate's stdout into every session, so ENTRY gets only "do not trust this number"
  # and EXIT — where the extend/harvest/accept call is made — pays for the explanation.
  if [ "$PHASE" != "exit" ]; then
    cat <<'EOF'

The burn above is not a measurement against this ceiling: do not size, compare, or
forecast off it. The per-axis explanation, and what clears each one, print at the
session-exit gate.
EOF
    # No reconciler here: this banner states no remedy at entry, so there is nothing to
    # contradict. It rides the FORESEEN OVERRUN menu below, where the remedies are.
  else
    # Each axis pays for its own explanation, and only when it fired.
    if [ "$UNIT_HAZARD" != "none" ]; then
      # Conditional on a pre-dedupe entry actually being in the window.
      case "$BURN_VINTAGE_NAMES" in
        *pre-dedupe*) cat <<'EOF'

Entries harvested "pre-dedupe" counted token usage once per transcript LINE rather than
once per API response, which over-counts by roughly 2.5x — measured 2.31x-2.88x all-class
across 18 reconstructed entries in guv's own record. A total that mixes these entries
with "per_response" ones is in no single unit.
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
output and cache mix, so a single divisor would have to be invented. That reason belongs
to THIS axis alone. The harvest-vintage axis also refuses a divisor, but for a different
reason ([28.4]): there the inflation is convertible in principle — one ~2.55x deflator
fits every reconstructed pre-fix entry to within ±13% — and what refuses it is that the
transcripts needed to validate a deflator no longer survive. Evidence there, arithmetic
here. Do not carry a conclusion from one axis to the other.

The remedy is a person's commit: re-denominate budgets.initiative.tokens into raw tokens,
or — if the ceiling is right and the marker is wrong — correct
budgets.initiative.denomination. Re-denominating means REDOING the setpoint's derivation
in the target unit, not scaling the old figure by a ratio: the ratio is exactly what this
paragraph says does not exist. This is a DECLARATION, not a stop; the machinery never
moves a setpoint.
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
    # Both remedy paragraphs above are now present, each correct on its own axis and each
    # naming budgets.initiative.tokens as what to move — in opposite directions.
    [ "$UNIT_HAZARD" != "none" ] && [ "$DENOM_HAZARD" = "mismatch" ] && emit_reconciler
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

# No ACTUAL-burn breach — check the FORESEEN one ([13.5]): burn-to-date plus the
# projection's cost-to-complete against the initiative setpoint. Declared, never a stop
# (the projection is a range, not a fact). Degrades silently to burn-only when no
# projection is available — never a fabricated forecast.
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
          # THE MENU IS WHERE THE WRONG MOVE GETS MADE, so every unit correction is
          # attached HERE rather than left to the banner above: this menu leads with
          # EXTEND, so an operator who has just re-denominated the ceiling down into the
          # post-fix unit is met by a gate demanding they raise it back. Composed before
          # the heredoc because a heredoc cannot hold a conditional.
          MIXNOTE=""
          if [ "$UNIT_HAZARD" != "none" ]; then
            # The direction decides whether EXTEND is merely premature or actively
            # backwards — not the same warning.
            case "$UNIT_DIR" in
              breach)
                # "some or all", never "wholly": in a MIXED window only the pre-dedupe
                # portion is inflated.
                MIXADVICE="EXTEND is the wrong first move here. The BURN side is inflated against this ceiling,
so some or all of this overrun may be an artifact of the old unit rather than real work, and
raising a ceiling to accommodate tokens that were never spent is the one move waiting cannot
undo. Expect this declaration to keep firing for the rest of the initiative even after you
act: the log is append-only, so the inflated entries never leave the window. That is the
arithmetic working, not the remedy failing." ;;
              headroom|headroom_prior)
                # headroom_prior ASSUMED a ceiling unit rather than reading one, so the
                # flat claim below must be prefixed as a prior, not stated as evidence.
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
NOT IN THE SAME UNIT AS EACH OTHER. The gate does not convert one into the other — not
because the inflation is unconvertible in principle (a single ~2.55x deflator fits every
reconstructed pre-fix entry to within ±13%), but because the transcripts that would validate
a deflator against THIS log no longer survive. Disclosure is what the evidence supports;
conversion would be precision the record cannot back.

${MIXADVICE}
"
          fi
          # This axis must NOT inherit the vintage advice: there the ceiling is the
          # inflated side, here it is the smaller one — opposite direction, opposite
          # first move. Appended rather than substituted so neither is dropped.
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
          # Both blocks above may now be present, each naming budgets.initiative.tokens
          # and pointing the opposite way. BRIEF: at exit the full statement already
          # printed a few paragraphs up, and at entry this is the only remedy text there
          # is, so the brief form has to carry the whole correction alone.
          # Command substitution runs in a SUBSHELL, so the flag it sets there is lost —
          # check and set it out here, or the menu would repeat what the banner just said.
          if [ "$UNIT_HAZARD" != "none" ] && [ "$DENOM_HAZARD" = "mismatch" ] \
             && [ "$RECONCILED" = 0 ]; then
            RECONCILED=1
            MIXNOTE="${MIXNOTE}$(RECONCILED=0; emit_reconciler)
"
          fi
          # A modeled number and a measured one look identical once both are just
          # digits, and the extend/harvest/accept call is made off these digits.
          BASISNOTE=""
          PCLAIM=$(printf '%s' "$PROJ" | jq -r '.basis.claim // empty' 2>/dev/null)
          PN=$(printf '%s' "$PROJ" | jq -r '.basis.n // empty' 2>/dev/null)
          case "$PN" in ''|*[!0-9]*) PN="" ;; esac
          if [ "$PCLAIM" = "structural" ] || { [ -n "$PN" ] && [ "$PN" -eq 0 ]; }; then
            # The structural constant was fitted against pre-[9.1] burns, so a MODELED
            # cost-to-complete reads high — the same phantom the banner above stops,
            # arriving from the other side of the sum.
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
  exit 0   # silent within budget; a foreseen declaration is a signal, not a stop
fi

# --- ACTUAL-BURN BREACH — the loud pause -------------------------------------
# Writes NOTHING, so the worktree the breach pauses over stays byte-identical.
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
