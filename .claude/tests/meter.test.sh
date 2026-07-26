#!/bin/bash
# Tests for .claude/meter.sh — session-boundary cost-and-performance capture ([9.1]).
# Pure bash + jq, no test runner required. Run: bash .claude/tests/meter.test.sh
#
# These tests verify INTENT, not "runs without crashing" (Rule 8): the metering
# log is RAW EVIDENCE — every field is guv- or git-derived, never agent-
# reported; no derived/aggregate field is computed (that is [9.5] downstream);
# attribution is the deliverable ID when one applies, session-scalar otherwise;
# the mechanical performance fields (deterministic-op wall-clock AND suite
# runtime) are never agent-written numbers — op_wallclock_s is script-measured,
# suite_runtime_s is script-measured (--run-suite) or read from the guv
# artifact, with NO flag or agent input able to set either; and the log is
# append-only — no code path rewrites it.
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
# the writer can derive the session id the way siblings resolve state.
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

# T2 — the entry carries the required guv/git-derived fields.
ENTRY=$( [ -f "$LOG" ] && tail -1 "$LOG" || echo '{}' )
for f in ts session deliverable_ids model tokens dollars perf; do
  echo "$ENTRY" | jq -e "has(\"$f\")" >/dev/null 2>&1 \
    && ok "field present: $f" \
    || no "required field missing: $f (entry=$ENTRY)"
done
# timestamp is a real UTC instant (guv-derived via date -u), not an agent string
echo "$ENTRY" | jq -re '.ts' 2>/dev/null | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  && ok "ts is an ISO-8601 UTC instant (guv-derived)" \
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

# T5 — the mechanical performance field is present, guv-derived, numeric.
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

# T5c — suite_runtime_s is MECHANICAL ONLY: NO flag or agent input may set it.
# The defining invariant of [9.1] is "every field guv/git-derived, never
# agent-reported", and suite_runtime_s is a perf field the acceptance scrutinizes.
# A --suite-runtime <number> path would let an agent inject the value (e.g.
# --suite-runtime 9.999), breaking the no-agent-I/O contract. Asserted on the
# writer source: no flag that takes a suite-runtime VALUE exists. (Scoped to a
# value-taking flag so the mechanical --run-suite, which takes no value, stays
# legal.) Written RED-first: this FAILED against the pre-fix --suite-runtime code.
grep -nE -- '--suite[-_]?runtime|--suite[-_]?time|--runtime[[:space:]]' "$SCRIPT" 2>/dev/null \
  | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' >/dev/null 2>&1 \
  && no "writer exposes a flag to set suite_runtime_s — that perf field must be mechanical only (no agent value)" \
  || ok "no CLI flag sets suite_runtime_s — mechanical only (--run-suite or the guv artifact, never agent input)"

# T5d — POSITIVE: the mechanical artifact source produces a measured value. The
# session-close path writes the suite wall-clock to .claude/metering/.last-suite-
# runtime; the writer READS it (mechanical, guv-written, not a CLI arg) into
# perf.suite_runtime_s. This proves the field is actually populated in production,
# not permanently null.
P5d=$(make_project); LOG5d="$P5d/.claude/metering/metering.ndjson"
mkdir -p "$P5d/.claude/metering"
printf '2.500\n' > "$P5d/.claude/metering/.last-suite-runtime"   # the guv-written artifact
( cd "$P5d" && bash "$SCRIPT" capture --deliverables "9.1" ) >/dev/null 2>"$WORK/t5d.err"
tail -1 "$LOG5d" | jq -e '.perf.suite_runtime_s == 2.5' >/dev/null 2>&1 \
  && ok "suite_runtime_s read from the guv artifact (mechanical, == 2.5)" \
  || no "expected suite_runtime_s == 2.5 from the artifact, got $(tail -1 "$LOG5d" | jq -c '.perf.suite_runtime_s') (err=$(cat "$WORK/t5d.err"))"
# a non-numeric artifact is never trusted into the log -> null (never an agent string)
P5dx=$(make_project); LOG5dx="$P5dx/.claude/metering/metering.ndjson"
mkdir -p "$P5dx/.claude/metering"
printf 'not-a-number\n' > "$P5dx/.claude/metering/.last-suite-runtime"
( cd "$P5dx" && bash "$SCRIPT" capture --deliverables "9.1" ) >/dev/null 2>&1
tail -1 "$LOG5dx" | jq -e '.perf.suite_runtime_s == null' >/dev/null 2>&1 \
  && ok "non-numeric artifact -> suite_runtime_s null (never an agent string into the log)" \
  || no "non-numeric artifact must degrade to null, got $(tail -1 "$LOG5dx" | jq -c '.perf.suite_runtime_s')"

# T5e — DEGRADATION (Rule 15): no artifact present -> suite_runtime_s is null,
# never an agent value. The default fixture writes no artifact, so the baseline
# ENTRY already exercises this; assert it explicitly on a clean project.
P5e=$(make_project); LOG5e="$P5e/.claude/metering/metering.ndjson"
( cd "$P5e" && bash "$SCRIPT" capture --deliverables "9.1" ) >/dev/null 2>&1
tail -1 "$LOG5e" | jq -e '.perf | has("suite_runtime_s") and .suite_runtime_s == null' >/dev/null 2>&1 \
  && ok "no artifact -> suite_runtime_s present and null (designed degradation, never an agent value)" \
  || no "absent artifact must yield suite_runtime_s: null, got $(tail -1 "$LOG5e" | jq -c '.perf.suite_runtime_s')"

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

# T7c — no OTHER guv code path rewrites the metering log (grep across the
# whole .claude tree, excluding this writer and its tests/doc). The only file
# allowed to write the log is meter.sh.
OTHERWRITERS=$(grep -rlnE 'metering\.ndjson|metering/metering' \
  "$ROOT/.claude/commands" "$ROOT/.claude/hooks" "$ROOT/.claude/skills" \
  "$ROOT/.claude/render-status.sh" "$ROOT/.claude/merge-queue.sh" \
  "$ROOT/.claude/lane-dispatch.sh" 2>/dev/null \
  | xargs grep -lE '[^>]>[[:space:]]*.*metering|sed -i.*metering|rm .*metering' 2>/dev/null || true)
