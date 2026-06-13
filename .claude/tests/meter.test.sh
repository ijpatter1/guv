#!/bin/bash
# Tests for .claude/meter.sh — session-boundary cost-and-performance capture ([9.1]).
# Pure bash + jq, no test runner required. Run: bash .claude/tests/meter.test.sh
#
# These tests verify INTENT, not "runs without crashing" (Rule 8): the metering
# log is RAW EVIDENCE — every field is harness- or git-derived, never agent-
# reported; no derived/aggregate field is computed (that is [9.5] downstream);
# attribution is the deliverable ID when one applies, session-scalar otherwise;
# a genuinely-mechanical performance field (deterministic-op wall-clock) is
# present and never an agent-written number; and the log is append-only — no
# code path rewrites it.
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$CLAUDE_DIR/meter.sh"
ROOT="$(cd "$CLAUDE_DIR/.." && pwd)"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A minimal project root: a manifest (single-repo) and a docs/sessions/ dir so
# the writer can derive the harness session id the way siblings resolve state.
make_project() {  # echoes the project dir
  local p="$WORK/proj.$RANDOM"
  rm -rf "$p"
  mkdir -p "$p/.claude" "$p/docs/sessions"
  jq -n '{roots:{control:".",code:"."},name:"t",language:"node",ceremony:"phased"}' \
    > "$p/.claude/project.json"
  echo "session-2026-06-13-001" > /dev/null  # convention reminder
  printf '# handoff\n' > "$p/docs/sessions/session-2026-06-13-001.md"
  echo "$p"
}

# --- The writer must exist and be the only NDJSON producer (RED until built) ---
[ -f "$SCRIPT" ] \
  && ok "writer script exists at .claude/meter.sh" \
  || no "writer script missing at .claude/meter.sh"

