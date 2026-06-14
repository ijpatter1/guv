#!/bin/bash
# .claude/meter.sh — session-boundary cost-and-performance capture ([9.1]).
#
# Appends ONE NDJSON line per session-close to an append-only metering log in
# the control plane (.claude/metering/metering.ndjson). The log is RAW EVIDENCE:
# every field is harness- or git-derived, NEVER agent-reported (no agent I/O),
# and NOTHING is derived/aggregated here — totals, rates, and cost-per-X are
# computed downstream by the [9.5] emitter, which is the only consumer surface.
# The raw log stays raw.
#
# Usage:
#   bash .claude/meter.sh capture [--deliverables "<id>[,<id>...]"]
#                                 [--session <session-YYYY-MM-DD-NNN>]
#                                 [--run-suite]
#                                 [--log <path>]
#
#   --deliverables  the deliverable ID(s) this session served. Absent or empty
#                   -> "session-scalar" (the attribution for a session with no
#                   single applicable ID). A comma list attributes to each ID.
#   --session       override the harness session id (default: derived from the
#                   newest docs/sessions/session-*.md — the same state siblings
#                   read).
#   --run-suite     time a real run of the manifest test suite (guv-cmd test)
#                   and record its wall-clock as perf.suite_runtime_s. The number
#                   is THIS SCRIPT'S measurement — never a caller-supplied value.
#                   Omit it in the session-close path: the suite already ran in
#                   handoff Step 3, which writes its measured wall-clock to the
#                   mechanical artifact below — this avoids a double run.
#   --log           override the log path (tests; default is root-relative).
#
# perf.suite_runtime_s — MECHANICAL ONLY, never an agent value. Two sources, both
# harness-measured: (1) --run-suite, where THIS SCRIPT times the suite; or (2) the
# artifact .claude/metering/.last-suite-runtime (resolved beside the log), a single
# number the session-close path writes mechanically when it runs the suite in
# Step 3. The writer READS that artifact — it is never a CLI argument or agent
# input. Absent / unreadable / non-numeric artifact -> suite_runtime_s: null, the
# designed degradation (Rule 15) — never an agent-supplied number.
#
# There is deliberately NO flag to set token counts, dollars, the operation
# wall-clock, or the suite runtime: those are harvested or measured by this
# script (or read from the harness artifact), never reported by a caller. That
# is the "measure exhaust, never steam — no agent I/O" contract.
#
# Spike C (harvestability) — rung taken: B (session-scalar token attribution),
# dollars at C (token-only, no guessed price table). Token counts by class are
# harvested mechanically from the Claude Code runtime transcript
# (~/.claude/projects/<cwd-slug>/<CLAUDE_CODE_SESSION_ID>.jsonl), which carries a
# per-assistant-message `usage` object. The transcript is a research-preview
# surface: if it is unreachable (no session id, no file, jq can't sum it), the
# writer takes the DESIGNED degradation (Rule 15) — tokens=null, model from the
# transcript if any, spike_c_rung="degraded" — and the log still gets its
# mechanical fields (ts, session, deliverable_ids, perf). The log existing never
# depends on Spike C. dollars is ALWAYS null on this rung: pricing tables drift
# and the spec forbids a guessed conversion.
#
# NOT A SessionEnd HOOK ([8.3] §3.3 — "AUTOMATE (caveated), verify at [8.3]").
# Verified and resolved to KEEP MODEL-TRIGGERED (the handoff invokes it at Step 6b):
# a SessionEnd hook has no agent input, so it could not pass --deliverables — every
# entry would record `session-scalar`, losing the per-deliverable attribution [9.1]
# was designed around; and the suite-runtime artifact (.last-suite-runtime, written
# by handoff Step 3) is absent unless that session ran the suite, so suite_runtime_s
# would usually be null. SessionEnd is also not guaranteed to fire (crash / wall).
# The other two §3.3 scripts (session-open dispatch, status render) ARE hooks; this
# one stays where the deliverable context lives — the session-close handoff.
#
# Exit: 0 wrote an entry · 2 usage · 4 no/corrupt manifest (cwd must be the
#       project root). A degraded harvest is exit 0 — it is a designed path, not
#       a failure.
set -u

SCHEMA="guv.meter.v1"
err() { echo "meter: $1" >&2; }
die() { err "$2"; exit "$1"; }