[ -z "$OTHERWRITERS" ] \
  && ok "no other guv path truncates/edits/removes the metering log" \
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
  # The doc must name every top-level field the writer emits, so it stays a
  # contract and not decoration. DERIVE that list from the writer — a hardcoded one
  # silently stops pinning "every field" the moment a field is added, which is
  # exactly what happened to harvest_basis (caught in review, 2026-07-25, not here).
  EMITTED=$(sed -n "/^ENTRY=\$(jq -cn/,/^   }')/p" "$SCRIPT" | sed -nE 's/^     ([a-z_]+):.*/\1/p')
  [ -n "$EMITTED" ] \
    && ok "the emitted-field list is derived from the writer, not hardcoded ($(printf '%s' "$EMITTED" | wc -w | tr -d ' ') fields)" \
    || no "could not derive the writer's emitted field list — the shape-doc guard would silently pass"
  MISSING=""
  for f in $EMITTED; do
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
HANDOFF="$ROOT/.claude/skills/handoff/SKILL.md"
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

# T14 — SUBAGENT-TOKEN CAPTURE ([13.1], the eval/fix spike). The token burn of the
# subagent reviewers (evaluator/reviewer) and any lane/workflow agents a session
# spawns lives in their OWN transcripts under the SIBLING <session>/ tree
# (subagents/, …), NOT in the main <session>.jsonl. A session-scalar total that
# harvested only the main transcript would systematically UNDERCOUNT real burn —
# and the missing burn is exactly the eval/fix loop the projection ([13.3]) must
# predict. The harvest therefore sums the main transcript PLUS every *.jsonl under
# the sibling <session>/ tree. These tests pin the captured path (the [13.1]
# finding: the meter CAPTURES subagent burn, not a disclosed exclusion). HOME is
# overridden to a fixture root and the slug computed the way the script does
# (pwd -P), so the path matches regardless of macOS /var symlink resolution.
mk_transcript() {  # $1=project $2=fake-home $3=session-id — main + one subagent
  local p="$1" fh="$2" sid="$3" slug base
  slug=$(cd "$p" && pwd -P | sed 's#/#-#g')
  base="$fh/.claude/projects/$slug"
  mkdir -p "$base/$sid/subagents"
  # main: cache_read 100, input 10, output 5, cache_creation 3, model claude-main
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-main","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":3}}}' \
    > "$base/$sid.jsonl"
  # subagent: cache_read 900, input 2, output 1, cache_creation 7, model claude-sub
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-sub","usage":{"input_tokens":2,"output_tokens":1,"cache_read_input_tokens":900,"cache_creation_input_tokens":7}}}' \
    > "$base/$sid/subagents/agent-deadbeef.jsonl"
}

P14=$(make_project); LOG14="$P14/.claude/metering/metering.ndjson"
FH14="$WORK/home.$RANDOM"; SID14="11111111-2222-3333-4444-555555555555"
mk_transcript "$P14" "$FH14" "$SID14"
( cd "$P14" && HOME="$FH14" CLAUDE_CODE_SESSION_ID="$SID14" bash "$SCRIPT" capture --deliverables "13.1" ) >/dev/null 2>"$WORK/t14.err"
E14=$( [ -f "$LOG14" ] && tail -1 "$LOG14" || echo '{}' )
# headline: cache_read = main(100) + subagent(900) = 1000. RED against a main-only
# harvest (would be 100); GREEN once the sibling subagent transcripts are summed.
echo "$E14" | jq -e '.tokens.cache_read == 1000' >/dev/null 2>&1 \
  && ok "harvest INCLUDES subagent cache_read (100 main + 900 subagent = 1000)" \
  || no "subagent burn not captured: expected cache_read 1000, got $(echo "$E14" | jq -c '.tokens') (err=$(cat "$WORK/t14.err"))"
# every class is summed across main + subagents, not just cache_read
echo "$E14" | jq -e '.tokens.input == 12 and .tokens.output == 6 and .tokens.cache_creation == 10' >/dev/null 2>&1 \
  && ok "all token classes summed across main + subagents (input 12, output 6, cache_creation 10)" \
  || no "expected input 12 / output 6 / cache_creation 10, got $(echo "$E14" | jq -c '.tokens')"
echo "$E14" | jq -e '.spike_c_rung == "B"' >/dev/null 2>&1 \
  && ok "rung B recorded when the combined harvest succeeds" \
  || no "expected rung B, got $(echo "$E14" | jq -c '.spike_c_rung')"

# T14b — the MODEL is the session's, read from the MAIN transcript ONLY, never a
# subagent's. The subagent message names a different model (claude-sub); were the
# model harvest to slurp subagents, `last` could pick it up. Pins that tokens span
# main+subagents but model does not (the session's model, not a reviewer's).
echo "$E14" | jq -e '.model == "claude-main"' >/dev/null 2>&1 \
  && ok "model harvested from the MAIN transcript only (claude-main, not the subagent's claude-sub)" \
  || no "model must come from the main transcript: expected claude-main, got $(echo "$E14" | jq -c '.model')"

# T14c — BACK-COMPAT: a session that spawned no subagents (no sibling <session>/
# dir) meters exactly as before — main transcript only, no error, rung B.
P14c=$(make_project); LOG14c="$P14c/.claude/metering/metering.ndjson"
FH14c="$WORK/home.$RANDOM"; SID14c="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
slug14c=$(cd "$P14c" && pwd -P | sed 's#/#-#g')
mkdir -p "$FH14c/.claude/projects/$slug14c"
printf '%s\n' '{"type":"assistant","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":42,"cache_creation_input_tokens":0}}}' \
  > "$FH14c/.claude/projects/$slug14c/$SID14c.jsonl"
