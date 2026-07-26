#!/bin/bash
# Tests for .claude/projection.sh — the cost-to-complete projection ([9.7] of the
# plan-as-data spec; the structural spine, local blend, graded always).
#
# These tests verify INTENT, not "runs without crashing" (Rule 8). The
# heart-of-the-deliverable invariants this suite defends:
#
#   1. STRUCTURAL SPINE, n=0: with no landings yet the projection is computed
#      ANYWAY (no refusal state) — a floor-anchored lower-bound band × a basis
#      claim (structural, bound=lower_bound_only) × a scope claim (cost to
#      COMPLETE, not total). The spine is quantity (ratified sessions over remaining
#      work, from the resolver + the estimate sidecar) × unit rate (the measured
#      THROUGHPUT floor; occupancy is informational, never the cost unit — [12.1]).
#   2. LOCAL BLEND: as landings accrue in THIS control plane's metering log, the
#      projection shifts toward the observed rate; the blend WEIGHT moves as
#      samples accrue (more samples -> more weight on observed). History is a
#      weighted INPUT, never the foundation.
#   3. NO FOREIGN HISTORY (grep-assert): the only inputs are THIS control plane's
#      metering log, the estimate sidecar, the calibration record, and the
#      resolver. No path reaches anyone else's history.
#   4. DEFAULT DISCLOSURE: a deliverable lacking a ratified estimate projects at
#      the default AND the projection discloses it.
#   5. BANKED forecasts: every projection can be banked (append-only) to the
#      calibration record.
#   6. CLOSE-TIME GRADING names the layer: two SEPARABLE errors — quantity error
#      (sessions estimated vs actual) and rate error (envelope vs actual
#      tokens/session) — so a miss names whether the takeoff or the rate was off.
#   7. DEPS-AMEND FOLLOWS BY RECOMPUTATION: change remaining work (the tracker)
#      and the next projection reflects it — no special handling.
#
# Pure bash + jq, no test runner. Stderr-clean for well-formed input (the battery
# fails any suite that writes to stderr). Run: bash .claude/tests/projection.test.sh
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"          # .claude/
SCRIPT="$CLAUDE_DIR/projection.sh"
SHAPE="$CLAUDE_DIR/projection.shape.md"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# ── A self-contained guv instance root: a manifest, a tracker, an (optional)
# estimate sidecar, an (optional) metering log, and a copy of the spine scripts
# the projection consults (the resolver). The projection reads ONLY artifacts
# under this root — that confinement is itself a tested invariant (T_FOREIGN).
#   mk_instance  ->  echoes the instance dir
mk_instance() {
  local d; d=$(mktemp -d "$WORK/inst.XXXXXX")
  mkdir -p "$d/.claude/metering" "$d/docs/sessions"
  jq -nc '{name:"x",language:"shell",roots:{control:".",code:"."},commands:{},scaffoldCheck:"true",ceremony:"phased"}' \
    > "$d/.claude/project.json"
  # the resolver is the one parser of plan state — the projection consults it for
  # the remaining-work count, never re-parsing the tracker. Carry it (and the
  # projection script itself) into the instance so the run is hermetic.
  cp "$CLAUDE_DIR/resolve-ready.sh" "$d/.claude/resolve-ready.sh"
  cp "$CLAUDE_DIR/estimate.sh"      "$d/.claude/estimate.sh"
  cp "$SCRIPT"                      "$d/.claude/projection.sh"
  # Populate the control-plane docs a session loads so the envelope FLOOR is
  # MEASURED from real bytes (the deterministic chars/4 tokenization), not the
  # FLOOR_MIN degradation: a realistic floor (tens of thousands of tokens) is
  # what the blend's low landings sit BELOW. ~40k chars -> ~10k token floor.
  mkdir -p "$d/.claude/rules"
  head -c 24000 /dev/zero | tr '\0' 'x' > "$d/CLAUDE.md"
  head -c 16000 /dev/zero | tr '\0' 'y' > "$d/.claude/rules/guv-core.md"
  echo "$d"
}

# A DAG tracker with three remaining deliverables and one done, in this instance.
# [9.7] is in_progress, [9.8] ready, [9.9] blocked on [9.8]; [9.1] done.
write_tracker() {  # <instance-dir>
  cat > "$1/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 9 — The Meter**
> Last updated: 2026-06-14, session-2026-06-14-001

---

## Phase 9 — The Meter

_Goal: meter cost at every boundary._

- ✅ **[9.1]** Session-boundary cost capture `[deps: none]` (2026-06-14, session-x)
- 🔄 **[9.7]** Projection `[deps: 9.1]`
- ⬜ **[9.8]** A ready deliverable `[deps: 9.1]`
- ⬜ **[9.9]** A blocked deliverable `[deps: 9.8]`
MD
}

# Append one guv.meter.v1 session entry to the instance's metering log with the
# given per-session total token burn (split across the four classes) attributed
# to the given deliverable id. This is the "landing" the blend learns from.
add_landing() {  # <instance-dir> <deliverable-id> <total-tokens>
  local d="$1" id="$2" tot="$3"
  local log="$d/.claude/metering/metering.ndjson"
  jq -cn --arg id "$id" --argjson t "$tot" \
    '{schema:"guv.meter.v1", ts:"2026-06-14T00:00:00Z", session:"session-2026-06-14-001",
      session_derived:true, runtime_session:null, deliverable_ids:[$id],
      model:"claude-opus-4-8[1m]",
      tokens:{input:($t/2|floor), output:($t/4|floor), cache_read:($t - ($t/2|floor) - ($t/4|floor)), cache_creation:0},
      transcript_tokens:null, slice_basis:"per_deliverable", compaction_cycles:0,
      harvest_basis:"per_response",
      dollars:null, spike_c_rung:"B", perf:{op_wallclock_s:0.1, suite_runtime_s:null}}' \
    >> "$log"
}

# A PRE-FIX landing: identical to add_landing except it carries NO harvest_basis
# key — the shape every entry harvested before the [9.1] dedupe fix has. Its
# tokens are in the inflated unit (usage counted once per transcript LINE, so a
# multi-block response was multiplied by its block count). The rate must NOT
# sample it: an average across the vintage boundary is a number in no unit.
add_landing_prefix() {  # <instance-dir> <deliverable-id> <total-tokens>
  local d="$1" id="$2" tot="$3"
  local log="$d/.claude/metering/metering.ndjson"
  jq -cn --arg id "$id" --argjson t "$tot" \
    '{schema:"guv.meter.v1", ts:"2026-06-14T00:00:00Z", session:"session-2026-06-14-001",
      session_derived:true, runtime_session:null, deliverable_ids:[$id],
      model:"claude-opus-4-8[1m]",
      tokens:{input:($t/2|floor), output:($t/4|floor), cache_read:($t - ($t/2|floor) - ($t/4|floor)), cache_creation:0},
      transcript_tokens:null, slice_basis:"per_deliverable", compaction_cycles:0,
      dollars:null, spike_c_rung:"B", perf:{op_wallclock_s:0.1, suite_runtime_s:null}}' \
    >> "$log"
}

# Like add_landing, but with an explicit session id and timestamp — so a test can
# place a session BEFORE or AFTER a banked forecast's timestamp. The grade's
# actual-sessions denominator must be bounded to sessions occurring AFTER the
# banked forecast (the forecast was only ever scoped to remaining work from bank
# time forward), so before/after timestamping is the discriminator.
add_landing_at() {  # <instance-dir> <deliverable-id> <total-tokens> <session-id> <ts>
  local d="$1" id="$2" tot="$3" sess="$4" ts="$5"
  local log="$d/.claude/metering/metering.ndjson"
  jq -cn --arg id "$id" --argjson t "$tot" --arg sess "$sess" --arg ts "$ts" \
    '{schema:"guv.meter.v1", ts:$ts, session:$sess,
      session_derived:true, runtime_session:null, deliverable_ids:[$id],
      model:"claude-opus-4-8[1m]",
      tokens:{input:($t/2|floor), output:($t/4|floor), cache_read:($t - ($t/2|floor) - ($t/4|floor)), cache_creation:0},
      transcript_tokens:null, slice_basis:"per_deliverable", compaction_cycles:0,
      harvest_basis:"per_response",
      dollars:null, spike_c_rung:"B", perf:{op_wallclock_s:0.1, suite_runtime_s:null}}' \
    >> "$log"
}

# Append a LEGACY cumulative entry — the pre-[13.6] shape: NO slice_basis field, a
# runtime_session, and tokens that are the WHOLE-transcript cumulative sum to that
# instant (so consecutive same-runtime_session entries strictly increase). This is
# the exact shape the forensic bug produced (docs/notes/meter-forensics.md A2). The
# slice-aware observed_rate() must MIGRATE these to per-session deltas at read time
# (difference consecutive same-runtime_session cumulatives), never average the
# running totals.
add_legacy_cumulative() {  # <instance-dir> <runtime_session> <cumulative-total>
  local d="$1" rs="$2" cum="$3"
  local log="$d/.claude/metering/metering.ndjson"
  jq -cn --arg rs "$rs" --argjson t "$cum" \
    '{schema:"guv.meter.v1", ts:"2026-06-14T00:00:00Z", session:"session-2026-06-14-001",
      session_derived:true, runtime_session:$rs, deliverable_ids:["8.3"],
      model:"claude-opus-4-8[1m]",
      tokens:{input:0, output:0, cache_read:$t, cache_creation:0},
      dollars:null, spike_c_rung:"B", perf:{op_wallclock_s:0.1, suite_runtime_s:null}}' \
    >> "$log"
}

# ════════════════════════════════════════════════════════════════════════════
# T0 — the script and its shape doc exist (RED until built)
# ════════════════════════════════════════════════════════════════════════════
[ -f "$SCRIPT" ] && ok "projection script exists at .claude/projection.sh" \
  || no "projection script missing at .claude/projection.sh"

# ════════════════════════════════════════════════════════════════════════════
# T1 — STRUCTURAL SPINE at n=0: computed anyway, no refusal state
# ════════════════════════════════════════════════════════════════════════════
# An instance with estimates ratified but NO landings yet. The projection must
# still produce a range, a basis claim of "structural", and a scope claim. This
# is the heart: n=0 is not a refusal — the spine stands on the user's own plan.
I=$(mk_instance); write_tracker "$I"
bash "$I/.claude/estimate.sh" set 9.7 2 "$I/docs/estimates.json" >/dev/null 2>&1
bash "$I/.claude/estimate.sh" set 9.8 3 "$I/docs/estimates.json" >/dev/null 2>&1
# 9.9 left unratified -> default (1), disclosed below in T4.
DOC=$( cd "$I" && bash .claude/projection.sh project 2>/dev/null )
RC_OK=$( cd "$I" && bash .claude/projection.sh project >/dev/null 2>&1; echo $? )

[ "$RC_OK" = "0" ] && [ -n "$DOC" ] && echo "$DOC" | jq -e . >/dev/null 2>&1 \
  && ok "n=0: projection is COMPUTED (valid JSON, exit 0) — no refusal state" \
  || no "n=0 must still produce a valid projection document (rc=$RC_OK doc=$DOC)"

echo "$DOC" | jq -e '.basis.claim == "structural"' >/dev/null 2>&1 \
  && ok "n=0: the basis claim is \"structural\" (the spine, no landings)" \
  || no "n=0 basis claim must be \"structural\" (got: $(echo "$DOC" | jq -c '.basis'))"

echo "$DOC" | jq -e '.basis.n == 0' >/dev/null 2>&1 \
  && ok "n=0: the basis records n=0 (zero landings consulted)" \
  || no "n=0 basis.n must be 0 (got: $(echo "$DOC" | jq -c '.basis.n'))"

# A token band (low <= high, both positive). At n=0 [12.1] this is a lower-bound
# POINT (low == high == remaining×floor) — asserted precisely just below.
echo "$DOC" | jq -e '.range.low_tokens <= .range.high_tokens and .range.low_tokens > 0' >/dev/null 2>&1 \
  && ok "n=0: the output is a token band (low <= high, both positive)" \
  || no "the projection must carry a token range with low <= high (got: $(echo "$DOC" | jq -c '.range'))"

# SCOPE claim: cost to COMPLETE (remaining), not total — stated on the document.
echo "$DOC" | jq -e '.scope.claim' >/dev/null 2>&1 \
  && echo "$DOC" | jq -re '.scope.claim' | grep -qiE 'complete|remaining' \
  && ok "scope claim says cost to COMPLETE/remaining, not total" \
  || no "the scope claim must state cost-to-complete (got: $(echo "$DOC" | jq -c '.scope'))"