# T1 — a session produces ONE valid NDJSON entry.
P=$(make_project)
LOG="$P/.claude/metering/metering.ndjson"
( cd "$P" && bash "$SCRIPT" capture --deliverables "9.1" ) >"$WORK/t1.out" 2>"$WORK/t1.err"; RC=$?
LINES=$( [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0 )
[ $RC -eq 0 ] && [ "$LINES" = "1" ] && jq -e . "$LOG" >/dev/null 2>&1 \
  && ok "one session -> exactly one valid JSON line (rc=$RC, lines=$LINES)" \
  || no "expected one valid NDJSON line (rc=$RC, lines=$LINES, err=$(cat "$WORK/t1.err"))"

# T2 — the entry carries the required harness/git-derived fields.
ENTRY=$( [ -f "$LOG" ] && tail -1 "$LOG" || echo '{}' )
for f in ts session deliverable_ids model tokens dollars perf; do
  echo "$ENTRY" | jq -e "has(\"$f\")" >/dev/null 2>&1 \
    && ok "field present: $f" \
    || no "required field missing: $f (entry=$ENTRY)"
done
# timestamp is a real UTC instant (harness-derived via date -u), not an agent string
echo "$ENTRY" | jq -re '.ts' 2>/dev/null | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  && ok "ts is an ISO-8601 UTC instant (harness-derived)" \
  || no "ts is not a UTC instant: $(echo "$ENTRY" | jq -c '.ts')"
# session id follows the docs/sessions/ convention, derived not supplied
echo "$ENTRY" | jq -re '.session' 2>/dev/null | grep -qE '^session-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3}$' \
  && ok "session id matches session-YYYY-MM-DD-NNN, derived from docs/sessions/" \
  || no "session id off-convention: $(echo "$ENTRY" | jq -c '.session')"

# T3 — deliverable-scoped sessions attribute to the ID.
echo "$ENTRY" | jq -e '.deliverable_ids == ["9.1"]' >/dev/null 2>&1 \
  && ok "deliverable-scoped session attributes to the ID (9.1)" \
  || no "expected deliverable_ids == [\"9.1\"], got $(echo "$ENTRY" | jq -c '.deliverable_ids')"

# T3b — multiple IDs are recorded as a list.
P3=$(make_project); LOG3="$P3/.claude/metering/metering.ndjson"
( cd "$P3" && bash "$SCRIPT" capture --deliverables "9.1,9.4" ) >/dev/null 2>&1
tail -1 "$LOG3" | jq -e '.deliverable_ids == ["9.1","9.4"]' >/dev/null 2>&1 \
  && ok "comma-separated deliverables attribute to both IDs" \
  || no "expected [\"9.1\",\"9.4\"], got $(tail -1 "$LOG3" | jq -c '.deliverable_ids')"

# T4 — a session with no single applicable ID records session-scalar.
P4=$(make_project); LOG4="$P4/.claude/metering/metering.ndjson"
( cd "$P4" && bash "$SCRIPT" capture ) >/dev/null 2>&1
tail -1 "$LOG4" | jq -e '.deliverable_ids == ["session-scalar"]' >/dev/null 2>&1 \
  && ok "no deliverable given -> session-scalar attribution" \
  || no "expected [\"session-scalar\"], got $(tail -1 "$LOG4" | jq -c '.deliverable_ids')"
# an explicitly-empty deliverable string is also session-scalar, never a blank id
P4b=$(make_project); LOG4b="$P4b/.claude/metering/metering.ndjson"
( cd "$P4b" && bash "$SCRIPT" capture --deliverables "" ) >/dev/null 2>&1
tail -1 "$LOG4b" | jq -e '.deliverable_ids == ["session-scalar"]' >/dev/null 2>&1 \
  && ok "empty --deliverables -> session-scalar (never a blank id)" \
  || no "empty deliverables must map to session-scalar, got $(tail -1 "$LOG4b" | jq -c '.deliverable_ids')"

# T5 — the mechanical performance field is present, harness-derived, numeric.
# op_wallclock_s is the deterministic-operation wall-clock the script measures
# of its OWN session-close work — the genuinely mechanical perf field the
# acceptance requires. It must be a number the script produced, not a value any
# caller passed in.
echo "$ENTRY" | jq -e '.perf | has("op_wallclock_s")' >/dev/null 2>&1 \
  && echo "$ENTRY" | jq -e '.perf.op_wallclock_s | type == "number"' >/dev/null 2>&1 \
  && echo "$ENTRY" | jq -e '.perf.op_wallclock_s >= 0' >/dev/null 2>&1 \
  && ok "perf.op_wallclock_s present, numeric, >= 0 (mechanical, script-measured)" \
  || no "perf.op_wallclock_s must be a non-negative number the script measured ($(echo "$ENTRY" | jq -c '.perf'))"

# T5b — the perf field is NOT a value any agent/caller can dictate. The writer
# accepts NO flag that sets op_wallclock_s; it is always the script's own
# measurement. (Asserted on the writer source: no CLI path writes that field
# from input.) This is the "no agent-written value" guarantee.
grep -nE -- '--op[-_]?wallclock|--op[-_]?wall[-_]?clock|--op-time|--wallclock' "$SCRIPT" >/dev/null 2>&1 \
  && no "writer exposes a flag to set op_wallclock_s — the perf field must be script-measured only" \
  || ok "no CLI flag sets op_wallclock_s — the perf field is script-measured only (no agent value)"

# T6 — NO derived/aggregate field appears in the log (raw evidence only;
# aggregation is [9.5] downstream). Asserted both on the entry and on the writer
# source: the writer never emits a total/sum/average/rate/cost-per field.
DERIVED=$(echo "$ENTRY" | jq -r 'paths(scalars) | map(tostring) | join(".")' 2>/dev/null \
  | grep -iE 'total|sum|avg|average|mean|rate|per_|_per|cost_per|aggregate|cumulative|burn_rate|tokens_per' || true)
[ -z "$DERIVED" ] \
  && ok "no derived/aggregate field in the entry (raw evidence only)" \
  || no "derived field(s) leaked into the log: $DERIVED"
# the writer source must not EMIT a derived/aggregate FIELD into the entry. The
# guarantee is about what lands in the log, so scan for a derived field NAME
# being assigned as a JSON key in the entry-building jq — not for arithmetic per
# se (summing a transcript's per-message usage by class is raw EXTRACTION of the
# boundary's evidence, not a derived field). The writer must never key the entry
# on total/avg/rate/cost_per/burn_rate/per-anything.
grep -nE '^[[:space:]]*(total|sum|avg|average|mean|rate|aggregate|cumulative|burn_rate|tokens_per|cost_per|per_[a-z]+|[a-z_]+_per)[[:space:]]*:' "$SCRIPT" 2>/dev/null \
  | grep -viE '^\s*#' >/dev/null 2>&1 \
  && no "writer source emits a derived/aggregate field into the entry (raw log must stay raw)" \
  || ok "writer source emits no derived/aggregate field into the entry"

# T7 — APPEND-ONLY: a second capture appends; the first line is byte-identical.
P7=$(make_project); LOG7="$P7/.claude/metering/metering.ndjson"
( cd "$P7" && bash "$SCRIPT" capture --deliverables "9.1" ) >/dev/null 2>&1
FIRST=$(head -1 "$LOG7")
( cd "$P7" && bash "$SCRIPT" capture --deliverables "9.4" ) >/dev/null 2>&1
N=$(wc -l < "$LOG7" | tr -d ' ')
NOWFIRST=$(head -1 "$LOG7")
[ "$N" = "2" ] && [ "$FIRST" = "$NOWFIRST" ] \
  && ok "second capture appends (2 lines) and leaves line 1 byte-identical" \
  || no "append-only violated: lines=$N, line1 changed=$([ "$FIRST" = "$NOWFIRST" ] && echo no || echo YES)"

# T7b — APPEND-ONLY, grep-asserted on the source: no code path rewrites the log.
# The only write primitive permitted against the log is append (>>). Any
# truncating redirect (single >), in-place edit (sed -i), or mv/cp onto the log
# would rewrite it.
LOGVAR='(LOG|METER_LOG|METERING_LOG|LOGFILE)'
# A TRUNCATING redirect is a lone '>' used as a redirection operator (space on
# each side) before the log target — '> "$LOG"' truncates, '>> "$LOG"' appends,
# and a '-> $LOG' arrow in an echo string is not a redirect at all. Require
# whitespace before the '>' so the arrow's '-' disqualifies it.
grep -nE '[[:space:]]>[[:space:]]*"?\$\{?'"$LOGVAR" "$SCRIPT" 2>/dev/null \
  | grep -vE '>>|^[[:space:]]*[0-9]+:[[:space:]]*#' >/dev/null 2>&1 \
  && no "writer source has a truncating redirect onto the log (rewrites it)" \
  || ok "no truncating redirect onto the log in the writer source"
grep -nE 'sed -i|sed --in-place' "$SCRIPT" 2>/dev/null | grep -vE '^\s*#' >/dev/null 2>&1 \
  && no "writer source uses sed -i (rewrites the log in place)" \
  || ok "writer source uses no in-place edit (sed -i)"
# the writer DOES append (proves it is a writer, and that the append form is used)
grep -nE '>>[[:space:]]*"?\$\{?'"$LOGVAR" "$SCRIPT" >/dev/null 2>&1 \
  && ok "writer appends with >> (the only sanctioned write to the log)" \
  || no "writer source has no append (>>) to the log — it cannot be append-only-by-construction"

# T7c — no OTHER harness code path rewrites the metering log (grep across the
# whole .claude tree, excluding this writer and its tests/doc). The only file
# allowed to write the log is meter.sh.
OTHERWRITERS=$(grep -rlnE 'metering\.ndjson|metering/metering' \
  "$ROOT/.claude/commands" "$ROOT/.claude/hooks" "$ROOT/.claude/skills" \
  "$ROOT/.claude/render-status.sh" "$ROOT/.claude/merge-queue.sh" \
  "$ROOT/.claude/lane-dispatch.sh" 2>/dev/null \
  | xargs grep -lE '[^>]>[[:space:]]*.*metering|sed -i.*metering|rm .*metering' 2>/dev/null || true)
[ -z "$OTHERWRITERS" ] \
  && ok "no other harness path truncates/edits/removes the metering log" \
  || no "these paths appear to rewrite the metering log: $OTHERWRITERS"

# T8 — Spike C rung is recorded so a reader knows the entry's resolution. When
# tokens are harvestable the rung is B (session-scalar tokens, no guessed
# dollars); when the transcript is absent the writer degrades and the rung
# field still names what was achievable. dollars stays null on rung B/C (no
# guessed price table — Spike C forbids it).
echo "$ENTRY" | jq -e 'has("spike_c_rung")' >/dev/null 2>&1 \
  && ok "spike_c_rung recorded on the entry" \
  || no "entry lacks spike_c_rung (the harvest rung must be self-describing)"
echo "$ENTRY" | jq -e '.dollars == null' >/dev/null 2>&1 \
  && ok "dollars is null (Spike C rung B/C: token-only, no guessed price table)" \
  || no "dollars must be null on the token-only rung, got $(echo "$ENTRY" | jq -c '.dollars')"

# T9 — token fields are by class (or null when the transcript is unharvestable),
# and are NEVER agent-supplied. The writer exposes no flag to inject token
# counts; they come from the transcript or are null.
echo "$ENTRY" | jq -e '.tokens == null or (.tokens | has("input") and has("output"))' >/dev/null 2>&1 \
  && ok "tokens is null or carries by-class counts (input/output present)" \
  || no "tokens malformed: $(echo "$ENTRY" | jq -c '.tokens')"
grep -nE -- '--tokens|--input-tokens|--output-tokens|--cost|--dollars' "$SCRIPT" >/dev/null 2>&1 \
  && no "writer exposes a flag to inject token/cost values — those must be harvested, never agent-reported" \
  || ok "no CLI flag injects token/cost values (harvested or null, never agent-reported)"

# T10 — the writer resolves the log path relative to the project root (siblings'
# convention), never a hardcoded absolute path. Two different project roots get
# two different logs.
grep -nE '/Users/|/home/[a-z]' "$SCRIPT" 2>/dev/null | grep -vE '^\s*#' >/dev/null 2>&1 \
  && no "writer hardcodes an absolute home path (must resolve relative to the project root)" \
  || ok "writer hardcodes no absolute path (resolves relative to the project root)"
[ -f "$LOG" ] && [ -f "$LOG7" ] && [ "$LOG" != "$LOG7" ] \
  && ok "two project roots write to two distinct logs (path is root-relative)" \
  || no "log path is not root-relative"

# T11 — the NDJSON shape is documented in its OWN file under .claude/.
SHAPEDOC=$(ls "$CLAUDE_DIR"/metering*.md "$CLAUDE_DIR"/meter*.md 2>/dev/null | head -1)
[ -n "$SHAPEDOC" ] && [ -f "$SHAPEDOC" ] \
  && ok "shape doc exists ($([ -n "$SHAPEDOC" ] && basename "$SHAPEDOC"))" \
  || no "no shape doc file under .claude/ (metering*.md / meter*.md)"
if [ -n "$SHAPEDOC" ]; then
  # the doc must name every top-level field the writer emits, so it stays a
  # contract and not decoration
  MISSING=""
  for f in ts session deliverable_ids model tokens dollars perf spike_c_rung; do
    grep -q "$f" "$SHAPEDOC" || MISSING="$MISSING $f"
  done
  [ -z "$MISSING" ] \
    && ok "shape doc documents every emitted field" \
    || no "shape doc omits field(s):$MISSING"
  grep -qiE 'append-only|append only' "$SHAPEDOC" \
    && ok "shape doc states the append-only invariant" \
    || no "shape doc does not state the append-only invariant"
  grep -qiE 'spike c|rung' "$SHAPEDOC" \
    && ok "shape doc records the Spike C rung taken" \
    || no "shape doc does not record the Spike C rung"
fi

# T12 — handoff.md wires the writer into the session-close path.
HANDOFF="$ROOT/.claude/commands/handoff.md"
grep -qE 'meter\.sh' "$HANDOFF" \
  && ok "handoff.md invokes the metering writer at session-close" \
  || no "handoff.md does not wire in meter.sh"

# T13 — degraded harvest: when no transcript is reachable (the harvest source is
# a research-preview surface; Rule 15 designed degradation), the entry still
# validates with the mechanical fields and tokens=null — the log existing never
# depends on Spike C. The fixture provides no transcript, so this is the path
# the suite already exercised; assert tokens degraded cleanly to null OR a
# harvested object, and the perf field is present regardless.
echo "$ENTRY" | jq -e '.perf.op_wallclock_s | type == "number"' >/dev/null 2>&1 \
  && ok "perf field present even with no harvestable transcript (log never blocks on Spike C)" \
  || no "perf field must survive an unharvestable transcript"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
