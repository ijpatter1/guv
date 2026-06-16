#!/bin/bash
# Tests for .claude/meter-queue.sh — queue-boundary cost-and-performance capture ([9.4]).
# Pure bash + jq, no test runner required. Run: bash .claude/tests/meter-queue.test.sh
#
# These tests verify INTENT, not "runs without crashing" (Rule 8). [9.4] splits the
# QUEUE boundary off [9.1]'s SESSION boundary so metering as a whole never serializes
# behind the merge queue: a merge-queue landing appends ONE per-deliverable entry
# carrying the mechanical evidence the boundary affords — tokens (harvested, never
# agent-reported), the landing's wall-clock, the diff footprint the GATE already
# computed (files/insertions/deletions — reused, not recomputed here), and the
# dispatch outcome (landed / harvest-refused / conflict-routed). The log is the SAME
# append-only NDJSON the session meter writes; the queue entry is a sibling shape
# (guv.meter.queue.v1). Append-only is preserved; no flag injects tokens or dollars.
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$CLAUDE_DIR/meter-queue.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A minimal control-plane root: the manifest the queue resolves state against.
make_plane() {  # echoes the plane dir
  local p="$WORK/plane.$RANDOM"
  rm -rf "$p"
  mkdir -p "$p/.claude"
  jq -n '{roots:{control:".",code:"."},name:"t",language:"shell",ceremony:"phased"}' \
    > "$p/.claude/project.json"
  echo "$p"
}

# A standard landed capture: the footprint and wall-clock are MECHANICAL inputs the
# queue measured (the gate already computed the footprint; the queue timed the land).
cap_landed() {  # $1=plane $2=id [extra args…]
  local p="$1" id="$2"; shift 2
  ( cd "$p" && bash "$SCRIPT" capture \
      --deliverable "$id" --outcome landed \
      --files 3 --insertions 42 --deletions 7 --wallclock 1.250 "$@" )
}

# ── The helper must exist (RED until built) ──
[ -f "$SCRIPT" ] \
  && ok "queue-boundary writer exists at .claude/meter-queue.sh" \
  || no "writer missing at .claude/meter-queue.sh"