# The spine multiplies a quantity (remaining sessions) by a unit rate (envelope).
# Quantity = sum of ratified estimates over remaining work: 9.7(2)+9.8(3)+9.9(1)=6.
echo "$DOC" | jq -e '.spine.quantity.remaining_sessions == 6' >/dev/null 2>&1 \
  && ok "spine quantity = ratified sessions over REMAINING work (2+3+1=6)" \
  || no "remaining_sessions must sum the estimates of remaining deliverables (got: $(echo "$DOC" | jq -c '.spine.quantity'))"

# [13.3] throughput-native, MODELED: the structural unit rate is occupancy_budget ×
# expected_turns — the [9.2] setpoint's working set re-read over a session's inferences
# (the cumulative-FLOW reconstruction of the point-in-time occupancy STOCK). The measured
# doc-overhead floor and the raw occupancy threshold are carried only as INFORMATIONAL
# references, never as the cost rate (the floor was the pre-[13.3] structural rate — an
# orders-of-magnitude undershoot of real throughput).
echo "$DOC" | jq -e '.spine.unit_rate.floor_tokens > 0 and (.spine.unit_rate.occupancy_reference_tokens|type=="number")' >/dev/null 2>&1 \
  && ok "unit rate carries the measured floor + occupancy reference as INFORMATIONAL fields" \
  || no "the unit rate must carry a positive floor + an informational occupancy reference (got: $(echo "$DOC" | jq -c '.spine.unit_rate'))"

# [13.3] occupancy_budget = the [9.2] setpoint × the working-set fraction (the avg
# working set is ~0.4× the setpoint — meter-forensics B4 — not the full setpoint).
echo "$DOC" | jq -e '
  (.spine.unit_rate.occupancy_budget_tokens|type=="number")
  and .spine.unit_rate.occupancy_budget_tokens > 0
  and .spine.unit_rate.occupancy_budget_tokens < .spine.unit_rate.occupancy_reference_tokens' >/dev/null 2>&1 \
  && ok "[13.3] occupancy_budget is the modeled working set (a fraction of the setpoint, below it)" \
  || no "[13.3] occupancy_budget_tokens must be a positive fraction of the occupancy reference (got: $(echo "$DOC" | jq -c '.spine.unit_rate'))"

# [13.3] the structural rate DECOMPOSES as occupancy_budget × expected_turns (a
# documented formula), per band edge. The eval/fix term sets the band: the low edge is
# base_build alone (a clean run), the high edge adds the fix-heavy eval/fix turns.
echo "$DOC" | jq -e '
  (.spine.unit_rate.occupancy_budget_tokens) as $ob
  | (.spine.unit_rate.expected_turns) as $t
  | $t.low == $t.base_build
  and $t.low < $t.central and $t.central < $t.high
  and .spine.unit_rate.structural_low_tokens  == ($ob * $t.low)
  and .spine.unit_rate.structural_tokens      == ($ob * $t.central)
  and .spine.unit_rate.structural_high_tokens == ($ob * $t.high)' >/dev/null 2>&1 \
  && ok "[13.3] structural rate = occupancy_budget × expected_turns per edge; eval/fix term sets the band (low=base_build clean run < central < high fix-heavy)" \
  || no "[13.3] the structural rate must decompose as occupancy_budget × expected_turns with an eval/fix band (got: $(echo "$DOC" | jq -c '.spine.unit_rate'))"

# [13.3] n=0: with NO throughput history the projection is a REAL central estimate — the
# modeled occupancy×turns band, NOT a floor-anchored lower-bound point. The range is
# remaining × the structural band (low < high, a genuine band), and the basis bound names
# the modeled range (no lower_bound_only collapse — superseding [12.1]).
echo "$DOC" | jq -e '
  (.spine.quantity.remaining_sessions) as $q
  | .range.low_tokens  == ($q * .spine.unit_rate.structural_low_tokens)
  and .range.high_tokens == ($q * .spine.unit_rate.structural_high_tokens)
  and .range.low_tokens < .range.high_tokens' >/dev/null 2>&1 \
  && ok "[13.3] n=0: the range is the MODELED band (remaining × structural_{low,high}), a real band (low < high)" \
  || no "[13.3] n=0 range must be remaining × the structural band, low < high (got range=$(echo "$DOC" | jq -c '.range'), unit_rate=$(echo "$DOC" | jq -c '.spine.unit_rate'))"
echo "$DOC" | jq -e '.basis.bound == "modeled_range"' >/dev/null 2>&1 \
  && ok "[13.3] n=0: the basis bound is \"modeled_range\" — a real central estimate, no lower-bound-only collapse" \
  || no "[13.3] n=0 basis.bound must be \"modeled_range\" (got: $(echo "$DOC" | jq -c '.basis'))"
# the central blended rate at n=0 IS the structural central (a real point estimate, not
# the floor) and lies inside the modeled band.
echo "$DOC" | jq -e '
  .spine.unit_rate.blended_tokens == .spine.unit_rate.structural_tokens
  and .spine.unit_rate.structural_low_tokens <= .spine.unit_rate.structural_tokens
  and .spine.unit_rate.structural_tokens <= .spine.unit_rate.structural_high_tokens' >/dev/null 2>&1 \
  && ok "[13.3] n=0: the central rate is the structural central estimate, inside the modeled band" \
  || no "[13.3] n=0 central rate must equal structural_tokens within the band (got: $(echo "$DOC" | jq -c '.spine.unit_rate'))"

# Denomination follows Spike C's rung (tokens) — never a guessed dollar conversion.
echo "$DOC" | jq -e '.range.denomination == "tokens"' >/dev/null 2>&1 \
  && ok "denomination is tokens (Spike C's rung) — no guessed dollar conversion" \
  || no "denomination must follow Spike C's rung = tokens (got: $(echo "$DOC" | jq -c '.range.denomination'))"

# ════════════════════════════════════════════════════════════════════════════
# T2 — LOCAL BLEND: landings shift the projection toward the observed rate
# ════════════════════════════════════════════════════════════════════════════
# Seed the SAME instance's metering log with landings whose observed per-session
# burn is FAR below the structural envelope floor. The blended unit rate must
# move toward that observed rate, and the basis must flip to "blended" with n>0.
B=$(mk_instance); write_tracker "$B"
bash "$B/.claude/estimate.sh" set 9.7 2 "$B/docs/estimates.json" >/dev/null 2>&1
bash "$B/.claude/estimate.sh" set 9.8 3 "$B/docs/estimates.json" >/dev/null 2>&1
STRUCT=$( cd "$B" && bash .claude/projection.sh project 2>/dev/null )
# [13.3] the structural prior is now the occupancy×turns central rate (the n=0
# blended_tokens), not the doc-overhead floor.
STRUCT_RATE=$(echo "$STRUCT" | jq -r '.spine.unit_rate.structural_tokens')

# three landings at a LOW observed burn (well under the structural occupancy×turns prior)
add_landing "$B" 9.1 5000
add_landing "$B" 9.1 6000
add_landing "$B" 9.1 5500
BLEND=$( cd "$B" && bash .claude/projection.sh project 2>/dev/null )

echo "$BLEND" | jq -e '.basis.claim == "blended"' >/dev/null 2>&1 \
  && ok "with landings the basis claim flips to \"blended\"" \
  || no "basis must be \"blended\" once landings accrue (got: $(echo "$BLEND" | jq -c '.basis'))"

echo "$BLEND" | jq -e '.basis.n == 3' >/dev/null 2>&1 \
  && ok "basis.n counts the landings consulted (3)" \
  || no "basis.n must equal the landing count (got: $(echo "$BLEND" | jq -c '.basis.n'))"

# The blended effective rate sits BELOW the structural prior (it moved toward the
# low observed rate) but ABOVE the raw observed rate (the structure still pulls).
BLEND_RATE=$(echo "$BLEND" | jq -r '.spine.unit_rate.blended_tokens')
awk -v b="$BLEND_RATE" -v s="$STRUCT_RATE" 'BEGIN{ exit !(b < s) }' \
  && ok "blended rate moved BELOW the structural occupancy×turns prior toward the low observed rate" \
  || no "the blended rate must shift toward the observed rate (blended=$BLEND_RATE structural=$STRUCT_RATE)"

# WEIGHT MOVES with samples: more landings -> MORE weight on the observed rate,
# so the blended rate moves FURTHER toward observed. Add three more low landings
# and assert the blended rate dropped further (the weight grew).
W3=$(echo "$BLEND" | jq -r '.basis.observed_weight')
add_landing "$B" 9.1 5000
add_landing "$B" 9.1 6000
add_landing "$B" 9.1 5500
BLEND6=$( cd "$B" && bash .claude/projection.sh project 2>/dev/null )
W6=$(echo "$BLEND6" | jq -r '.basis.observed_weight')
BLEND6_RATE=$(echo "$BLEND6" | jq -r '.spine.unit_rate.blended_tokens')
awk -v a="$W6" -v b="$W3" 'BEGIN{ exit !(a > b) }' \
  && ok "the observed-rate WEIGHT grows as samples accrue (n=6 weight > n=3 weight)" \
  || no "the blend weight must move with sample count (n=6 weight=$W6 should exceed n=3 weight=$W3)"
awk -v a="$BLEND6_RATE" -v b="$BLEND_RATE" 'BEGIN{ exit !(a <= b) }' \
  && ok "more samples pull the blended rate further toward observed" \
  || no "more low landings should pull the blended rate further down (n=6=$BLEND6_RATE n=3=$BLEND_RATE)"

# ════════════════════════════════════════════════════════════════════════════
# T_BAND_BLEND — the RANGE tracks the blend, not a static occupancy band
# ════════════════════════════════════════════════════════════════════════════
# The blend corrects "the structural assumptions in-flight" — and the spec output
# is a RANGE, so the range EDGES must migrate toward observed burn as landings
# accrue, not stay frozen at the occupancy floor/ceiling while only the central
# rate moves. The bug this kills (BUG 3): a blended central rate sitting hundreds
# of times OUTSIDE its own reported range — occupancy is a point-in-time STOCK
# (the window working set, bounded by the threshold) but cost-to-complete is
# cumulative session THROUGHPUT (the four classes summed across every turn,
# cache_read-dominated), unbounded and ~orders of magnitude larger. The two
# invariants: (1) the central blended estimate lies INSIDE its own band — a
# coherent document; (2) the band moves with observed burn in BOTH directions
# (rising when observed >> ceiling, falling when observed << floor). At n=0 the
# band is unchanged (purely structural) — guarded by T1 above.

# (high) observed burn FAR ABOVE the floor lower bound (real throughput): the
# high edge must rise above the n=0 structural remaining×floor, and the center
# must sit inside the band.
HB=$(mk_instance); write_tracker "$HB"
bash "$HB/.claude/estimate.sh" set 9.7 2 "$HB/docs/estimates.json" >/dev/null 2>&1
bash "$HB/.claude/estimate.sh" set 9.8 3 "$HB/docs/estimates.json" >/dev/null 2>&1
HB_STRUCT=$( cd "$HB" && bash .claude/projection.sh project 2>/dev/null )
HB_HIGH0=$(echo "$HB_STRUCT" | jq -r '.range.high_tokens')   # n=0 structural high = remaining × structural_high
# [13.3] three landings whose per-session burn exceeds the modeled structural high edge
# (~65M at the test setpoint), varying so observed min<mean<max (a real band) — the band
# must track observed throughput UP above the modeled prior.
add_landing "$HB" 9.1 200000000
add_landing "$HB" 9.1 300000000
add_landing "$HB" 9.1 250000000
HB_DOC=$( cd "$HB" && bash .claude/projection.sh project 2>/dev/null )
HB_HIGH=$(echo "$HB_DOC" | jq -r '.range.high_tokens')
awk -v a="$HB_HIGH" -v b="$HB_HIGH0" 'BEGIN{ exit !(a > b) }' \
  && ok "BAND: observed burn above the modeled high edge RAISES the range high edge (it tracks throughput, not the occupancy stock)" \
  || no "the range high edge must rise toward observed burn (n=0 structural high=$HB_HIGH0, blended high=$HB_HIGH)"