[ $# -ge 1 ] || die 2 "usage: bash .claude/meter.sh capture [--deliverables ids] [--session id] [--run-suite] [--log path]"
SUB="$1"; shift
[ "$SUB" = "capture" ] || die 2 "unknown subcommand '$SUB' (only: capture)"

DELIVERABLES=""
SESSION=""
LOG=""
SUITE_RUNTIME="null"
RUN_SUITE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --deliverables) DELIVERABLES="${2:-}"; shift 2 ;;
    --session)      SESSION="${2:-}"; shift 2 ;;
    --run-suite)    RUN_SUITE=1; shift ;;
    --log)          LOG="${2:-}"; shift 2 ;;
    *) die 2 "unknown argument '$1'" ;;
  esac
done

# --- project root + log path (root-relative, the sibling convention) ----------
# cwd must be the project root (where .claude/project.json lives) — the same
# contract guv-git.sh / guv-cmd.sh / merge-queue.sh carry. The log lives in the
# control plane; in a single-repo project control == code == cwd.
MANIFEST=".claude/project.json"
[ -f "$MANIFEST" ] || die 4 "no manifest at $MANIFEST (cwd must be the project root)"
jq -e . "$MANIFEST" >/dev/null 2>&1 \
  || die 4 "$MANIFEST exists but is not valid JSON — fix the manifest"
[ -n "$LOG" ] || LOG=".claude/metering/metering.ndjson"
# The mechanical suite-runtime artifact lives beside the log (same metering dir),
# so an overridden --log in tests carries its artifact with it. This is a file
# the harness writes (handoff Step 3); the writer only ever READS it.
SUITE_ARTIFACT="$(dirname "$LOG")/.last-suite-runtime"

# --- a hi-res monotone-ish clock in seconds (bash + coreutils only) -----------
# GNU date expands %N (nanoseconds); stock macOS date leaves the literal "N", in
# which case we degrade to whole-second resolution. awk does the float subtraction
# (universally available; no bc/perl dependency added).
now_s() {
  local t; t=$(date +%s.%N 2>/dev/null)
  case "$t" in
    *N|"") date +%s ;;     # no sub-second support -> integer seconds
    *) printf '%s' "$t" ;;
  esac
}
START=$(now_s)   # the deterministic-op wall-clock starts HERE and is measured
                 # at append time — the genuinely mechanical perf field.

# --- harness session id: newest docs/sessions/session-*.md (derived, not given)
if [ -z "$SESSION" ]; then
  SESSION=$(ls docs/sessions/session-*.md 2>/dev/null \
    | sed -E 's#.*/(session-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3})\.md#\1#' \
    | grep -E '^session-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3}$' \
    | sort | tail -1)
fi
# Designed degradation (Rule 15): a project with no session artifacts yet still
# meters — fall to today's date with sequence 000, loudly marked on the entry.
SESSION_DERIVED=1
if [ -z "$SESSION" ]; then
  SESSION="session-$(date -u +%Y-%m-%d)-000"
  SESSION_DERIVED=0
fi

# --- deliverable attribution: ID(s) or session-scalar -------------------------
# Trim, split on comma, drop blanks. Empty -> ["session-scalar"].
DELIVERABLES_JSON=$(printf '%s' "$DELIVERABLES" \
  | tr ',' '\n' \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
  | grep -v '^$' \
  | jq -R . | jq -s '.')
if [ "$(printf '%s' "$DELIVERABLES_JSON" | jq 'length')" = "0" ]; then
  DELIVERABLES_JSON='["session-scalar"]'
fi

# --- Spike C harvest: tokens by class + model, from the runtime transcript ----
# Rung B (session-scalar token attribution); dollars at C (token-only). The
# transcript is named by the Claude Code runtime session id under a cwd-derived
# project slug. A research-preview surface: any miss degrades to tokens=null.
TOKENS_JSON="null"
MODEL_JSON="null"
RUNTIME_SESSION="${CLAUDE_CODE_SESSION_ID:-}"
RUNG="degraded"   # upgraded to "B" once tokens are summed
TRANSCRIPT=""
if [ -n "$RUNTIME_SESSION" ]; then
  SLUG=$(pwd -P | sed 's#/#-#g')
  CAND="$HOME/.claude/projects/$SLUG/$RUNTIME_SESSION.jsonl"
  [ -f "$CAND" ] && TRANSCRIPT="$CAND"