( cd "$P14c" && HOME="$FH14c" CLAUDE_CODE_SESSION_ID="$SID14c" bash "$SCRIPT" capture ) >/dev/null 2>"$WORK/t14c.err"
tail -1 "$LOG14c" | jq -e '.tokens.cache_read == 42 and .spike_c_rung == "B"' >/dev/null 2>&1 \
  && ok "no subagents dir -> main-only harvest unchanged (back-compat, cache_read 42)" \
  || no "back-compat broken: expected cache_read 42, got $(tail -1 "$LOG14c" | jq -c '.tokens') (err=$(cat "$WORK/t14c.err"))"

# ════════════════════════════════════════════════════════════════════════════
# [13.6] — PER-DELIVERABLE COST METERING: a bounded slice, not the cumulative
# transcript. The meter records a deliverable's burn as the runtime-transcript
# DELTA from the last same-runtime_session capture to now (forensics B2 mechanism
# 1: cumulative_now − cumulative_at_the_prior_capture), self-describing its slice
# basis, and preserving the cumulative high-water reading (transcript_tokens) so
# the NEXT slice can difference against it. This corrects WHAT a session-cost
# measures — the whole-transcript sum made every capture a cumulative snapshot of
# the entire Claude Code session (docs/notes/meter-forensics.md, ~4.6× inflation).
# ════════════════════════════════════════════════════════════════════════════

# Seed a PRIOR same-runtime_session capture carrying a cumulative high-water
# reading, so the next capture has something to difference against.
seed_prior() {  # $1=log $2=runtime_session $3=ts $4=cumulative-json  [$5=harvest vintage]
  # $5 defaults to "per_response" — a prior banked by the CURRENT harvester, which
  # is what every delta test means by "a prior capture". Pass "legacy" to seed a
  # PRE-dedupe entry (the field absent entirely), the vintage boundary T20 pins.
  printf '%s\n' "$(jq -cn --arg rs "$2" --arg ts "$3" --argjson cum "$4" --arg hb "${5:-per_response}" \
    '{schema:"guv.meter.v1", ts:$ts, session:"session-2026-06-16-001",
      session_derived:true, runtime_session:$rs, deliverable_ids:["13.6"],
      model:"m", tokens:$cum, transcript_tokens:$cum, dollars:null,
      spike_c_rung:"B", slice_basis:"since_process_start", compaction_cycles:0,
      perf:{op_wallclock_s:0.1, suite_runtime_s:null}}
     + (if $hb == "legacy" then {} else {harvest_basis:$hb} end)')" >> "$1"
}

# A main transcript carrying a usage line PLUS $4 real compaction summaries
# (isCompactSummary==true, type user, each timestamped) at $5 — the verified-real
# compaction-event shape (docs/notes/meter-forensics.md A1).
mk_transcript_compaction() {  # $1=proj $2=home $3=sid $4=n-compactions $5=compaction-ts
  local p="$1" fh="$2" sid="$3" n="$4" cts="$5" slug base i
  slug=$(cd "$p" && pwd -P | sed 's#/#-#g'); base="$fh/.claude/projects/$slug"
  mkdir -p "$base"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-06-16T12:00:00.000Z","message":{"model":"claude-main","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":3}}}' \
    > "$base/$sid.jsonl"
  i=0; while [ "$i" -lt "$n" ]; do
    printf '%s\n' "{\"type\":\"user\",\"isCompactSummary\":true,\"timestamp\":\"$cts\"}" >> "$base/$sid.jsonl"
    i=$((i + 1))
  done
}

# ── T15 — BOUNDED SLICE: tokens is the per-session DELTA, not the cumulative sum.
# A prior same-runtime_session capture banked cumulative {2,1,300,4}; the current
# transcript harvests cumulative {12,6,1000,10} (mk_transcript: main 100 + sub
# 900 cache_read). The entry's tokens must be the DIFFERENCE {10,5,700,6} — the
# bounded slice — never the whole-transcript {12,6,1000,10}. RED against the
# pre-fix whole-transcript harvest (would record the cumulative).
P15=$(make_project); LOG15="$P15/.claude/metering/metering.ndjson"
FH15="$WORK/home.$RANDOM"; SID15="15151515-1111-2222-3333-444444444444"
mk_transcript "$P15" "$FH15" "$SID15"
mkdir -p "$P15/.claude/metering"
seed_prior "$LOG15" "$SID15" "2026-06-16T09:00:00Z" '{"input":2,"output":1,"cache_read":300,"cache_creation":4}'
( cd "$P15" && HOME="$FH15" CLAUDE_CODE_SESSION_ID="$SID15" bash "$SCRIPT" capture --deliverables "13.6" ) >/dev/null 2>"$WORK/t15.err"
E15=$(tail -1 "$LOG15")
echo "$E15" | jq -e '.tokens == {input:10,output:5,cache_read:700,cache_creation:6}' >/dev/null 2>&1 \
  && ok "[13.6] tokens is the bounded per-session DELTA (cumulative_now − prior capture), not the whole transcript" \
  || no "[13.6] expected delta {10,5,700,6}, got $(echo "$E15" | jq -c '.tokens') (err=$(cat "$WORK/t15.err"))"
echo "$E15" | jq -e '.slice_basis == "per_deliverable"' >/dev/null 2>&1 \
  && ok "[13.6] slice_basis = per_deliverable when a prior same-runtime_session capture exists" \
  || no "[13.6] expected slice_basis per_deliverable, got $(echo "$E15" | jq -c '.slice_basis')"
echo "$E15" | jq -e '.transcript_tokens == {input:12,output:6,cache_read:1000,cache_creation:10}' >/dev/null 2>&1 \
  && ok "[13.6] transcript_tokens preserves the cumulative high-water reading (the next slice differences against it)" \
  || no "[13.6] expected transcript_tokens = full cumulative {12,6,1000,10}, got $(echo "$E15" | jq -c '.transcript_tokens')"

# ── T15b — the slice basis is ALWAYS present and self-describing (Rule 15): no
# reading can be mistaken for the wrong unit. The field is one of the three named
# bases (or null when nothing was harvested), never absent.
echo "$E15" | jq -e 'has("slice_basis") and (.slice_basis | . == "per_deliverable" or . == "since_process_start" or . == "unbounded_cumulative" or . == null)' >/dev/null 2>&1 \
  && ok "[13.6] slice_basis is present and self-describing (per_deliverable|since_process_start|unbounded_cumulative|null)" \
  || no "[13.6] slice_basis must be a recognized basis, got $(echo "$E15" | jq -c '.slice_basis')"

