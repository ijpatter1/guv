#!/bin/bash
# .claude/meter.sh — session-boundary cost-and-performance capture ([9.1]).
#
# Appends ONE NDJSON line per session-close to an append-only metering log in
# the control plane (.claude/metering/metering.ndjson). The log is RAW EVIDENCE:
# every field is guv- or git-derived, NEVER agent-reported (no agent I/O),
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
#   --session       override the session id (default: derived from the
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
# guv-measured: (1) --run-suite, where THIS SCRIPT times the suite; or (2) the
# artifact .claude/metering/.last-suite-runtime (resolved beside the log), a single
# number the session-close path writes mechanically when it runs the suite in
# Step 3. The writer READS that artifact — it is never a CLI argument or agent
# input. Absent / unreadable / non-numeric artifact -> suite_runtime_s: null, the
# designed degradation (Rule 15) — never an agent-supplied number.
#
# There is deliberately NO flag to set token counts, dollars, the operation
# wall-clock, or the suite runtime: those are harvested or measured by this
# script (or read from the guv artifact), never reported by a caller. That
# is the "measure exhaust, never steam — no agent I/O" contract.
#
# Spike C (harvestability) — rung taken: B (session-scalar token attribution),
# dollars at C (token-only, no guessed price table). Token counts by class are
# harvested mechanically from the Claude Code runtime transcript
# (~/.claude/projects/<cwd-slug>/<CLAUDE_CODE_SESSION_ID>.jsonl), which carries a
# per-assistant-message `usage` object — PLUS every *.jsonl under the sibling
# <session>/ tree, where the subagents a session spawns (evaluator/reviewer, lane
# and workflow agents) write their own transcripts ([13.1]): a session-scalar
# total includes that subagent burn, not just the main transcript. The transcript
# is a research-preview
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
# guv writes (handoff Step 3); the writer only ever READS it.
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

# --- session id: newest docs/sessions/session-*.md (derived, not given)
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
# project slug. The MAIN session transcript is <session>.jsonl; the subagents a
# session spawns (evaluator/reviewer, lane builders, workflow agents) write their
# OWN transcripts under the SIBLING <session>/ directory tree (subagents/,
# workflows/), each carrying the identical per-message `usage` object. A session-
# scalar token total MUST include that subagent burn ([13.1]): the eval/fix
# review loop is the dominant turn-variance the projection must predict, and it
# lives entirely in those sub-transcripts — harvesting only the main transcript
# undercounts real burn (measured ~1.4x on a review-heavy session). So the harvest
# sums the main transcript PLUS every *.jsonl under the sibling <session>/ tree.
# The MODEL, by contrast, is read from the MAIN transcript ONLY — it names the
# session's model, never a subagent's. A research-preview surface: any miss
# degrades to tokens=null.
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
  # the sibling <session>/ tree holding subagents/, workflows/, … (may be absent)
  CANDTREE="$HOME/.claude/projects/$SLUG/$RUNTIME_SESSION"
  [ -d "$CANDTREE" ] && SUBAGENT_TREE="$CANDTREE"
