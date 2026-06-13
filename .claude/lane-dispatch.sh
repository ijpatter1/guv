#!/bin/bash
# .claude/lane-dispatch.sh — the lane-dispatch orchestrator ([7.5], fallback B).
#
# Built on Spike A's fallback B: no per-lane discriminator is available in
# workflow-subagent hook input (only agent_type, which is per-TYPE not per-lane),
# so confinement is DETECTED at the merge gate rather than PREVENTED by a lane
# guard — mechanically equivalent at the join per the spec's Pre-Resolved
# Decision ("detection at the gate ... must not become a blocker"). Lane guard
# (fallback A) stays a documented ladder position if a discriminator ever lands.
#
# This is the deterministic JOIN over lanes that have already executed (the lane
# EXECUTION — spawning agents into worktrees — is the conservative, user-confirmed
# conversational half; this script is the machinery the join runs on, Rule 12):
#
#   confine <id>     the lane's diff must not touch the shared surface the
#                    orchestrator owns at the join — the trackers (single-writer)
#                    and the docFragment-target prose (CHANGELOG/README). Drift
#                    is detected and refused; lanes route prose deltas through
#                    docFragments, never a direct edit.
#   harvest <id>     the lane-failure contract: a dirty / garbage / status=failed
#                    / drifted lane is REFUSED and a failure report is captured to
#                    the control plane (durable — survives worktree cleanup) BEFORE
#                    any destroy; an ok lane's structured output is collected.
#                    The tracker is never touched on this path (7.3 guarantees it).
#   assemble <out>…  docFragments applied SERIALLY to the shared prose — lanes
#                    never touch it, so two lanes' fragments assemble without
#                    conflict (the orchestrator owns the file at the join).
#   dispatch <id>…   the whole join: harvest all (collect ok, report refused),
#                    land the ok lanes through the [7.4] merge queue, assemble
#                    their docFragments, and emit a summary. A failed sibling
#                    never blocks an ok lane; re-dispatch carries the report.
#
# Lanes resolve through guv-lane.sh; landing goes through merge-queue.sh — this
# orchestrator composes them, it does not re-derive them. cwd must be the project
# root (the control plane). Ships byte-identical into both install modes.
#
# The .lane-output.json sidecar (lane → orchestrator) lives at the lane worktree
# root, is UNTRACKED (never committed to the deliverable), and is collected then
# removed at harvest so the worktree lands clean. Shape:
#   {"id","status":"ok|failed","docFragments":[{"file","content"}],"notes"}
#
# Exit: 0 ok · 2 usage · 4 no/corrupt manifest or no code repo · 5 unknown lane
#       or bad input · 6 lane refused (the failure contract).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LANE="$HERE/guv-lane.sh"
QUEUE="$HERE/merge-queue.sh"
REPORTS=".lane-reports"          # durable, in the control plane (survives cleanup)
SIDECAR=".lane-output.json"

die() { echo "lane-dispatch: $2" >&2; exit "$1"; }

CODE="."
if [ -f .claude/project.json ]; then
  jq -e . .claude/project.json >/dev/null 2>&1 \
    || die 4 ".claude/project.json exists but is not valid JSON — fix the manifest"
  CODE=$(jq -r '.roots.code // "."' .claude/project.json)
  { [ -n "$CODE" ] && [ "$CODE" != "null" ]; } || CODE="."
fi
git -C "$CODE" rev-parse --git-dir >/dev/null 2>&1 \
  || die 4 "no git repo at roots.code ($CODE)"

# The shared surface the orchestrator owns — lanes must NOT touch it directly:
# the single-writer trackers, and the changelog/README prose that arrives as
# docFragments. A lane diff intersecting this set has drifted out of confinement.
PROTECTED='(^|/)docs/(PHASE_STATUS|REQUIREMENTS)\.md$|(^|/)(CHANGELOG|README)(\.template)?\.md$'

# The integration branch the queue lands onto — resolved ONCE in the main shell.
# (A die inside a $()-substituted helper only exits the subshell, never the
# script, so the loud stop must live here, not in a function.)
INTEG=$(git -C "$CODE" symbolic-ref --short HEAD 2>/dev/null) \
  || die 4 "code repo HEAD is detached — the queue lands onto a branch"

lane_branch() {  # id -> branch on stdout; returns 1 if unknown (caller dies)
  local id="$1" out
  out=$(bash "$LANE" harvest "$id" 2>/dev/null) || return 1
  printf '%s' "$out" | grep -oE 'branch=[^ ]+' | cut -d= -f2-
}

lane_paths() {   # branch -> changed paths (merge-base..branch)
  local br="$1" base
  base=$(git -C "$CODE" merge-base "$INTEG" "$br")
  git -C "$CODE" diff --name-only "$base..$br"
}

