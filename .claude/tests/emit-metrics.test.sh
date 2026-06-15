#!/bin/bash
# Tests for .claude/emit-metrics.sh — the cost-and-performance emitter ([9.5]).
# Pure bash + jq, no test runner required. Run: bash .claude/tests/emit-metrics.test.sh
#
# These tests verify INTENT, not "runs without crashing" (Rule 8). The emitter
# is the ONE parser of meaning over the raw metering log: it aggregates the log
# by deliverable, phase, and initiative into a PUBLISHED JSON shape, and derives
# performance metrics MECHANICALLY from git history joined with the resolver's
# deliverable→phase map — cycle time, footprint, commits-per-deliverable, lane
# lifetime, phase wall-clock — with NO instrumentation path (derive, don't
# instrument). The heart-of-the-deliverable invariants this suite defends:
#   1. emitter output validates against its documented shape (every group and
#      perf field present, typed, self-describing with a schema version);
#   2. aggregates hand-check against a fixture log (exact token/session sums by
#      deliverable, phase, initiative — the emitter computes the MEANING the raw
#      log forbids);
#   3. git-derived perf metrics hand-check against a fixture history with NO
#      instrumentation (grep-asserted: the emitter reads `git log`, never any
#      timer/instrument hook, and accepts no agent-supplied metric);
#   4. NO consumer reads the raw log — the emitter is the only reader; commands,
#      hooks, and the renderer read the emitter, never metering.ndjson
#      (grep-asserted across the .claude tree).
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # .claude/
SCRIPT="$CLAUDE_DIR/emit-metrics.sh"
ROOT="$(cd "$CLAUDE_DIR/.." && pwd)"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# ─── A fixture project: a manifest, a tracker (deliverable→phase map), a raw
# metering log with HAND-COMPUTABLE sums, and a git history whose commit
# subjects carry [N.M] deliverable IDs (the convention git already records). ───
make_fixture() {  # echoes the project dir
  local p="$WORK/proj.$RANDOM"
  rm -rf "$p"
  mkdir -p "$p/.claude/metering" "$p/docs/sessions"
  jq -n '{roots:{control:".",code:"."},name:"t",language:"shell",ceremony:"phased"}' \
    > "$p/.claude/project.json"

  # The tracker is the resolver's input — it supplies the deliverable→phase map
  # the emitter JOINS git history against. Two phases (9, 10), four deliverables.
  cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 9 — The Meter

- ✅ **[9.1]** Session capture `[deps: none]`
- ✅ **[9.5]** Cost-and-performance emitter `[deps: 9.1]`

## Phase 10 — Topology

- ✅ **[10.1]** Human-gated marker `[deps: none]`
- ⬜ **[10.9]** Build fan-out `[deps: 10.1]`
MD

  # The raw metering log — RAW EVIDENCE, exactly the meter.sh shape. Sums below
  # are hand-computable. Three sessions:
  #   - 9.1   : tokens input=100 output=10  ; one session
  #   - 9.5   : tokens input=200 output=20  ; one session
  #   - 9.5,10.1 (multi-attribution session): input=40 output=4 ; one session
  # Phase 9 aggregate = 9.1 + 9.5 + the 9.5 leg of the multi session.
  local L="$p/.claude/metering/metering.ndjson"
  {
    printf '%s\n' '{"schema":"guv.meter.v1","ts":"2026-06-10T12:00:00Z","session":"session-2026-06-10-001","deliverable_ids":["9.1"],"model":"m","tokens":{"input":100,"output":10,"cache_read":0,"cache_creation":0},"dollars":null,"spike_c_rung":"B","perf":{"op_wallclock_s":0.10,"suite_runtime_s":1.0}}'
    printf '%s\n' '{"schema":"guv.meter.v1","ts":"2026-06-11T12:00:00Z","session":"session-2026-06-11-001","deliverable_ids":["9.5"],"model":"m","tokens":{"input":200,"output":20,"cache_read":0,"cache_creation":0},"dollars":null,"spike_c_rung":"B","perf":{"op_wallclock_s":0.20,"suite_runtime_s":2.0}}'
    printf '%s\n' '{"schema":"guv.meter.v1","ts":"2026-06-12T12:00:00Z","session":"session-2026-06-12-001","deliverable_ids":["9.5","10.1"],"model":"m","tokens":{"input":40,"output":4,"cache_read":0,"cache_creation":0},"dollars":null,"spike_c_rung":"B","perf":{"op_wallclock_s":0.30,"suite_runtime_s":3.0}}'
  } > "$L"
  printf '# h\n' > "$p/docs/sessions/session-2026-06-12-001.md"

  # A real git history with deliverable IDs in the subjects. The emitter derives
  # perf metrics from THIS — no instrumentation. Author dates are pinned so cycle
  # time and phase wall-clock are exact.
  (
    cd "$p"
    git init -q
    git config user.email t@t; git config user.name t
    git config commit.gpgsign false
    # 9.1: two commits, 2h apart. footprint: file a (3 lines), file b (1 line).
    printf 'l1\nl2\nl3\n' > a.txt
    git add a.txt
    GIT_AUTHOR_DATE='2026-06-10T10:00:00 +0000' GIT_COMMITTER_DATE='2026-06-10T10:00:00 +0000' \
      git commit -q -m 'feat([9.1]): scaffold capture'
    printf 'b1\n' > b.txt
    git add b.txt
    GIT_AUTHOR_DATE='2026-06-10T12:00:00 +0000' GIT_COMMITTER_DATE='2026-06-10T12:00:00 +0000' \
      git commit -q -m 'fix([9.1]): degrade path'
    # 9.5: one commit, the emitter itself. footprint: file c (5 lines).
    printf 'c1\nc2\nc3\nc4\nc5\n' > c.txt
    git add c.txt
    GIT_AUTHOR_DATE='2026-06-11T09:00:00 +0000' GIT_COMMITTER_DATE='2026-06-11T09:00:00 +0000' \
      git commit -q -m 'feat([9.5]): emitter'
    # 10.1: one commit, in phase 10. Pins phase-9 wall-clock end at 9.5's commit.
    printf 'd1\n' > d.txt
    git add d.txt
    GIT_AUTHOR_DATE='2026-06-13T09:00:00 +0000' GIT_COMMITTER_DATE='2026-06-13T09:00:00 +0000' \
      git commit -q -m 'feat([10.1]): human-gated marker'
    # CROSS-REFERENCE TRAP: an [8.3] commit whose SUBJECT carries 8.3 but whose
    # BODY prose mentions [9.1]. Attribution is SUBJECT-scoped: this commit must
    # be credited to 8.3 (not in our map → no perf bucket), and must NOT inflate
    # 9.1's commits/footprint/cycle-time, nor phase 9's wall-clock. A full-message
    # `git log --grep '[9.1]'` WOULD wrongly catch this — that is the bug T5b/T7b
    # defend against. We pin its author date AFTER 9.5's commit so a leak would
    # also stretch 9.1's cycle time and phase-9 wall-clock, making the leak loud.
    printf 'leak1\nleak2\n' > leak.txt
    git add leak.txt
    GIT_AUTHOR_DATE='2026-06-14T09:00:00 +0000' GIT_COMMITTER_DATE='2026-06-14T09:00:00 +0000' \
      git commit -q -m 'fix([8.3]): replan addendum' -m 'Follows up the work in [9.1]; see that lane for context.'
  ) >/dev/null 2>&1
  echo "$p"
}