# ── T16 — FIRST capture in a transcript (no prior same-runtime_session entry):
# the slice IS the burn since process start — correct as the first slice, and
# disclosed as such (since_process_start), never silently treated as a bounded
# per-deliverable delta. T14 already exercised a no-prior harvest; pin the basis.
echo "$E14" | jq -e '.slice_basis == "since_process_start" and .tokens.cache_read == 1000' >/dev/null 2>&1 \
  && ok "[13.6] first capture (no prior) → slice_basis since_process_start, slice = full cumulative (disclosed)" \
  || no "[13.6] first capture must disclose since_process_start, got $(echo "$E14" | jq -c '{slice_basis, tokens}')"

# ── T17 — DEGRADATION (Rule 15): if the cumulative shrank vs the prior capture
# (an anomaly — the high-water reading should be monotone within a transcript),
# the slice cannot be trusted as a bounded delta. Disclose it as
# unbounded_cumulative (excluded downstream), never a fabricated negative slice.
P17=$(make_project); LOG17="$P17/.claude/metering/metering.ndjson"
FH17="$WORK/home.$RANDOM"; SID17="17171717-1111-2222-3333-444444444444"
mk_transcript "$P17" "$FH17" "$SID17"   # cumulative now = cache_read 1000
mkdir -p "$P17/.claude/metering"
seed_prior "$LOG17" "$SID17" "2026-06-16T09:00:00Z" '{"input":99,"output":99,"cache_read":9999,"cache_creation":99}'  # prior > now
( cd "$P17" && HOME="$FH17" CLAUDE_CODE_SESSION_ID="$SID17" bash "$SCRIPT" capture --deliverables "13.6" ) >/dev/null 2>"$WORK/t17.err"
E17=$(tail -1 "$LOG17")
echo "$E17" | jq -e '.slice_basis == "unbounded_cumulative" and .tokens.cache_read == 1000' >/dev/null 2>&1 \
  && ok "[13.6] a negative (non-monotone) delta degrades to unbounded_cumulative, tokens = full cumulative (disclosed, never negative)" \
  || no "[13.6] non-monotone cumulative must degrade to unbounded_cumulative, got $(echo "$E17" | jq -c '{slice_basis, tokens}') (err=$(cat "$WORK/t17.err"))"

# ── T18 — COMPACTION-CYCLE COUNT: the meter records how many real compaction
# cycles (isCompactSummary==true, the verified-real event shape) the slice spanned,
# bounded to the slice window (timestamp ≥ the prior capture's ts). Raw evidence
# — a count, like tokens — that powers balloon detection and Phase 14.
P18=$(make_project); LOG18="$P18/.claude/metering/metering.ndjson"
FH18="$WORK/home.$RANDOM"; SID18="18181818-1111-2222-3333-444444444444"
mk_transcript_compaction "$P18" "$FH18" "$SID18" 3 "2026-06-16T12:30:00.000Z"  # 3 compactions, after prior ts
mkdir -p "$P18/.claude/metering"
seed_prior "$LOG18" "$SID18" "2026-06-16T09:00:00Z" '{"input":1,"output":1,"cache_read":1,"cache_creation":1}'
printf '%s\n' '{"13.6":{"sessions":1,"fraction":0.9,"size":"heavy"}}' > "$P18/docs/estimates.json"
( cd "$P18" && HOME="$FH18" CLAUDE_CODE_SESSION_ID="$SID18" bash "$SCRIPT" capture --deliverables "13.6" ) >"$WORK/t18.out" 2>"$WORK/t18.err"; RC18=$?
E18=$(tail -1 "$LOG18")
echo "$E18" | jq -e '.compaction_cycles == 3' >/dev/null 2>&1 \
  && ok "[13.6] compaction_cycles counts the real isCompactSummary events in the slice window (3)" \
  || no "[13.6] expected compaction_cycles 3, got $(echo "$E18" | jq -c '.compaction_cycles') (err=$(cat "$WORK/t18.err"))"

# ── T18b — BALLOON DETECTION, declared not stopped: a deliverable sized to 1
# session (≈1 window) whose slice spanned 3 compaction cycles ballooned past its
# sizing. The meter DECLARES it loudly (a line the handoff surfaces) but the
# capture still SUCCEEDS (exit 0) — a fuzzy breach is declared for a human call,
# never a mid-flight stop ([13.5] semantics, Rule 15).
[ "$RC18" -eq 0 ] \
  && ok "[13.6] a balloon is declared, NOT stopped — capture still exits 0 (fuzzy breach, [13.5] semantics)" \
  || no "[13.6] balloon must not stop the capture, rc=$RC18"
grep -qiE 'balloon|ballooned' "$WORK/t18.out" "$WORK/t18.err" 2>/dev/null \
  && ok "[13.6] the balloon is declared loudly (a 'balloon' line the handoff surfaces)" \
  || no "[13.6] expected a loud balloon declaration (out=$(cat "$WORK/t18.out"); err=$(cat "$WORK/t18.err"))"

# ── T18c — NO false balloon within sizing: a deliverable sized to 2 sessions
# whose slice spanned 1 compaction cycle is within tolerance — no declaration,
# silent success (a reviewer-asked-for-gaps defensive over-fire is its own failure,
# Rule 3).
P18c=$(make_project); LOG18c="$P18c/.claude/metering/metering.ndjson"
FH18c="$WORK/home.$RANDOM"; SID18c="18c18c18-1111-2222-3333-444444444444"
mk_transcript_compaction "$P18c" "$FH18c" "$SID18c" 1 "2026-06-16T12:30:00.000Z"
mkdir -p "$P18c/.claude/metering"
seed_prior "$LOG18c" "$SID18c" "2026-06-16T09:00:00Z" '{"input":1,"output":1,"cache_read":1,"cache_creation":1}'
printf '%s\n' '{"13.6":{"sessions":2,"fraction":0.9,"size":"heavy"}}' > "$P18c/docs/estimates.json"
( cd "$P18c" && HOME="$FH18c" CLAUDE_CODE_SESSION_ID="$SID18c" bash "$SCRIPT" capture --deliverables "13.6" ) >"$WORK/t18c.out" 2>"$WORK/t18c.err"
grep -qiE 'balloon' "$WORK/t18c.out" "$WORK/t18c.err" 2>/dev/null \
  && no "[13.6] false balloon: 1 cycle within a 2-session budget must NOT declare a breach" \
  || ok "[13.6] no false balloon when the slice is within its sized window budget (silent success)"