# Real dirtiness = uncommitted work EXCLUDING the orchestrator sidecar. Porcelain
# lines are "XY <path>", so anchor the sidecar match on the path tail, not column 0.
lane_realdirty() {  # id -> count of non-sidecar porcelain lines
  local wt="$CODE/.worktrees/lane-$1"
  [ -d "$wt" ] || { echo 0; return; }
  git -C "$wt" status --porcelain 2>/dev/null | grep -vE '\.lane-output\.json$' | grep -c .
}

# confine: returns 0 confined, 1 drift (prints offenders).
do_confine() {  # $1=id
  local id="$1" br offenders
  br=$(lane_branch "$id") || die 5 "no lane for id $id (expected lane/$id-<slug>)"
  offenders=$(lane_paths "$br" | grep -E "$PROTECTED" || true)
  if [ -n "$offenders" ]; then
    printf 'lane %s drifted onto the shared surface (route prose deltas via docFragments):\n%s\n' "$id" "$offenders"
    return 1
  fi
  return 0
}

# Capture a durable failure report to the control plane. $1=id $2=reason -> path
capture_report() {
  local id="$1" reason="$2" br wt base
  br=$(bash "$LANE" harvest "$id" 2>/dev/null | grep -oE 'branch=[^ ]+' | cut -d= -f2-)
  [ -n "$br" ] || br="(unresolved)"
  wt="$CODE/.worktrees/lane-$id"
  mkdir -p "$REPORTS"
  {
    echo "# Lane failure report — [$id]"
    echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "reason: $reason"
    echo "branch: $br"
    if [ -d "$wt" ]; then
      echo "head: $(git -C "$wt" rev-parse HEAD 2>/dev/null)"
      echo ""
      echo "## rejected diff (stat)"
      base=$(git -C "$CODE" merge-base "$INTEG" "$br" 2>/dev/null)
      [ -n "$base" ] && git -C "$CODE" diff --stat "$base..$br" 2>/dev/null
      echo ""
      echo "## lane output"
      [ -f "$wt/$SIDECAR" ] && cat "$wt/$SIDECAR" || echo "(no $SIDECAR)"
    fi
    echo ""
    echo "Re-dispatch carries this report as explicit input to the retry — the model improvises the repair, never the route."
  } > "$REPORTS/lane-$id.md"
  echo "$REPORTS/lane-$id.md"
}

# harvest: the failure contract. Echoes ok/refusal; returns 0 ok, 6 refused.
# On ok, collects the sidecar to staging and removes it from the worktree so the
# lane lands clean. Does NOT die on a contract refusal (dispatch loops over it).
do_harvest() {  # $1=id
  local id="$1" br wt status report
  br=$(lane_branch "$id") || die 5 "no lane for id $id (expected lane/$id-<slug>)"  # structural, not a contract refusal
  wt="$CODE/.worktrees/lane-$id"
  if [ "$(lane_realdirty "$id")" -gt 0 ]; then
    report=$(capture_report "$id" "dirty worktree (uncommitted changes beyond the sidecar)")
    echo "harvest=refused lane=$id reason=dirty report=$report"; return 6
  fi
  if [ ! -f "$wt/$SIDECAR" ] || ! jq -e . "$wt/$SIDECAR" >/dev/null 2>&1; then
    report=$(capture_report "$id" "missing or invalid $SIDECAR (garbage lane output)")
    echo "harvest=refused lane=$id reason=garbage-output report=$report"; return 6
  fi
  status=$(jq -r '.status // "unknown"' "$wt/$SIDECAR")
  if [ "$status" != "ok" ]; then
    report=$(capture_report "$id" "lane reported status=$status")
    echo "harvest=refused lane=$id reason=status-$status report=$report"; return 6
  fi
  if ! do_confine "$id" >/dev/null 2>&1; then
    report=$(capture_report "$id" "confinement drift (touched the shared surface)")
    echo "harvest=refused lane=$id reason=drift report=$report"; return 6
  fi
  # The docFragment targets are an UNTRUSTED channel — validate them at the gate
  # (here), not at assembly: a target that escapes the repo or names a tracker is
  # a refusal, not something assemble should discover after the lane has landed.
  if ! docfrag_targets_ok "$wt/$SIDECAR"; then
    report=$(capture_report "$id" "docFragment target escapes the repo or names a single-writer tracker")
    echo "harvest=refused lane=$id reason=bad-docfragment-target report=$report"; return 6
  fi
  # ok: collect the structured output to staging, then clear the sidecar so the
  # worktree lands clean through the queue.
  mkdir -p "$REPORTS/staging"
  cp "$wt/$SIDECAR" "$REPORTS/staging/$id.json"
  rm -f "$wt/$SIDECAR"
  echo "harvest=ok lane=$id branch=$br output=$REPORTS/staging/$id.json"
  return 0
}

# A docFragment target is safe only if it stays inside the repo (no absolute
# path, no .. escape) and is not a single-writer tracker (the channel writes
# shared PROSE; plan mutation is /replan only). Returns 1 if ANY target is bad.
docfrag_targets_ok() {  # $1 = lane-output json file
  ! jq -r '.docFragments[].file' "$1" 2>/dev/null \
    | grep -qE '^/|\.\.|(^|/)docs/(PHASE_STATUS|REQUIREMENTS)\.md$'
}