# ─── The emitter must exist (RED until built) ────────────────────────────────
[ -f "$SCRIPT" ] \
  && ok "emitter script exists at .claude/emit-metrics.sh" \
  || no "emitter script missing at .claude/emit-metrics.sh"

P=$(make_fixture)
OUT="$WORK/out.json"
( cd "$P" && bash "$SCRIPT" ) >"$OUT" 2>"$WORK/emit.err"; RC=$?

# ─── T1 — the emitter produces ONE valid JSON document, self-describing ──────
[ "$RC" -eq 0 ] && jq -e . "$OUT" >/dev/null 2>&1 \
  && ok "emitter exits 0 and emits one valid JSON document (rc=$RC)" \
  || no "emitter must emit one valid JSON document (rc=$RC, err=$(cat "$WORK/emit.err"))"
[ "$(jq -s 'length' "$OUT" 2>/dev/null)" = "1" ] \
  && ok "emitter output is exactly one JSON document (not NDJSON)" \
  || no "emitter must emit exactly one document, got $(jq -s 'length' "$OUT" 2>/dev/null)"
jq -e '.schema == "guv.metrics.v1"' "$OUT" >/dev/null 2>&1 \
  && ok "emitter output is self-describing (schema: guv.metrics.v1)" \
  || no "emitter output must carry a schema version, got $(jq -c '.schema // "MISSING"' "$OUT")"

