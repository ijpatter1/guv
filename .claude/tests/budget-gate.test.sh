#!/bin/bash
# Tests for .claude/budget-gate.sh — the burn-vs-ceiling comparison ([9.3], [32.4]).
#
# Invariant (post-[32.4]): the gate is ONE entry/exit burn-vs-ceiling comparison
# plus a pointer line. Optional budgets live in project.json at two granularities
# — initiative and session — schema-validated. ABSENT MEANS UNLIMITED: an absent
# budget gates NOTHING, silently. With a ceiling set the gate prints ONE
# comparison line per configured granularity (burn visible at boundaries) and ONE
# pointer line naming the record that qualifies the number; on breach it stops
# loud (exit 3) with work preserved — the choice (extend / harvest / kill) is the
# person's. THE MACHINERY NEVER RAISES A SETPOINT. Burn is summed from the [9.1]
# metering log, scoped to entries AFTER the last epoch line (guv.meter.epoch.v1
# — pre-epoch entries are historical and never compared across it; no epoch line
# means the whole log is one epoch, the fresh-project case) and, for the
# initiative figure, windowed to the [13.4] lineage boundary. The retired hazard
# machinery (HARVEST UNIT / SETPOINT DENOMINATION / FORESEEN OVERRUN) is
# tombstoned: its facts live in .claude/metering-log.md, not in code.
#
# Pure bash + jq, no test runner. Stderr-clean for well-formed input.
# Run: bash .claude/tests/budget-gate.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/.claude/budget-gate.sh"
SCHEMA="$ROOT/.claude/project.schema.json"
SS_HOOK="$ROOT/.claude/hooks/session-start.sh"
HANDOFF_SKILL="$ROOT/.claude/skills/handoff/SKILL.md"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Build a throwaway "project": a manifest carrying the given budgets JSON (or
# none), a current + prior session artifact, and a metering log whose entries sum
# to the given burns. Entries carry slice_basis:"per_deliverable" — the bounded
# per-session slices the gate sums. Echoes the project dir.
#   mk_project <budgets_json|""> <session_burn> <initiative_extra_burn>
mk_project() {
  local budgets="$1" sburn="$2" iextra="$3"
  local d; d=$(mktemp -d "$WORK/proj.XXXXXX")
  mkdir -p "$d/.claude/metering" "$d/docs/sessions"
  if [ -n "$budgets" ]; then
    jq -nc --argjson b "$budgets" \
      '{name:"x",language:"shell",roots:{control:".",code:"."},commands:{},scaffoldCheck:"true",ceremony:"task",budgets:$b}' \
      > "$d/.claude/project.json"
  else
    jq -nc \
      '{name:"x",language:"shell",roots:{control:".",code:"."},commands:{},scaffoldCheck:"true",ceremony:"task"}' \
      > "$d/.claude/project.json"
  fi
  printf '# handoff\n' > "$d/docs/sessions/session-2026-06-15-001.md"
  printf '# handoff\n' > "$d/docs/sessions/session-2026-06-14-001.md"
  # tokens split across classes to prove the gate sums classes, not just input.
  local h r
  h=$((sburn / 2)); r=$((sburn - sburn / 2))
  {
    jq -nc --argjson t "$iextra" \
      '{schema:"guv.meter.v1",ts:"2026-06-14T10:00:00Z",session:"session-2026-06-14-001",deliverable_ids:["9.0"],tokens:{input:$t,output:0,cache_read:0,cache_creation:0},slice_basis:"per_deliverable",harvest_basis:"per_response",coverage:"main_session",perf:{}}'
    jq -nc --argjson a "$h" --argjson b "$r" \
      '{schema:"guv.meter.v1",ts:"2026-06-15T10:00:00Z",session:"session-2026-06-15-001",deliverable_ids:["9.3"],tokens:{input:$a,output:0,cache_read:$b,cache_creation:0},slice_basis:"per_deliverable",harvest_basis:"per_response",coverage:"main_session",perf:{}}'
  } > "$d/.claude/metering/metering.ndjson"
  echo "$d"
}

# Run the gate for a project dir at a boundary. Echoes stdout; caller reads $?.
gate() {
  local d="$1" phase="$2"
  (cd "$d" && bash "$GATE" "$phase" 2>/dev/null)
}

# ── A0 — the gate exists ─────────────────────────────────────────────────────
echo "A0: gate script exists"
[ -f "$GATE" ] && ok "budget-gate.sh exists" || no "budget-gate.sh missing"

# ── A1 — absent budget gates nothing, silently, both boundaries ──────────────
echo "A1: absent budget gates nothing"
D=$(mk_project "" 500 500)
for ph in entry exit; do
  OUT=$(gate "$D" "$ph"); RC=$?
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
    && ok "no budgets → silent exit 0 at $ph" \
    || no "no budgets → expected silence at $ph (rc=$RC out='$OUT')"
done
D=$(mk_project '{}' 500 500)
OUT=$(gate "$D" exit); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && ok "empty budgets block → silent exit 0" \
  || no "empty budgets block → expected silence (rc=$RC)"

# ── A2 — within budget: ONE comparison line + ONE pointer line ───────────────
echo "A2: within budget prints the comparison and the pointer, nothing else"
D=$(mk_project '{"initiative":{"tokens":100000}}' 500 500)
for ph in entry exit; do
  OUT=$(gate "$D" "$ph"); RC=$?
  LINES=$(printf '%s\n' "$OUT" | grep -c .)
  echo "$OUT" | grep -q "initiative burn 1000 of 100000 tokens" \
    && ok "comparison line carries burn and ceiling at $ph" \
    || no "comparison line wrong at $ph: $OUT"
  echo "$OUT" | grep -q "metering-log.md" \
    && ok "pointer line names the record at $ph" \
    || no "pointer line missing at $ph: $OUT"
  [ "$RC" -eq 0 ] && [ "$LINES" -eq 2 ] \
    && ok "exactly two lines, exit 0 at $ph" \
    || no "expected 2 lines exit 0 at $ph (rc=$RC lines=$LINES)"
done

# ── A3 — percent arithmetic on the comparison line ───────────────────────────
echo "A3: percent is computed, not asserted"
D=$(mk_project '{"initiative":{"tokens":2000}}' 500 500)
OUT=$(gate "$D" exit)
echo "$OUT" | grep -q "(50%)" \
  && ok "burn 1000 of 2000 prints (50%)" \
  || no "percent wrong: $OUT"

# ── A4 — breach pauses loud at both boundaries, work preserved ───────────────
echo "A4: breach → exit 3, loud, work preserved, setpoint untouched"
D=$(mk_project '{"initiative":{"tokens":800}}' 500 500)
BEFORE_M=$(cat "$D/.claude/project.json")
BEFORE_L=$(cat "$D/.claude/metering/metering.ndjson")
for ph in entry exit; do
  OUT=$(gate "$D" "$ph"); RC=$?
  [ "$RC" -eq 3 ] \
    && ok "breach exits 3 at $ph" \
    || no "breach expected exit 3 at $ph (rc=$RC)"
  echo "$OUT" | grep -q "\[budget-gate\] BREACH" \
    && ok "BREACH headline present at $ph" \
    || no "BREACH headline missing at $ph"
done
echo "$OUT" | grep -q "initiative budget is exhausted" \
  && ok "breach names the granularity" || no "breach granularity missing"
echo "$OUT" | grep -qE "over by:? +200" \
  && ok "breach states the overrun" || no "overrun figure missing: $OUT"
for word in EXTEND HARVEST KILL; do
  echo "$OUT" | grep -q "$word" \
    && ok "breach offers $word" || no "breach missing $word"
done
[ "$(cat "$D/.claude/project.json")" = "$BEFORE_M" ] \
  && ok "manifest byte-identical after breach (machinery never raises a setpoint)" \
  || no "manifest changed on breach"
[ "$(cat "$D/.claude/metering/metering.ndjson")" = "$BEFORE_L" ] \
  && ok "metering log byte-identical after breach (gate writes nothing)" \
  || no "log changed on breach"

# ── A5 — breach fires at >= (boundary inclusive) ─────────────────────────────
echo "A5: burn == ceiling is a breach"
D=$(mk_project '{"initiative":{"tokens":1000}}' 500 500)
gate "$D" exit >/dev/null; RC=$?
[ "$RC" -eq 3 ] && ok "burn == ceiling breaches" || no "boundary not inclusive (rc=$RC)"

# ── A5b — [32.8] the fleet component counts toward burn ──────────────────────
# Under the widened epoch an entry carries subagent burn as a DISTINCT `fleet`
# component beside the main `tokens`. The gate's burn is the session's whole
# spend, so it sums BOTH components; a disclosed fleet:null contributes nothing
# (that entry's burn is a floor — the meter already declared the gap).
echo "A5b: fleet burn is summed; fleet:null adds main only"
D=$(mk_project '{"initiative":{"tokens":100000}}' 500 500)   # base burn 1000
{
  jq -nc '{schema:"guv.meter.v1",ts:"2026-06-15T11:00:00Z",session:"session-2026-06-15-001",deliverable_ids:["32.8"],tokens:{input:200,output:0,cache_read:0,cache_creation:0},fleet:{input:100,output:0,cache_read:200,cache_creation:0},slice_basis:"per_deliverable",harvest_basis:"per_response",coverage:"main_plus_fleet",perf:{}}'
  jq -nc '{schema:"guv.meter.v1",ts:"2026-06-15T12:00:00Z",session:"session-2026-06-15-001",deliverable_ids:["32.8"],tokens:{input:50,output:0,cache_read:0,cache_creation:0},fleet:null,slice_basis:"per_deliverable",harvest_basis:"per_response",coverage:"main_plus_fleet",perf:{}}'
} >> "$D/.claude/metering/metering.ndjson"
OUT=$(gate "$D" exit)
echo "$OUT" | grep -q "initiative burn 1550 of 100000 tokens" \
  && ok "fleet component joins the burn sum (1000 + 200+300 fleet-split + 50 null-fleet = 1550)" \
  || no "fleet burn not summed: $OUT"

# ── A5c — [32.8] the epoch's declared coverage scopes the sample set ─────────
# An epoch line that names a coverage admits only samples of THAT coverage:
# a sample of another scope inside the window (the seam before a ratified
# append, or a stray downgrade) is a different quantity, and an average across
# scopes is not a number — the same doctrine the harvest_basis select encodes
# on the unit axis.
echo "A5c: samples of another coverage stay out of the sum"
D=$(mk_project '{"initiative":{"tokens":100000}}' 500 500)   # base entries become PRE-epoch
{
  jq -nc '{schema:"guv.meter.epoch.v1",ts:"2026-06-16T00:00:00Z",harvest:"per_response",denomination:"raw_tokens",coverage:"main_plus_fleet"}'
  jq -nc '{schema:"guv.meter.v1",ts:"2026-06-16T10:00:00Z",session:"session-2026-06-15-001",deliverable_ids:["32.8"],tokens:{input:200,output:0,cache_read:0,cache_creation:0},fleet:{input:300,output:0,cache_read:0,cache_creation:0},slice_basis:"per_deliverable",harvest_basis:"per_response",coverage:"main_plus_fleet",perf:{}}'
  jq -nc '{schema:"guv.meter.v1",ts:"2026-06-16T11:00:00Z",session:"session-2026-06-15-001",deliverable_ids:["32.8"],tokens:{input:700,output:0,cache_read:0,cache_creation:0},slice_basis:"per_deliverable",harvest_basis:"per_response",coverage:"main_session",perf:{}}'
} >> "$D/.claude/metering/metering.ndjson"
OUT=$(gate "$D" exit)
echo "$OUT" | grep -q "initiative burn 500 of 100000 tokens" \
  && ok "only the epoch's declared coverage sums (500 = 200+300; the 700 main_session stray stays out)" \
  || no "coverage filter wrong: $OUT"

# ── A5d — [32.8] fleet-null samples are announced as a floor at the boundary ─
# The meter's fleet:null disclosure was a stderr line at a PREVIOUS session's
# close — invisible at the boundary where the person reads the number. The
# gate carries it forward the way it carries torn lines: a floor note on the
# comparison line.
echo "A5d: fleet-null samples get the floor note"
D=$(mk_project '{"initiative":{"tokens":100000}}' 500 500)
jq -nc '{schema:"guv.meter.v1",ts:"2026-06-15T12:00:00Z",session:"session-2026-06-15-001",deliverable_ids:["32.8"],tokens:{input:50,output:0,cache_read:0,cache_creation:0},fleet:null,slice_basis:"per_deliverable",harvest_basis:"per_response",coverage:"main_session",perf:{}}' \
  >> "$D/.claude/metering/metering.ndjson"
OUT=$(gate "$D" exit)
echo "$OUT" | grep -q "initiative burn 1050 of 100000" \
  && echo "$OUT" | grep -q "1 fleet-null entry(s) — burn is a floor" \
  && ok "a counted fleet-null sample adds main only and stamps the floor note on the comparison line" \
  || no "fleet-null floor note missing/wrong: $OUT"

# ── A6 — session granularity, and session precedence on a double breach ──────
echo "A6: session granularity"
D=$(mk_project '{"session":{"tokens":400}}' 500 200)
OUT=$(gate "$D" exit); RC=$?
[ "$RC" -eq 3 ] && echo "$OUT" | grep -q "session budget is exhausted" \
  && ok "session ceiling gates session burn" \
  || no "session breach missing (rc=$RC): $OUT"
D=$(mk_project '{"session":{"tokens":400},"initiative":{"tokens":500}}' 500 500)
OUT=$(gate "$D" exit)
echo "$OUT" | grep -q "session budget is exhausted" \
  && ok "session breach takes precedence on a double breach" \
  || no "precedence wrong: $OUT"
D=$(mk_project '{"session":{"tokens":100000},"initiative":{"tokens":200000}}' 500 500)
OUT=$(gate "$D" exit); RC=$?
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 3 ] \
  && echo "$OUT" | grep -q "session burn 500 of 100000" \
  && ok "both granularities → two comparisons + one pointer" \
  || no "double-granularity shape wrong (rc=$RC): $OUT"