# assemble: append each lane-output's docFragments to the shared prose, serially.
do_assemble() {  # $@ = lane-output json files
  local out file n i
  for out in "$@"; do
    [ -f "$out" ] || die 5 "no lane-output file at $out"
    jq -e . "$out" >/dev/null 2>&1 || die 5 "invalid lane-output JSON at $out"
    docfrag_targets_ok "$out" || die 5 "a docFragment target in $out escapes the repo or names a tracker — refused"
    n=$(jq '.docFragments | length' "$out")
    i=0
    while [ "$i" -lt "$n" ]; do
      file=$(jq -r ".docFragments[$i].file" "$out")
      # Normalize each fragment to end in exactly one newline so two fragments
      # targeting the same file land on separate lines (never run together).
      printf '%s\n' "$(jq -r ".docFragments[$i].content" "$out")" >> "$CODE/$file"
      echo "assembled: $file <- $(jq -r '.id' "$out")"
      i=$((i + 1))
    done
  done
}

[ $# -ge 1 ] || die 2 "usage: bash .claude/lane-dispatch.sh confine <id> | harvest <id> | assemble <out>… | dispatch <id>…"
VERB="$1"; shift

case "$VERB" in
  confine)
    [ $# -eq 1 ] || die 2 "usage: confine <id>"
    do_confine "$1"; exit $?
    ;;

  harvest)
    [ $# -eq 1 ] || die 2 "usage: harvest <id>"
    do_harvest "$1"; exit $?
    ;;

  assemble)
    [ $# -ge 1 ] || die 2 "usage: assemble <lane-output.json>…"
    do_assemble "$@"
    ;;

  dispatch)
    [ $# -ge 1 ] || die 2 "usage: dispatch <id>…"
    TOTAL=$#
    declare -a OK=(); SKIPPED=0
    for id in "$@"; do
      # A dispatched id with no lane is a malformed list entry — skip it (and say
      # so) rather than abort the batch and waste already-collected siblings.
      if ! bash "$LANE" harvest "$id" >/dev/null 2>&1; then
        echo "dispatch: lane $id does not exist — skipped (siblings unaffected)"
        SKIPPED=$((SKIPPED + 1)); continue
      fi
      if do_harvest "$id"; then OK+=("$id"); fi
    done
    declare -a LANDED=()
    if [ "${#OK[@]}" -gt 0 ]; then
      # Order cheapest-first through the [7.4] queue, then gate + land each.
      ORDER=$(bash "$QUEUE" preview "${OK[@]}" 2>/dev/null | grep '^order=' | cut -d= -f2-)
      [ -n "$ORDER" ] || ORDER="${OK[*]}"
      for id in $ORDER; do
        bash "$QUEUE" precheck "$id" >/dev/null 2>&1 \
          || { echo "dispatch: lane $id failed the queue pre-check — not landed"; continue; }
        if bash "$QUEUE" land "$id" >/dev/null 2>&1; then
          LANDED+=("$id")
        else
          echo "dispatch: lane $id hit a queue conflict — routed to serial re-dispatch (merge-queue land $id)"
        fi
      done
    fi
    # Assemble ONLY the landed lanes' docFragments, then commit the join with a
    # SCOPED add of exactly the touched prose — never `add -A`, which in
    # single-repo mode would sweep the orchestrator's own .lane-reports/ scratch
    # into the deliverable commit. (Guarded by the count so an empty LANDED never
    # expands "${LANDED[@]}" under set -u on bash 3.2 — the conflict-everything path.)
    if [ "${#LANDED[@]}" -gt 0 ]; then
      declare -a OUTS=()
      for id in "${LANDED[@]}"; do OUTS+=("$REPORTS/staging/$id.json"); done
      do_assemble "${OUTS[@]}" >/dev/null
      TARGETS=$(jq -r '.docFragments[].file' "${OUTS[@]}" 2>/dev/null | sort -u)
      if [ -n "$TARGETS" ]; then
        while IFS= read -r f; do
          [ -n "$f" ] && git -C "$CODE" add -- "$f"
        done <<< "$TARGETS"
        if ! git -C "$CODE" diff --cached --quiet; then
          git -C "$CODE" -c user.email=guv@local -c user.name=guv \
            commit -qm "docs: assemble lane docFragments at the join (${LANDED[*]})"
        fi
      fi
    fi
    echo "dispatch: landed=[${LANDED[*]:-}] of $TOTAL lane(s) — harvest-refused=$(( TOTAL - SKIPPED - ${#OK[@]} )), queue-not-landed=$(( ${#OK[@]} - ${#LANDED[@]} )), unknown-skipped=$SKIPPED"
    ;;

  *) die 2 "unknown verb '$VERB' (confine | harvest | assemble | dispatch)" ;;
esac
