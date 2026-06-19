#!/bin/bash
# .claude/hooks/continuation-checkpoint.sh
# PreCompact continuation checkpoint ([14.3]). Before compaction proceeds, persist
# the continuation state a post-compaction resume ([14.4]) needs, so losing the
# context-window cache costs nothing: the ACTIVE DELIVERABLE, the resolver
# FRONTIER, git HEAD, and the burn/budget posture ([13.6] slice + [13.5] budget).
#
# THE END-TO-END LOOP ([14.6]) — this hook is step 1 of the autonomous-context loop that
# holds working context in the quality zone across a multi-window deliverable with no human
# driving /compact:
#   1. compact-at-setpoint — a deployed CLAUDE_CODE_AUTO_COMPACT_WINDOW ([14.2]) fires
#      PROACTIVE compaction at the calibrated setpoint (verified: ~217k under a 250000 window
#      on the 1M model), well before the model's hard limit;
#   2. checkpoint — THIS hook (PreCompact) persists the continuation state to disk;
#   3. re-inject — continuation-resume.sh ([14.4], SessionStart source=compact) reads the
#      checkpoint and re-injects it via additionalContext, and surfaces the [14.2] setpoint
#      posture so the resume knows whether the loop is autonomous or on the manual rung;
#   4. continue — the model resumes the active deliverable in place from the re-injected MAP.
# The Rule-15 fallback ladder under the loop (per piece, taken not invented): proactive
# compaction → operator/loop-driven manual /compact at the setpoint → the CLAUDE.md-survival
# floor (load-bearing state is re-read every session regardless) → a loud stop + handoff.
# Two fields here are sharpened specifically for the loop's resume to be correct in guv's
# split topology: ACTIVE reconciles to the in-flight commit tag (not the bare serial), and
# git HEAD / dirty are measured against roots.code (the deliverable repo), not the control
# plane this hook runs in. Dogfooded across the Phase-14 build; the run is recorded in the
# session handoffs.
#
# WIRING ([14.1] finding (e)) — the directory a hook command runs in is the launch
# CWD, NOT the payload's `cwd` field. So this script resolves the project root from
# $CLAUDE_PROJECT_DIR (the env var Claude Code exports for exactly this), never from
# the payload. The hook COMMAND path stays relative in settings.json so the build's
# gsub derives the absolute "${CLAUDE_PLUGIN_ROOT}"/scripts/ form for the plugin —
# that derived form is the absolute install wiring the spike named.
#
# DEGRADATION (Rule 15) — every field degrades INDEPENDENTLY: a fresh consumer with
# no metering log / no budget / no tracker still gets a checkpoint of whatever IS
# resolvable, with the rest null (never fabricated). And a checkpoint failure NEVER
# blocks compaction: it is a loud, non-blocking stop (a message to the transcript +
# exit 0), per the spike's designed ladder — Claude Code lets the operation proceed
# past a hook failure, and a checkpoint must not strand the user by trying to block.
set -u

# Resolve the project root: $CLAUDE_PROJECT_DIR, else the launch CWD (which IS the
# project root for a main-session hook) — never the payload `cwd`.
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"

# Resolve the sibling shared-lib scripts in BOTH install modes (session-start.sh
# pattern): plugin mode ships this wrapper and the libs together under
# ${CLAUDE_PLUGIN_ROOT}/scripts/ ($0's own dir); project mode keeps the wrapper in
# .claude/hooks/ and the libs one level up in .claude/. Probe for a known sibling.
DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || DIR="."
if [ -f "$DIR/resolve-ready.sh" ]; then BASE="$DIR"; else BASE="$DIR/.."; fi

# Read the PreCompact payload from stdin.
INPUT=$(cat)

# Without jq there is no way to build the checkpoint envelope safely — loud stop,
# non-blocking (Rule 15). The CLAUDE.md-survival floor is the recovery rung then.
if ! command -v jq >/dev/null 2>&1; then
  echo "continuation-checkpoint: jq unavailable — checkpoint NOT written; compaction proceeds (Rule 15 loud stop)" >&2
  exit 0
fi

jqr() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }
TRIGGER=$(jqr '.trigger')
SESSION_ID=$(jqr '.session_id')
TRANSCRIPT=$(jqr '.transcript_path')
CUSTOM=$(jqr '.custom_instructions')