# ── T18d — UNSIZED deliverable: NO balloon even past 1 cycle. estimate.sh get
# defaults an unsized id to 1, so a budget MUST key on explicit sizing (the sidecar
# carries the id), never the default — else every unsized deliverable "breaches" at
# 2 cycles. A deliverable absent from the sidecar gets no budget → genuinely silent.
# RED against keying the budget on estimate.sh's default-1 (would declare 3 > 1).
P18d=$(make_project); LOG18d="$P18d/.claude/metering/metering.ndjson"
FH18d="$WORK/home.$RANDOM"; SID18d="18d18d18-1111-2222-3333-444444444444"
mk_transcript_compaction "$P18d" "$FH18d" "$SID18d" 3 "2026-06-16T12:30:00.000Z"
mkdir -p "$P18d/.claude/metering"
seed_prior "$LOG18d" "$SID18d" "2026-06-16T09:00:00Z" '{"input":1,"output":1,"cache_read":1,"cache_creation":1}'
printf '%s\n' '{"99.99":1}' > "$P18d/docs/estimates.json"   # sidecar exists but does NOT size 13.6
( cd "$P18d" && HOME="$FH18d" CLAUDE_CODE_SESSION_ID="$SID18d" bash "$SCRIPT" capture --deliverables "13.6" ) >"$WORK/t18d.out" 2>"$WORK/t18d.err"
tail -1 "$LOG18d" | jq -e '.compaction_cycles == 3' >/dev/null 2>&1 \
  && ! grep -qiE 'balloon' "$WORK/t18d.out" "$WORK/t18d.err" 2>/dev/null \
  && ok "[13.6] an UNSIZED deliverable past threshold declares NO balloon (budget keys on explicit sizing, not estimate.sh's default-1)" \
  || no "[13.6] unsized deliverable must stay silent: cycles=$(tail -1 "$LOG18d" | jq -c '.compaction_cycles') out=$(cat "$WORK/t18d.out") err=$(cat "$WORK/t18d.err")"

# ── T18e — since_process_start: NO balloon. On the FIRST capture of a transcript the
# compaction count spans the WHOLE process (no prior bound), not this deliverable's
# slice — so it is not attributable to one deliverable's budget. A sized deliverable
# captured first with many compactions must NOT declare a balloon (the feature's own
# honesty discipline: the token slice discloses since_process_start; the balloon must
# honor it too). RED against a guard that excludes only session-scalar/unsized.
P18e=$(make_project); LOG18e="$P18e/.claude/metering/metering.ndjson"
FH18e="$WORK/home.$RANDOM"; SID18e="18e18e18-1111-2222-3333-444444444444"
mk_transcript_compaction "$P18e" "$FH18e" "$SID18e" 8 "2026-06-16T12:30:00.000Z"   # 8 process-wide compactions
mkdir -p "$P18e/.claude/metering"                                                   # NO prior entry → since_process_start
printf '%s\n' '{"13.6":{"sessions":1,"fraction":0.9,"size":"heavy"}}' > "$P18e/docs/estimates.json"
( cd "$P18e" && HOME="$FH18e" CLAUDE_CODE_SESSION_ID="$SID18e" bash "$SCRIPT" capture --deliverables "13.6" ) >"$WORK/t18e.out" 2>"$WORK/t18e.err"
E18e=$(tail -1 "$LOG18e")
echo "$E18e" | jq -e '.slice_basis == "since_process_start"' >/dev/null 2>&1 \
  && ! grep -qiE 'balloon' "$WORK/t18e.out" "$WORK/t18e.err" 2>/dev/null \
  && ok "[13.6] a since_process_start first capture declares NO balloon (whole-process count not attributable to one deliverable)" \
  || no "[13.6] since_process_start must not balloon: basis=$(echo "$E18e" | jq -c '.slice_basis') out=$(cat "$WORK/t18e.out") err=$(cat "$WORK/t18e.err")"

# ── T18f — SLICE-BOUNDARY ts precision: a compaction in the SAME SECOND as the prior
# capture is counted. The metering ts is whole-second (date -u, "…09:00:00Z"); the
# transcript timestamp is millisecond ("…09:00:00.500Z"). A naive string compare puts
# "…00.500Z" < "…00Z" (the '.' sorts before 'Z'), wrongly excluding the boundary
# event. The fix compares the second-precision prefix, so the bound is exact. RED
# against the naive compare (would count 0).
P18f=$(make_project); LOG18f="$P18f/.claude/metering/metering.ndjson"
FH18f="$WORK/home.$RANDOM"; SID18f="18f18f18-1111-2222-3333-444444444444"
mk_transcript_compaction "$P18f" "$FH18f" "$SID18f" 2 "2026-06-16T09:00:00.500Z"  # same second as prior ts
mkdir -p "$P18f/.claude/metering"
seed_prior "$LOG18f" "$SID18f" "2026-06-16T09:00:00Z" '{"input":1,"output":1,"cache_read":1,"cache_creation":1}'
( cd "$P18f" && HOME="$FH18f" CLAUDE_CODE_SESSION_ID="$SID18f" bash "$SCRIPT" capture --deliverables "13.6" ) >/dev/null 2>"$WORK/t18f.err"
tail -1 "$LOG18f" | jq -e '.compaction_cycles == 2' >/dev/null 2>&1 \
  && ok "[13.6] a same-second compaction is counted (second-precision boundary, not dropped by the ms-vs-s string compare)" \
  || no "[13.6] same-second compaction must count: got $(tail -1 "$LOG18f" | jq -c '.compaction_cycles') (err=$(cat "$WORK/t18f.err"))"