# coherence: the central blended estimate (remaining × blended_tokens) lies INSIDE
# its own reported range — the bug was a center hundreds of × outside its band.
echo "$HB_DOC" | jq -e '
  (.spine.quantity.remaining_sessions * .spine.unit_rate.blended_tokens) as $center
  | .range.low_tokens <= $center and $center <= .range.high_tokens' >/dev/null 2>&1 \
  && ok "BAND: the central blended estimate lies INSIDE its own range (coherent document)" \
  || no "the blended center must lie within [low,high] (range=$(echo "$HB_DOC" | jq -c '.range'), blended=$(echo "$HB_DOC" | jq -r '.spine.unit_rate.blended_tokens'), remaining=$(echo "$HB_DOC" | jq -r '.spine.quantity.remaining_sessions'))"

# (low) observed burn FAR BELOW the measured floor: the low edge must fall below
# the structural remaining×floor (symmetric — the band tracks observed downward too).
LB=$(mk_instance); write_tracker "$LB"
bash "$LB/.claude/estimate.sh" set 9.7 2 "$LB/docs/estimates.json" >/dev/null 2>&1
bash "$LB/.claude/estimate.sh" set 9.8 3 "$LB/docs/estimates.json" >/dev/null 2>&1
LB_STRUCT=$( cd "$LB" && bash .claude/projection.sh project 2>/dev/null )
LB_LOW0=$(echo "$LB_STRUCT" | jq -r '.range.low_tokens')   # structural low = remaining×floor
add_landing "$LB" 9.1 5000
add_landing "$LB" 9.1 6000
add_landing "$LB" 9.1 5500
LB_DOC=$( cd "$LB" && bash .claude/projection.sh project 2>/dev/null )
LB_LOW=$(echo "$LB_DOC" | jq -r '.range.low_tokens')
awk -v a="$LB_LOW" -v b="$LB_LOW0" 'BEGIN{ exit !(a < b) }' \
  && ok "BAND: observed burn below the floor LOWERS the range low edge (the band tracks observed downward too)" \
  || no "the range low edge must fall toward the low observed burn (structural low=$LB_LOW0, blended low=$LB_LOW)"
echo "$LB_DOC" | jq -e '
  (.spine.quantity.remaining_sessions * .spine.unit_rate.blended_tokens) as $center
  | .range.low_tokens <= $center and $center <= .range.high_tokens' >/dev/null 2>&1 \
  && ok "BAND: (low case) the central blended estimate lies INSIDE its own range" \
  || no "(low case) the blended center must lie within [low,high] (range=$(echo "$LB_DOC" | jq -c '.range'))"

# SELF-RECONCILABLE: the blended band-edge rates the range is built from are
# EMITTED in spine.unit_rate, so a reader can derive the range from the document's
# own published fields — range.low == remaining × blended_low_tokens (and high).
# Without the emitted edges the range would be an unexplained number at n>0 (the
# spine would still publish the structural floor/ceiling, which no longer produce
# the range once the band has blended).
echo "$HB_DOC" | jq -e '
  (.spine.quantity.remaining_sessions * .spine.unit_rate.blended_low_tokens) == .range.low_tokens
  and (.spine.quantity.remaining_sessions * .spine.unit_rate.blended_high_tokens) == .range.high_tokens' >/dev/null 2>&1 \
  && ok "BAND: the document is SELF-RECONCILABLE — range = remaining × emitted blended_{low,high}_tokens" \
  || no "the range must reconcile from the emitted blended band-edge rates (unit_rate=$(echo "$HB_DOC" | jq -c '.spine.unit_rate'), range=$(echo "$HB_DOC" | jq -c '.range'))"
# [13.3] at n=0 the emitted blended edges equal the STRUCTURAL band edges (the modeled
# occupancy×turns band), NOT the floor — and the band is real (low < high), not a
# lower-bound point. With no observed pull yet the blend sits on the modeled prior.
echo "$HB_STRUCT" | jq -e '.spine.unit_rate.blended_low_tokens == .spine.unit_rate.structural_low_tokens
  and .spine.unit_rate.blended_high_tokens == .spine.unit_rate.structural_high_tokens
  and .spine.unit_rate.structural_low_tokens < .spine.unit_rate.structural_high_tokens' >/dev/null 2>&1 \
  && ok "[13.3] BAND: at n=0 the blended edges equal the modeled structural band edges (a real band, not a floor point)" \
  || no "[13.3] n=0 blended edges must equal the structural band edges, low<high (got: $(echo "$HB_STRUCT" | jq -c '.spine.unit_rate'))"

# ════════════════════════════════════════════════════════════════════════════
# T_FOREIGN — NO INPUT PATH TO FOREIGN HISTORY (the grep-assert)
# ════════════════════════════════════════════════════════════════════════════
# The projection may consult ONLY this control plane's own artifacts: its
# metering log, its estimate sidecar, its calibration record (and the resolver,
# which reads the local tracker). No path may reach another project's history —
# no home-global crawl, no foreign-instance path, no cross-project glob. This
# is grep-asserted against the CODE PATHS (Rule: the confinement is structural).
# Comment lines are stripped first: the header prose legitimately NAMES the
# foreign paths it forbids (explaining what the code deliberately does NOT do),
# so grepping the raw file would flag the documentation of the invariant. The
# invariant is about executable code, so we assert over non-comment lines only.
SRC=$(grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -vE '^[[:space:]]*$')

# It must NOT read from a home-global or foreign-project location. The metering
# harvest in [9.1] reaches into the runtime transcript under a home-global path
# to read tokens — the PROJECTION must NOT: it consumes the already-harvested
# local log, never a transcript and never a home-global path.
echo "$SRC" | grep -nE '\$HOME|~/\.claude|/projects/|projects/\$|getconf|find / ' \
  && no "FOREIGN-HISTORY: the projection source references a home-global / cross-project path — it must read only LOCAL artifacts" \
  || ok "FOREIGN-HISTORY: no \$HOME / ~/.claude / cross-project path in the projection source (grep-asserted)"

# It must NOT shell out to anything that could fetch foreign data (curl/wget/ssh/
# scp/nc) — the inputs are local files only.
echo "$SRC" | grep -nE '\b(curl|wget|ssh|scp|nc|rsync)\b' \
  && no "FOREIGN-HISTORY: the projection source shells out to a network/copy tool — inputs must be local files only" \
  || ok "FOREIGN-HISTORY: no network/copy tool in the projection source (inputs are local files)"

# Positive control: the grep WOULD fire on a planted foreign-path line, so a
# passing assertion above is meaningful (not a dead regex on a clean file).
printf 'x=$HOME/.claude/projects/other\n' | grep -qE '\$HOME|~/\.claude|/projects/' \
  && ok "FOREIGN-HISTORY (positive control): the foreign-path grep catches a planted \$HOME/.claude/projects line" \
  || no "the foreign-path grep is dead — it would pass on a clean file even if a foreign path were introduced"

# And it DOES read the three local inputs the spec names (proving it has real
# inputs, not that it reads nothing): the metering log, the estimate sidecar
# (via estimate.sh or the default path), and the calibration record.
echo "$SRC" | grep -qE 'metering\.ndjson|--log|LOG' \
  && ok "the projection reads the LOCAL metering log (the observed-rate input)" \
  || no "the projection must read the local metering log"
echo "$SRC" | grep -qE 'estimates\.json|estimate\.sh|SIDECAR' \
  && ok "the projection reads the LOCAL estimate sidecar (the quantity input)" \
  || no "the projection must read the local estimate sidecar"
echo "$SRC" | grep -qE 'calibration|CALIB' \
  && ok "the projection knows the LOCAL calibration record (bank + grade input)" \
  || no "the projection must reference the local calibration record"

# ════════════════════════════════════════════════════════════════════════════
# T_NO_DANGLING_CITE — [15.6] no citation points at a doc a fresh install lacks
# ════════════════════════════════════════════════════════════════════════════
# The projection script cited docs/notes/meter-forensics.md — a CONTROL-PLANE-ONLY
# forensic doc that a fresh code-repo install does NOT have. A path citation to a file
# that does not ship dangles: a reader following it hits nothing. [15.6] requires the
# citation to stop dangling — either ship the finding in a code-repo doc, or reword so
# the citation does not imply the file ships. The robust, install-agnostic check: the
# projection source must NOT carry the docs/notes/meter-forensics.md PATH unless that
# file actually ships in this repo. The forensic FINDINGS (the ≈70–350M numbers) stay
# inline in the prose — the citation just stops claiming a file the install lacks.
FORENSIC_DOC="$CLAUDE_DIR/../docs/notes/meter-forensics.md"
if [ -f "$FORENSIC_DOC" ]; then
  # the doc was shipped into the code repo — a path citation now RESOLVES, so it is fine.
  ok "[15.6] the forensic doc ships in this repo (docs/notes/meter-forensics.md) — a path citation resolves"
else
  # the doc does NOT ship — no projection citation may point at its path (it would dangle).
  grep -nE 'docs/notes/meter-forensics\.md' "$SCRIPT" >/dev/null 2>&1 \
    && no "[15.6] the projection cites docs/notes/meter-forensics.md but that file does NOT ship — the citation dangles (reword or ship the doc)" \
    || ok "[15.6] no dangling docs/notes/meter-forensics.md path citation in the projection (it does not imply a non-shipped file)"
fi
# positive control: the grep WOULD fire on a planted path line (not a dead regex).
printf 'see docs/notes/meter-forensics.md for detail\n' | grep -qE 'docs/notes/meter-forensics\.md' \
  && ok "[15.6] (positive control) the dangling-path grep catches a planted meter-forensics.md path" \
  || no "[15.6] the dangling-path grep is dead — it would pass even with a dangling citation present"

# ════════════════════════════════════════════════════════════════════════════
# T4 — DEFAULT DISCLOSURE: an unratified deliverable projects at the default and discloses
# ════════════════════════════════════════════════════════════════════════════
# In T1's instance, 9.9 had no ratified estimate -> default (1). The projection
# must disclose which remaining deliverables fell back to the default, so the
# range's basis is honest.
D=$(mk_instance); write_tracker "$D"
bash "$D/.claude/estimate.sh" set 9.7 2 "$D/docs/estimates.json" >/dev/null 2>&1
bash "$D/.claude/estimate.sh" set 9.8 3 "$D/docs/estimates.json" >/dev/null 2>&1
# 9.9 deliberately unratified.
DDOC=$( cd "$D" && bash .claude/projection.sh project 2>/dev/null )
echo "$DDOC" | jq -e '.spine.quantity.default_estimate_ids | index("9.9")' >/dev/null 2>&1 \
  && ok "DISCLOSURE: a deliverable with no ratified estimate is named in default_estimate_ids" \
  || no "9.9 (unratified) must be disclosed as projecting at the default (got: $(echo "$DDOC" | jq -c '.spine.quantity.default_estimate_ids'))"
# When every remaining deliverable is ratified, the disclosure list is empty.
ALLRAT=$(mk_instance); write_tracker "$ALLRAT"
bash "$ALLRAT/.claude/estimate.sh" set 9.7 2 "$ALLRAT/docs/estimates.json" >/dev/null 2>&1
bash "$ALLRAT/.claude/estimate.sh" set 9.8 3 "$ALLRAT/docs/estimates.json" >/dev/null 2>&1
bash "$ALLRAT/.claude/estimate.sh" set 9.9 1 "$ALLRAT/docs/estimates.json" >/dev/null 2>&1
ARDOC=$( cd "$ALLRAT" && bash .claude/projection.sh project 2>/dev/null )
echo "$ARDOC" | jq -e '.spine.quantity.default_estimate_ids == []' >/dev/null 2>&1 \
  && ok "DISCLOSURE: with every remaining deliverable ratified the disclosure list is empty" \
  || no "a fully-ratified plan must disclose no default fallbacks (got: $(echo "$ARDOC" | jq -c '.spine.quantity.default_estimate_ids'))"

# ════════════════════════════════════════════════════════════════════════════
# T5 — BANKED forecasts: every projection can be banked (append-only)
# ════════════════════════════════════════════════════════════════════════════
K=$(mk_instance); write_tracker "$K"
bash "$K/.claude/estimate.sh" set 9.7 2 "$K/docs/estimates.json" >/dev/null 2>&1
CALIB="$K/.claude/metering/calibration.ndjson"
( cd "$K" && bash .claude/projection.sh bank ) >/dev/null 2>&1
[ -f "$CALIB" ] && [ "$(wc -l < "$CALIB" | tr -d ' ')" = "1" ] && jq -e . "$CALIB" >/dev/null 2>&1 \
  && ok "BANK: a banked projection appends ONE valid forecast line to the calibration record" \
  || no "bank must append one valid forecast line (lines=$( [ -f "$CALIB" ] && wc -l < "$CALIB"))"