# ── T1 — a landing appends ONE valid NDJSON entry to the metering log ──
P=$(make_plane)
LOG="$P/.claude/metering/metering.ndjson"
cap_landed "$P" 9.4 >"$WORK/t1.out" 2>"$WORK/t1.err"; RC=$?
LINES=$( [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0 )
[ $RC -eq 0 ] && [ "$LINES" = "1" ] && jq -e . "$LOG" >/dev/null 2>&1 \
  && ok "a landing -> exactly one valid JSON line (rc=$RC, lines=$LINES)" \
  || no "expected one valid NDJSON line (rc=$RC, lines=$LINES, err=$(cat "$WORK/t1.err"))"

ENTRY=$( [ -f "$LOG" ] && tail -1 "$LOG" || echo '{}' )

# ── T2 — the entry is attributed to the LANDED deliverable ID ──
echo "$ENTRY" | jq -e '.deliverable_id == "9.4"' >/dev/null 2>&1 \
  && ok "entry attributed to the landed deliverable ID (9.4)" \
  || no "expected deliverable_id == \"9.4\", got $(echo "$ENTRY" | jq -c '.deliverable_id')"

# ── T3 — the entry carries the landing's wall-clock (mechanical, queue-measured) ──
echo "$ENTRY" | jq -e '.perf.landing_wallclock_s == 1.25' >/dev/null 2>&1 \
  && ok "entry carries the landing wall-clock (perf.landing_wallclock_s == 1.25)" \
  || no "expected landing_wallclock_s == 1.25, got $(echo "$ENTRY" | jq -c '.perf')"

# ── T4 — the entry carries the diff footprint the GATE computed (reused, not recomputed) ──
echo "$ENTRY" | jq -e '.footprint == {files:3, insertions:42, deletions:7}' >/dev/null 2>&1 \
  && ok "entry carries the gate's diff footprint (files/insertions/deletions)" \
  || no "expected footprint {3,42,7}, got $(echo "$ENTRY" | jq -c '.footprint')"

# ── T5 — the entry carries the dispatch outcome ──
echo "$ENTRY" | jq -e '.dispatch_outcome == "landed"' >/dev/null 2>&1 \
  && ok "entry carries dispatch_outcome == landed" \
  || no "expected dispatch_outcome landed, got $(echo "$ENTRY" | jq -c '.dispatch_outcome')"
# all three outcomes are accepted; an unknown outcome is a loud usage error
for oc in landed harvest-refused conflict-routed; do
  PO=$(make_plane); LO="$PO/.claude/metering/metering.ndjson"
  ( cd "$PO" && bash "$SCRIPT" capture --deliverable 9.4 --outcome "$oc" \
      --files 1 --insertions 1 --deletions 0 --wallclock 0.5 ) >/dev/null 2>&1
  tail -1 "$LO" | jq -e --arg oc "$oc" '.dispatch_outcome == $oc' >/dev/null 2>&1 \
    && ok "outcome '$oc' is accepted and recorded" \
    || no "outcome '$oc' must be accepted and recorded"
done
PB=$(make_plane)
( cd "$PB" && bash "$SCRIPT" capture --deliverable 9.4 --outcome bogus \
    --files 1 --insertions 1 --deletions 0 --wallclock 0.5 ) >/dev/null 2>&1; RC=$?
[ $RC -eq 2 ] \
  && ok "an unknown dispatch outcome is a loud usage error (exit 2)" \
  || no "an unknown outcome must fail loud (rc=$RC)"

# ── T6 — the entry self-identifies as the queue-boundary shape, distinct from the
#         session shape, so the [9.5] emitter can tell them apart ──
echo "$ENTRY" | jq -e '.schema == "guv.meter.queue.v1"' >/dev/null 2>&1 \
  && ok "entry tagged with the queue-boundary schema (guv.meter.queue.v1)" \
  || no "expected schema guv.meter.queue.v1, got $(echo "$ENTRY" | jq -c '.schema')"
echo "$ENTRY" | jq -e '.ts' 2>/dev/null | grep -qE '^"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"$' \
  && ok "ts is an ISO-8601 UTC instant (guv-derived)" \
  || no "ts is not a UTC instant: $(echo "$ENTRY" | jq -c '.ts')"

# ── T7 — APPEND-ONLY: a second landing appends; line 1 is byte-identical ──
FIRST=$(head -1 "$LOG")
cap_landed "$P" 9.1 >/dev/null 2>&1
N=$(wc -l < "$LOG" | tr -d ' ')
NOWFIRST=$(head -1 "$LOG")
[ "$N" = "2" ] && [ "$FIRST" = "$NOWFIRST" ] \
  && ok "second landing appends (2 lines), line 1 byte-identical (append-only)" \
  || no "append-only violated: lines=$N, line1 changed=$([ "$FIRST" = "$NOWFIRST" ] && echo no || echo YES)"

# ── T7b — APPEND-ONLY grep-asserted on the source: only >> writes the log,
#          never a truncating redirect or in-place edit ──
LOGVAR='(LOG|METER_LOG|METERING_LOG|LOGFILE)'
grep -nE '[[:space:]]>[[:space:]]*"?\$\{?'"$LOGVAR" "$SCRIPT" 2>/dev/null \
  | grep -vE '>>|^[[:space:]]*[0-9]+:[[:space:]]*#' >/dev/null 2>&1 \
  && no "writer has a truncating redirect onto the log (rewrites it)" \
  || ok "no truncating redirect onto the log"
grep -nE 'sed -i|sed --in-place' "$SCRIPT" 2>/dev/null | grep -vE '^\s*#' >/dev/null 2>&1 \
  && no "writer uses sed -i (rewrites the log in place)" \
  || ok "writer uses no in-place edit (sed -i)"
grep -nE '>>[[:space:]]*"?\$\{?'"$LOGVAR" "$SCRIPT" >/dev/null 2>&1 \
  && ok "writer appends with >> (the only sanctioned write to the log)" \
  || no "writer has no append (>>) — cannot be append-only-by-construction"

# ── T8 — NO agent I/O: no flag injects token counts, dollars, or footprint VALUES
#         the agent invents. tokens/dollars are harvested or null; the footprint
#         and wall-clock are MECHANICAL inputs the queue measured (guv-measured,
#         not agent-reported), which is why they ARE flags — but tokens/dollars
#         must never be settable by a caller. ──
grep -nE -- '--tokens|--input-tokens|--output-tokens|--cost|--dollars' "$SCRIPT" >/dev/null 2>&1 \
  && no "writer exposes a flag to inject token/cost values — those must be harvested, never agent-reported" \
  || ok "no CLI flag injects token/cost values (harvested or null)"
# tokens degrade to null when the transcript is unreachable (the fixture has none)
echo "$ENTRY" | jq -e '.tokens == null or (.tokens | has("input") and has("output"))' >/dev/null 2>&1 \
  && ok "tokens is null (unharvestable here) or carries by-class counts" \
  || no "tokens malformed: $(echo "$ENTRY" | jq -c '.tokens')"
echo "$ENTRY" | jq -e '.dollars == null' >/dev/null 2>&1 \
  && ok "dollars is null (token-only rung, no guessed price table)" \
  || no "dollars must be null, got $(echo "$ENTRY" | jq -c '.dollars')"

# ── T9 — NO derived/aggregate field (raw evidence only; aggregation is [9.5]) ──
DERIVED=$(echo "$ENTRY" | jq -r 'paths(scalars) | map(tostring) | join(".")' 2>/dev/null \
  | grep -iE 'total|sum|avg|average|mean|rate|per_|_per|cost_per|aggregate|cumulative|burn_rate|tokens_per' || true)
[ -z "$DERIVED" ] \
  && ok "no derived/aggregate field in the entry (raw evidence only)" \
  || no "derived field(s) leaked into the log: $DERIVED"

# ── T10 — the log path is root-relative (the sibling convention), shared with the
#          session meter — two planes write two distinct logs, and the queue entry
#          lands in the SAME log file the session meter uses ──
grep -nE '/Users/|/home/[a-z]' "$SCRIPT" 2>/dev/null | grep -vE '^\s*#' >/dev/null 2>&1 \
  && no "writer hardcodes an absolute home path (must resolve relative to the plane root)" \
  || ok "writer hardcodes no absolute path (resolves relative to the plane root)"
P10=$(make_plane); LOG10="$P10/.claude/metering/metering.ndjson"
cap_landed "$P10" 9.4 >/dev/null 2>&1
[ -f "$LOG" ] && [ -f "$LOG10" ] && [ "$LOG" != "$LOG10" ] \
  && ok "two planes write to two distinct logs (path is root-relative)" \
  || no "log path is not root-relative"

# ── T11 — loud stops: missing required args, corrupt manifest, bad subcommand ──
P11=$(make_plane)
( cd "$P11" && bash "$SCRIPT" capture --deliverable 9.4 --outcome landed ) >/dev/null 2>&1; RC=$?
[ $RC -eq 2 ] \
  && ok "missing the mechanical footprint/wall-clock args is a loud usage error (exit 2)" \
  || no "missing required args must fail loud (rc=$RC)"
PC="$WORK/corrupt"; mkdir -p "$PC/.claude"; echo '{bad' > "$PC/.claude/project.json"
( cd "$PC" && bash "$SCRIPT" capture --deliverable 9.4 --outcome landed \
    --files 1 --insertions 1 --deletions 0 --wallclock 0.5 ) >/dev/null 2>&1; RC=$?
[ $RC -eq 4 ] \
  && ok "corrupt manifest -> loud error (exit 4) before any append" \
  || no "corrupt manifest must fail loud (rc=$RC)"
( cd "$P11" && bash "$SCRIPT" bogus ) >/dev/null 2>&1; RC=$?
[ $RC -eq 2 ] && ok "unknown subcommand -> usage (exit 2)" || no "unknown subcommand must be exit 2 (rc=$RC)"
( cd "$P11" && bash "$SCRIPT" ) >/dev/null 2>&1; RC=$?
[ $RC -eq 2 ] && ok "no args -> usage (exit 2)" || no "no args must be exit 2 (rc=$RC)"

# ── T12 — the queue-boundary shape is documented as published contract ──
# A MAINTAINER-ONLY source-shape check: it resolves the shape doc by its explicit
# .claude/-relative path ($CLAUDE_DIR/metering-log.md). That literal path also
# matches build-plugin.sh's MAINTAINER_ONLY filter (/metering[a-z-]*\.md), so this
# whole suite is correctly partitioned as maintainer-only and is NOT reconstructed
# into the consumer plugin layout — the same treatment estimate.shape.md and the
# session meter's shape assertions get (the shape docs are source-shape contract,
# never shipped; ship-suite.test.sh §intro). In the source tree the doc must exist.
SHAPEDOC="$CLAUDE_DIR/metering-log.md"
if [ -f "$SHAPEDOC" ]; then
  grep -qiE 'guv\.meter\.queue\.v1|queue-boundary|queue boundary' "$SHAPEDOC" \
    && ok "shape doc documents the queue-boundary entry shape" \
    || no "shape doc does not document the queue-boundary shape"
  for f in dispatch_outcome footprint landing_wallclock; do
    grep -q "$f" "$SHAPEDOC" \
      && ok "shape doc names the queue-boundary field: $f" \
      || no "shape doc omits queue-boundary field: $f"
  done
else
  no "no metering shape doc to extend at $SHAPEDOC"
fi

# ── T13 — SUBAGENT-TOKEN CAPTURE ([13.1]). The queue meter harvests tokens
#          "exactly as the session meter" — so it MUST sum the sibling <session>/
#          subagent transcripts too, or the queue-boundary entry undercounts the
#          eval/fix loop the same way meter.sh did before [13.1]. This pins the
#          two harvesters in lockstep on subagent inclusion (same fixture shape as
#          meter.test.sh's T14: main cache_read 100 + subagent 900 = 1000; model
#          from the main transcript only). HOME overridden, slug computed via
#          pwd -P so the path matches under macOS /var symlink resolution. ──
P13=$(make_plane); LOG13="$P13/.claude/metering/metering.ndjson"
FH13="$WORK/home.$RANDOM"; SID13="99999999-8888-7777-6666-555555555555"
slug13=$(cd "$P13" && pwd -P | sed 's#/#-#g'); base13="$FH13/.claude/projects/$slug13"
mkdir -p "$base13/$SID13/subagents"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-main","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":0}}}' \
  > "$base13/$SID13.jsonl"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sub","usage":{"input_tokens":2,"output_tokens":1,"cache_read_input_tokens":900,"cache_creation_input_tokens":0}}}' \
  > "$base13/$SID13/subagents/agent-x.jsonl"
