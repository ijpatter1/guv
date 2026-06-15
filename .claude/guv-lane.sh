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
# Per-repo selector & worktree namespacing ([11.3]). Each verb takes an OPTIONAL
# trailing <repo> selecting which named code repo the lane lives in (resolved
# through the shared [11.2] resolver; default = the primary). When a repo IS
# named, the worktree is REPO-NAMESPACED at .worktrees/<repo>/lane-<id>/ so two
# code repos' lanes never collide and the same deliverable id can have a lane in
# each repo. Without a repo arg the worktree stays at the flat .worktrees/lane-<id>/
# — the load-bearing single-repo back-compat (a '.' plane is unaffected).
#
# Usage:
#   bash .claude/guv-lane.sh create <id> <slug> [<repo>]      # worktree + branch from current HEAD
#   bash .claude/guv-lane.sh harvest <id> [<repo>]            # one line: lane= branch= head= ahead= dirty=
#   bash .claude/guv-lane.sh destroy <id> [--force] [<repo>]  # remove + branch delete + prune
#
# destroy refuses a dirty or unmerged lane unless --force, and refuses BEFORE
# mutating anything — the [7.5] lane-failure contract builds on that refusal
# (a failed lane is preserved for its failure report, never half-deleted).
# Exit: 0 ok · 2 usage · 4 no/unknown code repo · 5 unknown/ambiguous lane ·
#       6 refused (dirty or unmerged without --force, duplicate create)
set -u