# ── A6b — at ENTRY the session burn is zero by definition ────────────────────
# The newest docs/sessions artifact at entry is the PRIOR, closed session; its
# burn is not this session's. Without the entry-zero rule, a breached prior
# session prints a false session BREACH into every session-open context until
# the next handoff writes a new artifact.
echo "A6b: entry never misattributes the prior session's burn"
D=$(mk_project '{"session":{"tokens":400}}' 500 200)   # prior shape breaches at exit
OUT=$(gate "$D" entry); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "session burn 0 of 400" \
  && ok "entry reports session burn 0 — no false breach from the closed prior session" \
  || no "entry misattributed prior-session burn (rc=$RC): $OUT"

# ── A7 — the epoch line scopes every sum ─────────────────────────────────────
echo "A7: pre-epoch entries are historical — never compared across the epoch"
D=$(mk_project '{"initiative":{"tokens":5000}}' 500 500)
# Rebuild the log: a giant pre-epoch entry, the epoch line, then the two entries.
{
  jq -nc '{schema:"guv.meter.v1",ts:"2026-06-01T00:00:00Z",session:"session-2026-06-01-001",deliverable_ids:["1.0"],tokens:{input:999999999,output:0,cache_read:0,cache_creation:0},slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
  jq -nc '{schema:"guv.meter.epoch.v1",ts:"2026-06-10T00:00:00Z",harvest:"per_response",denomination:"raw_tokens",coverage:"main_session"}'
  tail -2 "$D/.claude/metering/metering.ndjson"
} > "$D/.claude/metering/metering.ndjson.new"
mv "$D/.claude/metering/metering.ndjson.new" "$D/.claude/metering/metering.ndjson"
OUT=$(gate "$D" exit); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "initiative burn 1000 of 5000" \
  && ok "pre-epoch burn excluded — only post-epoch entries sum" \
  || no "epoch scoping failed (rc=$RC): $OUT"
