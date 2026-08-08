#!/bin/bash
# .claude/compaction-setpoint.sh
# [14.2] The compaction setpoint — engage PROACTIVE compaction at a calibrated window
# on a local extended-context (1M) model, so a long autonomous session holds its
# working context in the quality zone instead of running to the model's hard limit.
#
# THE LEVER (the [14.1] spike finding, now CONFIRMED). On a local Opus-4.x extended-
# context session, CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is INERT (it only tunes the % once
# proactive compaction is already engaged). The real lever is the env var
# CLAUDE_CODE_AUTO_COMPACT_WINDOW: setting it to a window SMALLER than the model's hard
# limit is what engages proactive compaction. "Does window-setting actually fire local
# proactive compaction?" was [14.1]'s lever-a PENDING question — CONFIRMED this
# initiative: with CLAUDE_CODE_AUTO_COMPACT_WINDOW=250000 deployed, a real proactive
# compaction fired at ~217000 occupancy (≈87% of the window; the ~13% remainder is the
# autocompact buffer). So the deployed path is DEPLOY, not degrade.
#
# THE DEPLOY SURFACE — the env block. CLAUDE_CODE_AUTO_COMPACT_WINDOW is read by Claude
# Code at LAUNCH; a hook cannot set it (a hook runs as a child and cannot mutate the
# parent session's environment, and the window is read before any SessionStart hook).
# It is therefore deployed STATICALLY via the settings `env` block — proven to fire from
# .claude/settings.local.json: {"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"250000"}}.
# The value is PER-PROJECT and PER-MODEL (a 1M-tuned window is inert on a 200000-window
# model), and like a budget it is a HUMAN-AUTHORED setpoint — so it lives in a project's
# local settings, NOT shipped as a universal product default. This script ships the
# MECHANISM (derive + verify), not a value.
#
# THE DERIVATION (Rule 12 — deterministic, not a magic number). `recommend` derives a
# window BAND from the model window and the [13.2]/[13.3] quality zone:
#   working_set = quality_setpoint × 0.4        (the [13.3] WORKING_SET_FRACTION; the
#                                                quality_setpoint is the manifest
#                                                occupancy.threshold, else the documented
#                                                DEFAULT_CEILING)
#   window_low  = one standard window (200000)  — the anti-thrash floor: compacting below
#                                                a standard window of working context
#                                                risks compacting away the active deliverable
#   window_high = 2× the standard window (400000) — above this the working set drifts toward
#                                                degradation/cost with diminishing return. The
#                                                [13.3] working_set raises this ceiling ONLY
#                                                when it EXCEEDS 2× standard (occupancy.threshold
#                                                > ~1M); on current models the anchor governs
#                                                and the occupancy-derived working_set is a
#                                                loose UPPER reference — it overestimates: the
#                                                validated 250000 window triggers at ~217000,
#                                                below the modeled working_set, so the band is
#                                                anchored on the empirically-calm standard
#                                                window, not stretched to the modeled set.
# The operator authors the exact value within the band (doctrine: setpoints are human-
# authored, the mechanism just places them). 250000 is the dogfood-validated value on the
# 1M model and falls inside the band.
#
# VERB
#   recommend [--model ID|--window N] [--setpoint N] [--root R]
#       Emit the derived band + basis as key=value lines. On a standard (≤ standard-window)
#       model: recommend=optional — the model already auto-compacts at its boundary, so a
#       larger window is inert; the active path is the model default + manual (the degrade).
#
# DEGRADATION (Rule 15 — the [14.1] lever-a ladder, TAKEN not invented):
#   1. PRIMARY — deploy the window; proactive compaction fires; the platform's native
#      compaction summary carries the session across it ([32.2] — continuity belongs to
#      the platform, not to guv).
#   2. If window-setting does not fire on some future runtime → drive compaction manually
#      at the setpoint: an operator-issued /compact.
#   3. CLAUDE.md-survival floor — the load-bearing state is re-read every session, so it
#      survives any compaction independent of the window.
#   4. Loud stop — pause and hand off for a human to /compact or /clear.
#
# WIRING ([14.1] finding e) — resolve the project root from $CLAUDE_PROJECT_DIR, never a
# payload cwd; this script takes --root explicitly and falls back to that env, then PWD.
# It ships in the plugin like the other .claude/*.sh scripts (build-plugin rewrites the path).
set -u

STANDARD_WINDOW=200000                 # guv's calm-window anchor (projection.sh [12.1]/[13.3])
DEFAULT_CEILING=$(( STANDARD_WINDOW * 3 / 4 ))   # 150000 — the documented occupancy default
WORKING_SET_NUM=2; WORKING_SET_DEN=5   # working_set = setpoint × 2/5 = 0.4 ([13.3])
VALIDATED_REFERENCE=250000             # the dogfood-validated 1M window (basis, not a default)

die() { local code="$1"; shift; printf 'compaction-setpoint: %s\n' "$*" >&2; exit "$code"; }
is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

[ $# -ge 1 ] || die 2 "usage: bash .claude/compaction-setpoint.sh recommend [--model ID|--window N] [--setpoint N] [--root R]"
VERB="$1"; shift
case "$VERB" in recommend) ;; *) die 2 "unknown verb '$VERB' (only: recommend)" ;; esac

MODEL=""; WINDOW_ARG=""; SETPOINT_ARG=""; ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
while [ $# -gt 0 ]; do
  case "$1" in
    --model)    MODEL="${2:-}"; shift 2 ;;
    --window)   WINDOW_ARG="${2:-}"; shift 2 ;;
    --setpoint) SETPOINT_ARG="${2:-}"; shift 2 ;;
    --root)     ROOT="${2:-}"; shift 2 ;;
    *) die 2 "unknown option '$1'" ;;
  esac
