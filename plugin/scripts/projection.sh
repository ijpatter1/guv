#!/bin/bash
# .claude/projection.sh — cost-to-complete projection ([9.7], cut at [32.4]).
#
# observed-rate × sized-remaining, and nothing else. The rate is the mean
# per-session token burn over the LOCAL metering log — post-epoch per_response
# bounded slices, windowed to the [13.4] lineage boundary (the same window
# budget-gate.sh sums burn over, so the two figures are comparable). The
# quantity is the [13.2] sizing: Σ sessions × the light/medium/heavy fraction
# over the resolver's open set ([28.1] — an all-light phase forecasts smaller
# than an all-heavy one). The forecast range rides the observed min/max.
#
# At n=0 the rate and forecast are HONEST NULLS, disclosed. There is no modeled
# fallback: the pre-[32.4] occupancy×turns structural band was fitted to
# pre-epoch evidence and deleted with it (the record: .claude/metering-log.md).
#
# NO FOREIGN HISTORY: the only inputs are this control plane's own artifacts —
# its metering log, its estimate sidecar, its calibration record, and the
# resolver. No $HOME crawl, no cross-project glob, no network. The suite
# grep-asserts this.
#
# BANKED + GRADED ([13.4]): `bank` appends the projection as a forecast line to
# the append-only calibration record — idempotent per boundary per initiative —
# stamping banked_session (the newest docs/sessions/ artifact), the session-
# record position the grade's denominator counts from. `grade` compares the
# opening (plan-boundary) forecast against the outcome and splits the miss into
# two separable errors. The quantity denominator is the SESSION RECORD — every
# session artifact after the bank counts, metered or not ([28.1]'s restored
# clause: the denominator reflects the record, not just the meter's coverage) —
# degrading to the metered count only for a legacy forecast with no
# banked_session stamp, disclosed in denominator_source. The lifecycle commands
# own the calls: /plan banks `--at plan` and grades at close, /handoff banks at
# phase boundaries (guv:-namespaced under a plugin install).
#
# DETERMINISTIC (Rule 12): arithmetic over logged data — no LLM, no agent input.
#
# Usage:
#   bash .claude/projection.sh project [--tracker P] [--log P] [--sidecar P] [--calibration P] [--root P]
#   bash .claude/projection.sh bank    [--at BOUNDARY] [...same flags]
#   bash .claude/projection.sh grade   [...same flags]
#
# Exit: 0 emitted/banked · 2 usage · 4 no/corrupt manifest.
set -u

SCHEMA="guv.projection.v2"
err() { echo "projection: $1" >&2; }
die() { err "$2"; exit "$1"; }

# Siblings travel with this script — located relative to it, never cwd.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVER="$SCRIPT_DIR/resolve-ready.sh"
ESTIMATE="$SCRIPT_DIR/estimate.sh"

[ $# -ge 1 ] || die 2 "usage: bash .claude/projection.sh project|bank|grade [--tracker P] [--log P] [--sidecar P] [--calibration P] [--root P] [--at BOUNDARY]"
SUB="$1"; shift
case "$SUB" in project|bank|grade) ;; *) die 2 "unknown subcommand '$SUB' (only: project, bank, grade)" ;; esac

ROOT="."
TRACKER=""; LOG=""; SIDECAR=""; CALIB=""; AT=""
while [ $# -gt 0 ]; do
  # A value-less trailing flag must fail loud, not spin (a bare `shift 2` on one
  # remaining positional leaves it in place and the loop never advances).
  case "$1" in
    --root|--tracker|--log|--sidecar|--calibration|--at)
      [ $# -ge 2 ] || die 2 "$1 requires a value" ;;
  esac
  case "$1" in
    --root)        ROOT="$2"; shift 2 ;;
    --tracker)     TRACKER="$2"; shift 2 ;;
    --log)         LOG="$2"; shift 2 ;;
    --sidecar)     SIDECAR="$2"; shift 2 ;;
    --calibration) CALIB="$2"; shift 2 ;;
    --at)          AT="$2"; shift 2 ;;
    *) die 2 "unknown argument '$1'" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die 2 "projection requires jq, which is not on PATH"

MANIFEST="$ROOT/.claude/project.json"
[ -f "$MANIFEST" ] || die 4 "no manifest at $MANIFEST (cwd must be the project root, or pass --root)"
jq -e . "$MANIFEST" >/dev/null 2>&1 \
  || die 4 "$MANIFEST exists but is not valid JSON — fix the manifest"