# Two epoch lines: the LAST one wins.
{
  jq -nc '{schema:"guv.meter.epoch.v1",ts:"2026-06-02T00:00:00Z",harvest:"per_response",denomination:"raw_tokens",coverage:"main_session"}'
  jq -nc '{schema:"guv.meter.v1",ts:"2026-06-05T00:00:00Z",session:"session-2026-06-05-001",deliverable_ids:["1.1"],tokens:{input:777777,output:0,cache_read:0,cache_creation:0},slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
  cat "$D/.claude/metering/metering.ndjson"
} > "$D/.claude/metering/metering.ndjson.new"
mv "$D/.claude/metering/metering.ndjson.new" "$D/.claude/metering/metering.ndjson"
OUT=$(gate "$D" exit)
echo "$OUT" | grep -q "initiative burn 1000 of 5000" \
  && ok "the LAST epoch line wins (append order is lineage order)" \
  || no "last-epoch-wins failed: $OUT"

# ── A8 — no epoch line → the whole log is one epoch (fresh project) ──────────
echo "A8: a log with no epoch line sums whole (the fresh-project case)"
D=$(mk_project '{"initiative":{"tokens":5000}}' 300 700)
OUT=$(gate "$D" exit)
echo "$OUT" | grep -q "initiative burn 1000 of 5000" \
  && ok "no epoch line → all entries sum" \
  || no "fresh-log sum wrong: $OUT"

