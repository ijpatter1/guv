#!/bin/bash
# .claude/meter-queue.sh — queue-boundary cost-and-performance capture ([9.4]).
#
# A merge-queue LANDING appends ONE per-deliverable NDJSON entry to the SAME
# append-only metering log the session meter ([9.1]) writes
# (.claude/metering/metering.ndjson). This is the QUEUE boundary, split off [9.1]'s
# SESSION boundary so metering as a whole never serializes behind the merge queue:
# the queue lands one lane at a time, and each landing emits its own raw-evidence
# line at the moment it lands — independent of the session-close meter.
#
# The entry is a SIBLING SHAPE to the session entry — guv.meter.queue.v1, distinct
# from guv.meter.v1 — so the downstream [9.5] emitter can tell a landing entry from
# a session entry while reading one log. Like the session meter, the log is RAW
# EVIDENCE: every field is guv-, git-, or queue-MEASURED, NEVER agent-reported, and
# NOTHING is derived/aggregated here (totals, rates, cost-per-X are the [9.5]
# emitter's job — the raw log stays raw).
#
# Usage:
#   bash .claude/meter-queue.sh capture --deliverable <id> --outcome <outcome> \
#                                       --files N --insertions N --deletions N \
#                                       --wallclock SECONDS [--log <path>]
#   bash .claude/meter-queue.sh emit    <same flags>          # build + PRINT, no append
#
#   --deliverable  the landed (or refused) deliverable ID this entry is attributed
#                  to. Required. ONE id per entry — the queue lands one lane at a time.
#   --outcome      the dispatch outcome: landed | harvest-refused | conflict-routed.
#                  Any other value is a loud usage error (exit 2).
#   --files / --insertions / --deletions
#                  the diff footprint the GATE already computed (merge-queue.sh
#                  footprint, surfaced at precheck/gate-input). REUSED here, never
#                  recomputed — the queue passes the gate's numbers straight in.
#                  These ARE flags because they are MECHANICAL inputs the queue
#                  measured upstream — not agent estimates (contrast tokens/dollars).
#   --wallclock    the landing's wall-clock in seconds, MEASURED by the queue while
#                  it landed the lane (rebase + ff-merge). A queue-measured number,
#                  passed straight in — never an agent value.
#   --log          override the log path (tests; default is root-relative).
#
# `capture` APPENDS the entry to the log (a real landing is owed a log line).
# `emit` builds the SAME entry and PRINTS it to stdout WITHOUT appending — the
# [7.5] failure report embeds it as the refused lane's burn profile (a refused lane
# never landed, so no log line is owed; the report is durable scratch, not a landing).
#
# NO AGENT I/O for cost. There is deliberately NO flag to set token counts or
# dollars: tokens are HARVESTED from the runtime transcript exactly as the session
# meter harvests them (same Spike C rung B); dollars stay null (rung C, token-only,
# no guessed price table). The footprint and wall-clock ARE flags only because the
# queue measured them mechanically — "measure exhaust, never steam."
#
# Designed degradation (Rule 15): the transcript is a research-preview surface — if
# CLAUDE_CODE_SESSION_ID is unset, the file is absent, or jq cannot sum it, tokens
# degrade to null and spike_c_rung to "degraded"; the entry still carries its
# mechanical fields (ts, deliverable_id, dispatch_outcome, footprint, perf). The log
# existing never depends on Spike C.
#
# Exit: 0 wrote/printed an entry · 2 usage (missing/bad args, bad outcome,
#       unknown subcommand) · 4 no/corrupt manifest (cwd must be the project root).
set -u

SCHEMA="guv.meter.queue.v1"
VALID_OUTCOMES="landed harvest-refused conflict-routed"
err() { echo "meter-queue: $1" >&2; }
die() { err "$2"; exit "$1"; }

[ $# -ge 1 ] || die 2 "usage: bash .claude/meter-queue.sh capture|emit --deliverable <id> --outcome <o> --files N --insertions N --deletions N --wallclock S [--log path]"
SUB="$1"; shift
case "$SUB" in
  capture|emit) ;;
  *) die 2 "unknown subcommand '$SUB' (only: capture | emit)" ;;
esac

DELIVERABLE=""
OUTCOME=""
FILES=""
INSERTIONS=""
DELETIONS=""
WALLCLOCK=""
LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --deliverable) DELIVERABLE="${2:-}"; shift 2 ;;
    --outcome)     OUTCOME="${2:-}"; shift 2 ;;
    --files)       FILES="${2:-}"; shift 2 ;;
    --insertions)  INSERTIONS="${2:-}"; shift 2 ;;
    --deletions)   DELETIONS="${2:-}"; shift 2 ;;
    --wallclock)   WALLCLOCK="${2:-}"; shift 2 ;;
    --log)         LOG="${2:-}"; shift 2 ;;
    *) die 2 "unknown argument '$1'" ;;
  esac