# the banked forecast carries the range and basis it was made under (a forecast
# you can later grade against the outcome).
tail -1 "$CALIB" | jq -e '.kind == "forecast" and (.range.low_tokens|type=="number") and (.basis.claim|type=="string")' >/dev/null 2>&1 \
  && ok "BANK: the banked forecast records the range and basis claim it was made under" \
  || no "the banked forecast must carry range+basis (got: $(tail -1 "$CALIB" | jq -c '.'))"
# append-only: a second bank leaves the first line byte-identical.
FIRST=$(head -1 "$CALIB")
( cd "$K" && bash .claude/projection.sh bank ) >/dev/null 2>&1
[ "$(wc -l < "$CALIB" | tr -d ' ')" = "2" ] && [ "$(head -1 "$CALIB")" = "$FIRST" ] \
  && ok "BANK: append-only — a second bank adds a line and leaves the first byte-identical" \
  || no "bank must be append-only (the first banked line changed)"

# ════════════════════════════════════════════════════════════════════════════
# T6 — CLOSE-TIME GRADING names the layer: quantity error AND rate error, separately
# ════════════════════════════════════════════════════════════════════════════
# Build an instance where the WHOLE remaining plan has now landed, so close-time
# grading can compare estimate-vs-actual. Estimated 2 sessions for 9.7 at a high
# envelope; the actual landings were FEWER sessions at a LOWER rate, so BOTH
# errors are non-zero AND distinguishable — a miss names its layer.
G=$(mk_instance)
bash "$G/.claude/estimate.sh" set 9.7 2 "$G/docs/estimates.json" >/dev/null 2>&1
# (1) BANK the forecast while [9.7] is still OPEN — the forecast freezes the
# takeoff it was made under (estimated 2 sessions for 9.7). Grading reads the
# BANKED forecast, not a recomputation, so the estimate it grades against is the
# one that was committed at forecast time.
cat > "$G/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 9 — The Meter**

## Phase 9 — The Meter

_Goal: meter cost at every boundary._

- ✅ **[9.1]** Session-boundary cost capture `[deps: none]`
- 🔄 **[9.7]** Projection `[deps: 9.1]`
MD
( cd "$G" && bash .claude/projection.sh bank ) >/dev/null 2>&1
# (2) CLOSE: [9.7] lands. The actual outcome is ONE session at a low rate, so the
# quantity layer missed (estimated 2, actual 1) — a miss the grade names by layer.
# The landing must occur AFTER the bank (grade bounds actual_sessions to post-bank
# sessions); stamp it a year out so it is unambiguously after the just-now bank.
cat > "$G/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 9 — The Meter**

## Phase 9 — The Meter

_Goal: meter cost at every boundary._

- ✅ **[9.1]** Session-boundary cost capture `[deps: none]`
- ✅ **[9.7]** Projection `[deps: 9.1]`
MD
add_landing_at "$G" 9.7 7000 "session-2099-01-01-001" "2099-01-01T00:00:00Z"
GRADE=$( cd "$G" && bash .claude/projection.sh grade 2>/dev/null )
RC_G=$( cd "$G" && bash .claude/projection.sh grade >/dev/null 2>&1; echo $? )

[ "$RC_G" = "0" ] && echo "$GRADE" | jq -e . >/dev/null 2>&1 \
  && ok "GRADE: close-time grading emits a valid document" \
  || no "grade must emit a valid document (rc=$RC_G doc=$GRADE)"
# TWO SEPARABLE errors, named by layer.
echo "$GRADE" | jq -e 'has("quantity_error") and has("rate_error")' >/dev/null 2>&1 \
  && ok "GRADE: emits quantity_error AND rate_error as SEPARATE fields (a miss names its layer)" \
  || no "grade must emit quantity_error and rate_error separately (got: $(echo "$GRADE" | jq -c 'keys'))"
# quantity error: estimated sessions vs actual sessions.
echo "$GRADE" | jq -e '.quantity_error.estimated_sessions == 2 and .quantity_error.actual_sessions == 1' >/dev/null 2>&1 \
  && ok "GRADE: quantity_error compares estimated (2) vs actual (1) sessions" \
  || no "quantity_error must name estimated-vs-actual sessions (got: $(echo "$GRADE" | jq -c '.quantity_error'))"
# rate error: envelope vs actual tokens/session — present and numeric.
echo "$GRADE" | jq -e '(.rate_error.envelope_tokens|type=="number") and (.rate_error.actual_tokens_per_session|type=="number")' >/dev/null 2>&1 \
  && ok "GRADE: rate_error compares the envelope vs actual tokens/session" \
  || no "rate_error must name envelope-vs-actual tokens/session (got: $(echo "$GRADE" | jq -c '.rate_error'))"
# the grade is banked into the calibration record (so the local record learns).
GLINES=$(grep -c '"kind":"grade"' "$G/.claude/metering/calibration.ndjson" 2>/dev/null || echo 0)
[ "$GLINES" -ge 1 ] \
  && ok "GRADE: the graded errors are banked into the calibration record (the local record learns)" \
  || no "the grade must be banked into the calibration record (kind=grade lines=$GLINES)"

# ════════════════════════════════════════════════════════════════════════════
# T_POSTBANK — actual_sessions counts only sessions AFTER the banked forecast
# ════════════════════════════════════════════════════════════════════════════
# A forecast's quantity takeoff is REMAINING work AT BANK TIME — sessions logged
# BEFORE the bank were spent on already-done work and were never in scope. So the
# quantity layer must compare estimated_sessions against ACTUAL sessions occurring
# AFTER the banked forecast's timestamp, not the whole-log session count. A
# whole-log denominator inflates quantity error for a mid-initiative forecast.
# Here: a banked forecast at a KNOWN timestamp, with TWO sessions before it and
# ONE after — only the one post-bank session may count toward actual_sessions.
PB=$(mk_instance)
bash "$PB/.claude/estimate.sh" set 9.7 2 "$PB/docs/estimates.json" >/dev/null 2>&1
PB_CALIB="$PB/.claude/metering/calibration.ndjson"
PB_BANK_TS="2026-06-10T00:00:00Z"
# Hand-bank a forecast with a KNOWN banked_at (the discriminator timestamp), so
# the before/after split is deterministic and independent of wall-clock.
jq -cn --arg ts "$PB_BANK_TS" \
  '{kind:"forecast", banked_at:$ts, schema:"guv.projection.v1", generated:$ts,
    range:{low_tokens:20000, high_tokens:300000, denomination:"tokens"},
    basis:{claim:"structural", n:0, observed_weight:0, observed_mean_tokens_per_session:0},
    scope:{claim:"guv-mediated cost to complete (remaining work, not total)"},
    spine:{quantity:{remaining_sessions:2, default_estimate_ids:[]},
           unit_rate:{floor_tokens:10000, occupancy_reference_tokens:150000, blended_tokens:10000}}}' \
  > "$PB_CALIB"
# TWO distinct sessions BEFORE the bank (already-spent work, out of scope)…
add_landing_at "$PB" 9.1 6000 "session-2026-06-05-001" "2026-06-05T00:00:00Z"
add_landing_at "$PB" 9.1 6000 "session-2026-06-08-001" "2026-06-08T00:00:00Z"
# …and ONE distinct session AFTER the bank (the only one in the forecast's scope).
add_landing_at "$PB" 9.7 7000 "session-2026-06-12-001" "2026-06-12T00:00:00Z"
PBGRADE=$( cd "$PB" && bash .claude/projection.sh grade 2>/dev/null )
# Whole-log unique sessions = 3; post-bank = 1. The bound must yield 1, not 3.
echo "$PBGRADE" | jq -e '.quantity_error.actual_sessions == 1' >/dev/null 2>&1 \
  && ok "POST-BANK: actual_sessions counts only sessions AFTER the banked forecast (1, not the whole-log 3)" \
  || no "actual_sessions must be bounded to post-bank sessions (got: $(echo "$PBGRADE" | jq -c '.quantity_error'))"

# ════════════════════════════════════════════════════════════════════════════
# T_POSTBANK_RATE — rate_error's actual tokens/session is post-bank-bounded too
# ════════════════════════════════════════════════════════════════════════════
# The rate layer is the symmetric analog of T_POSTBANK's quantity bound: a
# forecast's envelope was set against the burn of the work it COVERS (remaining
# work from bank time forward), so the grade must compare it against the actual
# per-session burn over POST-BANK sessions only. Pre-bank sessions were spent on
# already-done work at whatever rate then prevailed and were never in the
# forecast's scope — folding them into actual_tokens_per_session mixes two
# regimes and misstates the rate miss. observed_rate() (the LIVE projection
# blend) legitimately reads the whole log; only the GRADE's comparison is bounded.
# Here: pre-bank sessions burn LOW and post-bank sessions burn HIGH, at distinct
# rates, so a whole-log mean and a post-bank mean are unambiguously different —
# the grade must report the post-bank burn, not the whole-log average.
PBR=$(mk_instance)
bash "$PBR/.claude/estimate.sh" set 9.7 2 "$PBR/docs/estimates.json" >/dev/null 2>&1
PBR_CALIB="$PBR/.claude/metering/calibration.ndjson"
PBR_BANK_TS="2026-06-10T00:00:00Z"
jq -cn --arg ts "$PBR_BANK_TS" \
  '{kind:"forecast", banked_at:$ts, schema:"guv.projection.v1", generated:$ts,
    range:{low_tokens:20000, high_tokens:300000, denomination:"tokens"},
    basis:{claim:"structural", n:0, observed_weight:0, observed_mean_tokens_per_session:0},
    scope:{claim:"guv-mediated cost to complete (remaining work, not total)"},
    spine:{quantity:{remaining_sessions:2, default_estimate_ids:[]},
           unit_rate:{floor_tokens:10000, occupancy_reference_tokens:150000, blended_tokens:10000}}}' \
  > "$PBR_CALIB"
# TWO sessions BEFORE the bank at a LOW burn (3000 tokens each, already-spent)…
add_landing_at "$PBR" 9.1 3000 "session-2026-06-05-001" "2026-06-05T00:00:00Z"
add_landing_at "$PBR" 9.1 3000 "session-2026-06-08-001" "2026-06-08T00:00:00Z"
# …and ONE session AFTER the bank at a HIGH burn (90000 tokens, the in-scope work).
add_landing_at "$PBR" 9.7 90000 "session-2026-06-12-001" "2026-06-12T00:00:00Z"
PBRGRADE=$( cd "$PBR" && bash .claude/projection.sh grade 2>/dev/null )
# Whole-log mean = (3000+3000+90000)/3 = 32000; post-bank mean = 90000.
# The bound must report the post-bank burn (90000), not the whole-log average (32000).
echo "$PBRGRADE" | jq -e '.rate_error.actual_tokens_per_session == 90000' >/dev/null 2>&1 \
  && ok "POST-BANK: rate_error actual tokens/session counts only POST-BANK burn (90000, not the whole-log 32000)" \
  || no "rate_error.actual_tokens_per_session must be bounded to post-bank sessions (got: $(echo "$PBRGRADE" | jq -c '.rate_error'))"

# ════════════════════════════════════════════════════════════════════════════
# T_GRADE_BLENDED — [12.1] grade's rate_error uses the BLENDED forecast, not the floor
# ════════════════════════════════════════════════════════════════════════════
# Pre-[12.1] grade compared the structural floor (occupancy-scale) against actual
# throughput — incoherent, the same stock-vs-flow mismatch the live range had. [12.1]
# grades the BLENDED central rate the forecast actually committed. Here: landings
# accrue BEFORE the bank so the banked blended rate differs from the floor; the grade
# must report that blended rate as the envelope, not the raw floor.
GBL=$(mk_instance)
bash "$GBL/.claude/estimate.sh" set 9.7 2 "$GBL/docs/estimates.json" >/dev/null 2>&1
cat > "$GBL/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 9 — The Meter**

## Phase 9 — The Meter

_Goal: meter cost at every boundary._

