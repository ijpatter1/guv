#!/bin/bash
# .claude/emit-metrics.sh — the cost-and-performance emitter ([9.5] of the
# plan-as-data spec).
#
# This is the ONE parser of MEANING over the meter's raw evidence. The raw
# metering log (.claude/metering/metering.ndjson, written append-only by
# meter.sh) is RAW EVIDENCE and stays raw — no totals, rates, or cost-per-X
# fields ever appear there. This emitter is the only consumer that reads the
# raw log; every other consumer (commands, hooks, the renderer) reads THIS
# emitter's published shape, never metering.ndjson, and never re-derives
# (the "one parser discipline", A-001).
#
# Two halves, one document on the JSON spine:
#
#   cost — the raw log aggregated by deliverable, phase, and initiative. Token
#          counts and session counts are SUMMED from the log's per-session
#          entries. A session attributed to N deliverable IDs counts toward
#          each (its tokens are credited to each leg). The phase/initiative
#          rollups join the per-deliverable sums with the deliverable→phase map.
#
#   perf — performance metrics DERIVED MECHANICALLY from git history, joined
#          with the resolver's deliverable→phase map. DERIVE, DON'T INSTRUMENT:
#          there is no timer, no probe, no instrument hook, and NO CLI flag that
#          injects a metric. Every number comes from `git log` over existing
#          history, retroactively — cycle time, footprint, commits-per-
#          deliverable, lane lifetime (by-deliverable; the first lane commit → the
#          landing-MERGE author date, a genuine lane-boundary signal, NULL when the
#          lane fast-forwarded — never a cycle-time alias), and phase wall-clock
#          (by-phase). A deliverable's commits are those whose SUBJECT carries
#          its bracketed [N.M] ID — the convention git already records.
#          Attribution is subject-scoped, NOT full-message: a commit that only
#          MENTIONS another deliverable's [N.M] in its body prose (a lane
#          cross-reference) is NEVER credited to that deliverable. See
#          subject_commits() below for the mechanism.
#
# The deliverable→phase map comes from the resolver (resolve-ready.sh --json),
# NOT from re-splitting the ID string: the emitter knows which phase a
# deliverable belongs to ONLY via that map. This is the JOIN the spec names
# (tracker grammar ⋈ git history); it keeps a single source of plan truth.
#
# Read-only over everything: it reads the raw log, reads git, reads the tracker
# (through the resolver) — and writes NOTHING but its one JSON document to
# stdout. The raw log is never written, appended, truncated, or edited here.
#
# The published shape is documented in .claude/emit-metrics.shape.md, alongside
# the metering-log shape, the tracker grammar, the manifest schema, and
# status.json (the cross-referenced contract surface).
#
# Usage:
#   bash .claude/emit-metrics.sh [--log PATH] [--tracker PATH]
#
#   --log      override the raw metering log path (tests; default root-relative
#              .claude/metering/metering.ndjson).
#   --tracker  override the tracker the resolver reads for the deliverable→phase
#              map (tests; default docs/PHASE_STATUS.md).
#
#   cwd must be the project root (where .claude/project.json lives and where git
#   history is reachable) — the same contract every guv spine script carries.
#   There is deliberately NO flag that sets any cost or perf value: cost is
#   summed from the raw log, perf is git-derived. Measure exhaust, never steam.
#
# Exit: 0 emitted one valid document (an absent log degrades to empty cost
#       aggregates — Rule 15, never a crash) · 2 usage · 4 no/corrupt manifest.
set -u

SCHEMA="guv.metrics.v1"
err() { echo "emit-metrics: $1" >&2; }
die() { err "$2"; exit "$1"; }

# The resolver is a SIBLING spine script — it ships in the same .claude/ tree as
# this emitter, so we locate it relative to THIS script, never relative to cwd.
# (cwd is the project root for reading the log and git; the emitter and resolver
# travel together. The whole point is to consume the resolver's published JSON
# instead of re-parsing the tracker — the one-parser discipline applied to plan
# state, not just the metering log.)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVER="$SCRIPT_DIR/resolve-ready.sh"