# ── A9 — the initiative figure windows to the lineage boundary ───────────────
echo "A9: lineage window — prior-initiative burn stays out"
D=$(mk_project '{"initiative":{"tokens":5000}}' 500 500)
jq -nc '{kind:"forecast",boundary:"plan",banked_at:"2026-06-15T00:00:00Z"}' \
  > "$D/.claude/metering/calibration.ndjson"
OUT=$(gate "$D" exit); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "initiative burn 500 of 5000" \
  && ok "entries before the plan bank stay out of the initiative figure" \
  || no "lineage window failed (rc=$RC): $OUT"
# A phase-boundary bank never moves the window.
jq -nc '{kind:"forecast",boundary:"phase-9",banked_at:"2026-06-15T09:00:00Z"}' \
  >> "$D/.claude/metering/calibration.ndjson"
OUT=$(gate "$D" exit)
echo "$OUT" | grep -q "initiative burn 500 of 5000" \
  && ok "phase banks never move the window" \
  || no "phase bank moved the window: $OUT"
# Between initiatives the window opens at the grade.
jq -nc '{kind:"grade",banked_at:"2026-06-16T00:00:00Z"}' \
  >> "$D/.claude/metering/calibration.ndjson"
OUT=$(gate "$D" exit)
echo "$OUT" | grep -q "initiative burn 0 of 5000" \
  && ok "between initiatives the window opens at the grade" \
  || no "grade did not reset the window: $OUT"

