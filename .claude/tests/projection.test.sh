#!/bin/bash
# Tests for .claude/projection.sh — observed-rate × sized-remaining ([9.7], cut at [32.4]).
#
# Invariant (post-[32.4]): the projection is ARITHMETIC over the local record —
# observed per-session rate (post-epoch per_response bounded slices, windowed to
# the [13.4] lineage) × sized-remaining (the [13.2] light/medium/heavy fraction
# as the multiplier over the resolver's open set). No modeled band, no blend, no
# occupancy factor: at n=0 the rate and forecast are HONEST NULLS, disclosed —
# never a structural fallback. `bank` appends the forecast to the append-only
# calibration record (idempotent per boundary per initiative) and stamps the
# session-record position (banked_session); `grade` compares the opening
# forecast against the outcome with a quantity denominator read from the
# SESSION RECORD (docs/sessions/ artifacts — unmetered sessions still count;
# [28.1]'s restored clause), degrading to the metered count only for a legacy
# forecast, disclosed. Only local inputs — never another project's history.
#
# Pure bash + jq, no test runner. Stderr-clean for well-formed input.
# Run: bash .claude/tests/projection.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJ="$ROOT/.claude/projection.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A throwaway project: manifest, tracker with open deliverables, sidecar,
# session artifacts, metering log. Callers append log/calibration lines and
# sidecar entries per case. Echoes the dir.
mk_project() {
  local d; d=$(mktemp -d "$WORK/proj.XXXXXX")
  mkdir -p "$d/.claude/metering" "$d/docs/sessions"
  jq -nc '{name:"x",language:"shell",roots:{control:".",code:"."},commands:{},scaffoldCheck:"true",ceremony:"phased"}' \
    > "$d/.claude/project.json"
  cat > "$d/docs/PHASE_STATUS.md" <<'MD'
# Phase Status

## Phase 9 — Test

_Goal: fixtures._

- ⬜ **[9.1]** first open thing `[deps: none]`
- ⬜ **[9.2]** second open thing `[deps: none]`
- ✅ **[9.3]** a done thing `[deps: none]`
MD
  printf '# handoff\n' > "$d/docs/sessions/session-2026-06-10-001.md"
  echo "$d"
}

# One per_response bounded-slice log entry. mk_entry <dir> <ts> <session> <burn>
mk_entry() {
  jq -nc --arg ts "$2" --arg s "$3" --argjson t "$4" \
    '{schema:"guv.meter.v1",ts:$ts,session:$s,deliverable_ids:["9.1"],tokens:{input:$t,output:0,cache_read:0,cache_creation:0},slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}' \
    >> "$1/.claude/metering/metering.ndjson"
}

run() { local d="$1"; shift; (cd "$d" && bash "$PROJ" "$@" 2>/dev/null); }