( cd "$P13" && HOME="$FH13" CLAUDE_CODE_SESSION_ID="$SID13" bash "$SCRIPT" capture \
    --deliverable 9.4 --outcome landed --files 1 --insertions 1 --deletions 0 --wallclock 0.5 ) \
    >/dev/null 2>"$WORK/t13.err"
tail -1 "$LOG13" | jq -e '.tokens.cache_read == 1000 and .model == "claude-main"' >/dev/null 2>&1 \
  && ok "queue harvest INCLUDES subagent burn (cache_read 1000) and model from main (lockstep with meter.sh)" \
  || no "queue meter must capture subagents like the session meter: got $(tail -1 "$LOG13" | jq -c '{tokens,model}') (err=$(cat "$WORK/t13.err"))"

# ════════════════════════════════════════════════════════════════════════════
# [13.6] — the QUEUE meter records the SAME bounded per-deliverable slice as the
# session meter (lockstep): tokens = the runtime-transcript DELTA from the last
# same-runtime_session capture (session OR queue boundary — they advance one
# cumulative high-water mark per transcript), self-describing its slice basis,
# preserving transcript_tokens, and detecting+declaring a balloon. Same forensic
# fix, same shape, enforced byte-identical by the parity test below.
# ════════════════════════════════════════════════════════════════════════════