usage() { echo "usage: bash .claude/guv-lane.sh create <id> <slug> [<repo>] | harvest <id> [<repo>] | destroy <id> [--force] [<repo>]" >&2; exit 2; }
die4() { echo "guv-lane: $1" >&2; exit 4; }
die5() { echo "guv-lane: $1" >&2; exit 5; }
die6() { echo "guv-lane: $1" >&2; exit 6; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/roots.sh"

[ $# -ge 2 ] || usage
VERB="$1"; ID="$2"; shift 2
# After dropping verb+id, an OPTIONAL TRAILING token that names a code repo
# selects it (and namespaces the worktree); anything else stays a verb flag (e.g.
# destroy's --force). The resolver's _roots_is_repo_name is the single oracle for
# "is this a repo name" — only the named-map shape has names, so on a string
# roots.code the trailing token never matches and single-repo stays a flat-path
# no-op. Peel the repo off the END of $@ so each verb's arg-count check below
# sees only its own positionals and a misplaced flag keeps its position.
# Is the plane a named map (the only shape with repo names)? On a string
# roots.code there are no names, so the trailing token is never a repo and
# single-repo stays a flat-path no-op. A named map is exactly "the code root is an
# object" — `jq -e` on that predicate, not a bare-string path read, so the
# no-single-root-read invariant (roots-map.test) is preserved.
_is_named_map() {
  [ -f "$ROOTS_MANIFEST" ] || return 1
  jq -e '(.roots.code | type) == "object"' "$ROOTS_MANIFEST" >/dev/null 2>&1
}
REPO=""; NS=""; MISROUTE=""
if [ $# -ge 1 ]; then
  _last="${!#}"
  if _roots_is_repo_name "$_last"; then
    REPO="$_last"; NS="$REPO/"
    set -- "${@:1:$#-1}"   # drop the peeled repo token
  elif [ "$VERB" != "destroy" ] || [ "$_last" != "--force" ]; then
    # An UNRECOGNISED trailing token on a NAMED-MAP plane that is not a known
    # verb flag is very likely a misrouted repo name — remember it so the verb
    # can loud-stop NAMING the offender (Rule 15: a lane in the wrong repo is the
    # worst outcome; refuse loudly rather than silently use the primary). On a
    # string plane there are no repo names, so this never fires and the token is
    # just a usage error handled by the per-verb arg-count check.
    if _is_named_map; then MISROUTE="$_last"; fi
  fi
fi

# Resolve WHICH code repo through the shared [11.2] resolver — a string
# roots.code is the single primary, a named map addresses each repo by name.
# An unparseable manifest is a loud error, never the single-repo fallback (a
# lane created in the wrong repo is the worst version of this mistake; Rule 15).
# A named-but-unknown <repo> loud-stops in the resolver (it names the offender).
CODE=$(roots_code_path "$REPO") || die4 "could not resolve code repo '${REPO:-<primary>}' from the manifest"
git -C "$CODE" rev-parse --git-dir >/dev/null 2>&1 \
  || die4 "no git repo at roots.code ($CODE)"

# The lane's branch, found by its id prefix. Exactly one or fail loud.
lane_branch() {
  local matches
  matches=$(git -C "$CODE" for-each-ref --format='%(refname:short)' "refs/heads/lane/$ID-*")
  [ -n "$matches" ] || die5 "no lane branch for id $ID (expected lane/$ID-<slug>)"
  [ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" -eq 1 ] \
    || die5 "ambiguous lane id $ID: $(printf '%s' "$matches" | tr '\n' ' ')"
  printf '%s' "$matches"
}

# The worktree path, repo-namespaced when a repo is named (NS="<repo>/"), flat
# otherwise — the one derivation every verb shares.
WT=".worktrees/${NS}lane-$ID"

# A misrouted repo name (a named-map plane, a trailing token that names no known
# repo) is refused loudly before any mutation — never a silent fall-through to the
# primary (Rule 15). Route it through the resolver, whose unknown-repo stop already
# names the offender AND the known repos (one message, one owner — and no inline
# roots.code read here).
[ -n "$MISROUTE" ] && { roots_code_path "$MISROUTE" >/dev/null; die4 "unknown code repo '$MISROUTE' — see the resolver error above"; }

case "$VERB" in
  create)
    # create <id> <slug> [<repo>] — the repo (if any) was already peeled off $@.
    [ $# -eq 1 ] || usage
    SLUG="$1"
    # id/slug shape the branch and worktree names — keep them to the safe
    # charset rather than letting a slash or space produce surprising refs
    case "$ID" in (*[!A-Za-z0-9._-]*|"") echo "guv-lane: invalid lane id '$ID' (use letters, digits, . _ -)" >&2; exit 2 ;; esac
    case "$SLUG" in (*[!A-Za-z0-9._-]*|"") echo "guv-lane: invalid slug '$SLUG' (use letters, digits, . _ -)" >&2; exit 2 ;; esac
    # The code repo must be a provisioned guv lane target before a lane is created:
    # without a manifest a lane builder cannot route its scoped work in the worktree
    # ([10.10]). Loud-stop, never auto-provision — the setup step stays explicit (Rule 15).
    # Check the manifest is TRACKED (not merely present): a worktree is a checkout of
    # HEAD, so an untracked manifest is absent from every lane — the invariant is
    # "committed", which provision-code-repo.sh guarantees.
    git -C "$CODE" ls-files --error-unmatch .claude/project.json >/dev/null 2>&1 \
      || die4 "code repo at roots.code ($CODE) is not a provisioned guv lane target (no committed .claude/project.json) — run: bash .claude/provision-code-repo.sh \"$CODE\""
    BR="lane/$ID-$SLUG"
    [ -e "$CODE/$WT" ] && die6 "lane $ID already exists at $WT"
    git -C "$CODE" show-ref --verify --quiet "refs/heads/$BR" \
      && die6 "branch $BR already exists"
    git -C "$CODE" worktree add --quiet "$WT" -b "$BR" || exit $?
    echo "lane=$ID worktree=$WT branch=$BR"
    ;;
  harvest)
    # harvest <id> [<repo>] — repo (if any) peeled off; no other positional.
    [ $# -eq 0 ] || usage
    BR=$(lane_branch) || exit $?
    [ -d "$CODE/$WT" ] || die5 "lane $ID branch exists but worktree $WT is missing"
    HEAD=$(git -C "$CODE/$WT" rev-parse HEAD) || die5 "cannot resolve HEAD of lane $ID"
    BASE=$(git -C "$CODE" merge-base HEAD "$BR") || die5 "cannot resolve merge-base for lane $ID"
    AHEAD=$(git -C "$CODE" rev-list --count "$BASE..$BR") || die5 "cannot count lane $ID commits"
    DIRTY=0
    [ -n "$(git -C "$CODE/$WT" status --porcelain)" ] && DIRTY=1
    echo "lane=$ID branch=$BR head=$HEAD ahead=$AHEAD dirty=$DIRTY"
    ;;
  destroy)
    # destroy <id> [--force] [<repo>] — repo (if any) peeled off; only --force
    # (or nothing) may remain.
    { [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = "--force" ]; }; } || usage
    FORCE=${1:-}
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