# ── P0 — exists; usage discipline ────────────────────────────────────────────
echo "P0: existence and usage"
[ -f "$PROJ" ] && ok "projection.sh exists" || no "projection.sh missing"
D=$(mk_project)
run "$D" sideways >/dev/null; RC=$?
[ "$RC" -eq 2 ] && ok "unknown subcommand exits 2" || no "unknown subcommand rc=$RC"
(cd "$D" && bash "$PROJ" bank --at >/dev/null 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "value-less trailing --at fails loud, never spins" || no "bare --at rc=$RC"

# ── P1 — n=0 is an honest null, not a modeled fallback ───────────────────────
echo "P1: no samples → null rate, null forecast, disclosed"
D=$(mk_project)
OUT=$(run "$D" project); RC=$?
[ "$RC" -eq 0 ] && ok "project exits 0 at n=0" || no "project rc=$RC at n=0"
echo "$OUT" | jq -e '.schema == "guv.projection.v2"' >/dev/null \
  && ok "schema is guv.projection.v2" || no "schema wrong: $(echo "$OUT" | jq -r .schema)"
echo "$OUT" | jq -e '.rate == null and .forecast == null' >/dev/null \
  && ok "rate and forecast are null at n=0 — no structural band" \
  || no "n=0 not honest-null: $OUT"
echo "$OUT" | jq -e '.quantity.sized_remaining != null' >/dev/null \
  && ok "quantity still computed at n=0 (the takeoff is local arithmetic)" \
  || no "quantity missing at n=0"

# ── P2 — the rate's selection rule ───────────────────────────────────────────
echo "P2: only post-epoch per_response bounded slices are samples"
D=$(mk_project)
{
  # pre-epoch entry (huge — leaks would be visible), then the epoch line
  jq -nc '{schema:"guv.meter.v1",ts:"2026-06-01T00:00:00Z",session:"session-2026-06-01-001",deliverable_ids:["9.1"],tokens:{input:999999999,output:0,cache_read:0,cache_creation:0},slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
  jq -nc '{schema:"guv.meter.epoch.v1",ts:"2026-06-05T00:00:00Z",harvest:"per_response",denomination:"raw_tokens",coverage:"main_session"}'
} >> "$D/.claude/metering/metering.ndjson"
mk_entry "$D" "2026-06-10T00:00:00Z" "session-2026-06-10-001" 100
mk_entry "$D" "2026-06-11T00:00:00Z" "session-2026-06-11-001" 300
# non-samples: unbounded_cumulative, tokens null, degraded harvest_basis null
jq -nc '{schema:"guv.meter.v1",ts:"2026-06-12T00:00:00Z",session:"session-2026-06-12-001",deliverable_ids:["9.1"],tokens:{input:555555,output:0,cache_read:0,cache_creation:0},slice_basis:"unbounded_cumulative",harvest_basis:"per_response",perf:{}}' \
  >> "$D/.claude/metering/metering.ndjson"
jq -nc '{schema:"guv.meter.v1",ts:"2026-06-12T01:00:00Z",session:"session-2026-06-12-001",deliverable_ids:["9.1"],tokens:{input:444444,output:0,cache_read:0,cache_creation:0},slice_basis:"per_deliverable",harvest_basis:null,perf:{}}' \
  >> "$D/.claude/metering/metering.ndjson"
OUT=$(run "$D" project)
echo "$OUT" | jq -e '.rate.n == 2 and .rate.mean == 200 and .rate.min == 100 and .rate.max == 300' >/dev/null \
  && ok "rate = n2 mean200 min100 max300 — pre-epoch and degraded entries are not samples" \
  || no "rate selection wrong: $(echo "$OUT" | jq -c .rate)"

# ── P3 — the lineage window bounds the sample set ────────────────────────────
echo "P3: samples window to the live initiative"
jq -nc '{kind:"forecast",boundary:"plan",banked_at:"2026-06-11T00:00:00Z"}' \
  > "$D/.claude/metering/calibration.ndjson"
OUT=$(run "$D" project)
echo "$OUT" | jq -e '.rate.n == 1 and .rate.mean == 300' >/dev/null \
  && ok "entries before the plan bank are not samples" \
  || no "lineage window wrong: $(echo "$OUT" | jq -c .rate)"
echo "$OUT" | jq -e '.basis.sample_window == "2026-06-11T00:00:00Z"' >/dev/null \
  && ok "the window is disclosed in the document" \
  || no "sample_window not disclosed"

# ── P4 — sized-remaining: the class fraction is the multiplier ([28.1]) ──────
echo "P4: two class mixes forecast differently"
DA=$(mk_project); DB=$(mk_project)
for d in "$DA" "$DB"; do mk_entry "$d" "2026-06-10T00:00:00Z" "session-2026-06-10-001" 1000; done
jq -n '{"9.1":{sessions:1,fraction:0.35,size:"light"},"9.2":{sessions:1,fraction:0.35,size:"light"}}' > "$DA/docs/estimates.json"
jq -n '{"9.1":{sessions:1,fraction:0.9,size:"heavy"},"9.2":{sessions:1,fraction:0.9,size:"heavy"}}' > "$DB/docs/estimates.json"
CA=$(run "$DA" project | jq -r '.forecast.central')
CB=$(run "$DB" project | jq -r '.forecast.central')
[ "$CA" = "700" ] && [ "$CB" = "1800" ] \
  && ok "all-light forecasts 700, all-heavy 1800 (rate 1000 × Σ sessions×fraction)" \
  || no "class mixes wrong: light=$CA heavy=$CB"

# ── P5 — unsized ids default to fraction 1.0, disclosed ──────────────────────
echo "P5: defaults are disclosed, never silent"
D=$(mk_project)
mk_entry "$D" "2026-06-10T00:00:00Z" "session-2026-06-10-001" 1000
jq -n '{"9.1":{sessions:1,fraction:0.5,size:"medium"}}' > "$D/docs/estimates.json"
OUT=$(run "$D" project)
echo "$OUT" | jq -e '.quantity.sized_remaining == 1.5' >/dev/null \
  && ok "unsized [9.2] contributes sessions×1.0 beside sized [9.1]×0.5" \
  || no "sized_remaining wrong: $(echo "$OUT" | jq -c .quantity)"
echo "$OUT" | jq -e '.quantity.defaulted_ids == ["9.2"]' >/dev/null \
  && ok "the defaulted id is disclosed" \
  || no "defaulted_ids wrong: $(echo "$OUT" | jq -c .quantity)"
# a legacy integer estimate: N sessions × fraction 1.0, also disclosed
jq -n '{"9.1":{sessions:1,fraction:0.5,size:"medium"},"9.2":3}' > "$D/docs/estimates.json"
OUT=$(run "$D" project)
echo "$OUT" | jq -e '.quantity.sized_remaining == 3.5 and .quantity.defaulted_ids == ["9.2"]' >/dev/null \
  && ok "a legacy integer projects N×1.0 and is disclosed as unsized" \
  || no "legacy integer wrong: $(echo "$OUT" | jq -c .quantity)"

# ── P6 — the forecast range is min/max × sized-remaining ─────────────────────
echo "P6: forecast arithmetic"
D=$(mk_project)
mk_entry "$D" "2026-06-10T00:00:00Z" "session-2026-06-10-001" 100
mk_entry "$D" "2026-06-11T00:00:00Z" "session-2026-06-11-001" 300
jq -n '{"9.1":{sessions:1,fraction:0.5,size:"medium"},"9.2":{sessions:1,fraction:0.5,size:"medium"}}' > "$D/docs/estimates.json"
OUT=$(run "$D" project)
echo "$OUT" | jq -e '.forecast.central == 200 and .forecast.low == 100 and .forecast.high == 300 and .forecast.denomination == "tokens"' >/dev/null \
  && ok "central/low/high = mean/min/max × 1.0 sized-remaining" \
  || no "forecast arithmetic wrong: $(echo "$OUT" | jq -c .forecast)"

# ── P7 — bank: append-only, stamped with the session-record position ─────────
echo "P7: bank appends and stamps"
run "$D" bank --at plan >/dev/null; RC=$?
[ "$RC" -eq 0 ] && [ -f "$D/.claude/metering/calibration.ndjson" ] \
  && ok "bank writes the calibration record" || no "bank failed (rc=$RC)"
L1=$(tail -1 "$D/.claude/metering/calibration.ndjson")
echo "$L1" | jq -e '.kind == "forecast" and .boundary == "plan" and .banked_session == "session-2026-06-10-001"' >/dev/null \
  && ok "the banked line carries kind, boundary, and banked_session" \
  || no "banked line wrong: $L1"
BEFORE=$(cat "$D/.claude/metering/calibration.ndjson")
run "$D" bank --at phase-9 >/dev/null
head -1 "$D/.claude/metering/calibration.ndjson" | grep -qF "$L1" \
  && ok "a second bank appends — prior lines byte-identical" \
  || no "append-only violated"

# ── P8 — bank idempotency per boundary, reopened by a grade ──────────────────
echo "P8: idempotency and the grade reopening"
N1=$(grep -c . "$D/.claude/metering/calibration.ndjson")
run "$D" bank --at plan >/dev/null
N2=$(grep -c . "$D/.claude/metering/calibration.ndjson")
[ "$N1" = "$N2" ] && ok "re-banking the same boundary is a no-op" || no "double-banked ($N1 -> $N2)"
run "$D" grade >/dev/null
run "$D" bank --at plan >/dev/null
N3=$(grep -c . "$D/.claude/metering/calibration.ndjson")
[ "$N3" -eq $((N2 + 2)) ] && ok "a grade reopens the dedup window for a fresh initiative" \
  || no "grade did not reopen ($N2 -> $N3)"

# ── P8b — a torn calibration line drops alone ────────────────────────────────
# A strict slurp here would (a) disable the dedup — every re-run double-banks a
# plan forecast, corrupting the [13.4] lineage both consumers window burn by —
# and (b) make grade die "no banked forecast" over a record full of valid ones.
echo "P8b: torn calibration lines never disable dedup or grade"
printf '{"kind":"forecast","boundary":"pl\n' >> "$D/.claude/metering/calibration.ndjson"
N4=$(grep -c . "$D/.claude/metering/calibration.ndjson")
run "$D" bank --at plan >/dev/null
N5=$(grep -c . "$D/.claude/metering/calibration.ndjson")
[ "$N4" = "$N5" ] \
  && ok "bank dedup survives a torn calibration line (no double-bank)" \
  || no "torn line disabled dedup ($N4 -> $N5)"
G8=$(run "$D" grade); RC=$?
[ "$RC" -eq 0 ] && echo "$G8" | jq -e '.graded_forecast.boundary == "plan"' >/dev/null \
  && ok "grade still reads the plan forecast past a torn line" \
  || no "grade broke on a torn calibration line (rc=$RC): $G8"

# ── P9 — grade reads the opening forecast, denominator from the record ───────
echo "P9: the grade's two errors and the session-record denominator"
D=$(mk_project)
mk_entry "$D" "2026-06-10T00:00:00Z" "session-2026-06-10-001" 1000
# A banked v2 forecast with a PINNED banked_at (P7 proves the live bank emits
# this shape; a real bank would stamp the wall clock and orphan these fixtures).
jq -nc '{kind:"forecast",banked_at:"2026-06-11T00:00:00Z",boundary:"plan",banked_session:"session-2026-06-10-001",schema:"guv.projection.v2",rate:{n:1,mean:1000,min:1000,max:1000},quantity:{sized_remaining:1,defaulted_ids:[]}}' \
  > "$D/.claude/metering/calibration.ndjson"
# Post-bank: TWO metered sessions but FOUR session artifacts — the record is
# bigger than the meter's coverage, and the denominator must follow the record.
mk_entry "$D" "2026-06-12T00:00:00Z" "session-2026-06-12-001" 400
mk_entry "$D" "2026-06-13T00:00:00Z" "session-2026-06-13-001" 600
for s in session-2026-06-12-001 session-2026-06-13-001 session-2026-06-14-001 session-2026-06-15-001; do
  printf '# handoff\n' > "$D/docs/sessions/$s.md"
done
G=$(run "$D" grade)
echo "$G" | jq -e '.quantity_error.actual_sessions == 4' >/dev/null \
  && ok "the denominator reflects the session record (4), not the meter's coverage (2)" \
  || no "denominator wrong: $(echo "$G" | jq -c .quantity_error)"
echo "$G" | jq -e '.quantity_error.denominator_source == "session_record"' >/dev/null \
  && ok "the denominator source is disclosed" \
  || no "denominator_source missing: $G"
echo "$G" | jq -e '.quantity_error.estimated_session_equivalents == 1' >/dev/null \
  && ok "the estimated side is the banked sized-remaining" \
  || no "estimated side wrong: $(echo "$G" | jq -c .quantity_error)"
echo "$G" | jq -e '.rate_error.actual_tokens_per_session == 500 and .rate_error.forecast_tokens_per_session == 1000' >/dev/null \
  && ok "rate error compares the banked mean to post-bank mean (500 vs 1000)" \
  || no "rate error wrong: $(echo "$G" | jq -c .rate_error)"
echo "$G" | jq -e '.graded_forecast.boundary == "plan"' >/dev/null \
  && ok "the grade names the lineage entry it read" || no "graded_forecast missing"

# ── P10 — a legacy v1 forecast still grades, degradation disclosed ───────────
echo "P10: legacy v1 forecasts grade via the spine fallbacks"
D=$(mk_project)
mk_entry "$D" "2026-06-12T00:00:00Z" "session-2026-06-12-001" 400
jq -nc '{kind:"forecast",boundary:"plan",banked_at:"2026-06-11T00:00:00Z",schema:"guv.projection.v1",spine:{quantity:{remaining_sessions:3},unit_rate:{blended_tokens:900}}}' \
  > "$D/.claude/metering/calibration.ndjson"
G=$(run "$D" grade); RC=$?
[ "$RC" -eq 0 ] \
  && echo "$G" | jq -e '.quantity_error.estimated_session_equivalents == 3 and .rate_error.forecast_tokens_per_session == 900' >/dev/null \
  && ok "v1 spine fields are read as the estimate" \
  || no "legacy grade wrong (rc=$RC): $G"
echo "$G" | jq -e '.quantity_error.denominator_source == "metering_log"' >/dev/null \
  && ok "a forecast with no banked_session degrades to the metered count, disclosed" \
  || no "legacy denominator_source wrong: $G"
# a torn log line must not zero the legacy denominator — actual_sessions=0 would
# bank a fabricated came-in-under grade into the append-only record.
printf '{"schema":"guv.meter.v1","ts":"2026-06-13T0\n' >> "$D/.claude/metering/metering.ndjson"
G=$(run "$D" grade)
echo "$G" | jq -e '.quantity_error.actual_sessions == 1' >/dev/null \
  && ok "the legacy denominator survives a torn log line (still 1 metered session)" \
  || no "torn log line zeroed the legacy denominator: $(echo "$G" | jq -c .quantity_error)"

# ── P11 — human-gated 🔒 is open work ────────────────────────────────────────
echo "P11: 🔒 counts as remaining"
D=$(mk_project)
cat > "$D/docs/PHASE_STATUS.md" <<'MD'
# Phase Status

## Phase 9 — Test

_Goal: fixtures._

- 🔒 **[9.1]** waiting on a person `[deps: none]`
- ✅ **[9.3]** a done thing `[deps: none]`
MD
mk_entry "$D" "2026-06-10T00:00:00Z" "session-2026-06-10-001" 1000
OUT=$(run "$D" project)
echo "$OUT" | jq -e '.quantity.sized_remaining == 1' >/dev/null \
  && ok "a human-gated deliverable is remaining work" \
  || no "🔒 dropped from the takeoff: $(echo "$OUT" | jq -c .quantity)"

# ── P12 — only local inputs; the retired machinery is gone ───────────────────
echo "P12: subtraction pins"
if grep -v '^\s*#' "$PROJ" | grep -qE '\$HOME|~/.claude/projects'; then
  no "projection reads foreign history"
else
  ok "no input path to another project's history"
fi
SRC=$(grep -v '^[[:space:]]*#' "$PROJ")
for gone in "WORKING_SET_FRACTION" "BASE_BUILD_TURNS" "EVAL_FIX_TURNS" "BLEND_K" "occupancy.threshold" "structural"; do
  printf '%s' "$SRC" | grep -q "$gone" \
    && no "retired surface '$gone' present in projection source" \
    || ok "'$gone' absent from projection source"
done

# ── P13 — the shape is documented ────────────────────────────────────────────
echo "P13: shape doc"
grep -q "guv.projection.v2" "$ROOT/.claude/projection.shape.md" 2>/dev/null \
  && ok "projection.shape.md documents the v2 shape" \
  || no "projection.shape.md missing or stale"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