# ─── T2 — DOCUMENTED SHAPE: every top-level group the shape names is present ──
# The shape is: { schema, generated, cost:{by_deliverable, by_phase, by_initiative},
#                 perf:{by_deliverable, by_phase} }. Validate the skeleton so the
# output is a contract, not an ad-hoc dump.
for path in '.generated' '.cost' '.cost.by_deliverable' '.cost.by_phase' \
            '.cost.by_initiative' '.perf' '.perf.by_deliverable' '.perf.by_phase'; do
  jq -e "$path != null" "$OUT" >/dev/null 2>&1 \
    && ok "shape: $path present" \
    || no "shape: $path missing (emitter output does not validate against its shape)"
done
# generated is a real UTC instant (mechanical, date -u), never an agent string
jq -re '.generated' "$OUT" 2>/dev/null | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  && ok "generated is an ISO-8601 UTC instant (mechanical)" \
  || no "generated must be a UTC instant, got $(jq -c '.generated' "$OUT")"

# ─── T3 — COST AGGREGATES hand-check against the fixture log (by deliverable) ─
# 9.1: input 100, output 10, 1 session. 9.5: appears in two sessions (its own +
# the multi), so input 200+40=240, output 20+4=24, 2 sessions. 10.1: input 40,
# output 4, 1 session.
jq -e '.cost.by_deliverable["9.1"].tokens.input == 100
   and .cost.by_deliverable["9.1"].tokens.output == 10
   and .cost.by_deliverable["9.1"].sessions == 1' "$OUT" >/dev/null 2>&1 \
  && ok "cost.by_deliverable[9.1] hand-checks (input 100, output 10, 1 session)" \
  || no "9.1 cost aggregate wrong: $(jq -c '.cost.by_deliverable["9.1"]' "$OUT")"
jq -e '.cost.by_deliverable["9.5"].tokens.input == 240
   and .cost.by_deliverable["9.5"].tokens.output == 24
   and .cost.by_deliverable["9.5"].sessions == 2' "$OUT" >/dev/null 2>&1 \
  && ok "cost.by_deliverable[9.5] hand-checks across two sessions (input 240, output 24, 2 sessions)" \
  || no "9.5 cost aggregate wrong: $(jq -c '.cost.by_deliverable["9.5"]' "$OUT")"

# ─── T4 — COST AGGREGATES hand-check by phase and initiative ─────────────────
# Phase 9 = 9.1 + 9.5(both legs) = input 100+200+40=340, output 10+20+4=34.
jq -e '.cost.by_phase["9"].tokens.input == 340
   and .cost.by_phase["9"].tokens.output == 34' "$OUT" >/dev/null 2>&1 \
  && ok "cost.by_phase[9] hand-checks (input 340, output 34 — both legs of the multi-session)" \
  || no "phase-9 cost aggregate wrong: $(jq -c '.cost.by_phase["9"]' "$OUT")"
# Phase 10 = 10.1 = input 40, output 4.
jq -e '.cost.by_phase["10"].tokens.input == 40
   and .cost.by_phase["10"].tokens.output == 4' "$OUT" >/dev/null 2>&1 \
  && ok "cost.by_phase[10] hand-checks (input 40, output 4)" \
  || no "phase-10 cost aggregate wrong: $(jq -c '.cost.by_phase["10"]' "$OUT")"
# Initiative is the whole live plan (the metering log's records). Grand total
# tokens = every leg = input 100+200+40=340 ... wait, 10.1 also: 340+? No:
# 9.1=100, 9.5=200, multi(9.5+10.1)=40 -> input total 340; output 10+20+4=34.
jq -e '.cost.by_initiative.tokens.input == 340
   and .cost.by_initiative.tokens.output == 34' "$OUT" >/dev/null 2>&1 \
  && ok "cost.by_initiative hand-checks (grand total input 340, output 34)" \
  || no "initiative cost aggregate wrong: $(jq -c '.cost.by_initiative' "$OUT")"
# session-scalar attribution is never miscounted as a deliverable phase
jq -e '.cost.by_deliverable | has("session-scalar") | not' "$OUT" >/dev/null 2>&1 \
  && ok "session-scalar is not folded into a phase (no phantom phase)" \
  || ok "(no session-scalar entry in this fixture)"

