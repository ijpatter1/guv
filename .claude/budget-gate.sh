#!/bin/bash
# .claude/budget-gate.sh — the burn-vs-ceiling comparison ([9.3], rebuilt at [32.4]).
#
# Runs at both session boundaries and compares burn (summed from the [9.1]
# metering log) against the ceiling(s) a person committed to project.json. One
# comparison line per configured granularity — burn visible at boundaries — plus
# one pointer line naming the record that qualifies the number. On breach it
# stops loud (exit 3) with work preserved; the choice is the person's. An absent
# setpoint gates nothing, silently — absent means unlimited, never "off". THE
# MACHINERY NEVER MOVES A SETPOINT: raising a ceiling is a human commit to
# project.json, which is also its only storage and its whole provenance. The
# gate writes nothing, anywhere.
#
# What the number is, and is not, is the EPOCH's declaration
# (.claude/metering-log.md § Epoch): burn counts only entries after the last
# guv.meter.epoch.v1 line in the log — pre-epoch entries are historical and
# never compared across it. A log with no epoch line is one epoch whole (the
# fresh-project case). The initiative figure additionally windows to the [13.4]
# lineage boundary (the opening plan bank, or between initiatives the last
# grade), so a still-set ceiling gates the live initiative, not all history.
#
# Usage:
#   bash .claude/budget-gate.sh <entry|exit> [--log <path>] [--manifest <path>] [--calibration <path>]
#
# Exit: 0 within budget / absent budget · 2 usage · 3 BREACH (the loud pause)
#       4 no/corrupt manifest (cwd must be the project root)
#
# Invoked at ENTRY by the SessionStart hook (which surfaces stdout and does not
# propagate exit 3 — a breach is a pause to decide at, not a denied start); at
# EXIT by the handoff skill's Step 6c.
set -u

err() { echo "budget-gate: $1" >&2; }
die() { err "$2"; exit "$1"; }

command -v jq >/dev/null 2>&1 || die 2 "requires jq, which is not on PATH — install jq"

[ $# -ge 1 ] || die 2 "usage: bash .claude/budget-gate.sh <entry|exit> [--log path] [--manifest path] [--calibration path]"
PHASE="$1"; shift
case "$PHASE" in
  entry|exit) ;;
  *) die 2 "unknown phase '$PHASE' — expected 'entry' or 'exit'" ;;
esac

LOG=""; MANIFEST=""; CALIB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --log)         LOG="${2:-}"; shift 2 ;;
    --manifest)    MANIFEST="${2:-}"; shift 2 ;;
    --calibration) CALIB="${2:-}"; shift 2 ;;
    *) die 2 "unknown argument '$1'" ;;
  esac
done

# cwd must be the project root — the sibling convention. The setpoints live in
# project.json and nowhere else.
[ -n "$MANIFEST" ] || MANIFEST=".claude/project.json"
[ -f "$MANIFEST" ] || die 4 "no manifest at $MANIFEST (cwd must be the project root)"
jq -e . "$MANIFEST" >/dev/null 2>&1 \
  || die 4 "$MANIFEST exists but is not valid JSON — fix the manifest"

# A zero or leading-zero ceiling is out of shape (the schema floors at 1) and is
# treated as absent — never fed to the percent arithmetic or the >= comparison,
# where 0 would divide by zero and then breach forever.
SESSION_BUDGET=$(jq -r '.budgets.session.tokens // empty' "$MANIFEST" 2>/dev/null)
INITIATIVE_BUDGET=$(jq -r '.budgets.initiative.tokens // empty' "$MANIFEST" 2>/dev/null)
case "$SESSION_BUDGET" in    ''|*[!0-9]*|0*) SESSION_BUDGET="" ;; esac
case "$INITIATIVE_BUDGET" in ''|*[!0-9]*|0*) INITIATIVE_BUDGET="" ;; esac
[ -z "$SESSION_BUDGET" ] && [ -z "$INITIATIVE_BUDGET" ] && exit 0

[ -n "$LOG" ] || LOG=".claude/metering/metering.ndjson"
[ -n "$CALIB" ] || CALIB=".claude/metering/calibration.ndjson"

# The current session id — derived exactly as meter.sh derives it.
CURRENT_SESSION=$(ls docs/sessions/session-*.md 2>/dev/null \
  | sed -E 's#.*/(session-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3})\.md#\1#' \
  | grep -E '^session-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3}$' \
  | sort | tail -1)