mk_main_transcript() {  # $1=plane $2=home $3=sid — main + one subagent (cr 100 + 900 = 1000)
  local p="$1" fh="$2" sid="$3" slug base
  slug=$(cd "$p" && pwd -P | sed 's#/#-#g'); base="$fh/.claude/projects/$slug"
  mkdir -p "$base/$sid/subagents"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-06-16T12:00:00.000Z","message":{"model":"claude-main","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":3}}}' \
    > "$base/$sid.jsonl"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-06-16T12:01:00.000Z","message":{"model":"claude-sub","usage":{"input_tokens":2,"output_tokens":1,"cache_read_input_tokens":900,"cache_creation_input_tokens":7}}}' \
    > "$base/$sid/subagents/agent-x.jsonl"
}
mk_compaction_transcript() {  # $1=plane $2=home $3=sid $4=n $5=cts
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
seed_prior_q() {  # $1=log $2=runtime_session $3=ts $4=cumulative-json  (a SESSION-boundary prior)
  printf '%s\n' "$(jq -cn --arg rs "$2" --arg ts "$3" --argjson cum "$4" \
    '{schema:"guv.meter.v1", ts:$ts, session:"session-2026-06-16-001",
      session_derived:true, runtime_session:$rs, deliverable_ids:["9.4"],
      model:"m", tokens:$cum, transcript_tokens:$cum, dollars:null,
      spike_c_rung:"B", slice_basis:"since_process_start", compaction_cycles:0,
      perf:{op_wallclock_s:0.1, suite_runtime_s:null}}')" >> "$1"
}