# ─── T5 — PERF: commits-per-deliverable, git-derived, hand-checks ────────────
# 9.1 has TWO commits; 9.5 has ONE; 10.1 has ONE.
jq -e '.perf.by_deliverable["9.1"].commits == 2' "$OUT" >/dev/null 2>&1 \
  && ok "perf.by_deliverable[9.1].commits == 2 (git-derived, hand-checked)" \
  || no "9.1 commits wrong: $(jq -c '.perf.by_deliverable["9.1"].commits' "$OUT")"
jq -e '.perf.by_deliverable["9.5"].commits == 1' "$OUT" >/dev/null 2>&1 \
  && ok "perf.by_deliverable[9.5].commits == 1 (git-derived)" \
  || no "9.5 commits wrong: $(jq -c '.perf.by_deliverable["9.5"].commits' "$OUT")"

# ─── T6 — PERF: cycle time, git-derived from first→last commit, hand-checks ──
# 9.1: 2026-06-10T10:00 → 12:00 = 7200 seconds. 9.5: single commit = 0.
jq -e '.perf.by_deliverable["9.1"].cycle_time_s == 7200' "$OUT" >/dev/null 2>&1 \
  && ok "perf.by_deliverable[9.1].cycle_time_s == 7200 (2h, git author dates, no instrumentation)" \
  || no "9.1 cycle time wrong: $(jq -c '.perf.by_deliverable["9.1"].cycle_time_s' "$OUT")"
jq -e '.perf.by_deliverable["9.5"].cycle_time_s == 0' "$OUT" >/dev/null 2>&1 \
  && ok "perf.by_deliverable[9.5].cycle_time_s == 0 (single commit, git-derived)" \
  || no "9.5 cycle time wrong: $(jq -c '.perf.by_deliverable["9.5"].cycle_time_s' "$OUT")"

# ─── T7 — PERF: footprint, git-derived (files touched + lines), hand-checks ──
# 9.1 touched 2 files (a.txt 3 lines added, b.txt 1) -> files 2, insertions 4.
jq -e '.perf.by_deliverable["9.1"].footprint.files == 2
   and .perf.by_deliverable["9.1"].footprint.insertions == 4' "$OUT" >/dev/null 2>&1 \
  && ok "perf.by_deliverable[9.1].footprint hand-checks (2 files, 4 insertions, git --numstat)" \
  || no "9.1 footprint wrong: $(jq -c '.perf.by_deliverable["9.1"].footprint' "$OUT")"
# 9.5 touched 1 file (c.txt 5 lines).
jq -e '.perf.by_deliverable["9.5"].footprint.files == 1
   and .perf.by_deliverable["9.5"].footprint.insertions == 5' "$OUT" >/dev/null 2>&1 \
  && ok "perf.by_deliverable[9.5].footprint hand-checks (1 file, 5 insertions)" \
  || no "9.5 footprint wrong: $(jq -c '.perf.by_deliverable["9.5"].footprint' "$OUT")"

# ─── T7b — SUBJECT-SCOPED ATTRIBUTION: a body cross-reference must NOT leak ──
# The CROSS-REFERENCE TRAP commit has subject [8.3] but its body mentions [9.1].
# Attribution is by SUBJECT (the convention git records on the subject line), so
# this commit belongs to 8.3 and 9.1 must not see it. A full-message
# `git log --grep '[9.1]'` matches subject AND body, so the buggy emitter credits
# the leak to 9.1 — inflating its commits (2→3), footprint (a 3rd file +2 lines),
# and cycle time (06-10→06-14 instead of the 7200s subject-only span). These
# assertions FAIL under full-message scope and pass only under subject-scoping.
jq -e '.perf.by_deliverable["9.1"].commits == 2' "$OUT" >/dev/null 2>&1 \
  && ok "subject-scope: 9.1 commits stay 2 — a body cross-ref [8.3] commit is NOT credited to 9.1" \
  || no "9.1 commits leaked a body cross-reference (full-message --grep): $(jq -c '.perf.by_deliverable["9.1"].commits' "$OUT") (expected 2)"
jq -e '.perf.by_deliverable["9.1"].footprint.files == 2
   and .perf.by_deliverable["9.1"].footprint.insertions == 4' "$OUT" >/dev/null 2>&1 \
  && ok "subject-scope: 9.1 footprint stays {2,4} — the cross-ref commit's file does not leak in" \
  || no "9.1 footprint leaked the cross-ref commit: $(jq -c '.perf.by_deliverable["9.1"].footprint' "$OUT") (expected files 2, insertions 4)"
