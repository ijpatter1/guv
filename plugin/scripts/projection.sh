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
#   unit rate = per-session cumulative THROUGHPUT ([12.1]) — the burn the [9.1]
#              meter captures (input + output + cache_read + cache_creation summed
#              across every turn), the unit a [9.3] budget is set in. The structural
#              anchor is the MODELED rate occupancy_budget × expected_turns ([13.3]):
#              a session re-reads ~its working set on every inference, so cumulative
#              FLOW ≈ working_set × turns — the flow reconstruction of the point-in-
#              time occupancy STOCK. occupancy_budget = the [9.2] setpoint's working
#              set (≈0.4× the setpoint — the forensic B4 finding — clamped ≥ the measured
#              doc-overhead floor); expected_turns = base_build + an eval/fix term whose
#              distribution sets the band. The pre-[13.3] anchor was the bare doc floor
#              (orders of magnitude below real throughput); occupancy now returns ONLY
#              as a modeled FACTOR (rate = occupancy × turns), never as the cost itself.
#              The raw occupancy threshold and the floor stay informational references.
#   range    = quantity × the throughput band. At n=0 (no history) the band is the
#              MODELED occupancy×turns band — a REAL central estimate with
#              basis.bound="modeled_range" (superseding [12.1]'s lower_bound_only): the
#              eval/fix term's low edge (clean run) and high edge (fix-heavy) set a
#              genuine band, no fabricated turn-count guess. Denomination follows Spike
#              C's rung — TOKENS — never a guessed dollar conversion (pricing tables
#              drift; the spec forbids the guess, exactly as [9.1]'s dollars stays null).
#
# THE LOCAL BLEND ────────────────────────────────────────────────────────────────
# Local observed THROUGHPUT blends into the unit rate as landings accrue. The
# observed rate is the per-session token burn over THIS control plane's metering
# log (.claude/metering/metering.ndjson — the [9.1] raw evidence): the mean drives
# the central rate, the min/max drive the band EDGES. The blend WEIGHT moves with
# the sample count (more landings -> more weight on observed): a plain arithmetic
# weight n/(n+K) over the count, K a smoothing constant. Each edge anchors on its
# structural occupancy×turns edge (low/central/high — [13.3]) and migrates toward the
# matching observed edge (min/mean/max) by the same weight, so the band is corrected
# in-flight as one. History is a WEIGHTED INPUT, never the foundation — at n=0 the
# weight is 0 and the spine is the modeled occupancy×turns band; the structure never
# disappears, it is CORRECTED in-flight (from a meaningful prior, not from ≈0).
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
# ([13.4]) The bank/grade calls are WIRED INTO THE LIFECYCLE COMMANDS — /plan banks
# the opening forecast (`--at plan`) and grades at initiative close, /handoff banks at
# each phase boundary (`--at phase-N`) — so the projection is banked when made, never
# by a manual call. Under a plugin install those commands are guv:-namespaced
# (/guv:plan, /guv:handoff); this script ships byte-identical, so the bare names here
# are the canonical references, decoded once.
#
# DETERMINISTIC (Rule 12). The projection is ARITHMETIC over logged data — no LLM,
# no judgment, no agent input. Tokenization is the standard chars/4 heuristic (a
# deterministic transform, the same approximation [9.1]'s consumers use), not a
# model call. Pure bash + jq, the sibling convention.
#
# Usage:
#   bash .claude/projection.sh project [--tracker P] [--log P] [--sidecar P] [--calibration P] [--root P]
#   bash .claude/projection.sh bank    [--at BOUNDARY] [--tracker P] [--log P] [--sidecar P] [--calibration P] [--root P]
#   bash .claude/projection.sh grade   [--tracker P] [--log P] [--sidecar P] [--calibration P] [--root P]
#
#   project  emit the projection JSON document to stdout (READ-ONLY).
#   bank     compute the projection and APPEND it as a forecast to the calibration
#            record (the only write to the record other than grade). [13.4] --at
#            BOUNDARY tags the forecast with the lifecycle boundary it was banked
#            at (e.g. `plan`, `phase-9`) — the lineage key. Banking at a boundary
#            is IDEMPOTENT: re-banking the SAME boundary is a no-op (no double-bank
#            on a re-run), while a different boundary appends (the lineage accrues).
#            A bank with no --at is unconditionally appended (the manual escape hatch).
#   grade    close-time: read the forecast lineage and grade the OPENING (plan-
#            boundary) forecast against the outcome — degrading to the latest
#            forecast when none was banked at `plan` — emit the two-error grade
#            (naming the lineage entry it read in graded_forecast) to stdout, and
#            bank it (kind="grade").
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