- ✅ **[9.1]** Session-boundary cost capture `[deps: none]`
- 🔄 **[9.7]** Projection `[deps: 9.1]`
MD
# three PRE-bank landings at a high throughput (stamped in the past so they precede
# the bank): the blended forecast rises well above the structural floor.
add_landing_at "$GBL" 9.1 9000000 "session-2020-01-01-001" "2020-01-01T00:00:00Z"
add_landing_at "$GBL" 9.1 9000000 "session-2020-01-02-001" "2020-01-02T00:00:00Z"
add_landing_at "$GBL" 9.1 9000000 "session-2020-01-03-001" "2020-01-03T00:00:00Z"
( cd "$GBL" && bash .claude/projection.sh bank ) >/dev/null 2>&1
GBL_BLENDED=$(jq -rs '[ .[] | select(.kind=="forecast") ] | last | .spine.unit_rate.blended_tokens' "$GBL/.claude/metering/calibration.ndjson")
GBL_FLOOR=$(jq -rs '[ .[] | select(.kind=="forecast") ] | last | .spine.unit_rate.floor_tokens' "$GBL/.claude/metering/calibration.ndjson")
# a POST-bank landing (stamped in the future) — the in-scope outcome.
add_landing_at "$GBL" 9.7 12000000 "session-2099-01-01-001" "2099-01-01T00:00:00Z"
GBLGRADE=$( cd "$GBL" && bash .claude/projection.sh grade 2>/dev/null )
echo "$GBLGRADE" | jq -e --argjson b "$GBL_BLENDED" '.rate_error.envelope_tokens == $b' >/dev/null 2>&1 \
  && ok "GRADE: rate_error envelope is the BANKED BLENDED rate the forecast committed (not the raw floor)" \
  || no "grade must grade the blended forecast (envelope should be $GBL_BLENDED, got: $(echo "$GBLGRADE" | jq -c '.rate_error'))"
awk -v b="$GBL_BLENDED" -v f="$GBL_FLOOR" 'BEGIN{ exit !(b > f) }' \
  && ok "GRADE: the banked blended rate ($GBL_BLENDED) exceeds the structural floor ($GBL_FLOOR) — non-vacuous" \
  || no "the blended forecast must differ from the floor for this test to mean anything (blended=$GBL_BLENDED floor=$GBL_FLOOR)"

# ════════════════════════════════════════════════════════════════════════════
# T_GRADE_LEGACY — a forecast banked WITHOUT blended_tokens falls back to the floor
# ════════════════════════════════════════════════════════════════════════════
# [12.1]'s grade reads `.spine.unit_rate.blended_tokens // .floor_tokens` — the
# Rule-15 designed degradation for a legacy forecast banked before blended_tokens
# existed. Exercise the FALLBACK arm directly: hand-bank a forecast whose unit_rate
# has floor_tokens but NO blended_tokens; grade must report the floor as the envelope.
LG=$(mk_instance)
LG_CALIB="$LG/.claude/metering/calibration.ndjson"
jq -cn --arg ts "2026-06-10T00:00:00Z" \
  '{kind:"forecast", banked_at:$ts, schema:"guv.projection.v1", generated:$ts,
    range:{low_tokens:20000, high_tokens:20000, denomination:"tokens"},
    basis:{claim:"structural", bound:"lower_bound_only", n:0, observed_weight:0, observed_mean_tokens_per_session:0},
    scope:{claim:"guv-mediated cost to complete (remaining work, not total)"},
    spine:{quantity:{remaining_sessions:2, default_estimate_ids:[]},
           unit_rate:{floor_tokens:10000, occupancy_reference_tokens:150000}}}' \
  > "$LG_CALIB"
add_landing_at "$LG" 9.7 50000 "session-2099-01-01-001" "2099-01-01T00:00:00Z"
LGGRADE=$( cd "$LG" && bash .claude/projection.sh grade 2>/dev/null )
echo "$LGGRADE" | jq -e '.rate_error.envelope_tokens == 10000' >/dev/null 2>&1 \
  && ok "GRADE (legacy): a forecast with no blended_tokens falls back to floor_tokens (Rule-15 degradation)" \
  || no "grade must fall back to floor_tokens for a legacy forecast (got: $(echo "$LGGRADE" | jq -c '.rate_error'))"

# ════════════════════════════════════════════════════════════════════════════
# T7 — DEPS-AMEND FOLLOWS BY RECOMPUTATION: change remaining work, projection reflects it
# ════════════════════════════════════════════════════════════════════════════
# A /replan-style change to remaining work (here: a deps-amend that adds a new
# remaining deliverable to the tracker) must change the next projection BY
# RECOMPUTATION — no special handling, the projection just re-reads the tracker.
A=$(mk_instance); write_tracker "$A"
bash "$A/.claude/estimate.sh" set 9.7 2 "$A/docs/estimates.json" >/dev/null 2>&1
bash "$A/.claude/estimate.sh" set 9.8 3 "$A/docs/estimates.json" >/dev/null 2>&1
bash "$A/.claude/estimate.sh" set 9.9 1 "$A/docs/estimates.json" >/dev/null 2>&1
BEFORE=$( cd "$A" && bash .claude/projection.sh project 2>/dev/null )
Q_BEFORE=$(echo "$BEFORE" | jq -r '.spine.quantity.remaining_sessions')   # 6
# deps-amend: add a remaining deliverable [9.10] (estimate 4) to the tracker.
cat >> "$A/docs/PHASE_STATUS.md" <<'MD'
- ⬜ **[9.10]** A newly-inserted deliverable `[deps: 9.8]`
MD
bash "$A/.claude/estimate.sh" set 9.10 4 "$A/docs/estimates.json" >/dev/null 2>&1
AFTER=$( cd "$A" && bash .claude/projection.sh project 2>/dev/null )
Q_AFTER=$(echo "$AFTER" | jq -r '.spine.quantity.remaining_sessions')     # 10
[ "$Q_BEFORE" = "6" ] && [ "$Q_AFTER" = "10" ] \
  && ok "DEPS-AMEND: adding remaining work raises the next projection's quantity (6 -> 10) by recomputation" \
  || no "the projection must follow a deps-amend by recomputation (before=$Q_BEFORE after=$Q_AFTER)"
# and the projected range grew accordingly (more remaining work -> larger range).
LOW_B=$(echo "$BEFORE" | jq -r '.range.low_tokens'); LOW_A=$(echo "$AFTER" | jq -r '.range.low_tokens')
awk -v a="$LOW_A" -v b="$LOW_B" 'BEGIN{ exit !(a > b) }' \
  && ok "DEPS-AMEND: the projected range grew with the added work (no special handling)" \
  || no "the range must grow with added remaining work (before low=$LOW_B after low=$LOW_A)"

# ════════════════════════════════════════════════════════════════════════════
# T_HUMAN_GATED — a 🔒 (human-gated) deliverable is OPEN work and must be counted
# ════════════════════════════════════════════════════════════════════════════
# 🔒 (human-gated, [10.1]) is OPEN work: the resolver recognizes it as
# status="human_gated" and counts it as open. The projection's remaining-work
# takeoff must include it — dropping it UNDERCOUNTS the cost to complete. (The
# resolver NEVER emits a per-deliverable status of "blocked"; "blocked" is a
# frontier classification, not a deliverable status — so filtering on it would be
# a dead arm that silently loses 🔒 work.) Here: a tracker with one 🔒 deliverable
# whose estimate must land in remaining_sessions.
HG=$(mk_instance)
cat > "$HG/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 9 — The Meter**

## Phase 9 — The Meter

_Goal: meter cost at every boundary._

- ✅ **[9.1]** Session-boundary cost capture `[deps: none]`
- 🔄 **[9.7]** Projection `[deps: 9.1]`
- 🔒 **[9.11]** A human-gated deliverable `[deps: 9.1]`
MD
bash "$HG/.claude/estimate.sh" set 9.7 2 "$HG/docs/estimates.json" >/dev/null 2>&1
bash "$HG/.claude/estimate.sh" set 9.11 5 "$HG/docs/estimates.json" >/dev/null 2>&1
HGDOC=$( cd "$HG" && bash .claude/projection.sh project 2>/dev/null )
# remaining = 9.7(2) + 9.11(5) = 7. If the 🔒 leg were dropped it would be 2.
echo "$HGDOC" | jq -e '.spine.quantity.remaining_sessions == 7' >/dev/null 2>&1 \
  && ok "HUMAN-GATED: a 🔒 deliverable is counted in remaining work (2+5=7, not undercounted to 2)" \
  || no "a 🔒 (human_gated) deliverable must be counted as open remaining work (got: $(echo "$HGDOC" | jq -c '.spine.quantity'))"

# ════════════════════════════════════════════════════════════════════════════
# T8 — usage / stderr discipline (the battery fails any suite that writes stderr)
# ════════════════════════════════════════════════════════════════════════════
OUT=$( bash "$SCRIPT" 2>&1 1>/dev/null ); RC=$?
[ "$RC" -eq 2 ] && [ -n "$OUT" ] && ok "usage: no subcommand exits 2 with a stderr message" \
  || no "no-arg should exit 2 to stderr (rc=$RC)"
OUT=$( bash "$SCRIPT" frobnicate 2>&1 1>/dev/null ); RC=$?
[ "$RC" -eq 2 ] && ok "usage: unknown subcommand exits 2" || no "unknown subcommand should exit 2 (rc=$RC)"
# a clean project run is silent on stderr.
CLEAN=$(mk_instance); write_tracker "$CLEAN"
bash "$CLEAN/.claude/estimate.sh" set 9.7 2 "$CLEAN/docs/estimates.json" >/dev/null 2>&1
ERR=$( cd "$CLEAN" && bash .claude/projection.sh project 2>&1 1>/dev/null )
[ -z "$ERR" ] && ok "stderr-gate: a clean project run is silent on stderr" \
  || no "clean project run leaked to stderr: $ERR"

# ════════════════════════════════════════════════════════════════════════════
# T9 — the shape is documented in its own file (the published-contract convention)
# ════════════════════════════════════════════════════════════════════════════
[ -f "$SHAPE" ] && ok "the projection shape is documented in its own file" \
  || no "projection.shape.md must exist"
if [ -f "$SHAPE" ]; then
  grep -qiE 'structural|spine' "$SHAPE" && ok "shape doc names the structural spine" \
    || no "shape doc must describe the structural spine"
  grep -qiE 'blend' "$SHAPE" && ok "shape doc describes the local blend" \
    || no "shape doc must describe the blend"
  grep -qiE 'foreign|only.*local|never.*history' "$SHAPE" \
    && ok "shape doc states the no-foreign-history confinement" \
    || no "shape doc must state inputs are local-only (no foreign history)"
  grep -qiE 'quantity error|rate error|two.*error|separable' "$SHAPE" \
    && ok "shape doc names the two separable close-time errors" \
    || no "shape doc must name quantity error and rate error"
  grep -qiE 'throughput' "$SHAPE" && grep -qiE 'occupanc' "$SHAPE" \
    && ok "shape doc names the throughput-vs-occupancy (flow vs stock) distinction ([12.1])" \
    || no "shape doc must explain the cost unit is throughput, not occupancy ([12.1])"
  grep -qiE 'occupancy_budget|expected.turns|occupancy.{0,4}turns' "$SHAPE" \
    && ok "[13.3] shape doc documents the occupancy×turns structural model" \
    || no "[13.3] shape doc must document the occupancy×turns rate model (occupancy_budget × expected_turns)"
fi

# ════════════════════════════════════════════════════════════════════════════
# T_OCCUPANCY_INFORMATIONAL — [13.3] occupancy is a modeled FACTOR, never a floor clamp
# ════════════════════════════════════════════════════════════════════════════
# [13.3] occupancy returns as a modeled FACTOR (the occupancy_budget feeding the rate),
# but the raw occupancy threshold and the measured doc-overhead floor stay INFORMATIONAL
# fields — the threshold never clamps the measured floor (the pre-[12.1] occupancy-as-
# ceiling coupling stays retired). A tiny setpoint below the measured floor must not
# invert the range, and occupancy_budget degrades UP to the floor as a lower bound
# (Rule 15) rather than collapsing the structural rate.
I=$(mk_instance); write_tracker "$I"
bash "$I/.claude/estimate.sh" set 9.7 2 "$I/docs/estimates.json" >/dev/null 2>&1
# A tiny occupancy.threshold setpoint, BELOW the ~10k measured floor (40k chars of
# docs mk_instance plants): occupancy×fraction (1200) falls under the floor.
jq '.occupancy={threshold:3000}' "$I/.claude/project.json" > "$I/.claude/project.json.tmp" \
  && mv "$I/.claude/project.json.tmp" "$I/.claude/project.json"
DOC=$( cd "$I" && bash .claude/projection.sh project 2>/dev/null )

echo "$DOC" | jq -e '.range.low_tokens <= .range.high_tokens' >/dev/null 2>&1 \
  && ok "occupancy<floor: the range never inverts (low <= high)" \
  || no "the range must not invert (got range=$(echo "$DOC" | jq -c '.range'))"

