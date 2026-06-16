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