done

# --- required args (loud stop on a missing mechanical input; Rule 15) ----------
[ -n "$DELIVERABLE" ] || die 2 "missing required --deliverable <id>"
[ -n "$OUTCOME" ]     || die 2 "missing required --outcome <landed|harvest-refused|conflict-routed>"
# the outcome must be one of the three the queue can produce — an unknown one is a
# loud usage error, never a silently-recorded typo.
case " $VALID_OUTCOMES " in
  *" $OUTCOME "*) ;;
  *) die 2 "unknown --outcome '$OUTCOME' (expected one of: $VALID_OUTCOMES)" ;;
esac
# the footprint + wall-clock are MECHANICAL inputs the queue measured; absent any
# of them is a usage error (the gate always has them at land time), and each must
# be a number — never an agent string smuggled into the log.
for pair in "files:$FILES" "insertions:$INSERTIONS" "deletions:$DELETIONS" "wallclock:$WALLCLOCK"; do
  name="${pair%%:*}"; val="${pair#*:}"
  [ -n "$val" ] || die 2 "missing required --$name (a mechanical input the queue measured)"
  printf '%s' "$val" | grep -qE '^[0-9]+(\.[0-9]+)?$' \
    || die 2 "--$name must be a number, got '$val' (the queue measures it; it is never an agent estimate)"
done

# --- project root + log path (root-relative, the sibling convention) ----------
# cwd must be the project root (where .claude/project.json lives) — the same
# contract meter.sh / merge-queue.sh / lane-dispatch.sh carry. The log lives in the
# control plane and is the SAME file the session meter writes.
MANIFEST=".claude/project.json"
[ -f "$MANIFEST" ] || die 4 "no manifest at $MANIFEST (cwd must be the project root)"
jq -e . "$MANIFEST" >/dev/null 2>&1 \
  || die 4 "$MANIFEST exists but is not valid JSON — fix the manifest"
[ -n "$LOG" ] || LOG=".claude/metering/metering.ndjson"

# --- Spike C harvest: tokens by class + model, from the runtime transcript ----
# Identical harvest contract to meter.sh (rung B; dollars at C): the token total
# sums the MAIN transcript PLUS every *.jsonl under the sibling <session>/ tree,
# so subagent burn (evaluator/reviewer, lane/workflow agents) is included and the
# queue entry never undercounts the eval/fix loop ([13.1]). The MODEL is read from
# the MAIN transcript only. The transcript is a research-preview surface — any miss
# degrades to tokens=null (Rule 15). tokens and dollars are NEVER caller-settable:
# they are harvested or null, never a flag.
TOKENS_JSON="null"
MODEL_JSON="null"
RUNTIME_SESSION="${CLAUDE_CODE_SESSION_ID:-}"
RUNG="degraded"   # upgraded to "B" once tokens are summed
TRANSCRIPT=""
SUBAGENT_TREE=""
if [ -n "$RUNTIME_SESSION" ]; then
  SLUG=$(pwd -P | sed 's#/#-#g')
  CAND="$HOME/.claude/projects/$SLUG/$RUNTIME_SESSION.jsonl"
  [ -f "$CAND" ] && TRANSCRIPT="$CAND"
  CANDTREE="$HOME/.claude/projects/$SLUG/$RUNTIME_SESSION"
  [ -d "$CANDTREE" ] && SUBAGENT_TREE="$CANDTREE"