jq -e '.perf.by_deliverable["9.1"].cycle_time_s == 7200' "$OUT" >/dev/null 2>&1 \
  && ok "subject-scope: 9.1 cycle time stays 7200 — the later [8.3] body cross-ref does not stretch it" \
  || no "9.1 cycle time leaked the cross-ref commit: $(jq -c '.perf.by_deliverable["9.1"].cycle_time_s' "$OUT") (expected 7200)"
# The cross-referenced [8.3] commit is NOT in the tracker map, so under correct
# subject-scoping it joins NO phase: phase 9's wall-clock is unchanged. Under the
# bug, 9.1 would catch the 06-14 leak and stretch phase 9 to ~4 days.
jq -e '.perf.by_phase["9"].wall_clock_s == 82800' "$OUT" >/dev/null 2>&1 \
  && ok "subject-scope: phase-9 wall-clock stays 82800 — the [8.3] body cross-ref does not leak into the phase JOIN" \
  || no "phase-9 wall-clock leaked the cross-ref commit: $(jq -c '.perf.by_phase["9"].wall_clock_s' "$OUT") (expected 82800)"

# ─── T8 — PERF: phase wall-clock, git-derived from the deliverable→phase map ─
# Phase 9 = first commit of any 9.x (9.1 @ 06-10T10:00) → last (9.5 @ 06-11T09:00)
# = 23 hours = 82800 seconds. This is the JOIN of git history with the resolver
# map: the emitter knows 9.1 and 9.5 are phase 9 ONLY via the deliverable→phase
# map, never by re-deriving it.
jq -e '.perf.by_phase["9"].wall_clock_s == 82800' "$OUT" >/dev/null 2>&1 \
  && ok "perf.by_phase[9].wall_clock_s == 82800 (23h across 9.1→9.5, joined via resolver map)" \
  || no "phase-9 wall-clock wrong: $(jq -c '.perf.by_phase["9"].wall_clock_s' "$OUT")"

# ─── T9 — PERF: lane lifetime field is present and git-derived ───────────────
# Lane lifetime = the span a deliverable's lane branch was live. With no merge
# data in this single-branch fixture it degrades to the commit span (== cycle
# time) — but the FIELD must exist and be a number/null, never absent or agent-set.
jq -e '.perf.by_deliverable["9.1"] | has("lane_lifetime_s")' "$OUT" >/dev/null 2>&1 \
  && jq -e '.perf.by_deliverable["9.1"].lane_lifetime_s | (type == "number" or . == null)' "$OUT" >/dev/null 2>&1 \
  && ok "perf.by_deliverable[9.1].lane_lifetime_s present, number-or-null (git-derived)" \
  || no "lane_lifetime_s must be present and number-or-null: $(jq -c '.perf.by_deliverable["9.1"].lane_lifetime_s' "$OUT")"

# ─── T10 — NO INSTRUMENTATION: derive, don't instrument (grep-asserted) ──────
# The emitter must read git history; it must NOT add any timer/instrument/probe
# hook, and it must accept NO agent-supplied metric flag. (cycle time, footprint,
# commits, wall-clock all come from `git log`, never from a recorded measurement.)
grep -qE 'git log' "$SCRIPT" \
  && ok "emitter reads git log (derives perf from history — no instrumentation)" \
  || no "emitter does not read git log — perf must be git-derived"
grep -nE -- '--cycle[-_]?time|--footprint|--commits|--wall[-_]?clock|--lane[-_]?lifetime|--metric|--instrument' "$SCRIPT" \
  | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' >/dev/null 2>&1 \
  && no "emitter exposes a flag to set a perf metric — metrics must be git-derived, never agent-supplied" \
  || ok "no CLI flag injects a perf metric (all git-derived, no instrumentation path)"
# No timer/instrument hook is installed by the emitter (it derives retroactively).
grep -nE 'date \+%s.*START|INSTRUMENT|probe_start|timer_start' "$SCRIPT" \
  | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' >/dev/null 2>&1 \
  && no "emitter installs a timer/instrument — perf must be derived retroactively from git, not measured" \
  || ok "emitter installs no timer/instrument (retroactive over existing history)"

# ─── T11 — THE RAW LOG STAYS RAW: emitter only reads it, never writes it ─────
grep -nE '[[:space:]]>[[:space:]]*"?[^|]*metering' "$SCRIPT" 2>/dev/null \
  | grep -vE '>>|^[[:space:]]*[0-9]+:[[:space:]]*#' >/dev/null 2>&1 \
  && no "emitter has a truncating redirect onto the metering log (it must read-only the raw log)" \
  || ok "emitter does not write the metering log (read-only; the raw log stays raw)"
