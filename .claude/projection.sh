#!/bin/bash
# .claude/projection.sh — cost-to-complete PROJECTION ([9.7] of the plan-as-data
# spec). Structural spine, local blend, graded always.
#
# WHAT THIS IS ─────────────────────────────────────────────────────────────────
# A projection of the guv-mediated cost to COMPLETE the live initiative — a
# RANGE carrying a BASIS claim and a SCOPE claim. It is computed at n=0 and ever
# after: there is NO refusal state. The spine stands on the user's OWN plan and
# guv, never anyone's history.
#
# THE SPINE = a quantity takeoff × a unit rate, both derived locally ──────────────
#   quantity = the ratified sessions-per-deliverable (the [9.6] estimate sidecar)
#              summed over REMAINING work — the resolver (resolve-ready.sh) tells
#              us which deliverables remain (every open deliverable, by marker:
#              todo ⬜ + in_progress 🔄 + human_gated 🔒);
#              deliverables lacking a ratified estimate project at the DEFAULT (1)
#              and are DISCLOSED in default_estimate_ids.
#   unit rate = the SESSION ENVELOPE — the fixed overhead a session carries,
#              measured by tokenizing the actual control-plane docs a session
#              loads (CLAUDE.md + .claude/rules/*.md), as the FLOOR, bounded ABOVE
#              by [9.2]'s occupancy threshold as the CEILING. Floor is MEASURED;
#              ceiling is a SETPOINT (manifest occupancy.threshold, else the
#              window-relative default the [9.2]/[10.6] meter ships).
#   range    = quantity × envelope: low = remaining × floor, high = remaining ×
#              ceiling. Denomination follows Spike C's rung — TOKENS — never a
#              guessed dollar conversion (pricing tables drift; the spec forbids
#              the guess, exactly as [9.1]'s dollars stays null).
#
# THE LOCAL BLEND ────────────────────────────────────────────────────────────────
# Local observed rates blend into the unit rate as landings accrue. The observed
# rate is the mean per-session token burn over THIS control plane's metering log
# (.claude/metering/metering.ndjson — the [9.1] raw evidence). The blend WEIGHT
# moves with the sample count (more landings -> more weight on observed): a plain
# arithmetic weight n/(n+K) over the count, K a smoothing constant. History is a
# WEIGHTED INPUT, never the foundation — at n=0 the weight is 0 and the spine is
# purely structural; the structure never disappears, it is corrected in-flight.
#
# NO FOREIGN HISTORY ─────────────────────────────────────────────────────────────
# The ONLY inputs are THIS control plane's own artifacts: its metering log, its
# estimate sidecar, its calibration record, and the resolver (which reads the
# local tracker). There is deliberately NO path to another project's history —
# no $HOME crawl, no cross-project glob, no network fetch. The [9.1] harvest
# reaches into the runtime transcript under $HOME; the PROJECTION never does — it
# consumes the already-harvested LOCAL log. The suite grep-asserts this.
#
# BANKED + GRADED ────────────────────────────────────────────────────────────────
# `bank` appends the current projection as a forecast line to the calibration
# record (.claude/metering/calibration.ndjson — append-only, like the metering
# log). At initiative close `grade` compares the banked forecast against what
# actually happened and emits TWO SEPARABLE errors — quantity error (sessions
# estimated vs actual) and rate error (envelope vs actual tokens/session) — so a
# miss NAMES ITS LAYER, and banks the grade back into the calibration record.
#
# DETERMINISTIC (Rule 12). The projection is ARITHMETIC over logged data — no LLM,
# no judgment, no agent input. Tokenization is the standard chars/4 heuristic (a
# deterministic transform, the same approximation [9.1]'s consumers use), not a
# model call. Pure bash + jq, the sibling convention.
#
# Usage:
#   bash .claude/projection.sh project [--tracker P] [--log P] [--sidecar P] [--calibration P] [--root P]
#   bash .claude/projection.sh bank    [--tracker P] [--log P] [--sidecar P] [--calibration P] [--root P]
#   bash .claude/projection.sh grade   [--tracker P] [--log P] [--sidecar P] [--calibration P] [--root P]
#
#   project  emit the projection JSON document to stdout (READ-ONLY).
#   bank     compute the projection and APPEND it as a forecast to the calibration
#            record (the only write to the record other than grade).
#   grade    close-time: grade the latest banked forecast against the outcome,
#            emit the two-error grade to stdout, and bank it (kind="grade").
#
#   Paths default root-relative (cwd = the project root, the sibling convention
#   every guv spine script carries); --root overrides the base for all defaults.
#   --tracker docs/PHASE_STATUS.md · --log .claude/metering/metering.ndjson ·
#   --sidecar docs/estimates.json · --calibration .claude/metering/calibration.ndjson.
#
# Exit: 0 emitted/banked · 2 usage · 4 no/corrupt manifest.
set -u