# ── T14 — BOUNDED SLICE (lockstep with meter.sh T15): the landing's tokens are the
# DELTA from the prior same-runtime_session capture, differencing even against a
# SESSION-boundary prior — both boundaries advance one cumulative high-water mark
# per transcript. Prior cumulative {2,1,300,4}; now {12,6,1000,10}; slice {10,5,700,6}.
P14=$(make_plane); LOG14="$P14/.claude/metering/metering.ndjson"
FH14="$WORK/home.$RANDOM"; SID14="14141414-1111-2222-3333-444444444444"
mk_main_transcript "$P14" "$FH14" "$SID14"
mkdir -p "$P14/.claude/metering"
seed_prior_q "$LOG14" "$SID14" "2026-06-16T09:00:00Z" '{"input":2,"output":1,"cache_read":300,"cache_creation":4}'
( cd "$P14" && HOME="$FH14" CLAUDE_CODE_SESSION_ID="$SID14" bash "$SCRIPT" capture \
    --deliverable 9.4 --outcome landed --files 1 --insertions 1 --deletions 0 --wallclock 0.5 ) >/dev/null 2>"$WORK/qt14.err"
QE14=$(tail -1 "$LOG14")
echo "$QE14" | jq -e '.tokens == {input:10,output:5,cache_read:700,cache_creation:6} and .slice_basis == "per_deliverable"' >/dev/null 2>&1 \
  && ok "[13.6] queue landing records the bounded DELTA against the prior capture (lockstep with the session meter)" \
  || no "[13.6] queue slice wrong: got $(echo "$QE14" | jq -c '{tokens, slice_basis}') (err=$(cat "$WORK/qt14.err"))"
echo "$QE14" | jq -e '.transcript_tokens == {input:12,output:6,cache_read:1000,cache_creation:10}' >/dev/null 2>&1 \
  && ok "[13.6] queue entry preserves transcript_tokens (the cumulative high-water reading)" \
  || no "[13.6] queue transcript_tokens wrong: $(echo "$QE14" | jq -c '.transcript_tokens')"