# (1)+(2) resolver frontier + active deliverable. Pass the tracker path EXPLICITLY
# (resolve-ready takes it as $1) so the capture never depends on CWD. A missing or
# MALFORMED tracker exits non-zero with stderr we discard, leaving FRONTIER empty.
FRONTIER=""
[ -f "$BASE/resolve-ready.sh" ] && FRONTIER=$(bash "$BASE/resolve-ready.sh" "$ROOT/docs/PHASE_STATUS.md" 2>/dev/null)
fval() { printf '%s' "$FRONTIER" | grep -E "^$1=" | head -1 | sed "s/^$1=//"; }
# roots.code — the DELIVERABLE repo. In guv's split topology the product work-in-flight
# lives in roots.code (../guv), NOT the control-plane root this hook runs in; "." or absent
# means single-repo (CODE == ROOT). Resolved ONCE here and used for BOTH the in-flight
# commit-tag reconcile AND the git HEAD / dirty-tree signal ([14.6]): measuring git state
# against ROOT made a resume report "clean tree" while a deliverable was mid-flight in
# roots.code — the dirty-tree resume crux the Phase-14 dogfood surfaced (the re-injection
# said "no uncommitted work" with four files in flight in the code repo).
CODE="$ROOT"
if [ -f "$ROOT/.claude/project.json" ]; then
  rc=$(jq -r '.roots.code // "."' "$ROOT/.claude/project.json" 2>/dev/null)
  case "$rc" in
    ""|".") CODE="$ROOT" ;;
    /*)     CODE="$rc" ;;
    *)      CODE=$(cd "$ROOT/$rc" 2>/dev/null && pwd) || CODE="$ROOT" ;;
  esac
fi

# active deliverable — RECONCILE the in-flight signal with the resolver serial ([14.6]).
# The serial (first 🔄 else first ready) is the right "what next" pick, but it diverges
# from the work ACTUALLY in flight once that work is committed-but-not-yet-marked-✅: the
# resolver advances past it while a person is still finishing it (observed 3× in the
# Phase-14 dogfood — every resume named the serial, not the deliverable being built). The
# in-flight signal is the latest CODE-repo commit's conventional [N.N] tag; it wins WHILE
# that deliverable is still OPEN (present in the resolver ready/in_progress/blocked), else
# the serial governs (don't resume a just-finished deliverable). Deterministic — a commit-
# message parse + frontier membership, no judgment (Rule 12). The full lists stay in
# `frontier` below; this only sharpens the scalar headline.
ACTIVE=$(fval serial); ACTIVE=${ACTIVE%% *}
TAG=$(git -C "$CODE" log -20 --format='%s' 2>/dev/null | grep -oE '\[[0-9]+\.[0-9]+\]' | head -1 | tr -d '[]')
if [ -n "$TAG" ]; then
  OPEN=" $(fval ready) $(fval in_progress) $(fval blocked | sed 's/:[^ ]*//g') "
  case "$OPEN" in *" $TAG "*) ACTIVE="$TAG" ;; esac
fi

# (3) git HEAD (short) + a dirty-tree signal — measured against CODE (roots.code, the
# DELIVERABLE repo), NOT the control-plane ROOT. "git HEAD" alone points at the last
# COMMIT, not the working state; a model resuming mid-deliverable needs to know there is
# uncommitted work in flight, and in a split topology that work is in roots.code. Capture
# the count of changed paths there. Distinguish a clean repo (0) from a non-repo (null) by
# gating on a real git dir; absent/non-git degrades to empty/null. CODE_ROOT is carried
# ONLY in the split case (CODE != ROOT) so the resume can point `git -C <code_root>` at the
# right repo; single-repo leaves it null and the resume wording is unchanged.
GIT_HEAD=$(git -C "$CODE" rev-parse --short HEAD 2>/dev/null)
GIT_DIRTY=""
if git -C "$CODE" rev-parse --git-dir >/dev/null 2>&1; then
  GIT_DIRTY=$(git -C "$CODE" status --porcelain 2>/dev/null | grep -c .)
fi
CODE_ROOT=""
[ "$CODE" != "$ROOT" ] && CODE_ROOT="$CODE"

# (4) budget setpoints — from project.json, the SINGLE source (budget-gate's
# provenance rule); absent means unlimited → null, gates nothing. The value is
# type-checked in jq: a non-numeric setpoint (a hand-broken manifest the schema
# would reject) degrades to null HERE rather than crashing --argjson below and
# collapsing the whole envelope — every field degrades independently (Rule 15).
MANIFEST="$ROOT/.claude/project.json"
BUDGET_INIT=null; BUDGET_SESS=null
if [ -f "$MANIFEST" ]; then
  v=$(jq -r '(.budgets.initiative.tokens) as $t | if ($t|type)=="number" then $t else "null" end' "$MANIFEST" 2>/dev/null); [ -n "$v" ] && BUDGET_INIT=$v
  v=$(jq -r '(.budgets.session.tokens)    as $t | if ($t|type)=="number" then $t else "null" end' "$MANIFEST" 2>/dev/null); [ -n "$v" ] && BUDGET_SESS=$v