# ── A10 — non-samples stay out: unbounded_cumulative, tokens null, no ts ─────
echo "A10: disclosed degradations are not burn"
D=$(mk_project '{"initiative":{"tokens":5000}}' 500 500)
{
  jq -nc '{schema:"guv.meter.v1",ts:"2026-06-15T11:00:00Z",session:"session-2026-06-15-001",deliverable_ids:["9.3"],tokens:{input:400000,output:0,cache_read:0,cache_creation:0},slice_basis:"unbounded_cumulative",harvest_basis:"per_response",perf:{}}'
  jq -nc '{schema:"guv.meter.v1",ts:"2026-06-15T12:00:00Z",session:"session-2026-06-15-001",deliverable_ids:["9.3"],tokens:null,slice_basis:null,perf:{}}'
} >> "$D/.claude/metering/metering.ndjson"
OUT=$(gate "$D" exit)
echo "$OUT" | grep -q "initiative burn 1000 of 5000" \
  && ok "unbounded_cumulative and tokens:null are excluded" \
  || no "degradation leaked into burn: $OUT"

# ── A11 — a torn line is announced as a floor, never absorbed ────────────────
echo "A11: torn metering lines make the burn a floor, said so"
D=$(mk_project '{"initiative":{"tokens":5000}}' 500 500)
printf '{"schema":"guv.meter.v1","ts":"2026-06-15T13:00:0\n' >> "$D/.claude/metering/metering.ndjson"
OUT=$(gate "$D" exit); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "initiative burn 1000 of 5000" \
  && ok "a torn line drops alone — the gate still compares" \
  || no "torn line broke the gate (rc=$RC): $OUT"
echo "$OUT" | grep -qi "1 unparsed" && echo "$OUT" | grep -qi "floor" \
  && ok "the floor disclosure names the torn-line count" \
  || no "floor disclosure missing: $OUT"