SCHEMA="guv.projection.v1"
err() { echo "projection: $1" >&2; }
die() { err "$2"; exit "$1"; }

# The resolver is a SIBLING spine script — located relative to THIS script, never
# cwd (the projection and the resolver travel together; cwd is the project root
# for reading the local artifacts). We consume the resolver's published JSON for
# the remaining-work set and NEVER re-parse the tracker (the one-parser
# discipline, A-001 — the same join emit-metrics.sh makes).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVER="$SCRIPT_DIR/resolve-ready.sh"
ESTIMATE="$SCRIPT_DIR/estimate.sh"

# ── window-relative occupancy ceiling (mirrors the [9.2]/[10.6] meter) ──────────
# The envelope CEILING is the occupancy threshold: the manifest setpoint if
# present, else the documented window-relative default. We cannot see a live
# model here (no transcript context at projection time), so the default is the
# standard-window fallback the meter ships: 3/4 of the standard 200000 window.
STANDARD_WINDOW=200000
CALM_FRACTION_NUM=3
CALM_FRACTION_DEN=4
DEFAULT_CEILING=$((STANDARD_WINDOW * CALM_FRACTION_NUM / CALM_FRACTION_DEN))   # 150000

# Blend smoothing constant: the observed-rate weight is n/(n+K). K=3 means at
# n=3 the observed rate carries half the weight; the weight rises monotonically
# with the landing count and never reaches 1 (the structure never fully leaves).
BLEND_K=3

# ── arg parse ───────────────────────────────────────────────────────────────────
[ $# -ge 1 ] || die 2 "usage: bash .claude/projection.sh project|bank|grade [--tracker P] [--log P] [--sidecar P] [--calibration P] [--root P]"
SUB="$1"; shift
case "$SUB" in project|bank|grade) ;; *) die 2 "unknown subcommand '$SUB' (only: project, bank, grade)" ;; esac

ROOT="."
TRACKER=""; LOG=""; SIDECAR=""; CALIB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root)        ROOT="${2:-}"; shift 2 ;;
    --tracker)     TRACKER="${2:-}"; shift 2 ;;
    --log)         LOG="${2:-}"; shift 2 ;;
    --sidecar)     SIDECAR="${2:-}"; shift 2 ;;
    --calibration) CALIB="${2:-}"; shift 2 ;;
    *) die 2 "unknown argument '$1'" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die 2 "projection requires jq, which is not on PATH"

# cwd must be the project root — the sibling convention shared with meter.sh /
# emit-metrics.sh / resolve-ready.sh. All local artifacts resolve under $ROOT.
MANIFEST="$ROOT/.claude/project.json"
[ -f "$MANIFEST" ] || die 4 "no manifest at $MANIFEST (cwd must be the project root, or pass --root)"
jq -e . "$MANIFEST" >/dev/null 2>&1 \
  || die 4 "$MANIFEST exists but is not valid JSON — fix the manifest"