[ -n "$TRACKER" ] || TRACKER="$ROOT/docs/PHASE_STATUS.md"
[ -n "$LOG" ]     || LOG="$ROOT/.claude/metering/metering.ndjson"
[ -n "$SIDECAR" ] || SIDECAR="$ROOT/docs/estimates.json"
[ -n "$CALIB" ]   || CALIB="$ROOT/.claude/metering/calibration.ndjson"

# ── the lineage boundary — derived exactly as budget-gate.sh derives it ───────
# (last-in-file-order grade or plan forecast; append order is lineage order).
# Shape-vetted before interpolation. Empty = nothing banked yet, disclosed.
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

# ── the newest session artifact — the session-record position banks stamp ────
current_session() {
  ls "$ROOT"/docs/sessions/session-*.md 2>/dev/null \
    | sed -E 's#.*/(session-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3})\.md#\1#' \
    | grep -E '^session-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3}$' \
    | sort | tail -1
}

# ── remaining work, from the resolver (the one parser of plan state) ─────────
# Every OPEN deliverable: todo ⬜ + in_progress 🔄 + human_gated 🔒. Designed
# degradation: no tracker / a resolver refusal → empty set (a zero-quantity
# takeoff, honestly, never a crash).
remaining_ids() {
  [ -f "$TRACKER" ] && [ -f "$RESOLVER" ] || return 0
  local resolved
  resolved=$(bash "$RESOLVER" "$TRACKER" --json 2>/dev/null) || return 0
  [ -n "$resolved" ] || return 0
  printf '%s' "$resolved" | jq -r '
    [ .deliverables[] | select(.status=="todo" or .status=="in_progress" or .status=="human_gated") | .id
      | select(. != null) ] | .[]' 2>/dev/null
}