# ── A12 — robustness: no log, corrupt manifest, bad phase ────────────────────
echo "A12: designed degradations and usage errors"
D=$(mk_project '{"initiative":{"tokens":5000}}' 0 0)
rm "$D/.claude/metering/metering.ndjson"
OUT=$(gate "$D" exit); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "initiative burn 0 of 5000" \
  && ok "missing log → burn 0, never a fabricated breach" \
  || no "missing log mishandled (rc=$RC): $OUT"
(cd "$D" && bash "$GATE" sideways >/dev/null 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "unknown phase exits 2" || no "unknown phase rc=$RC"
E=$(mktemp -d "$WORK/empty.XXXXXX")
(cd "$E" && bash "$GATE" exit >/dev/null 2>&1); RC=$?
[ "$RC" -eq 4 ] && ok "no manifest exits 4" || no "no manifest rc=$RC"
D=$(mk_project '{"initiative":{"tokens":"a lot"}}' 500 500)
OUT=$(gate "$D" exit); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && ok "non-integer setpoint treated as absent (unlimited), silent" \
  || no "non-integer setpoint mishandled (rc=$RC): $OUT"
# tokens: 0 is out of shape (schema floors at 1) — treated as absent, never fed
# to the percent arithmetic (division by zero) or the >= comparison (instant
# permanent breach at every boundary).
D=$(mk_project '{"session":{"tokens":0},"initiative":{"tokens":0}}' 500 500)
OUT=$(gate "$D" exit 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && ok "a zero ceiling is treated as absent — no division by zero, no false breach" \
  || no "zero ceiling mishandled (rc=$RC): $OUT"

# ── A13 — the gate never writes, the source never mutates a setpoint ─────────
echo "A13: read-only by source"
if grep -E '>>|tee ' "$GATE" | grep -v '^[[:space:]]*#' | grep -q .; then
  no "gate source carries a write redirection"
else
  ok "no write redirection in the gate source"
fi
grep -q 'jq .*budgets.*=' "$GATE" \
  && no "gate source edits budgets" \
  || ok "no jq assignment against budgets in the gate source"

# ── A14 — the retired machinery is gone from the source (tombstone) ──────────
echo "A14: subtraction pins — the hazard machinery does not creep back"
# harvest_basis stays LEGAL in the source (burn_sum filters samples to the
# epoch's unit — the same selection projection.sh's rate applies, so the two
# sample sets agree); what must not creep back is the hazard/forecast apparatus.
SRC=$(grep -v '^\s*#' "$GATE")
for gone in "HARVEST UNIT HAZARD" "SETPOINT DENOMINATION HAZARD" "FORESEEN OVERRUN" "denomination" "projection.sh"; do
  printf '%s' "$SRC" | grep -q "$gone" \
    && no "retired surface '$gone' present in gate source" \
    || ok "'$gone' absent from gate source"
done

# ── A15 — schema parity: budgets carry tokens only, both granularities ───────
echo "A15: the manifest schema matches the cut"
# tokens is the one LIVE field; the two retired declarations stay schema-legal
# (marked HISTORICAL) so a pre-[32.4] manifest still validates — the
# contextManagement grandfather pattern, not a silent re-arming.
jq -e '.properties.budgets.properties.initiative.properties | keys == ["denomination","harvest_basis","tokens"]' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema: initiative budget = tokens + the two grandfathered historical fields" \
  || no "schema: initiative budget properties wrong"
jq -e '.properties.budgets.properties.initiative.properties | .harvest_basis.description + .denomination.description | test("HISTORICAL") and test("no longer reads")' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema: the grandfathered fields say the gate no longer reads them" \
  || no "schema: historical marking missing on grandfathered fields"
jq -e '.properties.budgets.properties.session.properties | keys == ["tokens"]' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema: session budget carries tokens only" \
  || no "schema: session budget properties wrong"

# ── A16 — wired into both boundaries ─────────────────────────────────────────
echo "A16: wiring"
grep -q 'budget-gate.sh" entry' "$SS_HOOK" \
  && ok "SessionStart hook runs the gate at entry" \
  || no "entry wiring missing in session-start.sh"
grep -q 'budget-gate.sh exit' "$HANDOFF_SKILL" \
  && ok "handoff skill runs the gate at exit" \
  || no "exit wiring missing in handoff SKILL.md"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