fi
if [ -n "$TRANSCRIPT" ]; then
  # Sum the per-message usage objects by class. Missing fields default to 0; a
  # transcript with no usage lines yields zeros (still a valid harvest). This is
  # extraction over the transcript, NOT aggregation into a derived field — the
  # four class counts are the raw evidence the boundary affords.
  TOKENS_JSON=$(jq -s '
      [ .[] | (.message.usage // .usage) | select(. != null) ] as $u
      | if ($u | length) == 0 then null
        else {
          input:          ([ $u[].input_tokens // 0 ]          | add),
          output:         ([ $u[].output_tokens // 0 ]         | add),
          cache_read:     ([ $u[].cache_read_input_tokens // 0 ]| add),
          cache_creation: ([ $u[].cache_creation_input_tokens // 0 ] | add)
        } end
    ' "$TRANSCRIPT" 2>/dev/null) || TOKENS_JSON="null"
  [ -n "$TOKENS_JSON" ] || TOKENS_JSON="null"
  if [ "$TOKENS_JSON" != "null" ]; then RUNG="B"; fi
  # model id: the last assistant message's model (mechanical, from the transcript)
  MODEL_JSON=$(jq -s '
      [ .[] | select((.type // "") == "assistant") | (.message.model // .model) | select(. != null) ]
      | last // null
    ' "$TRANSCRIPT" 2>/dev/null) || MODEL_JSON="null"
  [ -n "$MODEL_JSON" ] || MODEL_JSON="null"
fi

# --- suite runtime (mechanical only — measured here or read from the artifact) -
# Two mechanical sources, NEVER an agent value:
#   1. --run-suite : THIS SCRIPT times a real run of the manifest suite.
#   2. the artifact .claude/metering/.last-suite-runtime : a single number the
#      session-close path wrote mechanically when it ran the suite in Step 3.
# There is no CLI flag and no agent input that can set this field. Absent /
# unreadable / non-numeric -> null (the designed degradation, Rule 15).
if [ "$RUN_SUITE" = "1" ]; then
  ST=$(now_s)
  bash .claude/guv-cmd.sh test >/dev/null 2>&1 || true   # time it even if red
  SE=$(now_s)
  SUITE_RUNTIME=$(awk -v a="$ST" -v b="$SE" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f", d }')
elif [ -r "$SUITE_ARTIFACT" ]; then
  # Read the harness-written artifact (mechanical). Take the first whitespace-
  # trimmed token; accept it only if it is a number, else degrade to null —
  # never trust a non-number, and never an agent string, into the log.
  ART=$(tr -d '[:space:]' < "$SUITE_ARTIFACT" 2>/dev/null)
  if printf '%s' "$ART" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
    SUITE_RUNTIME="$ART"
  fi
fi

# --- timestamp (harness-derived UTC instant) ----------------------------------
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- the deterministic-operation wall-clock: measured NOW, at append time -----
END=$(now_s)
OP_WALLCLOCK=$(awk -v a="$START" -v b="$END" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f", d }')

# --- assemble the entry (one NDJSON line) -------------------------------------
# jq -c builds compact, valid JSON; --argjson for the already-JSON pieces so the
# numbers/objects/null stay typed, --arg for the strings.
ENTRY=$(jq -cn \
  --arg schema "$SCHEMA" \
  --arg ts "$TS" \
  --arg session "$SESSION" \
  --argjson session_derived "$SESSION_DERIVED" \
  --arg runtime_session "$RUNTIME_SESSION" \
  --argjson deliverable_ids "$DELIVERABLES_JSON" \
  --argjson model "$MODEL_JSON" \
  --argjson tokens "$TOKENS_JSON" \
  --arg rung "$RUNG" \
  --argjson op "$OP_WALLCLOCK" \
  --argjson suite "$SUITE_RUNTIME" \
  '{
     schema: $schema,
     ts: $ts,
     session: $session,
     session_derived: ($session_derived == 1),
     runtime_session: (if $runtime_session == "" then null else $runtime_session end),
     deliverable_ids: $deliverable_ids,
     model: $model,
     tokens: $tokens,
     dollars: null,
     spike_c_rung: $rung,
     perf: { op_wallclock_s: $op, suite_runtime_s: $suite }
   }') || die 4 "failed to assemble the metering entry (jq error)"

# --- APPEND-ONLY write --------------------------------------------------------
# The ONLY write primitive against the log is append (>>). No code path here
# truncates, rewrites, or in-place-edits the log — the suite grep-asserts this.
mkdir -p "$(dirname "$LOG")"
printf '%s\n' "$ENTRY" >> "$LOG"

echo "[meter] appended $SESSION ($(printf '%s' "$DELIVERABLES_JSON" | jq -r 'join(",")')) rung=$RUNG -> $LOG"