# ════════════════════════════════════════════════════════════════════════════
# PER-RESPONSE DEDUPE — one API response counts ONCE, however many transcript
# lines it occupies. The runtime serializes a single assistant response as N
# lines, one per content block (thinking / text / tool_use), and EVERY line
# repeats the IDENTICAL message.usage object. Summing per line therefore
# multiplies input/cache_read/cache_creation by the block count — i.e. by the
# number of tool calls in the turn. Measured 2026-07-25 on the guv-guv transcript
# tree (192 files, 8,422 responses across 21,323 usage lines — the corpus grows, so
# the counts are as-of and the RATIO is the finding): 2.5x inflation, ~1.32B
# phantom tokens. The billing cross-check is PARTIAL — /cost reports a scope this
# analysis could not reconstruct, so there is no absolute per-model reconciliation;
# on opus-5 (the one model concentrated in the billed period) deduped output is
# 1.03x of billed vs 2.35x per-line. The load-bearing evidence is structural: no
# message.id spans two requestIds, so a requestId is a response boundary.
# This is NOT cosmetic: burn = input+output+cache_read+cache_creation feeds
# budget-gate.sh's BREACH decision, the [13.4] forecast grade, and the
# calibration record. Worse, the error is SHAPE-DEPENDENT (tool-heavy turns
# inflate more than prose turns), so it biases any comparison between
# differently-shaped work rather than cancelling out.
# The harvest groups usage by requestId and takes the max per class — max is
# correct under BOTH observed serializations (identical repeats, and
# placeholder-output-until-the-final-line) and ignores aborted all-zero lines.
# ════════════════════════════════════════════════════════════════════════════

# ── T19 — a multi-block response is counted once; distinct responses still sum;
# the true output is the max across the response's lines (the placeholder
# serialization writes a near-zero output on every line but the last).
# req_A: 3 identical lines {10,5,100,3}          -> contributes {10,5,100,3}
# req_B: 3 lines, output 3/3/500, rest identical -> contributes {7,500,200,1}
# expected total {17,505,300,4}. RED pre-fix: per-line sum gives {51,521,900,12}.
mk_multiblock() {  # $1=proj $2=home $3=sid
  local p="$1" fh="$2" sid="$3" slug base
  slug=$(cd "$p" && pwd -P | sed 's#/#-#g'); base="$fh/.claude/projects/$slug"
  mkdir -p "$base"
  {
    printf '%s\n' '{"type":"assistant","requestId":"req_A","message":{"model":"claude-main","content":[{"type":"thinking"}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":3}}}'
    printf '%s\n' '{"type":"assistant","requestId":"req_A","message":{"model":"claude-main","content":[{"type":"text"}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":3}}}'
    printf '%s\n' '{"type":"assistant","requestId":"req_A","message":{"model":"claude-main","content":[{"type":"tool_use"}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":3}}}'
    printf '%s\n' '{"type":"assistant","requestId":"req_B","message":{"model":"claude-main","content":[{"type":"thinking"}],"usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":200,"cache_creation_input_tokens":1}}}'
    printf '%s\n' '{"type":"assistant","requestId":"req_B","message":{"model":"claude-main","content":[{"type":"tool_use"}],"usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":200,"cache_creation_input_tokens":1}}}'
    printf '%s\n' '{"type":"assistant","requestId":"req_B","message":{"model":"claude-main","content":[{"type":"tool_use"}],"usage":{"input_tokens":7,"output_tokens":500,"cache_read_input_tokens":200,"cache_creation_input_tokens":1}}}'
  } > "$base/$sid.jsonl"
}
P19=$(make_project); LOG19="$P19/.claude/metering/metering.ndjson"
FH19="$WORK/home.$RANDOM"; SID19="19191919-1111-2222-3333-444444444444"
mk_multiblock "$P19" "$FH19" "$SID19"
( cd "$P19" && HOME="$FH19" CLAUDE_CODE_SESSION_ID="$SID19" bash "$SCRIPT" capture --deliverables "9.1" ) >/dev/null 2>"$WORK/t19.err"
E19=$(tail -1 "$LOG19")
echo "$E19" | jq -e '.tokens == {input:17,output:505,cache_read:300,cache_creation:4}' >/dev/null 2>&1 \
  && ok "a multi-block response counts ONCE per class (req_A+req_B = {17,505,300,4}, not the per-line {51,521,900,12})" \
  || no "per-response dedupe missing: expected {17,505,300,4}, got $(echo "$E19" | jq -c '.tokens') (err=$(cat "$WORK/t19.err"))"
# the response's TRUE output is the max across its lines, never the placeholder
echo "$E19" | jq -e '.tokens.output == 505' >/dev/null 2>&1 \
  && ok "output takes the max across a response's lines (500 final, not the 3-token placeholder)" \
  || no "output must be the per-response max: expected 505, got $(echo "$E19" | jq -c '.tokens.output')"

# ── T19b — BACK-COMPAT: usage lines carrying NO requestId are NOT collapsed
# together. The dedupe key falls back to a per-line synthetic when neither
# requestId nor uuid is present, so pre-existing transcripts (and every fixture
# above) meter exactly as before. Guards the fallback: a naive `.requestId //
# .uuid` would group all key-less lines under null and take one max, silently
# DROPPING real burn — the opposite failure, and a worse one.
P19b=$(make_project); LOG19b="$P19b/.claude/metering/metering.ndjson"
FH19b="$WORK/home.$RANDOM"; SID19b="19b19b19-1111-2222-3333-444444444444"
slug19b=$(cd "$P19b" && pwd -P | sed 's#/#-#g')
mkdir -p "$FH19b/.claude/projects/$slug19b"
{
  printf '%s\n' '{"type":"assistant","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":40,"cache_creation_input_tokens":2}}}'
  printf '%s\n' '{"type":"assistant","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":40,"cache_creation_input_tokens":2}}}'
} > "$FH19b/.claude/projects/$slug19b/$SID19b.jsonl"
( cd "$P19b" && HOME="$FH19b" CLAUDE_CODE_SESSION_ID="$SID19b" bash "$SCRIPT" capture ) >/dev/null 2>"$WORK/t19b.err"
tail -1 "$LOG19b" | jq -e '.tokens == {input:2,output:2,cache_read:80,cache_creation:4}' >/dev/null 2>&1 \
  && ok "key-less usage lines each count (no requestId -> per-line synthetic key, back-compat {2,2,80,4})" \
  || no "key-less lines were collapsed: expected {2,2,80,4}, got $(tail -1 "$LOG19b" | jq -c '.tokens') (err=$(cat "$WORK/t19b.err"))"