# ── window-relative occupancy REFERENCE (mirrors the [9.2]/[10.6] meter) ─────────
# [12.1] the occupancy threshold is the manifest setpoint if present, else the
# documented window-relative default. We cannot see a live model here (no transcript
# context at projection time), so the default is the standard-window fallback the
# meter ships: 3/4 of the standard 200000 window. This value is carried as an
# INFORMATIONAL reference only (occupancy is a point-in-time stock, not a cost
# ceiling) — it never enters the throughput range.
STANDARD_WINDOW=200000
CALM_FRACTION_NUM=3
CALM_FRACTION_DEN=4
DEFAULT_CEILING=$((STANDARD_WINDOW * CALM_FRACTION_NUM / CALM_FRACTION_DEN))   # 150000

# Blend smoothing constant: the observed-rate weight is n/(n+K). K=3 means at
# n=3 the observed rate carries half the weight; the weight rises monotonically
# with the landing count and never reaches 1 (the structure never fully leaves).
BLEND_K=3

# ── [13.3] the occupancy×turns structural rate model ─────────────────────────────
# The structural per-session rate is occupancy_budget × expected_turns — the modeled
# cumulative THROUGHPUT (flow) reconstructed from the point-in-time occupancy (stock):
# a session re-reads ~its working set on every inference, so flow ≈ working_set × turns.
# This replaces the pre-[13.3] doc-overhead floor (an orders-of-magnitude undershoot
# that made the n=0 prior a bare lower bound and the blend converge from ≈0). The
# coefficients are calibrated against the forensic per-deliverable deltas measured
# during guv's own development (the B4 finding: real throughput ≈ 70–350M/session,
# mean ~150M, with an observed per-session envelope of ~37M–628M; occupancy_budget ≈
# avg working set ≈ 0.4× the setpoint). Those numbers are inlined here — the forensic
# analysis is a maintainer artifact and does not ship in this code repo, so this cites
# the FINDING, not a file path a fresh install would lack ([15.6]):
#   • occupancy_budget = occupancy setpoint × WORKING_SET_FRACTION. The avg working set
#     is ~0.4× the setpoint, NOT the full setpoint (a session sits below the calm
#     ceiling most of its life). Clamped UP to the measured floor (the doc overhead is
#     a true lower bound on a session's working set) so a tiny/absent setpoint degrades
#     to the floor rather than collapsing the rate to 0 (Rule 15).
#   • expected_turns = BASE_BUILD_TURNS + an eval/fix term whose DISTRIBUTION sets the
#     band: the low edge is base_build alone (a clean run, no fix iterations), the high
#     edge adds the fix-heavy eval/fix loop. "Turns" = inferences/session (hundreds;
#     the unit cumulative flow counts).
# At the real 800k setpoint: occupancy_budget=320000; turns 115/470/1963 → structural
# 36.8M / 150.4M / 628.16M — bracketing the observed ~37M–628M per-session envelope
# ([15.6] widened the tails so the band CONTAINS the envelope from outside; the central
# is unchanged).
#
# CALIBRATION vs MEASUREMENT — be honest about which is which (Rule 10). The forensic
# evidence independently grounds TWO inputs: the working-set fraction (≈0.375 observed,
# ~300k/800k — rounded to 0.4) and the target token band (70–350M/session mean ~150M,
# the wider ~37M–628M per-session envelope at the tails). expected_turns is the FITTED
# free parameter: turns_central is chosen so occupancy_budget × turns reproduces the
# forensic MEAN (320000 × 470 = 150.4M; the forensics' own main-only estimate is ~360
# inferences/session, of which 470 is the subagent-inclusive analog). The base/eval SPLIT
# (115 + 355/1848) and the band SPREAD are a MODELING ASSUMPTION shaped to BRACKET the
# ~37M–628M envelope — [13.1]'s now-in-scope subagent burn grounds the DIRECTION
# (fix-heavy sessions burn more), not the exact turn counts. A measured per-session
# inference-count distribution would refine the split. So the exact reconcile lands the
# PRODUCT on the evidence; it is not independent triangulation of three measured factors.
WORKING_SET_FRACTION_NUM=2          # occupancy_budget = setpoint × 2/5 = 0.4 × setpoint
WORKING_SET_FRACTION_DEN=5
# [15.6] the band TAILS are widened to BRACKET the observed per-session envelope
# (~37M–628M at the 800k setpoint), without moving the load-bearing CENTRAL: the
# central is the PRODUCT turns_central = BASE_BUILD_TURNS + EVAL_FIX_TURNS_TYPICAL = 470,
# byte-unchanged (320000 × 470 = 150.4M, the forensic mean). The pre-[15.6] band
# (turns 220/470/1090 → 70.4M / 150.4M / 348.8M) UNDER-bracketed the observed tails: a
# tiny clean fix ran as low as ~37M, a fix-heavy build as high as ~628M, so the band
# failed to CONTAIN the envelope it models. Re-split the same central 470 to lower the
# low edge BELOW the envelope floor and lengthen the heavy tail ABOVE its ceiling: turns
# 115/470/1963 → 36.8M / 150.4M / 628.16M, so the band brackets ~37M–628M from outside.
# Only the eval/fix tails moved (the BASE_BUILD/EVAL_FIX SPLIT is the modeling
# assumption — Rule 10 honesty: the band SPREAD is fitted to the observed envelope, the
# central PRODUCT to the forensic mean).
BASE_BUILD_TURNS=115                 # clean-run inferences (the band's LOW edge → 36.8M, ≤ ~37M)
EVAL_FIX_TURNS_TYPICAL=355          # + typical eval/fix loop → central = 470 (UNCHANGED)
EVAL_FIX_TURNS_HEAVY=1848           # + fix-heavy eval/fix loop → high = 1963 (628.16M, ≥ ~628M)