LOG=""
TRACKER="docs/PHASE_STATUS.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --log)     LOG="${2:-}"; shift 2 ;;
    --tracker) TRACKER="${2:-}"; shift 2 ;;
    *) die 2 "unknown argument '$1' (usage: bash .claude/emit-metrics.sh [--log PATH] [--tracker PATH])" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die 2 "emit-metrics requires jq, which is not on PATH"

# cwd must be the project root — the sibling convention shared with meter.sh /
# guv-git.sh / resolve-ready.sh. The log lives in the control plane.
MANIFEST=".claude/project.json"
[ -f "$MANIFEST" ] || die 4 "no manifest at $MANIFEST (cwd must be the project root)"
jq -e . "$MANIFEST" >/dev/null 2>&1 \
  || die 4 "$MANIFEST exists but is not valid JSON — fix the manifest"
[ -n "$LOG" ] || LOG=".claude/metering/metering.ndjson"

# --- the deliverable→phase map, from the resolver (the JOIN's left side) ------
# We consume the resolver's published JSON and NEVER re-parse the tracker
# ourselves — the resolver is the one parser of plan state. From its
# deliverables[] we lift an id→phase object: { "9.1": 9, "10.1": 10, ... }.
# Designed degradation (Rule 15): no tracker / a resolver refusal yields an
# EMPTY map. With an empty map, cost still aggregates by deliverable (the log
# is self-sufficient for that), the phase/initiative rollups simply find no
# members, and perf falls back to deriving phase from the ID prefix only where
# the map is silent — see below.
DELIV_PHASE_JSON="{}"
if [ -f "$TRACKER" ] && [ -f "$RESOLVER" ]; then
  RESOLVED=$(bash "$RESOLVER" "$TRACKER" --json 2>/dev/null) || RESOLVED=""
  if [ -n "$RESOLVED" ]; then
    M=$(printf '%s' "$RESOLVED" | jq -c '
        [ .deliverables[] | select(.id != null and .phase != null)
          | {key: .id, value: .phase} ] | from_entries' 2>/dev/null) || M=""
    [ -n "$M" ] && DELIV_PHASE_JSON="$M"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# COST — aggregate the raw log. The log is RAW EVIDENCE; this is the meaning.
# Read-only (jq -s slurps; the log is never written). A session with N
# deliverable_ids credits its tokens/session-count to EACH id (multi-attribution
# is additive, the convention the meter records). session-scalar is a real
# attribution bucket in the log but NOT a phase/deliverable: it is kept out of
# the per-deliverable map so it never invents a phantom phase.
# ─────────────────────────────────────────────────────────────────────────────
if [ -f "$LOG" ]; then
  COST_BY_DELIV=$(jq -s '
      # explode each entry into (id, tokens) legs, one per attributed id
      [ .[] | . as $e
        | ($e.deliverable_ids // [])[]
        | { id: ., tok: ($e.tokens // {input:0,output:0,cache_read:0,cache_creation:0}) } ]
      # group by id, sum token classes + session count
      | group_by(.id)
      | map({
          key: .[0].id,
          value: {
            tokens: {
              input:          (map(.tok.input          // 0) | add),
              output:         (map(.tok.output         // 0) | add),
              cache_read:     (map(.tok.cache_read     // 0) | add),
              cache_creation: (map(.tok.cache_creation // 0) | add)
            },
            sessions: length
          }
        })
      | from_entries
    ' "$LOG" 2>/dev/null) || COST_BY_DELIV="{}"
  [ -n "$COST_BY_DELIV" ] || COST_BY_DELIV="{}"

  # by_initiative is the WHOLE plan: every log ENTRY counted ONCE (not per leg).
  # A multi-attribution session credits its tokens to each deliverable in
  # by_deliverable (additive — the per-deliverable view), but the initiative
  # grand total must not double-count it — it is one session, one set of tokens.
  # So this rolls up directly over the raw entries, never over the exploded
  # legs. sessions = the entry count.
  COST_BY_INIT=$(jq -s '
      {
        tokens: {
          input:          ([ .[] | (.tokens.input          // 0) ] | add // 0),
          output:         ([ .[] | (.tokens.output         // 0) ] | add // 0),
          cache_read:     ([ .[] | (.tokens.cache_read     // 0) ] | add // 0),
          cache_creation: ([ .[] | (.tokens.cache_creation // 0) ] | add // 0)
        },
        sessions: length
      }
    ' "$LOG" 2>/dev/null) || COST_BY_INIT='{"tokens":{"input":0,"output":0,"cache_read":0,"cache_creation":0},"sessions":0}'
  [ -n "$COST_BY_INIT" ] || COST_BY_INIT='{"tokens":{"input":0,"output":0,"cache_read":0,"cache_creation":0},"sessions":0}'
else
  COST_BY_DELIV="{}"
  COST_BY_INIT='{"tokens":{"input":0,"output":0,"cache_read":0,"cache_creation":0},"sessions":0}'
fi

# by_phase and by_initiative roll the per-deliverable sums up THROUGH the
# deliverable→phase map (the JOIN). session-scalar (and any id absent from the
# map) contributes to by_initiative but NOT to a phase — it has no phase.
# by_initiative is the grand total across every leg in the log: it is the whole
# live plan, so it sums per-deliverable buckets (every real attribution),
# including ids not in the map. The grammar-version feedback entry gains this
# shape as a data point: the rollup IS the initiative-level cost report.
COST_ROLLUP=$(jq -cn \
  --argjson by_deliverable "$COST_BY_DELIV" \
  --argjson by_initiative "$COST_BY_INIT" \
  --argjson phase_of "$DELIV_PHASE_JSON" '
    ($by_deliverable | to_entries) as $entries
    | {
        by_deliverable: $by_deliverable,
        by_phase: (
          [ $entries[]
            | . as $e
            | ($phase_of[$e.key]) as $ph
            | select($ph != null)
            | { phase: ($ph | tostring), v: $e.value } ]
          | group_by(.phase)
          | map({
              key: .[0].phase,
              value: {
                tokens: {
                  input:          (map(.v.tokens.input)          | add),
                  output:         (map(.v.tokens.output)         | add),
                  cache_read:     (map(.v.tokens.cache_read)     | add),
                  cache_creation: (map(.v.tokens.cache_creation) | add)
                },
                sessions: (map(.v.sessions) | add)
              }
            })
          | from_entries
        ),
        by_initiative: $by_initiative
      }
  ') || die 4 "failed to assemble the cost rollup (jq error)"

# ─────────────────────────────────────────────────────────────────────────────
# PERF — DERIVE, DON'T INSTRUMENT. Every field below comes from `git log` over
# existing history; nothing is measured live, nothing is agent-supplied. A
# deliverable's commits are those whose SUBJECT carries its bracketed [N.M] ID,
# resolved by subject_commits() — `git log --grep '[N.M]' -F` narrows (the
# brackets stay literal, so [9.1] never matches [9.15]), then a post-filter on
# the subject field (%s) drops any commit that only carries [N.M] in its BODY.
# So a body cross-reference to another lane never leaks into the metrics.
# cycle time = last author date − first work commit; footprint
# = distinct files touched + insertions, from --numstat; commits = count of WORK
# commits (--no-merges). lane lifetime = first work commit → the author date of
# the MERGE that LANDED the lane (the lane-boundary signal git records), via
# lane_merge_epoch(); it is a GENUINE, INDEPENDENT signal — distinct from cycle
# time — and is NULL (honest absence) when the lane fast-forwarded with no merge,
# NEVER a cycle_time alias. The phase wall-clock joins git with the
# deliverable→phase map: a phase's span
# is min→max author date across the commits of ALL its member deliverables —
# membership comes from the map, never from re-splitting the ID.
# ─────────────────────────────────────────────────────────────────────────────

# The id universe = every id the cost map OR the phase map knows. perf is
# derived for each (a deliverable with no commits yields zeros, not an omission).
IDS=$(jq -rn \
  --argjson cost "$COST_BY_DELIV" \
  --argjson map "$DELIV_PHASE_JSON" \
  '(($cost | keys) + ($map | keys)) | unique
   | map(select(. != "session-scalar")) | .[]' 2>/dev/null)

# Is this a git repo at the project root? Outside one, perf degrades to zeros/
# nulls (Rule 15) rather than crashing — perf is git-derived, no git no derive.
HAVE_GIT=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && HAVE_GIT=1

# subject_commits <id> — the WORK commit hashes whose SUBJECT literally carries
# the bracketed [id]. Attribution is SUBJECT-scoped, NOT full-message: `git log
# --grep` matches the entire message (subject + body), so a commit that merely
# MENTIONS [id] in its body prose — a cross-reference to another lane — would be
# miscredited. We narrow with --grep (a cheap superset), then post-filter each
# candidate on its subject field (%s) with a literal grep -F, so a body-only
# mention never counts. -F keeps the brackets literal: [9.1] never matches
# [9.15]. --no-merges drops the landing MERGE commit: that commit is the lane
# BOUNDARY (consumed by lane_merge_epoch below for lane_lifetime_s), not work —
# counting it would inflate commits/cycle_time/footprint with the merge. Emits
# one hash per line (empty when none), newest-first.
subject_commits() {
  local sid="$1"
  git log --no-merges --grep="[$sid]" -F --pretty=$'%H\t%s' 2>/dev/null \
    | awk -F'\t' -v id="[$sid]" 'index($2, id) { print $1 }'
}

# lane_merge_epoch <id> — the author epoch of the MERGE commit that LANDED this
# deliverable's lane, or empty if none. This is the genuine lane-BOUNDARY signal
# git records: a lane lands as a --min-parents=2 merge whose SUBJECT names the
# lane (`Merge lane/<id>-…: land [id]`) or otherwise carries [id]. Subject-scoped
# exactly like subject_commits (a body cross-reference never counts), and merges-
# only (--min-parents=2), so it is DISJOINT from the work-commit set above: the
# merge boundary and the work commits are different commits. When a deliverable's
# lane fast-forwarded (the merge-queue's default land path) there is NO merge
# commit — this emits empty, and lane_lifetime_s is an HONEST null, never a
# cycle_time_s alias. Newest merge wins if a lane somehow landed twice.
lane_merge_epoch() {
  local sid="$1"
  git log --min-parents=2 --grep="[$sid]" -F --pretty=$'%H\t%at\t%s' 2>/dev/null \
    | awk -F'\t' -v id="[$sid]" 'index($3, id) { print $2; exit }'
}

# Build perf.by_deliverable as a jq object, assembling one id at a time. For
# each id we read git ONCE per metric over its [ID] commits — driven by the
# SUBJECT-scoped hash set above, never by a full-message --grep.
PERF_BY_DELIV="{}"
for id in $IDS; do
  commits=0; cycle=0; files=0; insertions=0; lane="null"
  if [ "$HAVE_GIT" -eq 1 ]; then
    # the subject-scoped commit hashes for this deliverable (one per line)
    hashes=$(subject_commits "$id")
    if [ -n "$hashes" ]; then
      # author-epoch per matching commit, read from the subject-scoped hash set
      epochs=$(printf '%s\n' "$hashes" | git log --no-walk --stdin --pretty='%at' 2>/dev/null)
      commits=$(printf '%s\n' "$epochs" | grep -c .)
      mn=$(printf '%s\n' "$epochs" | sort -n | head -1)
      mx=$(printf '%s\n' "$epochs" | sort -n | tail -1)
      cycle=$((mx - mn))
      # lane lifetime: first WORK commit → the MERGE that LANDED the lane (the
      # lane-boundary signal git records). A genuine, INDEPENDENT signal — NOT a
      # cycle_time alias. When the lane fast-forwarded (no merge commit) there is
      # no boundary signal: emit null (honest absence), never the cycle value.
      merge_at=$(lane_merge_epoch "$id")
      if [ -n "$merge_at" ]; then
        lane=$((merge_at - mn))
      fi
      # footprint: distinct files touched + total insertions, from --numstat over
      # the SAME subject-scoped hash set. --numstat lines are
      # "added<TAB>deleted<TAB>path"; binary files show "-".
      numstat=$(printf '%s\n' "$hashes" | git log --no-walk --stdin --numstat --pretty=format: 2>/dev/null)
      insertions=$(printf '%s\n' "$numstat" \
        | awk -F'\t' 'NF==3 && $1 ~ /^[0-9]+$/ { s += $1 } END { print s+0 }')
      files=$(printf '%s\n' "$numstat" \
        | awk -F'\t' 'NF==3 { print $3 }' | grep -v '^$' | sort -u | grep -c .)
    fi
  fi
  PERF_BY_DELIV=$(printf '%s' "$PERF_BY_DELIV" | jq -c \
    --arg id "$id" \
    --argjson commits "$commits" \
    --argjson cycle "$cycle" \
    --argjson files "$files" \
    --argjson insertions "$insertions" \
    --argjson lane "$lane" '
      .[$id] = {
        commits: $commits,
        cycle_time_s: $cycle,
        footprint: { files: $files, insertions: $insertions },
        lane_lifetime_s: $lane
      }')
done

# perf.by_phase — the JOIN. For each phase in the map, the wall-clock is the
# min→max author date across the commits of EVERY member deliverable. Member-
# ship is read from the deliverable→phase map; the emitter never decides a
# commit's phase by splitting its ID.
PHASES=$(printf '%s' "$DELIV_PHASE_JSON" | jq -r '[.[]] | unique | .[]' 2>/dev/null)
PERF_BY_PHASE="{}"
for ph in $PHASES; do
  # the member deliverable ids of this phase, from the map
  members=$(printf '%s' "$DELIV_PHASE_JSON" \
    | jq -r --argjson ph "$ph" 'to_entries[] | select(.value == $ph) | .key' 2>/dev/null)
  wall="null"
  if [ "$HAVE_GIT" -eq 1 ] && [ -n "$members" ]; then
    all_epochs=""
    for mid in $members; do
      # SUBJECT-scoped, exactly as the per-deliverable derivation — a body
      # cross-reference to a member must not leak into the phase's wall-clock.
      h=$(subject_commits "$mid")
      e=""
      [ -n "$h" ] && e=$(printf '%s\n' "$h" | git log --no-walk --stdin --pretty='%at' 2>/dev/null)
      [ -n "$e" ] && all_epochs="$all_epochs
$e"
    done
    all_epochs=$(printf '%s\n' "$all_epochs" | grep -E '^[0-9]+$')
    if [ -n "$all_epochs" ]; then
      pmn=$(printf '%s\n' "$all_epochs" | sort -n | head -1)
      pmx=$(printf '%s\n' "$all_epochs" | sort -n | tail -1)
      wall=$((pmx - pmn))
    fi
  fi
  PERF_BY_PHASE=$(printf '%s' "$PERF_BY_PHASE" | jq -c \
    --arg ph "$ph" --argjson wall "$wall" \
    '.[$ph] = { wall_clock_s: $wall }')
done

# --- assemble the one published document on the JSON spine --------------------
GENERATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -cn \
  --arg schema "$SCHEMA" \
  --arg generated "$GENERATED" \
  --argjson cost "$COST_ROLLUP" \
  --argjson perf_by_deliverable "$PERF_BY_DELIV" \
  --argjson perf_by_phase "$PERF_BY_PHASE" '
  {
    schema: $schema,
    generated: $generated,
    cost: $cost,
    perf: {
      by_deliverable: $perf_by_deliverable,
      by_phase: $perf_by_phase
    }
  }' || die 4 "failed to assemble the metrics document (jq error)"