grep -nE 'sed -i.*metering|>>[[:space:]]*"?[^|]*metering|rm[[:space:]].*metering' "$SCRIPT" 2>/dev/null \
  | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' >/dev/null 2>&1 \
  && no "emitter edits/appends/removes the metering log — it must be read-only over the raw log" \
  || ok "emitter neither appends, in-place-edits, nor removes the raw log"

# ─── T12 — ONE PARSER: no OTHER consumer reads the RAW log (grep across tree) ─
# The whole discipline: consumers read the EMITTER, never metering.ndjson, and
# never re-derive. Only meter.sh (the writer) and emit-metrics.sh (the one
# reader) may name the raw log. Scan commands, hooks, the renderer, and the other
# spine scripts for a raw-log read.
RAWREADERS=$(grep -rlnE 'metering\.ndjson|metering/metering' \
  "$ROOT/.claude/commands" "$ROOT/.claude/hooks" "$ROOT/.claude/skills" \
  "$ROOT/.claude/render-status.sh" "$ROOT/.claude/merge-queue.sh" \
  "$ROOT/.claude/lane-dispatch.sh" "$ROOT/.claude/resolve-ready.sh" \
  "$ROOT/.claude/status-line.sh" 2>/dev/null || true)
[ -z "$RAWREADERS" ] \
  && ok "no command/hook/renderer reads the raw metering log (one-parser discipline holds)" \
  || no "these consumers read the RAW log instead of the emitter: $RAWREADERS"

# ─── T13 — the emitter resolves paths relative to the project root ───────────
grep -nE '/Users/|/home/[a-z]' "$SCRIPT" 2>/dev/null | grep -vE '^[[:space:]]*#' >/dev/null 2>&1 \
  && no "emitter hardcodes an absolute home path (must resolve relative to the project root)" \
  || ok "emitter hardcodes no absolute path (resolves relative to the project root)"

# ─── T14 — the published shape is DOCUMENTED in its own file under .claude/ ──
SHAPEDOC=$(ls "$CLAUDE_DIR"/emit-metrics*.md "$CLAUDE_DIR"/metrics*.md 2>/dev/null | head -1)
[ -n "$SHAPEDOC" ] && [ -f "$SHAPEDOC" ] \
  && ok "shape doc exists ($([ -n "$SHAPEDOC" ] && basename "$SHAPEDOC"))" \
  || no "no shape doc file under .claude/ (emit-metrics*.md / metrics*.md)"
if [ -n "$SHAPEDOC" ]; then
  MISSING=""
  for f in schema generated by_deliverable by_phase by_initiative cycle_time footprint commits wall_clock lane_lifetime; do
    grep -q "$f" "$SHAPEDOC" || MISSING="$MISSING $f"
  done
  [ -z "$MISSING" ] \
    && ok "shape doc documents every group and perf metric" \
    || no "shape doc omits:$MISSING"
  # the cross-reference: it must name the raw log and the one-parser discipline
  grep -qiE 'raw log|metering' "$SHAPEDOC" \
    && ok "shape doc cross-references the raw metering log" \
    || no "shape doc does not cross-reference the raw log"
  grep -qiE 'one[- ]parser|never re-derive|read the emitter|consumers read' "$SHAPEDOC" \
    && ok "shape doc states the one-parser discipline (consumers read the emitter)" \
    || no "shape doc does not state the one-parser discipline"
fi

# ─── T15 — DEGRADATION (Rule 15): an absent metering log is not a crash ──────
# A project that has metered nothing yet still emits a valid (empty-aggregate)
# shape — the emitter never fabricates and never dies on a missing log.
P15=$(make_fixture)
rm -f "$P15/.claude/metering/metering.ndjson"
( cd "$P15" && bash "$SCRIPT" ) >"$WORK/empty.json" 2>"$WORK/empty.err"; RC15=$?
[ "$RC15" -eq 0 ] && jq -e '.cost.by_deliverable == {} or (.cost.by_deliverable | length) == 0' "$WORK/empty.json" >/dev/null 2>&1 \
  && ok "absent metering log -> valid shape with empty cost aggregates (designed degradation)" \
  || no "absent log must degrade to empty aggregates, not crash (rc=$RC15, err=$(cat "$WORK/empty.err"))"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