[ -n "$TRACKER" ] || TRACKER="$ROOT/docs/PHASE_STATUS.md"
[ -n "$LOG" ]     || LOG="$ROOT/.claude/metering/metering.ndjson"
[ -n "$SIDECAR" ] || SIDECAR="$ROOT/docs/estimates.json"
[ -n "$CALIB" ]   || CALIB="$ROOT/.claude/metering/calibration.ndjson"

# ── the envelope FLOOR: tokenize the control-plane docs a session loads ─────────
# Fixed overhead = the bytes a session loads at startup regardless of task:
# the rendered CLAUDE.md plus every .claude/rules/*.md (the natively-loaded
# rules). Tokens ≈ chars/4 (the deterministic heuristic; NOT a model call). This
# is MEASURED from the actual local files — the floor is evidence, not a guess.
# Designed degradation (Rule 15): if no doc is readable the floor falls to a
# documented minimum so the spine never divides by zero or collapses to 0.
FLOOR_MIN=1000
envelope_floor() {
  local chars=0 f
  local files="$ROOT/CLAUDE.md"
  for f in "$ROOT"/.claude/rules/*.md; do
    [ -f "$f" ] && files="$files $f"
  done
  local total=0
  for f in $files; do
    [ -f "$f" ] || continue
    local c
    c=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    total=$((total + c))
  done
  local tok=$((total / 4))
  [ "$tok" -lt "$FLOOR_MIN" ] && tok="$FLOOR_MIN"
  printf '%s' "$tok"
}

# ── the envelope CEILING: the occupancy threshold (setpoint, else default) ──────
envelope_ceiling() {
  local t
  t=$(jq -r '.occupancy.threshold // empty' "$MANIFEST" 2>/dev/null)
  case "$t" in
    ''|*[!0-9]*) printf '%s' "$DEFAULT_CEILING" ;;
    *)           printf '%s' "$t" ;;
  esac
}

# ── remaining work, from the resolver (the one parser of plan state) ────────────
# Remaining = every OPEN deliverable, selected by the per-deliverable status the
# resolver actually emits: todo (⬜), in_progress (🔄), and human_gated (🔒). We
# read the resolver's published JSON and never re-parse the tracker. Note the
# resolver NEVER emits a per-deliverable status of "blocked" — "blocked" is a
# FRONTIER classification (a ⬜ with an unsatisfied dep), not a deliverable
# status — so it is not a selectable status here; a ⬜ is counted as open whether
# or not its deps are satisfied. Designed degradation: no tracker / a resolver
# refusal -> empty remaining set (the spine then projects a zero-quantity range
# honestly, never crashes).
remaining_ids() {
  [ -f "$TRACKER" ] && [ -f "$RESOLVER" ] || return 0
  local resolved
  resolved=$(bash "$RESOLVER" "$TRACKER" --json 2>/dev/null) || return 0
  [ -n "$resolved" ] || return 0
  printf '%s' "$resolved" | jq -r '
    [ .deliverables[] | select(.status=="todo" or .status=="in_progress" or .status=="human_gated") | .id
      | select(. != null) ] | .[]' 2>/dev/null
}

# ── observed per-session rate, from the LOCAL metering log ──────────────────────
# The observed burn is the total token burn per session over this control plane's
# metering log. Total burn = the four token classes summed (the same burn
# definition budget-gate.sh uses) — cumulative session THROUGHPUT, not point-in-
# time occupancy: it sums across every turn, so cache_read dominates and the value
# is unbounded by the window. Only entries with harvested tokens count as a sample
# (a degraded tokens:null entry is no sample). Emits "n<TAB>mean<TAB>min<TAB>max"
# (all 0 when n=0) — the mean drives the central blended rate, the min/max drive
# the blended band EDGES. NEVER reads anything but this local log.
observed_rate() {
  if [ ! -f "$LOG" ]; then printf '0\t0\t0\t0'; return; fi
  jq -rs '
    [ .[] | select((.schema // "") | startswith("guv.meter"))
          | (.tokens // null) | select(. != null)
          | ((.input // 0) + (.output // 0) + (.cache_read // 0) + (.cache_creation // 0)) ] as $b
    | ($b | length) as $n
    | if $n == 0 then "0\t0\t0\t0"
      else "\($n)\t\(($b | add) / $n | floor)\t\($b | min)\t\($b | max)" end
  ' "$LOG" 2>/dev/null || printf '0\t0\t0\t0'
}

# ── compute the projection document (shared by project / bank) ──────────────────
# Pure read over the local artifacts; emits one guv.projection.v1 JSON document.
compute_projection() {
  local floor ceiling
  floor=$(envelope_floor)
  ceiling=$(envelope_ceiling)
  # The floor is "bounded above by [9.2]'s occupancy threshold" (the spec wording):
  # a measured fixed overhead that exceeds the ceiling setpoint is a degenerate
  # config (overhead alone above the calm threshold). Clamp so the band can never
  # invert (low <= high) — the floor is evidence, the ceiling is its upper bound.
  [ "$floor" -gt "$ceiling" ] && floor="$ceiling"

  # quantity takeoff: sum ratified estimates over remaining work; disclose the
  # deliverables that fell back to the default.
  local ids id est remaining_sessions=0 default_ids="" def
  def=$(bash "$ESTIMATE" default 2>/dev/null); case "$def" in ''|*[!0-9]*) def=1 ;; esac
  ids=$(remaining_ids)
  for id in $ids; do
    est=$(bash "$ESTIMATE" get "$id" "$SIDECAR" 2>/dev/null)
    case "$est" in ''|*[!0-9]*) est="$def" ;; esac
    remaining_sessions=$((remaining_sessions + est))
    # a deliverable with NO entry in the sidecar projected at the default — disclose it.
    if ! { [ -f "$SIDECAR" ] && jq -e --arg k "$id" 'has($k)' "$SIDECAR" >/dev/null 2>&1; }; then
      default_ids="$default_ids $id"
    fi
  done

  # the local blend: observed burn (mean + band edges min/max), weight = n/(n+K).
  local obs n mean omin omax blended weight_num weight_den
  obs=$(observed_rate)
  IFS=$'\t' read -r n mean omin omax <<EOF
$obs
EOF
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  case "$mean" in ''|*[!0-9]*) mean=0 ;; esac
  case "$omin" in ''|*[!0-9]*) omin=0 ;; esac
  case "$omax" in ''|*[!0-9]*) omax=0 ;; esac

  # The structural per-session rate is the floor (the measured fixed overhead is
  # the structural unit rate; the ceiling is the structural band's upper edge).
  # blended = (1-w)*structural + w*observed, w = n/(n+K). Integer arithmetic via
  # the weight numerator/denominator to stay pure-bash + deterministic. The SAME
  # weight applies to the CENTER and to BOTH BAND EDGES, so the whole band is
  # "corrected in-flight" toward observed throughput — not just the central rate
  # while the band stays frozen at occupancy scale (the incoherence BUG 3 fixes:
  # a blended central rate is throughput-scale but a static floor..ceiling band is
  # occupancy-scale, so the center landed hundreds of × outside its own range).
  weight_num=$n
  weight_den=$((n + BLEND_K))
  local basis_claim blended_rate blended_low_rate blended_high_rate observed_weight_str
  if [ "$n" -eq 0 ]; then
    # n=0: purely structural — center = floor, band = floor..ceiling (occupancy).
    basis_claim="structural"
    blended_rate="$floor"
    blended_low_rate="$floor"
    blended_high_rate="$ceiling"
    observed_weight_str="0"
  else
    basis_claim="blended"
    # center: (floor*(den-num) + observed_mean*num) / den
    blended_rate=$(( (floor * (weight_den - weight_num) + mean * weight_num) / weight_den ))
    # band edges migrate by the same weight: low toward observed min, high toward
    # observed max. floor<=ceiling (clamped) and min<=mean<=max => the band never
    # inverts and the center always lies inside it (coherent document).
    blended_low_rate=$(( (floor * (weight_den - weight_num) + omin * weight_num) / weight_den ))
    blended_high_rate=$(( (ceiling * (weight_den - weight_num) + omax * weight_num) / weight_den ))
    # observed weight as a decimal string for the document (num/den)
    observed_weight_str=$(awk -v a="$weight_num" -v b="$weight_den" 'BEGIN{ printf "%.4f", a/b }')
  fi

  # the range: quantity × the (possibly blended) envelope band. low = remaining ×
  # the low edge, high = remaining × the high edge. At n=0 these are the structural
  # floor/ceiling; once landings accrue the edges have migrated toward observed
  # throughput, so the reported range and the central blended rate stay in the
  # same unit and the same universe.
  local low high
  low=$((remaining_sessions * blended_low_rate))
  high=$((remaining_sessions * blended_high_rate))

  # disclosure list as a JSON array
  local default_json
  default_json=$(printf '%s' "$default_ids" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -cs '.')

  jq -cn \
    --arg schema "$SCHEMA" \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson remaining_sessions "$remaining_sessions" \
    --argjson floor "$floor" \
    --argjson ceiling "$ceiling" \
    --argjson blended "$blended_rate" \
    --argjson blended_low "$blended_low_rate" \
    --argjson blended_high "$blended_high_rate" \
    --argjson low "$low" \
    --argjson high "$high" \
    --arg basis "$basis_claim" \
    --argjson n "$n" \
    --arg ow "$observed_weight_str" \
    --argjson observed_mean "$mean" \
    --argjson default_ids "$default_json" '
    {
      schema: $schema,
      generated: $generated,
      range: { low_tokens: $low, high_tokens: $high, denomination: "tokens" },
      basis: {
        claim: $basis,
        n: $n,
        observed_weight: ($ow | tonumber),
        observed_mean_tokens_per_session: $observed_mean
      },
      scope: {
        claim: "guv-mediated cost to complete (remaining work, not total)"
      },
      spine: {
        quantity: {
          remaining_sessions: $remaining_sessions,
          default_estimate_ids: $default_ids
        },
        unit_rate: {
          floor_tokens: $floor,
          ceiling_tokens: $ceiling,
          blended_tokens: $blended,
          blended_low_tokens: $blended_low,
          blended_high_tokens: $blended_high
        }
      }
    }'
}

# ── append-only write to the calibration record (the ONLY mutating primitive) ──
# Like the metering log, the calibration record is append-only NDJSON: no code
# path here rewrites, truncates, or in-place-edits it. Only >> is used.
bank_line() {  # <json-line>
  mkdir -p "$(dirname "$CALIB")"
  printf '%s\n' "$1" >> "$CALIB"
}

case "$SUB" in

  project)
    compute_projection
    ;;

  bank)
    PROJ=$(compute_projection) || die 4 "failed to compute the projection to bank"
    LINE=$(printf '%s' "$PROJ" | jq -c \
      --arg kind "forecast" \
      --arg banked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{kind:$kind, banked_at:$banked_at, schema:.schema, generated:.generated,
        range:.range, basis:.basis, scope:.scope, spine:.spine}') \
      || die 4 "failed to assemble the banked forecast (jq error)"
    bank_line "$LINE"
    echo "[projection] banked forecast -> $CALIB"
    ;;

  grade)
    # Close-time grading: compare the latest banked FORECAST against the OUTCOME
    # in the local metering log, and split the miss into its two layers.
    [ -f "$CALIB" ] || die 4 "no calibration record at $CALIB — nothing banked to grade (bank a forecast first)"
    FORECAST=$(jq -cs '[ .[] | select(.kind=="forecast") ] | last // empty' "$CALIB" 2>/dev/null)
    [ -n "$FORECAST" ] || die 4 "no banked forecast in $CALIB to grade against"

    # quantity layer: estimated sessions (the forecast's takeoff) vs ACTUAL
    # sessions. The takeoff was REMAINING work AT BANK TIME, so the comparison is
    # like-for-like only if actual_sessions is bounded to sessions occurring AFTER
    # the forecast was banked — sessions logged BEFORE the bank were spent on
    # already-done work and were never in the forecast's scope. We bound on the
    # banked forecast's own timestamp (banked_at, falling back to generated).
    EST_SESSIONS=$(printf '%s' "$FORECAST" | jq -r '.spine.quantity.remaining_sessions')
    ENVELOPE=$(printf '%s' "$FORECAST" | jq -r '.spine.unit_rate.floor_tokens')
    BANK_TS=$(printf '%s' "$FORECAST" | jq -r '.banked_at // .generated // empty')
    if [ -f "$LOG" ]; then
      # distinct post-bank sessions: meter entries whose ts is at/after the bank
      # timestamp (an empty BANK_TS degrades to the whole log — no bound to apply).
      ACTUAL_SESSIONS=$(jq -rs --arg since "$BANK_TS" \
        '[ .[] | select((.schema // "") | startswith("guv.meter"))
               | select($since == "" or (.ts // "") >= $since)
               | .session ] | unique | length' "$LOG" 2>/dev/null)
      # actual per-session burn, bounded the SAME way as actual_sessions: the mean
      # total token burn over POST-BANK sessions only. The forecast's envelope was
      # set against the work it COVERS (remaining work from bank time forward), so
      # the rate comparison is like-for-like only over post-bank burn — pre-bank
      # sessions were spent on already-done work and were never in scope. We do NOT
      # touch observed_rate() (the live projection blend reads the full history); we
      # bound the GRADE's comparison alone. An empty BANK_TS degrades to whole-log,
      # matching the actual_sessions bound. (Same burn definition as observed_rate:
      # the four token classes summed; only harvested-token entries are samples.)
      ACTUAL_RATE=$(jq -rs --arg since "$BANK_TS" '
        [ .[] | select((.schema // "") | startswith("guv.meter"))
              | select($since == "" or (.ts // "") >= $since)
              | (.tokens // null) | select(. != null)
              | ((.input // 0) + (.output // 0) + (.cache_read // 0) + (.cache_creation // 0)) ] as $b
        | ($b | length) as $n
        | if $n == 0 then 0 else ($b | add) / $n | floor end' "$LOG" 2>/dev/null)
    else
      ACTUAL_SESSIONS=0; ACTUAL_RATE=0
    fi
    case "$ACTUAL_SESSIONS" in ''|*[!0-9]*) ACTUAL_SESSIONS=0 ;; esac
    case "$ACTUAL_RATE" in ''|*[!0-9]*) ACTUAL_RATE=0 ;; esac

    GRADE=$(jq -cn \
      --arg schema "guv.projection.grade.v1" \
      --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson est_sessions "$EST_SESSIONS" \
      --argjson actual_sessions "$ACTUAL_SESSIONS" \
      --argjson envelope "$ENVELOPE" \
      --argjson actual_rate "$ACTUAL_RATE" '
      {
        schema: $schema,
        generated: $generated,
        # TWO SEPARABLE errors — a miss names its LAYER.
        quantity_error: {
          estimated_sessions: $est_sessions,
          actual_sessions: $actual_sessions,
          delta_sessions: ($actual_sessions - $est_sessions)
        },
        rate_error: {
          envelope_tokens: $envelope,
          actual_tokens_per_session: $actual_rate,
          delta_tokens: ($actual_rate - $envelope)
        }
      }') || die 4 "failed to assemble the grade (jq error)"

    # emit, then bank the grade (the local record learns from the close).
    printf '%s\n' "$GRADE"
    BANKED=$(printf '%s' "$GRADE" | jq -c --arg kind "grade" --arg banked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{kind:$kind, banked_at:$banked_at} + .')
    bank_line "$BANKED"
    ;;
esac

exit 0