fi
if [ -n "$TRANSCRIPT" ]; then
  # Token sources: the main transcript + every *.jsonl under the sibling
  # <session>/ tree (the subagent/workflow transcripts). NUL-safe (read -d '') so
  # a HOME with spaces is fine, and bash-3.2 compatible (no mapfile). The
  # .meta.json sidecars are excluded by the *.jsonl filter. No sidechain double-
  # count: this runtime EXTERNALIZES subagents to their own files (the main
  # transcript carries no isSidechain usage); re-verify if the layout shifts.
  TOKEN_FILES=("$TRANSCRIPT")
  if [ -n "$SUBAGENT_TREE" ]; then
    while IFS= read -r -d '' f; do TOKEN_FILES+=("$f"); done \
      < <(find "$SUBAGENT_TREE" -name '*.jsonl' -type f -print0 2>/dev/null)
  fi
  # Sum the per-RESPONSE usage objects by class across ALL token sources. Missing
  # fields default to 0; no usage lines anywhere yields null (still a valid
  # harvest). This is extraction over the transcripts, NOT aggregation into a
  # derived field — the four class counts are the raw evidence the boundary affords.
  #
  # DEDUPE BY requestId — one API response counts ONCE. The runtime serializes a
  # single assistant response as N transcript lines, one per content block
  # (thinking / text / tool_use), carrying duplicate usage in one of two forms:
  # 66.2% of responses repeat a byte-identical usage object on every line, the
  # other 33.8% carry near-zero placeholders until the final line (41,949
  # responses, 2026-07-25). A per-LINE sum multiplies input/cache_read/cache_creation
  # by the block count — i.e. by the number of tool calls in the turn — and
  # inflates output too under the main-transcript serialization. Measured
  # 2026-07-25 on the guv-guv transcript tree (192 files, 8,422 responses across
  # 21,323 usage lines — the corpus grows, so treat the counts as as-of, the
  # RATIO as the finding): 2.5x, ~1.32B phantom tokens. Burn feeds
  # budget-gate.sh, the [13.4] grade, and calibration, and the error is
  # SHAPE-DEPENDENT (tool-heavy turns inflate more), so it biases comparisons
  # between differently-shaped work instead of cancelling.
  #
  # BILLING CROSS-CHECK (2026-07-25) — PARTIAL. An earlier revision of this
  # comment claimed deduped lands within 0.88–1.14x of Claude Code's /cost on
  # every model and class; that does NOT reproduce. /cost reports a scope this
  # analysis could not reconstruct (no window start, project slug, or session
  # tree reproduces its per-model totals), so there is no absolute per-model
  # reconciliation. What does reproduce, on the one model whose corpus usage is
  # concentrated in the billed period (opus-5): deduped output 1.03x of billed,
  # per-line output 2.35x. Both are an INSTANT reading (2026-07-25), not a constant —
  # that ratio moves ~1.8-3.1x across the three days opus-5 exists in this corpus.
  # Re-measure rather than reuse them. Corroboration, not proof.
  #
  # The load-bearing evidence is STRUCTURAL: no message.id spans two requestIds
  # (0 of ~42k responses corpus-wide), so a requestId is a response boundary.
  # KNOWN UNDER-COUNT, disclosed not corrected: `message.usage.iterations[]`
  # decomposes a requestId that was retried/continued into its billed calls, and
  # the TOP-LEVEL usage this harvest reads reports only the LAST one. Measured:
  # 3 requestIds in 105,109 usage lines, costing ~563k cache_read (~0.01% of
  # corpus burn). Summing iterations would add a branch for a research-preview
  # field absent from a third of lines to recover a rounding error — not worth
  # the surface (Rule 3). Revisit if the multi-iteration share grows.
  #
  # max (not first/last) is correct under BOTH observed serializations: identical
  # repeats, and near-zero output placeholders until the response's final line.
  # It also ignores an aborted all-zero line sharing a live requestId (a real
  # instance carries 91,628 tokens that `last` would silently discard) — T21.
  # Lines carrying NEITHER requestId nor uuid — or an EMPTY one — get a per-line
  # synthetic key, so key-less transcripts meter exactly as before (never
  # collapsed to one max). Empty is checked explicitly: in jq only null/false are
  # falsy, so a bare `// ` fallback would let "" through and collapse the lot.
  # >>> per-response token harvest >>>
  TOKENS_JSON=$(jq -s '
      [ .[] | { rid: (.requestId // .uuid), u: (.message.usage // .usage) }
            | select(.u != null) ] as $lines
      | if ($lines | length) == 0 then null
        else ( $lines
               | to_entries
               | map({ rid: (if (.value.rid // "") == "" then ("__line_" + (.key | tostring)) else .value.rid end), u: .value.u })
               | group_by(.rid)
               | map({
                   input:          (map(.u.input_tokens                // 0) | max),
                   output:         (map(.u.output_tokens               // 0) | max),
                   cache_read:     (map(.u.cache_read_input_tokens     // 0) | max),
                   cache_creation: (map(.u.cache_creation_input_tokens // 0) | max)
                 }) ) as $resp
          | {
              input:          ([ $resp[].input ]          | add),
              output:         ([ $resp[].output ]         | add),
              cache_read:     ([ $resp[].cache_read ]     | add),
              cache_creation: ([ $resp[].cache_creation ] | add)
            }
        end
    ' "${TOKEN_FILES[@]}" 2>/dev/null) || TOKENS_JSON="null"
  # <<< per-response token harvest <<<
  [ -n "$TOKENS_JSON" ] || TOKENS_JSON="null"
  if [ "$TOKENS_JSON" != "null" ]; then RUNG="B"; fi
  # model id: the last assistant message's model — from the MAIN transcript ONLY
  # (the session's model, never a subagent's), mechanical, from the transcript.
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
# The HARVEST UNIT this entry's numbers are denominated in — the [13.6] slice_basis
# discipline applied to the other axis. `per_response` means the harvest deduped by
# requestId (one API call counted once); entries written before that fix carry NO
# harvest_basis and are ~2.5x inflated (measured per-entry band 2.31-2.88x over the
# 18 entries whose transcripts survive). They are NOT backfilled — not because the
# arithmetic is impossible, but because the evidence is gone: only 2 of the 14
# runtime_sessions in the live log still have transcripts (18 of 54 entries), and a
# deflator on the other 36 would be an estimate wearing a measurement's field name in
# an append-only record. The marker keeps the two vintages separable, and the delta
# below refuses to subtract across them. See .claude/metering-log.md.
HARVEST_BASIS="per_response"
# A degraded harvest has no unit to describe — nothing was read. Go null on this
# axis exactly as slice_basis does, rather than asserting how a reading that never
# happened was taken.
[ "$TOKENS_JSON" != "null" ] || HARVEST_BASIS="null"
SLICE_BASIS="null"
COMPACTION_CYCLES="null"
PRIOR_TS=""
if [ "$TOKENS_JSON" != "null" ] && [ -n "$RUNTIME_SESSION" ]; then
  # the most recent prior guv.meter.* entry for THIS runtime_session that carries a
  # usable cumulative reading (a [13.6] transcript_tokens, or a legacy cumulative
  # `tokens`), across BOTH boundaries (session + queue advance one high-water mark
  # per transcript). Emits "<cumulative-json>\t<ts>\t<harvest_basis>" or nothing.
  PRIOR=""
  if [ -f "$LOG" ]; then
    PRIOR=$(jq -rs --arg rs "$RUNTIME_SESSION" '
      [ .[] | select((.schema // "") | startswith("guv.meter"))
            | select(.runtime_session == $rs)
            | select(((.transcript_tokens // .tokens) // null) != null) ]
      | last
      | if . == null then empty
        else ((.transcript_tokens // .tokens) | @json) + "\t" + (.ts // "")
             + "\t" + (.harvest_basis // "") end
    ' "$LOG" 2>/dev/null)
  fi
  if [ -n "$PRIOR" ]; then
    PRIOR_CUM=${PRIOR%%$'\t'*}
    PRIOR_REST=${PRIOR#*$'\t'}
    PRIOR_TS=${PRIOR_REST%%$'\t'*}
    PRIOR_HARVEST=${PRIOR_REST#*$'\t'}
    # per-class delta = now - prior. The cumulative is monotone within a transcript
    # (the file only grows), so a NEGATIVE class delta means the high-water reading
    # is unreliable (e.g. subagent files pruned) — disclose unbounded_cumulative and
    # keep the full cumulative, never a fabricated negative slice (Rule 15).
    DELTA=$(jq -cn --argjson now "$TOKENS_JSON" --argjson prior "$PRIOR_CUM" '
      { input:          (($now.input//0)          - ($prior.input//0)),
        output:         (($now.output//0)         - ($prior.output//0)),
        cache_read:     (($now.cache_read//0)     - ($prior.cache_read//0)),
        cache_creation: (($now.cache_creation//0) - ($prior.cache_creation//0)) }' 2>/dev/null)
    # VINTAGE GUARD (checked BEFORE the magnitude guard, because magnitude cannot
    # see this): the prior reading must have been harvested under the SAME unit, or
    # the subtraction is across two different accountings and its result is
    # meaningless. The magnitude guard alone catches the boundary only while the
    # deduped cumulative is still below the last inflated one — once it outgrows it
    # (inevitable; the transcript only grows) every delta turns positive and a
    # cross-unit figure would be written as a valid per_deliverable slice, then
    # summed into INITIATIVE_BURN and observed_rate(). Disclose it instead.
    if [ "$PRIOR_HARVEST" != "$HARVEST_BASIS" ]; then
      SLICE_BASIS="unbounded_cumulative"   # TOKENS_JSON stays the full cumulative
      # LOUD (Rule 10): this entry's burn drops out of every downstream sum the
      # moment it is tagged unbounded_cumulative. Say so where a person sees it —
      # an undeclared ~2.5x step change reads as "suddenly under budget".
      echo "[meter] VINTAGE BREAK: prior reading for this runtime_session was harvested as '${PRIOR_HARVEST:-<pre-dedupe>}', this one as '$HARVEST_BASIS' — different units (~2.5x apart), so NO delta was taken. Entry discloses slice_basis=unbounded_cumulative and is EXCLUDED from burn sums and observed_rate(): it is not a burn sample. Expect this once per runtime_session (see .claude/metering-log.md)." >&2
    elif [ -n "$DELTA" ] && [ "$(printf '%s' "$DELTA" | jq '[.input,.output,.cache_read,.cache_creation] | all(. >= 0)')" = "true" ]; then
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
  # The bound is inclusive (ts >= the prior capture's second), so a compaction in the
  # exact boundary second can be counted in two consecutive slices — harmless here,
  # since compaction_cycles is an advisory per-slice signal, not a summed accounting
  # quantity (and the exclusive alternative would re-introduce the drop above).
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
  # Read the guv-written artifact (mechanical). Take the first whitespace-
  # trimmed token; accept it only if it is a number, else degrade to null —
  # never trust a non-number, and never an agent string, into the log.
  ART=$(tr -d '[:space:]' < "$SUITE_ARTIFACT" 2>/dev/null)
  if printf '%s' "$ART" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
    SUITE_RUNTIME="$ART"
  fi
fi

# --- timestamp (guv-derived UTC instant) ----------------------------------
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
  --argjson transcript_tokens "$TRANSCRIPT_TOKENS" \
  --arg slice_basis "$SLICE_BASIS" \
  --arg harvest_basis "$HARVEST_BASIS" \
  --argjson compaction_cycles "$COMPACTION_CYCLES" \
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
     transcript_tokens: $transcript_tokens,
     slice_basis: (if $slice_basis == "null" then null else $slice_basis end),
     harvest_basis: (if $harvest_basis == "null" then null else $harvest_basis end),
     compaction_cycles: $compaction_cycles,
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

# [13.6] balloon detection — DECLARE, never stop. A deliverable sized to N sessions
# (≈N context windows, [13.2]) whose slice spanned MORE compaction cycles than that
# ballooned past its sizing. Declare it loudly (the handoff surfaces this) but exit
# 0 — a deliverable-budget breach is fuzzy, a human call, never a mid-flight stop
# ([13.5] semantics). Genuinely silent (Rule 15, no fabricated breach) when:
#   • no compaction signal (COMPACTION_CYCLES null), OR
#   • a since_process_start slice — its count spans the WHOLE process, not this
#     deliverable's work, so it is not attributable to one deliverable's budget, OR
#   • no EXPLICITLY sized deliverable. A budget must key on REAL sizing (the sidecar
#     carries the id), never estimate.sh's default-1 for an unsized id — else every
#     unsized deliverable "breaches" at 2 cycles. session-scalar is likewise no budget.
# An unbounded_cumulative slice, by contrast, REMAINS balloon-eligible: only the token
# VALUE degraded — it still had a prior capture, so its compaction window is
# slice-bounded and its count is attributable to this deliverable's budget.
# ([14.1] hardens the compaction read across runtimes.)
if [ "$COMPACTION_CYCLES" != "null" ] && [ "$SLICE_BASIS" != "since_process_start" ]; then
  SIZED_WINDOWS=0; HAVE_BUDGET=0
  EST_SH="$(cd "$(dirname "$0")" && pwd)/estimate.sh"
  SIDECAR="docs/estimates.json"
  for did in $(printf '%s' "$DELIVERABLES_JSON" | jq -r '.[]'); do
    case "$did" in session-scalar) continue ;; esac
    # only an EXPLICITLY sized deliverable carries a budget to breach (the sidecar
    # has the id) — estimate.sh get defaults an unsized id to 1, which must NOT
    # arm a balloon. No sidecar / unsized id -> no budget, genuinely silent.
    { [ -f "$SIDECAR" ] && jq -e --arg k "$did" 'has($k)' "$SIDECAR" >/dev/null 2>&1; } || continue
    e=$(bash "$EST_SH" get "$did" "$SIDECAR" 2>/dev/null)
    case "$e" in ''|*[!0-9]*) continue ;; esac
    SIZED_WINDOWS=$((SIZED_WINDOWS + e)); HAVE_BUDGET=1
  done
  if [ "$HAVE_BUDGET" = "1" ] && [ "$COMPACTION_CYCLES" -gt "$SIZED_WINDOWS" ]; then
    echo "[meter] BALLOON: $(printf '%s' "$DELIVERABLES_JSON" | jq -r 'join(",")') spanned $COMPACTION_CYCLES compaction cycle(s) vs a sized budget of $SIZED_WINDOWS window-span(s) — declared for human review, not stopped ([13.5] fuzzy semantics)" >&2
  fi
fi
