#!/bin/bash
# .claude/guv-lane.sh — worktree lane lifecycle for fan-out dispatch ([7.1]).
#
# Lanes are git worktrees of the CODE repo (roots.code from the manifest, "."
# for single-repo), living in-repo at .worktrees/lane-<id>/ on branch
# lane/<id>-<slug> (gitignored via the guv-core block). One lane per
# deliverable ID. The full lifecycle is create → harvest → destroy; destroy is
# worktree remove + branch delete + prune — a destroy that leaks lane/*
# branches is a failure, not a variant.
#
# Usage:
#   bash .claude/guv-lane.sh create <id> <slug>      # worktree + branch from current HEAD
#   bash .claude/guv-lane.sh harvest <id>            # one line: lane= branch= head= ahead= dirty=
#   bash .claude/guv-lane.sh destroy <id> [--force]  # remove + branch delete + prune
#
# destroy refuses a dirty or unmerged lane unless --force, and refuses BEFORE
# mutating anything — the [7.5] lane-failure contract builds on that refusal
# (a failed lane is preserved for its failure report, never half-deleted).
# Exit: 0 ok · 2 usage · 4 no code repo · 5 unknown/ambiguous lane ·
#       6 refused (dirty or unmerged without --force, duplicate create)
set -u

usage() { echo "usage: bash .claude/guv-lane.sh create <id> <slug> | harvest <id> | destroy <id> [--force]" >&2; exit 2; }
die4() { echo "guv-lane: $1" >&2; exit 4; }
die5() { echo "guv-lane: $1" >&2; exit 5; }
die6() { echo "guv-lane: $1" >&2; exit 6; }

CODE="."
if [ -f .claude/project.json ]; then
  # Unparseable manifest -> loud error, never the single-repo fallback (a lane
  # created in the wrong repo is the worst version of this mistake; Rule 15).
  jq -e . .claude/project.json >/dev/null 2>&1 \
    || die4 ".claude/project.json exists but is not valid JSON — fix the manifest"
  CODE=$(jq -r '.roots.code // "."' .claude/project.json)
  { [ -n "$CODE" ] && [ "$CODE" != "null" ]; } || CODE="."
fi
git -C "$CODE" rev-parse --git-dir >/dev/null 2>&1 \
  || die4 "no git repo at roots.code ($CODE)"

[ $# -ge 2 ] || usage
VERB="$1"; ID="$2"

# The lane's branch, found by its id prefix. Exactly one or fail loud.
lane_branch() {
  local matches
  matches=$(git -C "$CODE" for-each-ref --format='%(refname:short)' "refs/heads/lane/$ID-*")
  [ -n "$matches" ] || die5 "no lane branch for id $ID (expected lane/$ID-<slug>)"
  [ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" -eq 1 ] \
    || die5 "ambiguous lane id $ID: $(printf '%s' "$matches" | tr '\n' ' ')"
  printf '%s' "$matches"
}

WT=".worktrees/lane-$ID"

case "$VERB" in
  create)
    [ $# -eq 3 ] || usage
    SLUG="$3"
    BR="lane/$ID-$SLUG"
    [ -e "$CODE/$WT" ] && die6 "lane $ID already exists at $WT"
    git -C "$CODE" show-ref --verify --quiet "refs/heads/$BR" \
      && die6 "branch $BR already exists"
    git -C "$CODE" worktree add --quiet "$WT" -b "$BR" || exit $?
    echo "lane=$ID worktree=$WT branch=$BR"
    ;;
  harvest)
    [ $# -eq 2 ] || usage
    BR=$(lane_branch) || exit $?
    [ -d "$CODE/$WT" ] || die5 "lane $ID branch exists but worktree $WT is missing"
    HEAD=$(git -C "$CODE/$WT" rev-parse HEAD)
    BASE=$(git -C "$CODE" merge-base HEAD "$BR")
    AHEAD=$(git -C "$CODE" rev-list --count "$BASE..$BR")
    DIRTY=0
    [ -n "$(git -C "$CODE/$WT" status --porcelain)" ] && DIRTY=1
    echo "lane=$ID branch=$BR head=$HEAD ahead=$AHEAD dirty=$DIRTY"
    ;;
  destroy)
    [ $# -eq 2 ] || { [ $# -eq 3 ] && [ "$3" = "--force" ]; } || usage
    FORCE=${3:-}
    BR=$(lane_branch) || exit $?
    # Refuse BEFORE mutating: a half-destroyed lane is worse than either state.
    if [ -z "$FORCE" ]; then
      if [ -d "$CODE/$WT" ] && [ -n "$(git -C "$CODE/$WT" status --porcelain)" ]; then
        die6 "lane $ID is dirty — harvest or pass --force"
      fi
      git -C "$CODE" merge-base --is-ancestor "$BR" HEAD \
        || die6 "lane $ID ($BR) is not merged — land it through the queue or pass --force"
    fi
    if [ -d "$CODE/$WT" ]; then
      if [ -n "$FORCE" ]; then
        git -C "$CODE" worktree remove --force "$WT" || exit $?
      else
        git -C "$CODE" worktree remove "$WT" || exit $?
      fi
    fi
    if [ -n "$FORCE" ]; then
      git -C "$CODE" branch --quiet -D "$BR" || exit $?
    else
      git -C "$CODE" branch --quiet -d "$BR" || exit $?
    fi
    git -C "$CODE" worktree prune
    echo "lane=$ID destroyed (worktree removed, $BR deleted, pruned)"
    ;;
  *) usage ;;
esac