# ── arg parse ───────────────────────────────────────────────────────────────────
[ $# -ge 1 ] || die 2 "usage: bash .claude/projection.sh project|bank|grade [--tracker P] [--log P] [--sidecar P] [--calibration P] [--root P] [--at BOUNDARY]"
SUB="$1"; shift
case "$SUB" in project|bank|grade) ;; *) die 2 "unknown subcommand '$SUB' (only: project, bank, grade)" ;; esac

ROOT="."
TRACKER=""; LOG=""; SIDECAR=""; CALIB=""; AT=""
while [ $# -gt 0 ]; do
  # Every flag here takes a value. A value-less TRAILING flag must fail loud, not
  # spin: a bare `shift 2` on a single remaining positional leaves it in place, so
  # the loop never advances — an infinite hang, the worst Rule-15 failure (a silent
  # non-stop is neither a designed degradation nor a loud stop). Guard once, here.
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

# ── the lineage boundary the observed samples are windowed to ───────────────────
# Derived exactly as budget-gate.sh derives it — same record, same `last`-in-FILE-
# ORDER convention (append order is lineage order): the most recent grade, else the
# opening plan forecast. The two readers must agree, because the cost-to-complete
# computed here is ADDED to the burn budget-gate.sh sums over this window and
# compared against this initiative's setpoint; a rate built from a DIFFERENT window
# than the burn makes that comparison meaningless. Empty = nothing banked yet (the
# opening forecast's own case) → no window, disclosed as such in basis.sample_window.
INITIATIVE_SINCE=""
if [ -f "$CALIB" ]; then
  INITIATIVE_SINCE=$(jq -rRn '
    [ inputs | fromjson? | select(type == "object")
      | select(((.kind // "") == "grade")
            or (((.kind // "") == "forecast") and ((.boundary // "") == "plan"))) ]
    | last | .banked_at // empty' "$CALIB" 2>/dev/null)
  # exact ISO-8601 UTC shape or it is no boundary. The glob's job is INJECTION
  # SAFETY — shape-vetting the string before it is interpolated as a jq --arg —
  # not semantic time validation: this file stamps boundaries with `date -u`, so a
  # digit-shaped non-time cannot arrive from the real writer.
  case "$INITIATIVE_SINCE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) INITIATIVE_SINCE="" ;;
  esac
fi

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

# ── the occupancy REFERENCE: the occupancy threshold (setpoint, else default) ───
# [12.1] informational only — the [9.2] linkage stays visible, but it is never the
# cost ceiling. (Function name kept for the call site; the value is occ_ref.)
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
# The observed burn is the per-session token burn over this control plane's metering
# log — a BOUNDED transcript SLICE ([13.6]), NOT the cumulative whole-transcript sum.
# Burn per sample = the four token classes summed (the same definition
# budget-gate.sh uses) — session THROUGHPUT (cache_read-dominated, unbounded by the
# window). [13.6] made the log slice-aware, so this reads each entry as the right
# unit (forensics: averaging cumulative snapshots produced the inflated ~503M
# anchor; the real per-session burns are ~70–350M):
#   • slice-tagged (slice_basis per_deliverable / since_process_start) — tokens IS
#     the bounded slice; counted directly as a sample.
#   • unbounded_cumulative (disclosed degradation) and tokens:null — NOT samples.
#   • legacy (pre-[13.6], no slice_basis key) — the cumulative snapshots; MIGRATED
#     to per-session deltas at READ TIME (difference consecutive same-runtime_session
#     cumulatives — the log stays append-only; nothing is rewritten).
# Emits "n<TAB>mean<TAB>min<TAB>max" (all 0 when n=0) — the mean drives the central
# blended rate, the min/max the band EDGES. NEVER reads anything but this local log.
# TWO FILTERS run BEFORE any arithmetic, because an average over this log means
# nothing until both hold:
#
#   VINTAGE — only entries harvested in the CURRENT unit (harvest_basis
#   "per_response", written after the [9.1] dedupe fix). An ABSENT key is pre-fix
#   BY CONSTRUCTION and over-counts: the pre-fix meter summed usage once per
#   transcript LINE, and one API response is serialized as N lines each repeating
#   the identical usage object. The overstatement is ~2.5x in aggregate but
#   SHAPE-DEPENDENT (subagent output 1.04x, main-loop output 3.20x), which is
#   exactly why no divisor can rescue a pre-fix sample. An EXPLICIT null is a
#   degraded harvest whose unit the writer could not determine; unknown degrades to
#   "not a sample", never to an assumed one (Rule 15). Averaging ACROSS the vintage
#   boundary produces a rate in NO unit — the error emit-metrics.shape.md discloses
#   one layer up and budget-gate.sh's mixed-vintage banner discloses one layer down.
#
#   LINEAGE WINDOW — only entries since the live initiative's boundary, the SAME
#   window budget-gate.sh sums burn over. Reading every initiative's history built
#   a 004 forecast out of 002 and 003 sessions. No boundary banked yet (the opening
#   forecast's own case) → no window: the prior initiatives' post-fix sessions are
#   the only signal available and they ARE unit-correct, so they are used and the
#   absence is DISCLOSED (basis.sample_window null), never silently implied.
#
# LEGACY entries (pre-[13.6] cumulative snapshots, no slice_basis key) are pre-fix
# by construction — [13.6] predates the dedupe fix — so the vintage filter excludes
# them and the [13.6] read-time differencing that used to migrate them here is GONE
# from this reader. budget-gate.sh still differences them and must: BURN
# legitimately sums every entry in the window in whatever unit it was recorded and
# then discloses the mix. A RATE cannot do that — an average across two units is
# not a number. This supersedes [13.6]'s migration in the rate reader only.
#
# n=0 is the DESIGNED result on a record with no post-fix sessions yet, not a
# failure: the blend weight goes to 0 and the projection rides the structural
# occupancy×turns band (basis.claim "structural"). The document discloses the
# window and the vintage so an n=0 is LEGIBLE rather than mysterious.
observed_rate() {
  if [ ! -f "$LOG" ]; then printf '0\t0\t0\t0'; return; fi
  jq -rs --arg since "$INITIATIVE_SINCE" '
    def burn: (.input // 0) + (.output // 0) + (.cache_read // 0) + (.cache_creation // 0);
    [ .[] | select((.schema // "") | startswith("guv.meter"))
          | select((.harvest_basis // "") == "per_response")
          | select($since == "" or ((.ts // "") >= $since)) ] as $all
    # slice-tagged entries: tokens is the bounded slice, a sample as-is
    | [ $all[] | select(.tokens != null)
              | select((.slice_basis // "") as $sb | $sb == "per_deliverable" or $sb == "since_process_start")
              | (.tokens | burn) ] as $b
    | ($b | length) as $n
    | if $n == 0 then "0\t0\t0\t0"
      else "\($n)\t\(($b | add) / $n | floor)\t\($b | min)\t\($b | max)" end
  ' "$LOG" 2>/dev/null || printf '0\t0\t0\t0'
}

# ── compute the projection document (shared by project / bank) ──────────────────
# Pure read over the local artifacts; emits one guv.projection.v1 JSON document.
compute_projection() {
  # [13.3] the cost-to-complete is denominated in cumulative session THROUGHPUT, not
  # point-in-time occupancy. The structural unit rate is the MODELED occupancy_budget ×
  # expected_turns (see the constants block): occupancy (the stock) returns as a FACTOR,
  # reconstructing the cumulative flow, never as the cost itself. The measured doc-overhead
  # floor and the raw occupancy threshold are carried only as informational references.
  local floor occ_ref
  floor=$(envelope_floor)
  occ_ref=$(envelope_ceiling)

  # [13.3] occupancy_budget = the [9.2] setpoint's modeled working set (a fraction of
  # it — the avg working set, not the full ceiling), clamped UP to the measured floor as
  # a true lower bound (Rule 15: a tiny/absent setpoint degrades to the floor, never to 0).
  local occ_budget turns_low turns_central turns_high struct_low struct_central struct_high
  occ_budget=$(( occ_ref * WORKING_SET_FRACTION_NUM / WORKING_SET_FRACTION_DEN ))
  [ "$occ_budget" -lt "$floor" ] && occ_budget="$floor"
  # expected_turns = base_build + the eval/fix term; its distribution sets the band
  # (low = clean run = base_build alone, high = base_build + the fix-heavy loop).
  turns_low=$BASE_BUILD_TURNS
  turns_central=$((BASE_BUILD_TURNS + EVAL_FIX_TURNS_TYPICAL))
  turns_high=$((BASE_BUILD_TURNS + EVAL_FIX_TURNS_HEAVY))
  # the structural band: occupancy_budget × expected_turns, per edge (low ≤ central ≤ high).
  struct_low=$(( occ_budget * turns_low ))
  struct_central=$(( occ_budget * turns_central ))
  struct_high=$(( occ_budget * turns_high ))

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

  # [13.3] each band edge anchors on its STRUCTURAL occupancy×turns edge (struct_low/
  # central/high) and migrates toward the matching observed edge (min/mean/max) by the
  # SAME weight w = n/(n+K): blended = (1-w)*structural_edge + w*observed_edge. Integer
  # arithmetic via the weight num/den to stay pure-bash + deterministic.
  #   n=0 (no history): each edge IS its structural anchor — the projection is the
  #        modeled occupancy×turns band, a REAL central estimate (struct_central), and
  #        the basis discloses bound="modeled_range" (superseding [12.1]'s
  #        lower_bound_only: the structural prior is a sensible central estimate, not a
  #        bare floor). The eval/fix term's spread (struct_low < struct_high) is the band.
  #   n>0: the blend CORRECTS the modeled prior toward observed throughput; basis bound
  #        ="observed_range". With struct_low<=struct_central<=struct_high and
  #        omin<=mean<=omax, the per-edge blend stays ordered (band never inverts) and
  #        the centre always lies inside.
  weight_num=$n
  weight_den=$((n + BLEND_K))
  local basis_claim basis_bound blended_rate blended_low_rate blended_high_rate observed_weight_str
  if [ "$n" -eq 0 ]; then
    basis_claim="structural"
    basis_bound="modeled_range"
    blended_rate="$struct_central"
    blended_low_rate="$struct_low"
    blended_high_rate="$struct_high"
    observed_weight_str="0"
  else
    basis_claim="blended"
    basis_bound="observed_range"
    # (structural_edge*(den-num) + observed_edge*num) / den — centre toward mean,
    # edges toward min/max, each from its own structural anchor.
    blended_rate=$(( (struct_central * (weight_den - weight_num) + mean * weight_num) / weight_den ))
    blended_low_rate=$(( (struct_low * (weight_den - weight_num) + omin * weight_num) / weight_den ))
    blended_high_rate=$(( (struct_high * (weight_den - weight_num) + omax * weight_num) / weight_den ))
    # observed weight as a decimal string for the document (num/den)
    observed_weight_str=$(awk -v a="$weight_num" -v b="$weight_den" 'BEGIN{ printf "%.4f", a/b }')
  fi

  # the range: quantity × the (possibly blended) throughput band. low = remaining ×
  # the low edge, high = remaining × the high edge. At n=0 the edges are the modeled
  # structural band (struct_low/high — a real band, not a point); once landings accrue
  # the edges migrate toward observed throughput, so the reported range and the central
  # blended rate stay in the same unit (throughput) and the same universe.
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
    --argjson occ_ref "$occ_ref" \
    --argjson occ_budget "$occ_budget" \
    --argjson turns_base "$BASE_BUILD_TURNS" \
    --argjson turns_low "$turns_low" \
    --argjson turns_central "$turns_central" \
    --argjson turns_high "$turns_high" \
    --argjson struct_low "$struct_low" \
    --argjson struct_central "$struct_central" \
    --argjson struct_high "$struct_high" \
    --argjson blended "$blended_rate" \
    --argjson blended_low "$blended_low_rate" \
    --argjson blended_high "$blended_high_rate" \
    --argjson low "$low" \
    --argjson high "$high" \
    --arg basis "$basis_claim" \
    --arg bound "$basis_bound" \
    --argjson n "$n" \
    --arg ow "$observed_weight_str" \
    --argjson observed_mean "$mean" \
    --arg sample_window "$INITIATIVE_SINCE" \
    --argjson default_ids "$default_json" '
    {
      schema: $schema,
      generated: $generated,
      range: { low_tokens: $low, high_tokens: $high, denomination: "tokens" },
      basis: {
        claim: $basis,
        bound: $bound,
        n: $n,
        observed_weight: ($ow | tonumber),
        observed_mean_tokens_per_session: $observed_mean,
        # WHERE the n samples came from. Without these two, an n=0 is unreadable —
        # "no sessions yet" and "sessions exist but none in this unit or window"
        # are different claims and lead to different decisions.
        sample_window: (if $sample_window == "" then null else $sample_window end),
        sample_vintage: "per_response"
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
          occupancy_reference_tokens: $occ_ref,
          occupancy_budget_tokens: $occ_budget,
          expected_turns: { base_build: $turns_base, low: $turns_low, central: $turns_central, high: $turns_high },
          structural_low_tokens: $struct_low,
          structural_tokens: $struct_central,
          structural_high_tokens: $struct_high,
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
    # [13.4] idempotent at a named boundary: re-banking the SAME --at boundary is
    # a no-op (the lineage carries ONE forecast per boundary; re-invoking /plan or
    # re-running a phase-completion handoff must not double-bank). Append-only is
    # preserved — a prior boundary's line is never rewritten. A bank with no --at
    # (the manual escape hatch) is unconditionally appended, exactly as before.
    #
    # The dedup window is THIS initiative: a `grade` line marks an initiative close,
    # so forecasts before the most recent grade belong to a CLOSED initiative and do
    # not collide with a new one's identically-named boundary (a fresh initiative's
    # `--at plan` must re-bank, not silently no-op against the predecessor's `plan`
    # forecast in the accumulating ledger).
    if [ -n "$AT" ] && [ -f "$CALIB" ] \
       && jq -e --arg b "$AT" -s '
            (map(.kind) | rindex("grade")) as $g
            | (if $g == null then . else .[($g + 1):] end)
            | any(.[]; (.kind // "") == "forecast" and (.boundary // "") == $b)
          ' "$CALIB" >/dev/null 2>&1; then
      echo "[projection] forecast for boundary '$AT' already banked this initiative -> $CALIB (idempotent no-op)"
      exit 0
    fi
    PROJ=$(compute_projection) || die 4 "failed to compute the projection to bank"
    # tag the forecast with the boundary it was banked at (the lineage key) when
    # one was named; a manual bank stays untagged, identical to the legacy shape.
    LINE=$(printf '%s' "$PROJ" | jq -c \
      --arg kind "forecast" \
      --arg banked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg boundary "$AT" \
      '{kind:$kind, banked_at:$banked_at}
       + (if $boundary == "" then {} else {boundary:$boundary} end)
       + {schema:.schema, generated:.generated,
          range:.range, basis:.basis, scope:.scope, spine:.spine}') \
      || die 4 "failed to assemble the banked forecast (jq error)"
    bank_line "$LINE"
    echo "[projection] banked forecast${AT:+ (boundary: $AT)} -> $CALIB"
    ;;

  grade)
    # Close-time grading: compare the latest banked FORECAST against the OUTCOME
    # in the local metering log, and split the miss into its two layers.
    [ -f "$CALIB" ] || die 4 "no calibration record at $CALIB — nothing banked to grade (bank a forecast first)"
    # [13.4] read the forecast lineage and grade the OPENING (plan-boundary)
    # forecast — its scope was the whole remaining initiative, which is what a
    # close-time grade honestly grades ("how good was the plan?"), not the last
    # phase-boundary snapshot (closest to actual, least informative). Degrade to
    # the most recent forecast when no plan-boundary forecast was banked (a legacy
    # record, or manual banks with no --at) — a designed fallback, not a guess
    # (Rule 15).
    FORECAST=$(jq -cs '
      [ .[] | select(.kind=="forecast") ] as $f
      | ( [ $f[] | select(.boundary=="plan") ] | last )   # the opening forecast, if banked
        // ( $f | last )                                    # else the most recent (degradation)
        // empty' "$CALIB" 2>/dev/null)
    [ -n "$FORECAST" ] || die 4 "no banked forecast in $CALIB to grade against"
    # name the lineage entry this grade read, so "the grade reads the lineage" is
    # visible in the grade itself ("unlabeled" for a legacy/manual forecast banked
    # without a boundary tag).
    GRADED_BOUNDARY=$(printf '%s' "$FORECAST" | jq -r '.boundary // "unlabeled"')
    GRADED_AT=$(printf '%s' "$FORECAST" | jq -r '.banked_at // .generated // empty')

    # quantity layer: estimated sessions (the forecast's takeoff) vs ACTUAL
    # sessions. The takeoff was REMAINING work AT BANK TIME, so the comparison is
    # like-for-like only if actual_sessions is bounded to sessions occurring AFTER
    # the forecast was banked — sessions logged BEFORE the bank were spent on
    # already-done work and were never in the forecast's scope. We bound on the
    # banked forecast's own timestamp (banked_at, falling back to generated).
    EST_SESSIONS=$(printf '%s' "$FORECAST" | jq -r '.spine.quantity.remaining_sessions')
    # [12.1] rate layer: grade the BLENDED central rate the forecast actually
    # committed (the cost it predicted), against actual post-bank throughput — both
    # in the same throughput unit. NOT the raw floor (occupancy-scale pre-[12.1],
    # which made rate_error incoherent — the same stock-vs-flow mismatch the range
    # had). Fallback to floor_tokens for a legacy forecast banked before
    # blended_tokens existed (designed degradation, Rule 15).
    ENVELOPE=$(printf '%s' "$FORECAST" | jq -r '.spine.unit_rate.blended_tokens // .spine.unit_rate.floor_tokens')
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
      # post-bank entries are [13.6] bounded slices; tokens IS the per-session burn.
      # Exclude the disclosed unbounded_cumulative degradation — it is not a real
      # per-session rate (same unit honesty as observed_rate).
      ACTUAL_RATE=$(jq -rs --arg since "$BANK_TS" '
        [ .[] | select((.schema // "") | startswith("guv.meter"))
              | select($since == "" or (.ts // "") >= $since)
              | select((.slice_basis // "") != "unbounded_cumulative")
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
      --argjson actual_rate "$ACTUAL_RATE" \
      --arg graded_boundary "$GRADED_BOUNDARY" \
      --arg graded_at "$GRADED_AT" '
      {
        schema: $schema,
        generated: $generated,
        # which lineage entry this grade read — the boundary it was banked at and
        # when ([13.4]: the close-time grade reads the forecast lineage).
        graded_forecast: { boundary: $graded_boundary, banked_at: $graded_at },
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