# ── observed per-session rate: post-epoch, per_response, bounded, windowed ───
# Emits "n<TAB>mean<TAB>min<TAB>max" (all 0 at n=0). A sample is an entry AFTER
# the last epoch line (guv.meter.epoch.v1 — pre-epoch entries are historical and
# never compared across it; no epoch line = the whole log is one epoch, the
# fresh-project case), harvested per_response, carrying a bounded slice
# (per_deliverable / since_process_start), inside the lineage window. Degraded
# and unbounded entries are not samples — an average across units is not a
# number. n=0 is a designed, legible result, never a failure.
observed_rate() {
  if [ ! -f "$LOG" ]; then printf '0\t0\t0\t0'; return; fi
  jq -rRn --arg since "$INITIATIVE_SINCE" '
    def burn: (.input // 0) + (.output // 0) + (.cache_read // 0) + (.cache_creation // 0);
    [ inputs | fromjson? | select(type == "object") ] as $lines
    | ([ $lines | to_entries[] | select(.value.schema == "guv.meter.epoch.v1") | .key ] | last // -1) as $epoch
    | [ $lines | to_entries[] | select(.key > $epoch) | .value
        | select((.schema // "") | startswith("guv.meter"))
        | select((.harvest_basis // "") == "per_response")
        | select(.tokens != null)
        | select((.slice_basis // "") as $sb | $sb == "per_deliverable" or $sb == "since_process_start")
        | select($since == "" or ((.ts // "") >= $since))
        | (.tokens | burn) ] as $b
    | ($b | length) as $n
    | if $n == 0 then "0\t0\t0\t0"
      else "\($n)\t\(($b | add) / $n | floor)\t\($b | min)\t\($b | max)" end
  ' "$LOG" 2>/dev/null || printf '0\t0\t0\t0'
}

# ── the projection document ──────────────────────────────────────────────────
compute_projection() {
  # quantity takeoff: Σ sessions × fraction over the open set. An id with no
  # ratified fraction (absent from the sidecar, or a legacy integer estimate)
  # contributes sessions × 1.0 and is DISCLOSED in defaulted_ids.
  local id sessions fraction pairs="" defaulted=""
  for id in $(remaining_ids); do
    sessions=$(bash "$ESTIMATE" get "$id" "$SIDECAR" 2>/dev/null)
    case "$sessions" in ''|*[!0-9]*) sessions=1 ;; esac
    fraction=$(bash "$ESTIMATE" fraction "$id" "$SIDECAR" 2>/dev/null)
    case "$fraction" in
      ''|*[!0-9.]*) fraction="1"; defaulted="$defaulted $id" ;;
    esac
    pairs="$pairs $sessions*$fraction"
  done
  local sized
  sized=$(printf '%s\n' $pairs | jq -Rn '[ inputs | split("*") | (.[0] | tonumber) * (.[1] | tonumber) ] | (add // 0) * 100 | round / 100' 2>/dev/null)
  case "$sized" in '') sized=0 ;; esac
  local defaulted_json
  defaulted_json=$(printf '%s' "$defaulted" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -cs '.')

  local n mean omin omax
  IFS=$'\t' read -r n mean omin omax <<EOF
$(observed_rate)
EOF
  case "$n" in ''|*[!0-9]*) n=0 ;; esac

  jq -cn \
    --arg schema "$SCHEMA" \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson sized "$sized" \
    --argjson defaulted "$defaulted_json" \
    --argjson n "$n" \
    --argjson mean "${mean:-0}" \
    --argjson omin "${omin:-0}" \
    --argjson omax "${omax:-0}" \
    --arg window "$INITIATIVE_SINCE" '
    {
      schema: $schema,
      generated: $generated,
      rate: (if $n == 0 then null
             else { n: $n, mean: $mean, min: $omin, max: $omax, denomination: "tokens_per_session" } end),
      quantity: { sized_remaining: $sized, defaulted_ids: $defaulted },
      forecast: (if $n == 0 then null
                 else { central: (($sized * $mean) | round),
                        low:     (($sized * $omin) | round),
                        high:    (($sized * $omax) | round),
                        denomination: "tokens" } end),
      basis: {
        sample_window: (if $window == "" then null else $window end),
        sample_selection: "post-epoch per_response bounded slices"
      },
      scope: { claim: "guv-mediated cost to complete (remaining work, not total)" }
    }'
}

# ── append-only write to the calibration record ──────────────────────────────
bank_line() {  # <json-line>
  mkdir -p "$(dirname "$CALIB")"
  printf '%s\n' "$1" >> "$CALIB"
}

case "$SUB" in

  project)
    compute_projection
    ;;

  bank)
    # Idempotent per named boundary per initiative: a grade closes the dedup
    # window, so a fresh initiative's identically-named boundary re-banks.
    # Per-line tolerant: a torn calibration line must not disable the dedup
    # (every re-run would double-bank) — it drops alone, like everywhere else.
    if [ -n "$AT" ] && [ -f "$CALIB" ] \
       && jq -eRn --arg b "$AT" '
            [ inputs | fromjson? | select(type == "object") ]
            | (map(.kind) | rindex("grade")) as $g
            | (if $g == null then . else .[($g + 1):] end)
            | any(.[]; (.kind // "") == "forecast" and (.boundary // "") == $b)
          ' "$CALIB" >/dev/null 2>&1; then
      echo "[projection] forecast for boundary '$AT' already banked this initiative -> $CALIB (idempotent no-op)"
      exit 0
    fi
    PROJ=$(compute_projection) || die 4 "failed to compute the projection to bank"
    SESSION_NOW=$(current_session)
    LINE=$(printf '%s' "$PROJ" | jq -c \
      --arg banked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg boundary "$AT" \
      --arg banked_session "$SESSION_NOW" \
      '{kind:"forecast", banked_at:$banked_at}
       + (if $boundary == "" then {} else {boundary:$boundary} end)
       + {banked_session: (if $banked_session == "" then null else $banked_session end)}
       + .') \
      || die 4 "failed to assemble the banked forecast (jq error)"
    bank_line "$LINE"
    echo "[projection] banked forecast${AT:+ (boundary: $AT)} -> $CALIB"
    ;;

  grade)
    [ -f "$CALIB" ] || die 4 "no calibration record at $CALIB — nothing banked to grade (bank a forecast first)"
    # Grade the OPENING (plan-boundary) forecast — the whole-initiative claim —
    # degrading to the most recent forecast when none was banked at plan.
    FORECAST=$(jq -cRn '
      [ inputs | fromjson? | select(type == "object") | select(.kind=="forecast") ] as $f
      | ( [ $f[] | select(.boundary=="plan") ] | last )
        // ( $f | last )
        // empty' "$CALIB" 2>/dev/null)
    [ -n "$FORECAST" ] || die 4 "no banked forecast in $CALIB to grade against"
    GRADED_BOUNDARY=$(printf '%s' "$FORECAST" | jq -r '.boundary // "unlabeled"')
    GRADED_AT=$(printf '%s' "$FORECAST" | jq -r '.banked_at // .generated // empty')
    BANK_TS="$GRADED_AT"

    # The estimate side: v2 fields, with v1 spine fallbacks for a legacy line.
    EST_QUANTITY=$(printf '%s' "$FORECAST" | jq -r '.quantity.sized_remaining // .spine.quantity.remaining_sessions // 0')
    EST_RATE=$(printf '%s' "$FORECAST" | jq -r '.rate.mean // .spine.unit_rate.blended_tokens // .spine.unit_rate.floor_tokens // 0')

    # The quantity denominator: the SESSION RECORD — every artifact after the
    # banked_session stamp counts, metered or not. A legacy forecast carries no
    # stamp; degrade to distinct post-bank metered sessions, disclosed.
    BANKED_SESSION=$(printf '%s' "$FORECAST" | jq -r '.banked_session // empty')
    if [ -n "$BANKED_SESSION" ]; then
      DENOM_SOURCE="session_record"
      ACTUAL_SESSIONS=$(ls "$ROOT"/docs/sessions/session-*.md 2>/dev/null \
        | sed -E 's#.*/(session-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3})\.md#\1#' \
        | grep -E '^session-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3}$' \
        | awk -v b="$BANKED_SESSION" '$0 > b' | sort -u | wc -l | tr -d ' ')
    else
      DENOM_SOURCE="metering_log"
      # Per-line tolerant, like every log read: a torn line dropping the whole
      # count would bank actual_sessions=0 — a fabricated came-in-under grade —
      # into the append-only record. Session COUNTS are unit-free (no token
      # comparison), so this denominator is post-bank, not post-epoch: a legacy
      # forecast's window legitimately spans the epoch line.
      ACTUAL_SESSIONS=0
      [ -f "$LOG" ] && ACTUAL_SESSIONS=$(jq -rRn --arg since "$BANK_TS" \
        '[ inputs | fromjson? | select(type == "object")
               | select((.schema // "") | startswith("guv.meter"))
               | select((.schema // "") != "guv.meter.epoch.v1")
               | select($since == "" or (.ts // "") >= $since)
               | .session | select(. != null) ] | unique | length' "$LOG" 2>/dev/null)
    fi
    case "$ACTUAL_SESSIONS" in ''|*[!0-9]*) ACTUAL_SESSIONS=0 ;; esac

    # The rate side: post-bank mean per-session burn, the same sample selection
    # as observed_rate() (unit honesty — degraded entries are not samples).
    ACTUAL_RATE=0
    if [ -f "$LOG" ]; then
      ACTUAL_RATE=$(jq -rRn --arg since "$BANK_TS" '
        def burn: (.input // 0) + (.output // 0) + (.cache_read // 0) + (.cache_creation // 0);
        [ inputs | fromjson? | select(type == "object") ] as $lines
        | ([ $lines | to_entries[] | select(.value.schema == "guv.meter.epoch.v1") | .key ] | last // -1) as $epoch
        | [ $lines | to_entries[] | select(.key > $epoch) | .value
            | select((.schema // "") | startswith("guv.meter"))
            | select((.harvest_basis // "") == "per_response")
            | select(.tokens != null)
            | select((.slice_basis // "") as $sb | $sb == "per_deliverable" or $sb == "since_process_start")
            | select($since == "" or ((.ts // "") >= $since))
            | (.tokens | burn) ] as $b
        | if ($b | length) == 0 then 0 else ($b | add) / ($b | length) | floor end' "$LOG" 2>/dev/null)
    fi
    case "$ACTUAL_RATE" in ''|*[!0-9]*) ACTUAL_RATE=0 ;; esac

    GRADE=$(jq -cn \
      --arg schema "guv.projection.grade.v2" \
      --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson est_q "$EST_QUANTITY" \
      --argjson actual_sessions "$ACTUAL_SESSIONS" \
      --arg denom_source "$DENOM_SOURCE" \
      --argjson est_rate "$EST_RATE" \
      --argjson actual_rate "$ACTUAL_RATE" \
      --arg graded_boundary "$GRADED_BOUNDARY" \
      --arg graded_at "$GRADED_AT" '
      {
        schema: $schema,
        generated: $generated,
        graded_forecast: { boundary: $graded_boundary, banked_at: $graded_at },
        quantity_error: {
          estimated_session_equivalents: $est_q,
          actual_sessions: $actual_sessions,
          delta_sessions: ($actual_sessions - $est_q),
          denominator_source: $denom_source
        },
        rate_error: {
          forecast_tokens_per_session: $est_rate,
          actual_tokens_per_session: $actual_rate,
          delta_tokens: ($actual_rate - $est_rate)
        }
      }') || die 4 "failed to assemble the grade (jq error)"

    printf '%s\n' "$GRADE"
    BANKED=$(printf '%s' "$GRADE" | jq -c --arg banked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{kind:"grade", banked_at:$banked_at} + .')
    bank_line "$BANKED"
    ;;
esac

exit 0