# ── T19bb — the same drop, one rung down: an EMPTY requestId. In jq only null and
# false are falsy, so `"" // .uuid` returns "" and `"" // "__line_N"` returns "" —
# a bare `//` fallback covers an ABSENT key but not an empty one, and three
# distinct responses would collapse to a single max (burn silently dropped, the
# exact failure T19b exists to prevent). Zero occurrences in the real corpus at
# time of writing, so this pins the guard's own contract, not an observed bug.
P19bb=$(make_project); LOG19bb="$P19bb/.claude/metering/metering.ndjson"
FH19bb="$WORK/home.$RANDOM"; SID19bb="19bb19bb-1111-2222-3333-444444444444"
slug19bb=$(cd "$P19bb" && pwd -P | sed 's#/#-#g')
mkdir -p "$FH19bb/.claude/projects/$slug19bb"
{
  printf '%s\n' '{"type":"assistant","requestId":"","message":{"model":"m","usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":1}}}'
  printf '%s\n' '{"type":"assistant","requestId":"","message":{"model":"m","usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":1}}}'
  printf '%s\n' '{"type":"assistant","requestId":"","message":{"model":"m","usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":1}}}'
} > "$FH19bb/.claude/projects/$slug19bb/$SID19bb.jsonl"
( cd "$P19bb" && HOME="$FH19bb" CLAUDE_CODE_SESSION_ID="$SID19bb" bash "$SCRIPT" capture ) >/dev/null 2>"$WORK/t19bb.err"
tail -1 "$LOG19bb" | jq -e '.tokens == {input:15,output:3,cache_read:30,cache_creation:3}' >/dev/null 2>&1 \
  && ok "EMPTY-string requestIds are not collapsed either (three responses total {15,3,30,3}, not one max)" \
  || no "empty requestIds were collapsed: expected {15,3,30,3}, got $(tail -1 "$LOG19bb" | jq -c '.tokens') (err=$(cat "$WORK/t19bb.err"))"

# ── T19c — the dedupe spans the SIBLING subagent tree without collapsing across
# agents: main req_M (2 lines) + subagent req_S (2 lines) each count once and
# still sum to the T14 totals. Pins that [13.1]'s subagent capture and the
# dedupe compose — a per-file dedupe, or a global one, would break one or the other.
P19c=$(make_project); LOG19c="$P19c/.claude/metering/metering.ndjson"
FH19c="$WORK/home.$RANDOM"; SID19c="19c19c19-1111-2222-3333-444444444444"
slug19c=$(cd "$P19c" && pwd -P | sed 's#/#-#g'); base19c="$FH19c/.claude/projects/$slug19c"
mkdir -p "$base19c/$SID19c/subagents"
{
  printf '%s\n' '{"type":"assistant","requestId":"req_M","message":{"model":"claude-main","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":3}}}'
  printf '%s\n' '{"type":"assistant","requestId":"req_M","message":{"model":"claude-main","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":3}}}'
} > "$base19c/$SID19c.jsonl"
{
  printf '%s\n' '{"type":"assistant","requestId":"req_S","message":{"model":"claude-sub","usage":{"input_tokens":2,"output_tokens":1,"cache_read_input_tokens":900,"cache_creation_input_tokens":7}}}'
  printf '%s\n' '{"type":"assistant","requestId":"req_S","message":{"model":"claude-sub","usage":{"input_tokens":2,"output_tokens":1,"cache_read_input_tokens":900,"cache_creation_input_tokens":7}}}'
} > "$base19c/$SID19c/subagents/agent-dedupe.jsonl"
( cd "$P19c" && HOME="$FH19c" CLAUDE_CODE_SESSION_ID="$SID19c" bash "$SCRIPT" capture --deliverables "13.1" ) >/dev/null 2>"$WORK/t19c.err"
tail -1 "$LOG19c" | jq -e '.tokens == {input:12,output:6,cache_read:1000,cache_creation:10}' >/dev/null 2>&1 \
  && ok "dedupe composes with subagent capture (main+sub duplicated lines still total {12,6,1000,10})" \
  || no "dedupe/subagent composition broken: expected {12,6,1000,10}, got $(tail -1 "$LOG19c" | jq -c '.tokens') (err=$(cat "$WORK/t19c.err"))"

# ── T20 — VINTAGE GUARD: never difference a deduped cumulative against a PRE-dedupe
# one. The [13.6] delta guard is MAGNITUDE-based (all classes >= 0), so it catches the
# vintage boundary only while the new-unit cumulative is still smaller than the last
# old-unit reading. The moment it outgrows it — inevitable, since the transcript only
# grows — all four deltas go positive and the entry would be written as a valid
# per_deliverable slice while being a subtraction across two DIFFERENT UNITS (a naive
# per-line sum vs a per-response one, ~2.5x apart). That slice then feeds
# INITIATIVE_BURN and observed_rate() as a real sample. Magnitude cannot detect it;
# only the recorded vintage can. Here the legacy prior is DELIBERATELY small
# ({1,1,1,1} vs a now-cumulative of {12,6,1000,10}) so every delta is positive and the
# magnitude guard is satisfied — the entry must STILL disclose unbounded_cumulative.
P20=$(make_project); LOG20="$P20/.claude/metering/metering.ndjson"
FH20="$WORK/home.$RANDOM"; SID20="20202020-1111-2222-3333-444444444444"
mk_transcript "$P20" "$FH20" "$SID20"   # cumulative now = {12,6,1000,10}
mkdir -p "$P20/.claude/metering"
seed_prior "$LOG20" "$SID20" "2026-06-16T09:00:00Z" '{"input":1,"output":1,"cache_read":1,"cache_creation":1}' legacy
( cd "$P20" && HOME="$FH20" CLAUDE_CODE_SESSION_ID="$SID20" bash "$SCRIPT" capture --deliverables "13.6" ) >/dev/null 2>"$WORK/t20.err"
E20=$(tail -1 "$LOG20")
echo "$E20" | jq -e '.slice_basis == "unbounded_cumulative" and .tokens == {input:12,output:6,cache_read:1000,cache_creation:10}' >/dev/null 2>&1 \
  && ok "a PRE-dedupe prior is never differenced against: vintage boundary discloses unbounded_cumulative, tokens = full cumulative" \
  || no "vintage boundary produced a cross-unit slice: expected unbounded_cumulative + full cumulative, got $(echo "$E20" | jq -c '{slice_basis, tokens}') (err=$(cat "$WORK/t20.err"))"

