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

# [12.1] throughput-native: the structural unit rate is the MEASURED floor (a true
# lower bound on a session's THROUGHPUT). The occupancy threshold is emitted only
# as an informational reference, NEVER as the cost ceiling (occupancy is a
# point-in-time stock; cost-to-complete is cumulative throughput).
echo "$DOC" | jq -e '.spine.unit_rate.floor_tokens > 0 and (.spine.unit_rate.occupancy_reference_tokens|type=="number")' >/dev/null 2>&1 \
  && ok "unit rate is the measured floor; occupancy is an informational reference, not the cost ceiling" \
  || no "the unit rate must carry a positive floor + an informational occupancy reference (got: $(echo "$DOC" | jq -c '.spine.unit_rate'))"

# [12.1] n=0: with NO throughput history the projection is a floor-anchored LOWER
# BOUND — the band is a point at remaining × floor (low == high), and the basis
# discloses it has no observed throughput ceiling yet (no occupancy ceiling
# masquerading as a cost ceiling, no fabricated turn-count multiplier).
echo "$DOC" | jq -e '
  (.spine.quantity.remaining_sessions * .spine.unit_rate.floor_tokens) == .range.low_tokens
  and .range.low_tokens == .range.high_tokens' >/dev/null 2>&1 \
  && ok "n=0: the range is a floor-anchored lower bound (low==high==remaining×floor)" \
  || no "n=0 range must be a point at remaining×floor (got range=$(echo "$DOC" | jq -c '.range'), floor=$(echo "$DOC" | jq -r '.spine.unit_rate.floor_tokens'))"
echo "$DOC" | jq -e '.basis.bound == "lower_bound_only"' >/dev/null 2>&1 \
  && ok "n=0: the basis discloses a lower-bound-only claim (no observed throughput ceiling yet)" \
  || no "n=0 basis.bound must be \"lower_bound_only\" (got: $(echo "$DOC" | jq -c '.basis'))"

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
STRUCT_RATE=$(echo "$STRUCT" | jq -r '.spine.unit_rate.floor_tokens')

# three landings at a LOW observed burn (well under the structural floor)
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

# The blended effective rate sits BELOW the structural floor (it moved toward the
# low observed rate) but ABOVE the raw observed rate (the structure still pulls).
BLEND_RATE=$(echo "$BLEND" | jq -r '.spine.unit_rate.blended_tokens')
awk -v b="$BLEND_RATE" -v s="$STRUCT_RATE" 'BEGIN{ exit !(b < s) }' \
  && ok "blended rate moved BELOW the structural floor toward the low observed rate" \
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
HB_HIGH0=$(echo "$HB_STRUCT" | jq -r '.range.high_tokens')   # n=0 structural high = remaining×floor
# three landings whose per-session burn dwarfs the ceiling (throughput scale),
# varying so observed min<mean<max (a real band, not a degenerate point).
add_landing "$HB" 9.1 4000000
add_landing "$HB" 9.1 6000000
add_landing "$HB" 9.1 5000000
HB_DOC=$( cd "$HB" && bash .claude/projection.sh project 2>/dev/null )
HB_HIGH=$(echo "$HB_DOC" | jq -r '.range.high_tokens')
awk -v a="$HB_HIGH" -v b="$HB_HIGH0" 'BEGIN{ exit !(a > b) }' \
  && ok "BAND: observed burn above the floor RAISES the range high edge (it tracks throughput, not the occupancy stock)" \
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
# [12.1] at n=0 BOTH emitted blended edges equal the floor — the band is a
# floor-anchored lower-bound point, the occupancy ceiling is retired from the
# cost path (it no longer forms the high edge).
echo "$HB_STRUCT" | jq -e '.spine.unit_rate.blended_low_tokens == .spine.unit_rate.floor_tokens
  and .spine.unit_rate.blended_high_tokens == .spine.unit_rate.floor_tokens' >/dev/null 2>&1 \
  && ok "BAND: at n=0 BOTH blended edges equal the floor (lower-bound point; no occupancy ceiling in the band)" \
  || no "n=0 blended edges must both equal the floor (got: $(echo "$HB_STRUCT" | jq -c '.spine.unit_rate'))"

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
fi

# ════════════════════════════════════════════════════════════════════════════
# T_OCCUPANCY_INFORMATIONAL — [12.1] occupancy no longer clamps the floor
# ════════════════════════════════════════════════════════════════════════════
# Pre-[12.1] the envelope floor was "bounded above by the occupancy threshold" and
# clamped to it, because the band ran floor..ceiling. [12.1] retires occupancy from
# the cost path: the floor is the MEASURED throughput lower bound and stands on its
# own; the occupancy threshold is informational only. So a LOW occupancy setpoint
# must NOT cap the measured floor, and the range still never inverts (both edges
# anchor on the floor).
I=$(mk_instance); write_tracker "$I"
bash "$I/.claude/estimate.sh" set 9.7 2 "$I/docs/estimates.json" >/dev/null 2>&1
# A tiny occupancy.threshold setpoint, BELOW the ~10k measured floor (40k chars of
# docs mk_instance plants): pre-[12.1] this would have clamped the floor to 3000.
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