echo "$DOC" | jq -e '.spine.unit_rate.floor_tokens > .spine.unit_rate.occupancy_reference_tokens
  and .spine.unit_rate.occupancy_reference_tokens == 3000' >/dev/null 2>&1 \
  && ok "occupancy<floor: the floor is NOT clamped to occupancy (occupancy is the informational reference=3000)" \
  || no "the floor must stand on its own with occupancy informational=3000 (got floor=$(echo "$DOC" | jq -c '.spine.unit_rate.floor_tokens'), occ=$(echo "$DOC" | jq -c '.spine.unit_rate.occupancy_reference_tokens'))"

# [13.3] degradation: a setpoint whose working-set fraction falls below the measured
# floor clamps occupancy_budget UP to the floor (the doc overhead is a true lower bound
# on a session's working set) — the structural rate never collapses below it (Rule 15).
echo "$DOC" | jq -e '.spine.unit_rate.occupancy_budget_tokens >= .spine.unit_rate.floor_tokens
  and .spine.unit_rate.structural_tokens > 0' >/dev/null 2>&1 \
  && ok "[13.3] occupancy_budget degrades UP to ≥ the measured floor when the setpoint is tiny (Rule-15 lower bound)" \
  || no "[13.3] occupancy_budget must clamp to ≥ floor (got budget=$(echo "$DOC" | jq -r '.spine.unit_rate.occupancy_budget_tokens'), floor=$(echo "$DOC" | jq -r '.spine.unit_rate.floor_tokens'))"

# ════════════════════════════════════════════════════════════════════════════
# [13.6] — observed_rate() is SLICE-AWARE: it measures per-session DELTAS, never
# the cumulative running totals the forensic bug produced. The metering log mixes
# three shapes and observed_rate() must read each as the right unit:
#   • slice-tagged entries (slice_basis per_deliverable / since_process_start) —
#     tokens IS the bounded slice, counted directly;
#   • unbounded_cumulative — disclosed degradation, EXCLUDED;
#   • legacy (no slice_basis) — the pre-fix cumulative snapshots, MIGRATED to
#     deltas at read time (difference consecutive same-runtime_session cumulatives).
# This is the bug's principal victim made right: averaging running totals produced
# the inflated ~503M anchor; differencing recovers the real per-session burns.
# ════════════════════════════════════════════════════════════════════════════

# ── T_VINTAGE_LEGACY — legacy cumulative entries are NOT rate samples. They are
# pre-[13.6] by definition, and [13.6] PREDATES the [9.1] dedupe fix, so a legacy
# entry is pre-fix BY CONSTRUCTION: its tokens over-count (usage summed once per
# transcript LINE). Differencing them yields deltas that are still in the inflated
# unit, so the migrated deltas were never commensurable with a post-fix setpoint.
# The rate excludes them and rides the structural band instead. (budget-gate.sh
# still differences legacy entries and MUST — burn legitimately sums every entry in
# the window in whatever unit it was recorded, then DISCLOSES the mix. A rate
# cannot: an average across two units is not a number.) Supersedes the [13.6]
# read-time migration in this reader only.
I=$(mk_instance); write_tracker "$I"
add_legacy_cumulative "$I" "tx-legacy" 1000000
add_legacy_cumulative "$I" "tx-legacy" 3000000
add_legacy_cumulative "$I" "tx-legacy" 6000000
DOC=$( cd "$I" && bash .claude/projection.sh project 2>/dev/null )
echo "$DOC" | jq -e '.basis.n == 0 and .basis.claim == "structural"' >/dev/null 2>&1 \
  && ok "[9.1] legacy cumulative entries are pre-fix by construction and NEVER sample the rate (n=0, basis falls back to structural)" \
  || no "[9.1] legacy entries must not sample a post-fix rate: expected n=0 claim=structural, got n=$(echo "$DOC" | jq -c '.basis.n'), claim=$(echo "$DOC" | jq -c '.basis.claim')"
# a NON-MONOTONE legacy series (pruned subagent files, an out-of-order append) is
# excluded by the same filter — the vintage test precedes any delta arithmetic, so
# there is no negative-sample path left to guard.
I4=$(mk_instance); write_tracker "$I4"
add_legacy_cumulative "$I4" "tx-nonmono" 10000000
add_legacy_cumulative "$I4" "tx-nonmono"  5000000
DOC4=$( cd "$I4" && bash .claude/projection.sh project 2>/dev/null )
echo "$DOC4" | jq -e '.basis.n == 0' >/dev/null 2>&1 \
  && ok "[9.1] a non-monotone legacy series is excluded by vintage before any delta arithmetic (n=0)" \
  || no "[9.1] non-monotone legacy must be excluded by vintage: expected n=0, got n=$(echo "$DOC4" | jq -c '.basis.n')"

# ── T_SLICE_EXCLUDE — an unbounded_cumulative entry (the disclosed degradation) is
# EXCLUDED from observed_rate: it never becomes a phantom sample. Seed one alongside
# two clean slice samples; n must be 2, the mean the two slices' mean only.
I2=$(mk_instance); write_tracker "$I2"
add_landing "$I2" 8.3 1000000     # slice sample (tagged per_deliverable)
add_landing "$I2" 8.3 3000000     # slice sample
LOG2="$I2/.claude/metering/metering.ndjson"
jq -cn '{schema:"guv.meter.v1", ts:"2026-06-14T00:00:00Z", session:"session-2026-06-14-009",
  session_derived:true, runtime_session:"tx-ub", deliverable_ids:["8.3"], model:"m",
  tokens:{input:0,output:0,cache_read:999000000,cache_creation:0},
  transcript_tokens:{input:0,output:0,cache_read:999000000,cache_creation:0},
  slice_basis:"unbounded_cumulative", compaction_cycles:0, dollars:null, spike_c_rung:"B",
  perf:{op_wallclock_s:0.1, suite_runtime_s:null}}' >> "$LOG2"
DOC2=$( cd "$I2" && bash .claude/projection.sh project 2>/dev/null )
echo "$DOC2" | jq -e '.basis.n == 2 and .basis.observed_mean_tokens_per_session == 2000000' >/dev/null 2>&1 \
  && ok "[13.6] an unbounded_cumulative entry is EXCLUDED from observed_rate (n=2, mean=2M; the 999M degradation never samples)" \
  || no "[13.6] unbounded_cumulative must be excluded: expected n=2 mean=2M, got n=$(echo "$DOC2" | jq -c '.basis.n'), mean=$(echo "$DOC2" | jq -c '.basis.observed_mean_tokens_per_session')"

# ── T_VINTAGE_MIX — a log holding BOTH vintages samples only the post-fix half.
# 2 post-fix slices (1M, 3M) + a legacy series (10M, 30M): the legacy pair is
# excluded, so n=2 and the mean is the post-fix mean (2M) — NOT 8.5M, which is what
# mixing the two units produces. This is the assertion that would have caught the
# contaminated 004 forecast: a 107,137,720/session blended rate built from 53
# pre-fix samples, multiplied out to a 4.29B cost-to-complete against a 1B ceiling.
I3=$(mk_instance); write_tracker "$I3"
add_landing "$I3" 8.3 1000000
add_landing "$I3" 8.3 3000000
add_legacy_cumulative "$I3" "tx-mix" 10000000
add_legacy_cumulative "$I3" "tx-mix" 30000000
DOC3=$( cd "$I3" && bash .claude/projection.sh project 2>/dev/null )
echo "$DOC3" | jq -e '.basis.n == 2 and .basis.observed_mean_tokens_per_session == 2000000' >/dev/null 2>&1 \
  && ok "[9.1] a mixed-vintage log samples ONLY the post-fix entries (n=2, mean 2M — never the 8.5M cross-unit average)" \
  || no "[9.1] mixed-vintage log must sample post-fix only: expected n=2 mean=2000000, got n=$(echo "$DOC3" | jq -c '.basis.n'), mean=$(echo "$DOC3" | jq -c '.basis.observed_mean_tokens_per_session')"

# ── T_VINTAGE_PREFIX — a pre-fix entry is identical to a post-fix one in EVERY
# field except the absent harvest_basis key. Same slice_basis, same shape, same
# tokens. Only the vintage marker separates them, so this pins that the filter
# reads the marker and not some incidental difference in the fixture.
I5=$(mk_instance); write_tracker "$I5"
add_landing_prefix "$I5" 8.3 1000000
add_landing_prefix "$I5" 8.3 3000000
DOC5=$( cd "$I5" && bash .claude/projection.sh project 2>/dev/null )
echo "$DOC5" | jq -e '.basis.n == 0 and .basis.claim == "structural"' >/dev/null 2>&1 \
  && ok "[9.1] a pre-fix slice entry (no harvest_basis key) is not a sample — the vintage marker is what decides, not the entry's shape" \
  || no "[9.1] pre-fix slice must not sample: expected n=0, got n=$(echo "$DOC5" | jq -c '.basis.n')"

# ── T_VINTAGE_UNKNOWN — an EXPLICIT harvest_basis:null is a DEGRADED harvest: the
# writer could not determine the unit. Unknown is not the same as post-fix, and
# Rule 15 says an unknown unit degrades to "not a sample", never to an assumed one.
I6=$(mk_instance); write_tracker "$I6"
add_landing "$I6" 8.3 2000000
LOG6="$I6/.claude/metering/metering.ndjson"
jq -cn '{schema:"guv.meter.v1", ts:"2026-06-14T00:00:00Z", session:"session-2026-06-14-077",
  session_derived:true, runtime_session:null, deliverable_ids:["8.3"], model:"m",
  tokens:{input:0,output:0,cache_read:900000000,cache_creation:0},
  transcript_tokens:null, slice_basis:"per_deliverable", compaction_cycles:0,
  harvest_basis:null, dollars:null, spike_c_rung:"B",
  perf:{op_wallclock_s:0.1, suite_runtime_s:null}}' >> "$LOG6"
DOC6=$( cd "$I6" && bash .claude/projection.sh project 2>/dev/null )
echo "$DOC6" | jq -e '.basis.n == 1 and .basis.observed_mean_tokens_per_session == 2000000' >/dev/null 2>&1 \
  && ok "[9.1] an explicit harvest_basis:null (degraded harvest, unknown unit) is NOT a sample — the 900M never enters the rate" \
  || no "[9.1] unknown vintage must not sample: expected n=1 mean=2000000, got n=$(echo "$DOC6" | jq -c '.basis.n'), mean=$(echo "$DOC6" | jq -c '.basis.observed_mean_tokens_per_session')"

# ── T_WINDOW — the rate is windowed to the LIVE INITIATIVE's lineage boundary, the
# same window budget-gate.sh sums burn over. The cost-to-complete is ADDED to that
# windowed burn and compared against that initiative's setpoint, so a rate built
# from a PREVIOUS initiative's sessions makes the comparison meaningless. Bank a
# plan-boundary forecast, then seed post-fix landings on both sides of it: only the
# ones at/after the boundary sample.
I7=$(mk_instance); write_tracker "$I7"
( cd "$I7" && bash .claude/projection.sh bank --at plan >/dev/null 2>&1 )
BOUND=$(jq -rs 'map(select(((.kind // "") == "forecast") and ((.boundary // "") == "plan"))) | last | .banked_at' "$I7/.claude/metering/calibration.ndjson" 2>/dev/null)
add_landing_at "$I7" 8.3  9000000 "session-old-1" "2020-01-01T00:00:00Z"
add_landing_at "$I7" 8.3 11000000 "session-old-2" "2020-01-02T00:00:00Z"
add_landing_at "$I7" 8.3  1000000 "session-new-1" "2099-01-01T00:00:00Z"
add_landing_at "$I7" 8.3  3000000 "session-new-2" "2099-01-02T00:00:00Z"
DOC7=$( cd "$I7" && bash .claude/projection.sh project 2>/dev/null )
echo "$DOC7" | jq -e '.basis.n == 2 and .basis.observed_mean_tokens_per_session == 2000000' >/dev/null 2>&1 \
  && ok "[9.1] the rate is windowed to the lineage boundary — pre-boundary sessions (9M/11M) are excluded, only in-window ones sample (n=2, mean 2M)" \
  || no "[9.1] rate must window to the lineage boundary (boundary=$BOUND): expected n=2 mean=2000000, got n=$(echo "$DOC7" | jq -c '.basis.n'), mean=$(echo "$DOC7" | jq -c '.basis.observed_mean_tokens_per_session')"