# ── T20b — the harvest unit is SELF-DESCRIBING on every entry (the [13.6]
# slice_basis discipline applied to the other axis). Without this field the log is
# silently mixed-vintage: no consumer — the gate, observed_rate(), a [13.4] grade,
# or a human — can tell a 2.5x-inflated pre-dedupe reading from a corrected one.
# Read-time recovery is not available here the way [13.6]'s legacy differencing was:
# only 2 of the 14 runtime_sessions in the live log still have transcripts (18 of 54
# entries), so a backfill would be an estimate wearing a measurement's field name.
# The marker is what keeps old and new entries separable instead.
echo "$E20" | jq -e '.harvest_basis == "per_response"' >/dev/null 2>&1 \
  && ok "every entry declares its harvest unit (harvest_basis = per_response)" \
  || no "harvest_basis must be present and per_response, got $(echo "$E20" | jq -c '.harvest_basis')"

# ── T20c — the vintage boundary is DECLARED, not merely recorded. This entry's burn
# silently drops out of every burn sum (gate, observed_rate(), the [13.4] grade) the
# moment it is tagged unbounded_cumulative. An operator who is not told will read the
# resulting step change as the initiative suddenly running under budget. The balloon
# path already declares on stderr for a FUZZIER condition ([13.5]); a unit break in
# the record is at least as load-bearing. Rule 10: a silent designed degradation is
# still silent.
grep -q 'VINTAGE BREAK' "$WORK/t20.err" \
  && ok "the vintage boundary is declared loudly on stderr, not just recorded in the entry" \
  || no "vintage boundary was silent: no 'VINTAGE BREAK' on stderr, got: $(cat "$WORK/t20.err")"

# ── T20d — a DEGRADED harvest declares no harvest unit. harvest_basis describes how
# a reading was taken; when no reading was taken there is no unit to describe, and
# asserting one is a small lie in a record whose whole value is that its fields mean
# what they say. slice_basis already goes null on this path — this is the same
# discipline on the other axis. (No functional impact today: the prior-lookup skips
# entries with a null cumulative, so such an entry is never chosen as a prior. It is
# a self-description invariant, and it is cheap to hold.)
P20d=$(make_project); LOG20D="$P20d/.claude/metering/metering.ndjson"
FH20D="$WORK/home.$RANDOM"
mkdir -p "$P20d/.claude/metering"
# No CLAUDE_CODE_SESSION_ID -> the transcript is unreachable -> designed degradation.
( cd "$P20d" && HOME="$FH20D" bash "$SCRIPT" capture --deliverables "9.1" ) >/dev/null 2>&1
E20D=$(tail -1 "$LOG20D")
echo "$E20D" | jq -e '.spike_c_rung == "degraded" and .tokens == null and .harvest_basis == null' >/dev/null 2>&1 \
  && ok "a degraded harvest declares no harvest unit (harvest_basis null, matching slice_basis)" \
  || no "degraded entry must carry harvest_basis null, got $(echo "$E20D" | jq -c '{spike_c_rung, tokens, slice_basis, harvest_basis}')"

# ── T21 — max is LOAD-BEARING, not cosmetic: neither first nor last is correct.
# Real corpus evidence (2026-07-25, 192 files): requestId req_011CcLJpisVXagzw
# carries an all-zero stop_sequence line sharing a LIVE requestId — `last` would
# silently discard 91,628 tokens there. The observed serializations also include
# placeholder-then-final (early lines near-zero), which is what breaks `first`.
# This fixture reproduces both in one response: zero, real, zero. Only max survives.
P21=$(make_project); LOG21="$P21/.claude/metering/metering.ndjson"
FH21="$WORK/home.$RANDOM"; SID21="21212121-1111-2222-3333-444444444444"
slug21=$(cd "$P21" && pwd -P | sed 's#/#-#g')
mkdir -p "$FH21/.claude/projects/$slug21"
{
  printf '%s\n' '{"type":"assistant","requestId":"req_Z","message":{"model":"m","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
  printf '%s\n' '{"type":"assistant","requestId":"req_Z","message":{"model":"m","usage":{"input_tokens":10,"output_tokens":500,"cache_read_input_tokens":200,"cache_creation_input_tokens":5}}}'
  printf '%s\n' '{"type":"assistant","requestId":"req_Z","message":{"model":"m","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
} > "$FH21/.claude/projects/$slug21/$SID21.jsonl"
( cd "$P21" && HOME="$FH21" CLAUDE_CODE_SESSION_ID="$SID21" bash "$SCRIPT" capture ) >/dev/null 2>"$WORK/t21.err"
tail -1 "$LOG21" | jq -e '.tokens == {input:10,output:500,cache_read:200,cache_creation:5}' >/dev/null 2>&1 \
  && ok "per-response reduction takes MAX (an all-zero line sharing a live requestId never zeroes the response; first/last both wrong)" \
  || no "expected max {10,500,200,5}, got $(tail -1 "$LOG21" | jq -c '.tokens') (err=$(cat "$WORK/t21.err"))"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