done

# The derivation reads the manifest JSON for the quality setpoint; without jq we
# cannot read it, so we cannot derive — a NAMED loud stop, never a guessed value.
command -v jq >/dev/null 2>&1 || die 3 "jq is required to read the manifest JSON (not found on PATH) — cannot derive the setpoint"

# MODE + MODEL_WINDOW from --window (explicit) | --model ([1m] → extended) | a fallback.
# arg1: fallback model window when neither --window nor --model is given.
determine_mode() {
  if [ -n "$WINDOW_ARG" ]; then
    is_int "$WINDOW_ARG" || die 2 "--window must be a positive integer: '$WINDOW_ARG'"
    MODEL_WINDOW="$WINDOW_ARG"
  elif [ -n "$MODEL" ]; then
    case "$MODEL" in *"[1m]"*) MODEL_WINDOW=1000000 ;; *) MODEL_WINDOW="$STANDARD_WINDOW" ;; esac
  else
    MODEL_WINDOW="$1"
  fi
  if [ "$MODEL_WINDOW" -gt "$STANDARD_WINDOW" ]; then MODE=extended; else MODE=standard; fi
}

# S = the [13.3] quality setpoint: --setpoint | manifest occupancy.threshold | DEFAULT_CEILING.
resolve_setpoint_S() {
  if [ -n "$SETPOINT_ARG" ]; then
    is_int "$SETPOINT_ARG" || die 2 "--setpoint must be a positive integer: '$SETPOINT_ARG'"
    S="$SETPOINT_ARG"; return
  fi
  local mf="$ROOT/.claude/project.json" v=""
  [ -f "$mf" ] && v=$(jq -r '.occupancy.threshold // empty' "$mf" 2>/dev/null)
  if [ -n "$v" ]; then
    is_int "$v" || die 2 "occupancy.threshold in $mf is not an integer: '$v'"
    S="$v"
  else
    S="$DEFAULT_CEILING"
  fi
}

# WORKING_SET, WIN_LOW, WIN_HIGH from MODE + S + MODEL_WINDOW.
compute_band() {
  WORKING_SET=$(( S * WORKING_SET_NUM / WORKING_SET_DEN ))
  # Never recommend a window that reaches the model limit (a window ≥ the limit is inert).
  local cap=$(( MODEL_WINDOW * 3 / 4 ))
  # A model whose 3/4 cap cannot even host the anti-thrash floor is too small for a
  # calibrated window above that floor — a NAMED loud stop, never a degenerate sub-floor
  # band emitted as if it were a deploy recommendation (Rule 10/15).
  if [ "$cap" -lt "$STANDARD_WINDOW" ]; then
    die 5 "model window $MODEL_WINDOW is too small to host a compaction window above the anti-thrash floor ($STANDARD_WINDOW) — rely on the model default and the manual/handoff degrade (Rule 15)"
  fi
  WIN_LOW="$STANDARD_WINDOW"
  WIN_HIGH=$(( STANDARD_WINDOW * 2 ))
  # The [13.3] working_set raises the ceiling ONLY when it exceeds the 2x-standard anchor
  # (i.e. occupancy.threshold > ~1M). On current models the anchor dominates and the
  # occupancy-derived working_set is a loose UPPER reference (it overestimates — the
  # dogfood-validated 250000 window triggers at ~217000, below the modeled working_set).
  [ "$WORKING_SET" -gt "$WIN_HIGH" ] && WIN_HIGH="$WORKING_SET"
  [ "$WIN_HIGH" -gt "$cap" ] && WIN_HIGH="$cap"
}

determine_mode "$STANDARD_WINDOW"        # fallback: assume standard unless told otherwise
resolve_setpoint_S
printf 'mode=%s\n' "$MODE"
printf 'model_window=%s\n' "$MODEL_WINDOW"
printf 'quality_setpoint=%s\n' "$S"
WORKING_SET=$(( S * WORKING_SET_NUM / WORKING_SET_DEN ))
printf 'working_set=%s\n' "$WORKING_SET"
if [ "$MODE" = "extended" ]; then
  compute_band
  printf 'window_low=%s\n' "$WIN_LOW"
  printf 'window_high=%s\n' "$WIN_HIGH"
  printf 'recommend=deploy\n'
  printf 'validated_reference=%s\n' "$VALIDATED_REFERENCE"
  printf 'basis=floor=one standard window (%s, anti-thrash); ceiling=2x the standard window — the [13.3] working_set (setpoint x 0.4) raises this ceiling ONLY when it exceeds 2x standard (occupancy.threshold > ~1M), so on current models the standard-window anchor governs and the occupancy-derived working_set is a loose UPPER reference (it overestimates: the validated 250000 window triggers at ~217000, below the modeled working_set); the trigger fires at ~87%% of the window (the ~13%% autocompact buffer); author the exact value within the band like a budget setpoint — %s is the dogfood-validated value on this 1M model. Deploy it to .claude/settings.local.json {"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"<value>"}}.\n' \
    "$STANDARD_WINDOW" "$VALIDATED_REFERENCE"
else
  printf 'recommend=optional\n'
  printf 'basis=this model auto-compacts at its ~%s boundary by default; CLAUDE_CODE_AUTO_COMPACT_WINDOW helps only if set BELOW the boundary to compact earlier — otherwise leave it unset and rely on the model default plus the manual/handoff degrade (Rule 15).\n' \
    "$MODEL_WINDOW"
fi
exit 0