echo "$DOC7" | jq -e --arg b "$BOUND" '.basis.sample_window == $b' >/dev/null 2>&1 \
  && ok "[9.1] the document DISCLOSES the lineage boundary its samples were windowed to" \
  || no "[9.1] basis.sample_window must name the boundary ($BOUND), got $(echo "$DOC7" | jq -c '.basis.sample_window')"

# ── T_WINDOW_NONE — no calibration record means no boundary to window by (the
# OPENING forecast's own case: the ceiling is being set before anything is banked).
# The designed degradation is to use the whole log — the prior initiatives' post-fix
# sessions are the only signal available and they ARE unit-correct — and to DISCLOSE
# the absence rather than imply a window that was never applied.
I8=$(mk_instance); write_tracker "$I8"
add_landing_at "$I8" 8.3 1000000 "session-a" "2020-01-01T00:00:00Z"
add_landing_at "$I8" 8.3 3000000 "session-b" "2099-01-01T00:00:00Z"
DOC8=$( cd "$I8" && bash .claude/projection.sh project 2>/dev/null )
echo "$DOC8" | jq -e '.basis.n == 2 and .basis.sample_window == null' >/dev/null 2>&1 \
  && ok "[9.1] with no lineage boundary the rate degrades to the whole log and DISCLOSES sample_window:null (never a silent unwindowed read)" \
  || no "[9.1] no-boundary case must read whole log and disclose null: got n=$(echo "$DOC8" | jq -c '.basis.n'), window=$(echo "$DOC8" | jq -c '.basis.sample_window')"
echo "$DOC8" | jq -e '.basis.sample_vintage == "per_response"' >/dev/null 2>&1 \
  && ok "[9.1] the document DISCLOSES the harvest vintage its samples are denominated in" \
  || no "[9.1] basis.sample_vintage must name the vintage, got $(echo "$DOC8" | jq -c '.basis.sample_vintage')"

# ════════════════════════════════════════════════════════════════════════════
# T_MODEL_RECONCILE — [13.3] the modeled rate reconciles with the forensic band
# ════════════════════════════════════════════════════════════════════════════
# meter-forensics (B4) fixed the unit: real per-deliverable throughput ≈ 70–350M/session,
# mean ~150M; occupancy_budget ≈ avg working set ≈ 0.4× the 800k setpoint (~320k). With
# the REAL setpoint the structural occupancy×turns model must land IN that band — the
# calibration is the deliverable's point (a prior that under/over-shoots the forensic
# evidence would be untrustworthy). occ_budget = 800000 × 0.4 = 320000; expected_turns
# 220/470/1090 → structural 70.4M / 150.4M / 348.8M.
MR=$(mk_instance); write_tracker "$MR"
bash "$MR/.claude/estimate.sh" set 9.7 2 "$MR/docs/estimates.json" >/dev/null 2>&1
jq '.occupancy={threshold:800000}' "$MR/.claude/project.json" > "$MR/.claude/project.json.tmp" \
  && mv "$MR/.claude/project.json.tmp" "$MR/.claude/project.json"
MR_DOC=$( cd "$MR" && bash .claude/projection.sh project 2>/dev/null )
# [15.6] the n=0 band TAILS widened to BRACKET the observed per-session envelope
# (~37M–628M) — the central coefficient is UNCHANGED. At the real 800k setpoint
# (occ_budget 320000): turns 115/470/1963 → structural 36.8M / 150.4M / 628.16M, so the
# band brackets the envelope from OUTSIDE (low 36.8M ≤ 37M, high 628.16M ≥ 628M). The
# central (470 turns → 150.4M) is byte-identical to the pre-[15.6] value; only the
# eval/fix tails moved (the low edge down below ~37M, the high edge up above ~628M).
echo "$MR_DOC" | jq -e '
  .spine.unit_rate.occupancy_budget_tokens == 320000
  and .spine.unit_rate.structural_low_tokens  == 36800000
  and .spine.unit_rate.structural_tokens      == 150400000
  and .spine.unit_rate.structural_high_tokens == 628160000' >/dev/null 2>&1 \
  && ok "[15.6] RECONCILE: at the real 800k setpoint the widened band brackets the observed envelope (low 36.8M / central 150.4M / high 628.16M)" \
  || no "[15.6] the modeled structural band must bracket ~37M–628M with central unchanged (got: $(echo "$MR_DOC" | jq -c '.spine.unit_rate'))"
# the central estimate sits inside the forensic 70–350M envelope (the meter's real deltas).
echo "$MR_DOC" | jq -e '.spine.unit_rate.structural_tokens >= 70000000 and .spine.unit_rate.structural_tokens <= 350000000' >/dev/null 2>&1 \
  && ok "[13.3] RECONCILE: the central structural estimate sits inside the forensic 70–350M envelope" \
  || no "[13.3] the central structural estimate must lie in the forensic envelope (got: $(echo "$MR_DOC" | jq -r '.spine.unit_rate.structural_tokens'))"

# ════════════════════════════════════════════════════════════════════════════
# T_BAND_BRACKETS — [15.6] the n=0 band BRACKETS the observed envelope (~37M–628M)
# ════════════════════════════════════════════════════════════════════════════
# The [13.3] band (70.4M–348.8M) under-bracketed the observed per-session envelope:
# real sessions ran as low as ~37M (a tiny clean fix) and as high as ~628M (a
# fix-heavy build), so the modeled band failed to contain the tails it claims to
# model. [15.6] widens the eval/fix TAILS so the n=0 band brackets ~37M–628M — WITHOUT
# changing the load-bearing CENTRAL coefficient (the product that reconciles the
# forensic mean ~150M). This test pins BOTH halves of the acceptance: (1) the band
# brackets the envelope, and (2) the central estimate is byte-unchanged.
BR=$(mk_instance); write_tracker "$BR"
bash "$BR/.claude/estimate.sh" set 9.7 2 "$BR/docs/estimates.json" >/dev/null 2>&1
jq '.occupancy={threshold:800000}' "$BR/.claude/project.json" > "$BR/.claude/project.json.tmp" \
  && mv "$BR/.claude/project.json.tmp" "$BR/.claude/project.json"
BR_DOC=$( cd "$BR" && bash .claude/projection.sh project 2>/dev/null )
# (1) the band brackets the observed envelope: low <= 37M and high >= 628M. The band's
# job is to CONTAIN the observed tails — the pre-[15.6] band (low 70.4M > 37M, high
# 348.8M < 628M) failed both ends; the widened band must contain both.
echo "$BR_DOC" | jq -e '
  .spine.unit_rate.structural_low_tokens  <= 37000000
  and .spine.unit_rate.structural_high_tokens >= 628000000' >/dev/null 2>&1 \
  && ok "[15.6] the n=0 band BRACKETS the observed per-session envelope (low <= 37M, high >= 628M)" \
  || no "[15.6] the band must bracket ~37M–628M (got low=$(echo "$BR_DOC" | jq -r '.spine.unit_rate.structural_low_tokens'), high=$(echo "$BR_DOC" | jq -r '.spine.unit_rate.structural_high_tokens'))"
# (2) the LOAD-BEARING CENTRAL is byte-unchanged: turns_central stays 470 and the
# central structural rate stays 150.4M — the widening moved ONLY the tails. (Pinned
# explicitly so a future tail tweak that drifts the central is caught.)
echo "$BR_DOC" | jq -e '
  .spine.unit_rate.expected_turns.central == 470
  and .spine.unit_rate.structural_tokens == 150400000' >/dev/null 2>&1 \
  && ok "[15.6] the central coefficient is UNCHANGED by the widening (turns_central=470, structural_central=150.4M)" \
  || no "[15.6] the load-bearing central must be byte-unchanged (got turns_central=$(echo "$BR_DOC" | jq -r '.spine.unit_rate.expected_turns.central'), central=$(echo "$BR_DOC" | jq -r '.spine.unit_rate.structural_tokens'))"
# (3) the band still ORDERS (low < central < high) and the central lies strictly
# inside — a widened band is still a coherent band, not an inverted one.
echo "$BR_DOC" | jq -e '
  .spine.unit_rate.structural_low_tokens < .spine.unit_rate.structural_tokens
  and .spine.unit_rate.structural_tokens < .spine.unit_rate.structural_high_tokens' >/dev/null 2>&1 \
  && ok "[15.6] the widened band stays ordered (low < central < high), the central strictly inside" \
  || no "[15.6] the widened band must stay ordered with the central strictly inside (got: $(echo "$BR_DOC" | jq -c '.spine.unit_rate'))"

# ════════════════════════════════════════════════════════════════════════════
# T_BLEND_FROM_MODELED — [13.3] the blend corrects a MEANINGFUL prior, not ≈0
# ════════════════════════════════════════════════════════════════════════════
# Pre-[13.3] the structural prior was the doc-overhead floor (~10k tokens), orders of
# magnitude below real throughput — so at n=0 the central estimate was a bare lower bound
# and the blend had to drag it up from ≈0 over many landings. [13.3] makes the prior a
# real occupancy×turns central estimate (throughput scale), so the n/(n+K) blend now
# CORRECTS a sensible start: blended_central lies strictly BETWEEN the modeled prior and
# the observed mean — converging from a meaningful anchor rather than from ≈0.
BM=$(mk_instance); write_tracker "$BM"
bash "$BM/.claude/estimate.sh" set 9.7 2 "$BM/docs/estimates.json" >/dev/null 2>&1
bash "$BM/.claude/estimate.sh" set 9.8 3 "$BM/docs/estimates.json" >/dev/null 2>&1
BM_STRUCT=$( cd "$BM" && bash .claude/projection.sh project 2>/dev/null )
BM_PRIOR=$(echo "$BM_STRUCT" | jq -r '.spine.unit_rate.structural_tokens')
# the n=0 prior is at THROUGHPUT scale (millions), not the near-zero doc floor — a real
# central estimate, the heart of [13.3].
awk -v p="$BM_PRIOR" 'BEGIN{ exit !(p >= 1000000) }' \
  && ok "[13.3] the n=0 structural prior is a real central estimate at throughput scale (≥1M), not the ≈0 floor" \
  || no "[13.3] the n=0 prior must be a throughput-scale central estimate (got structural_tokens=$BM_PRIOR)"
# observed landings ABOVE the modeled prior — the blend must correct toward them, landing
# strictly BETWEEN the prior and the observed mean (a correction, not a replacement).
add_landing "$BM" 9.1 100000000
add_landing "$BM" 9.1 100000000
add_landing "$BM" 9.1 100000000
BM_BLEND=$( cd "$BM" && bash .claude/projection.sh project 2>/dev/null )
BM_CENT=$(echo "$BM_BLEND" | jq -r '.spine.unit_rate.blended_tokens')
BM_OBS=$(echo "$BM_BLEND" | jq -r '.basis.observed_mean_tokens_per_session')
awk -v c="$BM_CENT" -v p="$BM_PRIOR" -v o="$BM_OBS" 'BEGIN{ exit !(c > p && c < o) }' \
  && ok "[13.3] the blend corrects the modeled prior: blended_central lies BETWEEN the prior and observed mean" \
  || no "[13.3] blended central must sit between the modeled prior and observed mean (prior=$BM_PRIOR blended=$BM_CENT observed=$BM_OBS)"

# ════════════════════════════════════════════════════════════════════════════
# T_BANK_AT — [13.4] banking at a named boundary is idempotent (no double-bank)
# ════════════════════════════════════════════════════════════════════════════
# [13.4] auto-banks the projection at lifecycle boundaries (/plan, each phase
# boundary, initiative close). Re-running a boundary — re-invoking /plan, or
# re-running a phase-completion handoff — must NOT append a second forecast for
# that boundary, or the lineage would carry duplicates and a re-run would inflate
# the record. The boundary identity (`--at <token>`) is the idempotency key:
# append-only (a prior boundary's line is never rewritten) AND idempotent on the
# boundary (re-banking the SAME boundary is a no-op). A DIFFERENT boundary still
# appends — that is the lineage accruing.
BA=$(mk_instance); write_tracker "$BA"
bash "$BA/.claude/estimate.sh" set 9.7 2 "$BA/docs/estimates.json" >/dev/null 2>&1
BA_CALIB="$BA/.claude/metering/calibration.ndjson"
( cd "$BA" && bash .claude/projection.sh bank --at phase-9 ) >/dev/null 2>&1
# the forecast records the boundary it was banked at (the lineage tag).
BA_N1=$(jq -s '[ .[] | select(.kind=="forecast" and .boundary=="phase-9") ] | length' "$BA_CALIB" 2>/dev/null)
[ "$BA_N1" = "1" ] \
  && ok "BANK --at: a boundary bank records its boundary tag and appends ONE forecast" \
  || no "bank --at must tag the forecast with its boundary and append once (phase-9 lines=$BA_N1)"