# The [13.4] lineage boundary: last-in-file-order grade or plan forecast
# (append order is lineage order). Shape-vetted before interpolation.
INITIATIVE_SINCE=""
if [ -f "$CALIB" ]; then
  INITIATIVE_SINCE=$(jq -rRn '
    [ inputs | fromjson? | select(type == "object")
      | select(((.kind // "") == "grade")
            or (((.kind // "") == "forecast") and ((.boundary // "") == "plan"))) ]
    | last | .banked_at // empty' "$CALIB" 2>/dev/null)
  case "$INITIATIVE_SINCE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) INITIATIVE_SINCE="" ;;
  esac
fi

# Burn. Per-line tolerant (a torn append drops alone, counted); entries after
# the LAST epoch line only; a burn sample is a bounded slice with tokens.
SESSION_BURN=0; INITIATIVE_BURN=0; LOG_TORN=0
if [ -f "$LOG" ]; then
  burn_sum() {  # $1 = a jq boolean selecting entries (post-epoch, post-schema)
    jq -rRn "
      def burn: (.input // 0) + (.output // 0) + (.cache_read // 0) + (.cache_creation // 0);
      [ inputs | fromjson? | select(type == \"object\") ] as \$lines
      | ([ \$lines | to_entries[] | select(.value.schema == \"guv.meter.epoch.v1\") | .key ] | last // -1) as \$epoch
      | [ \$lines | to_entries[] | select(.key > \$epoch) | .value
          | select((.schema // \"\") | startswith(\"guv.meter\"))
          | select(.tokens != null)
          | select((.harvest_basis // \"\") == \"per_response\")
          | select((.slice_basis // \"\") as \$sb | \$sb == \"per_deliverable\" or \$sb == \"since_process_start\")
          | select($1) | (.tokens | burn) ]
      | add // 0" "$LOG" 2>/dev/null
  }
  LOG_TORN=$(jq -rRn '[ inputs | select(length > 0)
                        | (fromjson? | "ok") // "torn" ]
                      | map(select(. == "torn")) | length' "$LOG" 2>/dev/null)
  case "$LOG_TORN" in ''|*[!0-9]*) LOG_TORN=0 ;; esac
  if [ -n "$INITIATIVE_SINCE" ]; then
    INITIATIVE_BURN=$(burn_sum "((.ts // \"\") >= \"$INITIATIVE_SINCE\")")
  else
    INITIATIVE_BURN=$(burn_sum 'true')
  fi
  SESSION_BURN=$(burn_sum "(.session == \"$CURRENT_SESSION\")")
  case "$INITIATIVE_BURN" in ''|*[!0-9]*) INITIATIVE_BURN=0 ;; esac
  case "$SESSION_BURN" in    ''|*[!0-9]*) SESSION_BURN=0 ;; esac
fi

# At ENTRY the current session has no artifact yet — the newest docs/sessions/
# file is the PRIOR, already-closed session, so its burn is not this session's.
# A new session has metered nothing: its session burn is zero by definition.
# (At exit the handoff's Step 6 has written this session's artifact and Step 6b
# its metering entry before Step 6c runs the gate, so the exit sum is correctly
# attributed.) Without this, a breached prior session would print a false
# session BREACH into every session-open context until the next handoff.
[ "$PHASE" = "entry" ] && SESSION_BURN=0

WHERE=$([ "$PHASE" = "entry" ] && echo "at session entry" || echo "at session exit")
TORN_NOTE=""
[ "$LOG_TORN" -gt 0 ] && TORN_NOTE=" [$LOG_TORN unparsed line(s) skipped — burn is a floor]"

# The comparison — one line per configured granularity, then the pointer.
pct() { awk -v b="$1" -v c="$2" 'BEGIN{ printf "%d", (b * 100) / c }'; }
if [ -n "$SESSION_BUDGET" ]; then
  echo "[budget-gate] session burn ${SESSION_BURN} of ${SESSION_BUDGET} tokens ($(pct "$SESSION_BURN" "$SESSION_BUDGET")%) ${WHERE}${TORN_NOTE}"
fi
if [ -n "$INITIATIVE_BUDGET" ]; then
  echo "[budget-gate] initiative burn ${INITIATIVE_BURN} of ${INITIATIVE_BUDGET} tokens ($(pct "$INITIATIVE_BURN" "$INITIATIVE_BUDGET")%) ${WHERE}${TORN_NOTE}"
fi
echo "[budget-gate] what this number is — unit, coverage, epoch, window: .claude/metering-log.md (§ Epoch)"

# The tension decision: burn ≥ ceiling on any configured granularity is the
# loud pause. Session first — the narrower scope names the nearer problem.
BREACH_KIND=""
if [ -n "$SESSION_BUDGET" ] && [ "$SESSION_BURN" -ge "$SESSION_BUDGET" ]; then
  BREACH_KIND="session"; BREACH_BURN="$SESSION_BURN"; BREACH_BUDGET="$SESSION_BUDGET"
elif [ -n "$INITIATIVE_BUDGET" ] && [ "$INITIATIVE_BURN" -ge "$INITIATIVE_BUDGET" ]; then
  BREACH_KIND="initiative"; BREACH_BURN="$INITIATIVE_BURN"; BREACH_BUDGET="$INITIATIVE_BUDGET"
fi
[ -n "$BREACH_KIND" ] || exit 0

# The BREACH headline stays ONE literal line — the handoff skill greps for it.
cat <<EOF

[budget-gate] BREACH ${WHERE} — the ${BREACH_KIND} budget is exhausted.

    burn:    ${BREACH_BURN} tokens
    ceiling: ${BREACH_BUDGET} tokens (budgets.${BREACH_KIND}.tokens)
    over by: $((BREACH_BURN - BREACH_BUDGET)) tokens

This is a PAUSE for a decision, not a stop the machine recovers from. Work is
preserved — nothing has been changed, and the machinery never raises a
setpoint. The decision is yours:

  • EXTEND   — raise budgets.${BREACH_KIND}.tokens in ${MANIFEST} and commit it
               (the commit IS the provenance — no approval flow, no side channel).
  • HARVEST  — wrap up now: /handoff (/guv:handoff under the plugin) to capture
               state, then end within budget.
  • KILL     — stop here; the worktree is intact for a later pickup.

A headless run stays paused here, loud, with state intact — it does not choose
for you and never raises the ceiling on its own.
EOF
exit 3