fi
if [ -n "$TRANSCRIPT" ]; then
  # main transcript + every subagent/workflow *.jsonl under the sibling tree.
  # NUL-safe, bash-3.2 compatible (no mapfile); .meta.json excluded by *.jsonl. No
  # sidechain double-count — this runtime externalizes subagents to their own files.
  TOKEN_FILES=("$TRANSCRIPT")
  if [ -n "$SUBAGENT_TREE" ]; then
    while IFS= read -r -d '' f; do TOKEN_FILES+=("$f"); done \
      < <(find "$SUBAGENT_TREE" -name '*.jsonl' -type f -print0 2>/dev/null)
  fi
  TOKENS_JSON=$(jq -s '
      [ .[] | (.message.usage // .usage) | select(. != null) ] as $u
      | if ($u | length) == 0 then null
        else {
          input:          ([ $u[].input_tokens // 0 ]          | add),
          output:         ([ $u[].output_tokens // 0 ]         | add),
          cache_read:     ([ $u[].cache_read_input_tokens // 0 ]| add),
          cache_creation: ([ $u[].cache_creation_input_tokens // 0 ] | add)
        } end
    ' "${TOKEN_FILES[@]}" 2>/dev/null) || TOKENS_JSON="null"
  [ -n "$TOKENS_JSON" ] || TOKENS_JSON="null"
  if [ "$TOKENS_JSON" != "null" ]; then RUNG="B"; fi
  MODEL_JSON=$(jq -s '
      [ .[] | select((.type // "") == "assistant") | (.message.model // .model) | select(. != null) ]
      | last // null
    ' "$TRANSCRIPT" 2>/dev/null) || MODEL_JSON="null"
  [ -n "$MODEL_JSON" ] || MODEL_JSON="null"
fi

# >>> [13.6] bounded-slice harvest (lockstep with meter.sh / meter-queue.sh) >>>
# The harvest above summed the WHOLE transcript (main + subagents) to NOW — a
# cumulative reading. A guv session is a SLICE of that transcript, not the whole
# thing (docs/notes/meter-forensics.md): summing the whole made every capture a
# cumulative snapshot of the entire Claude Code process (~4.6x inflation). Convert
# the cumulative reading into a BOUNDED per-session SLICE — the delta from the last
# same-runtime_session capture to now (forensics B2 mechanism 1). TRANSCRIPT_TOKENS
# preserves the cumulative high-water reading so the NEXT slice differences against
# it; SLICE_BASIS self-describes the unit so a reading is never mistaken for the
# wrong one (Rule 15); COMPACTION_CYCLES counts the real compaction events the slice
# spanned (isCompactSummary==true, ts >= the prior capture) for balloon detection.
# This block is BYTE-IDENTICAL in both meters — meter-queue.test.sh asserts it; edit
# both or neither.
TRANSCRIPT_TOKENS="$TOKENS_JSON"   # the raw cumulative high-water reading
SLICE_BASIS="null"
COMPACTION_CYCLES="null"
PRIOR_TS=""
if [ "$TOKENS_JSON" != "null" ] && [ -n "$RUNTIME_SESSION" ]; then
  # the most recent prior guv.meter.* entry for THIS runtime_session that carries a
  # usable cumulative reading (a [13.6] transcript_tokens, or a legacy cumulative
  # `tokens`), across BOTH boundaries (session + queue advance one high-water mark
  # per transcript). Emits "<cumulative-json>\t<ts>" or nothing.
  PRIOR=""
  if [ -f "$LOG" ]; then
    PRIOR=$(jq -rs --arg rs "$RUNTIME_SESSION" '
      [ .[] | select((.schema // "") | startswith("guv.meter"))
            | select(.runtime_session == $rs)
            | select(((.transcript_tokens // .tokens) // null) != null) ]
      | last
      | if . == null then empty
        else ((.transcript_tokens // .tokens) | @json) + "\t" + (.ts // "") end
    ' "$LOG" 2>/dev/null)
  fi
  if [ -n "$PRIOR" ]; then
    PRIOR_CUM=${PRIOR%%$'\t'*}
    PRIOR_TS=${PRIOR#*$'\t'}
    # per-class delta = now - prior. The cumulative is monotone within a transcript
    # (the file only grows), so a NEGATIVE class delta means the high-water reading
    # is unreliable (e.g. subagent files pruned) — disclose unbounded_cumulative and
    # keep the full cumulative, never a fabricated negative slice (Rule 15).
    DELTA=$(jq -cn --argjson now "$TOKENS_JSON" --argjson prior "$PRIOR_CUM" '
      { input:          (($now.input//0)          - ($prior.input//0)),
        output:         (($now.output//0)         - ($prior.output//0)),
        cache_read:     (($now.cache_read//0)     - ($prior.cache_read//0)),
        cache_creation: (($now.cache_creation//0) - ($prior.cache_creation//0)) }' 2>/dev/null)
    if [ -n "$DELTA" ] && [ "$(printf '%s' "$DELTA" | jq '[.input,.output,.cache_read,.cache_creation] | all(. >= 0)')" = "true" ]; then
      TOKENS_JSON="$DELTA"
      SLICE_BASIS="per_deliverable"
    else
      SLICE_BASIS="unbounded_cumulative"   # TOKENS_JSON stays the full cumulative
    fi
  else
    SLICE_BASIS="since_process_start"       # first capture: the full reading IS the first slice
  fi
  # compaction cycles the slice spanned: real isCompactSummary==true events in the
  # MAIN transcript with ts >= the prior capture (all when since_process_start).
  # Compare on the second-precision prefix (first 19 chars, YYYY-MM-DDTHH:MM:SS):
  # the metering ts is whole-second (date -u) while the transcript timestamp is
  # millisecond — lexically "00.000Z" < "00Z", so a same-second event would sort
  # before the boundary and be wrongly dropped. Truncating both makes the bound exact.
  if [ -n "$TRANSCRIPT" ]; then
    COMPACTION_CYCLES=$(jq -rs --arg since "$PRIOR_TS" '
      ($since | .[0:19]) as $s
      | [ .[] | select(.isCompactSummary == true)
            | select($s == "" or ((.timestamp // "") | .[0:19]) >= $s) ] | length
    ' "$TRANSCRIPT" 2>/dev/null)
    case "$COMPACTION_CYCLES" in ''|*[!0-9]*) COMPACTION_CYCLES="null" ;; esac
  fi
fi
# <<< [13.6] bounded-slice harvest <<<

# --- timestamp (guv-derived UTC instant) ----------------------------------
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- assemble the entry (one NDJSON line) -------------------------------------
# --argjson for the already-numeric/object/null pieces so they stay typed; --arg
# for the strings. The footprint is the gate's numbers, reused verbatim.
ENTRY=$(jq -cn \
  --arg schema "$SCHEMA" \
  --arg ts "$TS" \
  --arg deliverable "$DELIVERABLE" \
  --arg outcome "$OUTCOME" \
  --arg runtime_session "$RUNTIME_SESSION" \
  --argjson files "$FILES" \
  --argjson insertions "$INSERTIONS" \
  --argjson deletions "$DELETIONS" \
  --argjson wallclock "$WALLCLOCK" \
  --argjson model "$MODEL_JSON" \
  --argjson tokens "$TOKENS_JSON" \
  --argjson transcript_tokens "$TRANSCRIPT_TOKENS" \
  --arg slice_basis "$SLICE_BASIS" \
  --argjson compaction_cycles "$COMPACTION_CYCLES" \
  --arg rung "$RUNG" \
  '{
     schema: $schema,
     ts: $ts,
     deliverable_id: $deliverable,
     dispatch_outcome: $outcome,
     runtime_session: (if $runtime_session == "" then null else $runtime_session end),
     footprint: { files: $files, insertions: $insertions, deletions: $deletions },
     model: $model,
     tokens: $tokens,
     transcript_tokens: $transcript_tokens,
     slice_basis: (if $slice_basis == "null" then null else $slice_basis end),
     compaction_cycles: $compaction_cycles,
     dollars: null,
     spike_c_rung: $rung,
     perf: { landing_wallclock_s: $wallclock }
   }') || die 4 "failed to assemble the queue-boundary entry (jq error)"

if [ "$SUB" = "emit" ]; then
  # emit: PRINT the entry, never append — the [7.5] failure report embeds it as the
  # refused lane's burn profile (a refused lane never landed; no log line is owed).
  printf '%s\n' "$ENTRY"
  exit 0
fi

# --- APPEND-ONLY write (capture) ----------------------------------------------
# The ONLY write primitive against the log is append (>>). No code path here
# truncates, rewrites, or in-place-edits the log — the suite grep-asserts this.
mkdir -p "$(dirname "$LOG")"
printf '%s\n' "$ENTRY" >> "$LOG"

echo "[meter-queue] appended $DELIVERABLE ($OUTCOME) rung=$RUNG -> $LOG"

# [13.6] balloon detection — DECLARE, never stop (lockstep with meter.sh). A
# deliverable sized to N sessions (≈N context windows, [13.2]) whose landing slice
# spanned MORE compaction cycles than that ballooned past its sizing. Declare it
# loudly (the handoff surfaces this) but exit 0 — a fuzzy deliverable-budget breach
# is a human call, never a mid-flight stop ([13.5]). Genuinely silent (Rule 15):
# no compaction signal, a since_process_start slice (its count spans the whole
# process, not this deliverable), or no EXPLICITLY sized deliverable (the sidecar
# has the id — never estimate.sh's default-1 for an unsized id). ([14.1] hardens it.)
if [ "$COMPACTION_CYCLES" != "null" ] && [ "$SLICE_BASIS" != "since_process_start" ]; then
  EST_SH="$(cd "$(dirname "$0")" && pwd)/estimate.sh"
  SIDECAR="docs/estimates.json"
  if [ -f "$SIDECAR" ] && jq -e --arg k "$DELIVERABLE" 'has($k)' "$SIDECAR" >/dev/null 2>&1; then
    SIZED_WINDOWS=$(bash "$EST_SH" get "$DELIVERABLE" "$SIDECAR" 2>/dev/null)
    case "$SIZED_WINDOWS" in
      ''|*[!0-9]*) : ;;  # malformed estimate → no budget, no declaration
      *) if [ "$COMPACTION_CYCLES" -gt "$SIZED_WINDOWS" ]; then
           echo "[meter-queue] BALLOON: $DELIVERABLE spanned $COMPACTION_CYCLES compaction cycle(s) vs a sized budget of $SIZED_WINDOWS window-span(s) — declared for human review, not stopped ([13.5] fuzzy semantics)" >&2
         fi ;;
    esac
  fi
fi