# idempotent: re-banking the SAME boundary does not append a second line.
( cd "$BA" && bash .claude/projection.sh bank --at phase-9 ) >/dev/null 2>&1
BA_N2=$(jq -s '[ .[] | select(.kind=="forecast" and .boundary=="phase-9") ] | length' "$BA_CALIB" 2>/dev/null)
[ "$BA_N2" = "1" ] \
  && ok "BANK --at: re-banking the SAME boundary is a no-op (idempotent — no double-bank)" \
  || no "re-banking the same boundary must not double-bank (phase-9 lines after re-run=$BA_N2)"
# idempotent bank exits 0 (a no-op is success, not an error) so a re-run never fails the ceremony.
BA_RC=$( cd "$BA" && bash .claude/projection.sh bank --at phase-9 >/dev/null 2>&1; echo $? )
[ "$BA_RC" = "0" ] \
  && ok "BANK --at: the idempotent no-op exits 0 (a re-run never fails the lifecycle step)" \
  || no "an idempotent re-bank must exit 0 (got rc=$BA_RC)"
# a DIFFERENT boundary appends — the lineage accrues.
( cd "$BA" && bash .claude/projection.sh bank --at phase-10 ) >/dev/null 2>&1
BA_TOT=$(jq -s '[ .[] | select(.kind=="forecast") ] | length' "$BA_CALIB" 2>/dev/null)
[ "$BA_TOT" = "2" ] \
  && ok "BANK --at: a DIFFERENT boundary appends — the forecast lineage accrues" \
  || no "a different boundary must append a new forecast (total forecasts=$BA_TOT)"

# ════════════════════════════════════════════════════════════════════════════
# T_LINEAGE_GRADE — [13.4] the close-time grade reads the OPENING forecast lineage
# ════════════════════════════════════════════════════════════════════════════
# The calibration record accrues a forecast lineage (one per boundary). At
# initiative close the grade reads it — and grades the OPENING (plan-boundary)
# forecast, whose scope was the whole remaining initiative, because that is the
# forecast a close-time grade honestly grades ("how good was the plan?"), not the
# last phase-boundary snapshot (closest to actual, least informative). The grade
# NAMES which lineage entry it read (graded_forecast.boundary), so "the grade
# reads the lineage" is verifiable, not asserted.
LG=$(mk_instance); write_tracker "$LG"
# Make the two forecasts DISTINGUISHABLE by their takeoff, so the grade's
# estimated_sessions proves WHICH forecast was graded — not just its label (Rule 8:
# verify the consequence, not the tag). Plan-time: all three open (9.7,9.8,9.9) with
# estimates 2+3+1(default) = remaining_sessions 6. Phase-boundary (below): only 9.9
# open = remaining_sessions 1. The two takeoffs (6 vs 1) are the discriminator.
bash "$LG/.claude/estimate.sh" set 9.7 2 "$LG/docs/estimates.json" >/dev/null 2>&1
bash "$LG/.claude/estimate.sh" set 9.8 3 "$LG/docs/estimates.json" >/dev/null 2>&1
LG_CALIB="$LG/.claude/metering/calibration.ndjson"
( cd "$LG" && bash .claude/projection.sh bank --at plan ) >/dev/null 2>&1          # opening forecast (takeoff 6)
# advance to the phase boundary: 9.7 + 9.8 land, leaving only 9.9 open, so the
# phase-9 forecast's takeoff is 1 — distinct from the plan-time 6.
cat > "$LG/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 9 — The Meter**

## Phase 9 — The Meter

_Goal: meter cost at every boundary._

- ✅ **[9.1]** Session-boundary cost capture `[deps: none]`
- ✅ **[9.7]** Projection `[deps: 9.1]`
- ✅ **[9.8]** A ready deliverable `[deps: 9.1]`
- ⬜ **[9.9]** A blocked deliverable `[deps: 9.8]`
MD
( cd "$LG" && bash .claude/projection.sh bank --at phase-9 ) >/dev/null 2>&1       # later forecast (takeoff 1)
LG_NF=$(jq -s '[ .[] | select(.kind=="forecast") | .boundary ] | unique | length' "$LG_CALIB" 2>/dev/null)
[ "$LG_NF" = "2" ] \
  && ok "LINEAGE: the calibration record accrues a forecast per boundary (plan + phase-9)" \
  || no "the lineage must accrue one forecast per distinct boundary (distinct boundaries=$LG_NF)"
LGGRADE=$( cd "$LG" && bash .claude/projection.sh grade 2>/dev/null )
# CONSEQUENCE, not label: grade's estimated_sessions is the PLAN-time takeoff (6),
# not the phase-boundary takeoff (1) — proof it read+graded the OPENING forecast,
# whose scope was the whole initiative. A wrong selection (the latest) would read 1.
echo "$LGGRADE" | jq -e '.graded_forecast.boundary == "plan" and .quantity_error.estimated_sessions == 6' >/dev/null 2>&1 \
  && ok "GRADE: reads+grades the OPENING (plan) forecast — estimated_sessions is the plan-time takeoff (6), not the phase-9 takeoff (1)" \
  || no "grade must grade the plan forecast's takeoff, not a later boundary's (got: $(echo "$LGGRADE" | jq -c '{boundary:.graded_forecast.boundary, est:.quantity_error.estimated_sessions}'))"
# the two-layer error structure is unchanged (regression guard over the lineage read).
echo "$LGGRADE" | jq -e 'has("quantity_error") and has("rate_error")' >/dev/null 2>&1 \
  && ok "GRADE: reading the lineage preserves the two-layer error structure (quantity + rate)" \
  || no "grade over a lineage must still emit quantity_error and rate_error (got: $(echo "$LGGRADE" | jq -c 'keys'))"

# ════════════════════════════════════════════════════════════════════════════
# T_GRADE_DEGRADE — [13.4] no plan forecast → grade degrades to the LATEST, names it
# ════════════════════════════════════════════════════════════════════════════
# The realistic inaugural-initiative state: only phase boundaries were banked, no
# `plan` forecast (a pre-[13.4] project, or one whose opening forecast predates the
# wiring). grade must DEGRADE to the most recent forecast and NAME it — a designed
# fallback (Rule 15), not a die. Two phase forecasts, no plan → grade reads phase-7.
DG=$(mk_instance); write_tracker "$DG"
bash "$DG/.claude/estimate.sh" set 9.7 2 "$DG/docs/estimates.json" >/dev/null 2>&1
( cd "$DG" && bash .claude/projection.sh bank --at phase-6 ) >/dev/null 2>&1
( cd "$DG" && bash .claude/projection.sh bank --at phase-7 ) >/dev/null 2>&1
DGGRADE=$( cd "$DG" && bash .claude/projection.sh grade 2>/dev/null )
echo "$DGGRADE" | jq -e '.graded_forecast.boundary == "phase-7"' >/dev/null 2>&1 \
  && ok "GRADE DEGRADE: with no plan forecast, grade reads the LATEST boundary forecast and names it (phase-7)" \
  || no "grade must degrade to the most recent forecast when no plan forecast exists (got: $(echo "$DGGRADE" | jq -c '.graded_forecast'))"

# ════════════════════════════════════════════════════════════════════════════
# T_AT_NOVALUE — [13.4] a value-less --at fails loud, never spins (Rule 15)
# ════════════════════════════════════════════════════════════════════════════
# A bare `shift 2` on a single remaining positional leaves it in place — an infinite
# loop. A value-less trailing flag must be a loud usage error (exit 2), not a silent
# hang (the worst Rule-15 failure: neither a designed degradation nor a loud stop).
NV=$(mk_instance); write_tracker "$NV"
NV_RC=$( cd "$NV" && bash .claude/projection.sh bank --at >/dev/null 2>&1; echo $? )
[ "$NV_RC" = "2" ] \
  && ok "ARG: a value-less trailing --at fails loud (exit 2), never spins (Rule 15)" \
  || no "bank --at with no value must exit 2, not hang or succeed (got rc=$NV_RC)"
# the guard is ONE alternation over every value-taking flag, not an --at special-case
# — pin a sibling so a future split that drops a flag is caught (the pattern was the
# pre-existing hang [13.4] fixed wholesale).
NV_RC2=$( cd "$NV" && bash .claude/projection.sh project --root >/dev/null 2>&1; echo $? )
[ "$NV_RC2" = "2" ] \
  && ok "ARG: the value-less guard covers every value flag (a sibling --root also exits 2)" \
  || no "the shared value-guard must cover all flags, not just --at (project --root rc=$NV_RC2)"

# ════════════════════════════════════════════════════════════════════════════
# T_BANK_AT_REOPEN — [13.4] a grade (initiative close) reopens the dedup window
# ════════════════════════════════════════════════════════════════════════════
# The calibration record accumulates across initiatives (append-only). Idempotency
# is scoped to THIS initiative — a grade line marks a close — so a NEW initiative's
# `--at plan` must re-bank, not silently no-op against the predecessor's `plan`
# forecast still in the ledger. Without this scoping the second initiative would
# have NO opening forecast (a silent drop). Sequence: bank plan → grade (close) →
# bank plan again must APPEND.
RO=$(mk_instance); write_tracker "$RO"
bash "$RO/.claude/estimate.sh" set 9.7 2 "$RO/docs/estimates.json" >/dev/null 2>&1
RO_CALIB="$RO/.claude/metering/calibration.ndjson"
( cd "$RO" && bash .claude/projection.sh bank --at plan ) >/dev/null 2>&1   # initiative 1 opens
( cd "$RO" && bash .claude/projection.sh grade )          >/dev/null 2>&1   # initiative 1 closes (grade line)
( cd "$RO" && bash .claude/projection.sh bank --at plan ) >/dev/null 2>&1   # initiative 2 opens — must re-bank
RO_PLANS=$(jq -s '[ .[] | select(.kind=="forecast" and .boundary=="plan") ] | length' "$RO_CALIB" 2>/dev/null)
[ "$RO_PLANS" = "2" ] \
  && ok "REOPEN: a grade (close) reopens the window — a new initiative re-banks --at plan (no silent drop)" \
  || no "a grade must reopen the dedup window so the next initiative re-banks (plan forecasts=$RO_PLANS, expected 2)"

# ════════════════════════════════════════════════════════════════════════════
# T_WIRING — [13.4] the lifecycle banks/grades through the engine (no manual call)
# ════════════════════════════════════════════════════════════════════════════
# The wiring lives in the skill procedures (the meter.sh-capture convention): the
# bank/grade calls are documented steps the skill runs, not a manual invocation.
# This guards that the three boundaries are wired — /plan banks the opening
# forecast and grades the closing initiative; /handoff banks at the phase
# boundary — so the engine is actually reached by the lifecycle, not just present.
PLAN_SKILL="$CLAUDE_DIR/skills/plan/SKILL.md"
HANDOFF_SKILL="$CLAUDE_DIR/skills/handoff/SKILL.md"
INIT_SKILL="$CLAUDE_DIR/skills/init/SKILL.md"
{ [ -f "$PLAN_SKILL" ] && grep -qE 'projection\.sh bank --at plan' "$PLAN_SKILL"; } \
  && ok "WIRING: /plan banks the opening forecast (projection.sh bank --at plan)" \
  || no "the /plan skill must wire the opening-forecast bank (projection.sh bank --at plan)"
{ [ -f "$INIT_SKILL" ] && grep -qE 'projection\.sh bank --at plan' "$INIT_SKILL"; } \
  && ok "WIRING: /init banks the greenfield opening forecast (projection.sh bank --at plan)" \
  || no "the /init skill must wire the greenfield opening-forecast bank (projection.sh bank --at plan)"
{ [ -f "$PLAN_SKILL" ] && grep -qE 'projection\.sh grade' "$PLAN_SKILL"; } \
  && ok "WIRING: /plan grades the closing initiative at archive (projection.sh grade)" \
  || no "the /plan skill must wire the close-time grade (projection.sh grade) before archival"
{ [ -f "$HANDOFF_SKILL" ] && grep -qE 'projection\.sh bank --at phase' "$HANDOFF_SKILL"; } \
  && ok "WIRING: /handoff banks at the phase boundary (projection.sh bank --at phase-<N>)" \
  || no "the /handoff phase-completion path must wire the boundary bank (projection.sh bank --at phase-<N>)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