# ── T15 — first capture (no prior) discloses since_process_start, like the session meter.
P15=$(make_plane); LOG15="$P15/.claude/metering/metering.ndjson"
FH15="$WORK/home.$RANDOM"; SID15="15a5a5a5-1111-2222-3333-444444444444"
mk_main_transcript "$P15" "$FH15" "$SID15"
( cd "$P15" && HOME="$FH15" CLAUDE_CODE_SESSION_ID="$SID15" bash "$SCRIPT" capture \
    --deliverable 9.4 --outcome landed --files 1 --insertions 1 --deletions 0 --wallclock 0.5 ) >/dev/null 2>&1
tail -1 "$LOG15" | jq -e '.slice_basis == "since_process_start" and .tokens.cache_read == 1000' >/dev/null 2>&1 \
  && ok "[13.6] queue first capture → since_process_start, slice = full cumulative (lockstep)" \
  || no "[13.6] queue first-capture basis wrong: $(tail -1 "$LOG15" | jq -c '{slice_basis, tokens}')"

# ── T16 — the queue meter detects + declares a balloon too (lockstep), exit 0.
P16=$(make_plane); LOG16="$P16/.claude/metering/metering.ndjson"
FH16="$WORK/home.$RANDOM"; SID16="16a6a6a6-1111-2222-3333-444444444444"
mk_compaction_transcript "$P16" "$FH16" "$SID16" 3 "2026-06-16T12:30:00.000Z"
mkdir -p "$P16/.claude/metering" "$P16/docs"
seed_prior_q "$LOG16" "$SID16" "2026-06-16T09:00:00Z" '{"input":1,"output":1,"cache_read":1,"cache_creation":1}'
printf '%s\n' '{"9.4":1}' > "$P16/docs/estimates.json"
( cd "$P16" && HOME="$FH16" CLAUDE_CODE_SESSION_ID="$SID16" bash "$SCRIPT" capture \
    --deliverable 9.4 --outcome landed --files 1 --insertions 1 --deletions 0 --wallclock 0.5 ) >"$WORK/qt16.out" 2>"$WORK/qt16.err"; QRC=$?
QE16=$(tail -1 "$LOG16")
[ "$QRC" -eq 0 ] && echo "$QE16" | jq -e '.compaction_cycles == 3' >/dev/null 2>&1 \
  && grep -qiE 'balloon' "$WORK/qt16.out" "$WORK/qt16.err" 2>/dev/null \
  && ok "[13.6] queue meter counts compaction cycles (3) and declares a balloon loudly, exit 0 (lockstep)" \
  || no "[13.6] queue balloon detection wrong: rc=$QRC cycles=$(echo "$QE16" | jq -c '.compaction_cycles') out=$(cat "$WORK/qt16.out") err=$(cat "$WORK/qt16.err")"

# ── T17 — LOCKSTEP BY CONSTRUCTION: the bounded-slice harvest block is BYTE-IDENTICAL
# between meter.sh and meter-queue.sh. The two harvesters "share the bounded harvest"
# ([13.6] acceptance); rather than risk drift between two copies, the shared logic is
# delimited by sentinels in both files and this test asserts the delimited regions
# match exactly. If they diverge, the meters are no longer in lockstep — fail loud.
MQ="$CLAUDE_DIR/meter-queue.sh"; MS="$CLAUDE_DIR/meter.sh"
extract_block() {  # $1=file — the lines strictly between the two sentinels
  awk '/# >>> \[13\.6\] bounded-slice harvest/{f=1; next} /# <<< \[13\.6\] bounded-slice harvest/{f=0} f' "$1"
}
BLK_Q=$(extract_block "$MQ"); BLK_S=$(extract_block "$MS")
[ -n "$BLK_S" ] && [ "$BLK_Q" = "$BLK_S" ] \
  && ok "[13.6] the bounded-slice harvest block is byte-identical in meter.sh and meter-queue.sh (lockstep by construction)" \
  || no "[13.6] the bounded-slice block DRIFTED between the two meters (or its sentinels are missing) — they must stay in lockstep"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