fi

# (4) burn — read through the EMITTER ([9.5]), NEVER the raw log: the one-parser
# discipline is that the emitter is the sole reader of the meter and every command,
# hook, and renderer reads its published shape (enforced by emit-metrics.test.sh
# T12). The emitter computes the slice-aware initiative aggregation ([13.6]); we
# capture its cost.by_initiative rollup. It resolves paths relative to its cwd, so
# run it from the resolved root. An absent log / missing tracker degrade to a
# zeroed rollup by the emitter's own contract; an outright failure degrades to
# null here (Rule 15) — never a fabricated burn.
# PreCompact is latency-sensitive and the emitter's cost scales with the metering
# log, so bound it: with a timeout tool present, cap the read and degrade burn to
# null past the cap (Rule 15) rather than stalling compaction; without one, read
# best-effort. Burn is re-derivable at resume (session-start surfaces the budget
# gate), so a dropped burn here loses nothing load-bearing.
TBIN=""
command -v timeout  >/dev/null 2>&1 && TBIN="timeout 10"
command -v gtimeout >/dev/null 2>&1 && TBIN="gtimeout 10"
BURN_INIT=null
if [ -f "$BASE/emit-metrics.sh" ]; then
  EM=$( cd "$ROOT" 2>/dev/null && $TBIN bash "$BASE/emit-metrics.sh" --tracker "$ROOT/docs/PHASE_STATUS.md" 2>/dev/null )
  bi=$(printf '%s' "$EM" | jq -c '.cost.by_initiative' 2>/dev/null)
  [ -n "$bi" ] && [ "$bi" != "null" ] && BURN_INIT="$bi"
fi

# A timestamp the resume can read; if `date` is somehow unavailable it degrades to empty.
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

# Build the checkpoint envelope. --arg always yields a JSON string; the (if =="" …)
# guards turn an empty capture into null rather than "". --argjson carries the
# numeric/null budget + burn values verbatim.
CKPT_JSON=$(jq -n \
  --arg now "$NOW" \
  --arg trigger "$TRIGGER" \
  --arg session "$SESSION_ID" \
  --arg transcript "$TRANSCRIPT" \
  --arg custom "$CUSTOM" \
  --arg active "$ACTIVE" \
  --arg frontier "$FRONTIER" \
  --arg ghead "$GIT_HEAD" \
  --arg gdirty "$GIT_DIRTY" \
  --arg croot "$CODE_ROOT" \
  --argjson binit "$BUDGET_INIT" \
  --argjson bsess "$BUDGET_SESS" \
  --argjson burn "$BURN_INIT" \
  '{
    schema: "guv.continuation-checkpoint/1",
    checkpoint_at: (if $now=="" then null else $now end),
    trigger: (if $trigger=="" then null else $trigger end),
    session_id: (if $session=="" then null else $session end),
    transcript_path: (if $transcript=="" then null else $transcript end),
    custom_instructions: (if $custom=="" then null else $custom end),
    active_deliverable: (if $active=="" then null else $active end),
    frontier: (if $frontier=="" then null else $frontier end),
    git_head: (if $ghead=="" then null else $ghead end),
    git_dirty_paths: (if $gdirty=="" then null else ($gdirty|tonumber) end),
    code_root: (if $croot=="" then null else $croot end),
    budget: { initiative: $binit, session: $bsess },
    burn: (if $burn == null then null
           else { source: "emit-metrics.sh", by_initiative: $burn } end)
  }' 2>/dev/null)

if [ -z "$CKPT_JSON" ]; then
  echo "continuation-checkpoint: could not assemble the checkpoint envelope — NOT written; compaction proceeds (Rule 15 loud stop)" >&2
  exit 0
fi

# Write it under the resolved root's .claude/. A failure to create the dir or write
# the file is a LOUD, NON-BLOCKING stop — never a reason to block compaction.
OUTDIR="$ROOT/.claude"
OUT="$OUTDIR/continuation-checkpoint.json"
if ! mkdir -p "$OUTDIR" 2>/dev/null || ! printf '%s\n' "$CKPT_JSON" > "$OUT" 2>/dev/null; then
  echo "continuation-checkpoint: cannot write $OUT — checkpoint NOT written; compaction proceeds without a continuation breadcrumb (Rule 15 loud stop)" >&2
  exit 0
fi

exit 0
