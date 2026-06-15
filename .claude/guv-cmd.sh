#!/bin/bash
# .claude/guv-cmd.sh — run a manifest command with null-skip, once ([7.1]).
#
# The manifest-command read (jq -r '.commands.<name>' + the null check) used
# to be inlined at every call site; this helper is that read, once. A defined
# command runs via sh -c with cwd = the project root; its exit code
# propagates. null or absent means skip — loudly, with exit 0 (null-means-skip
# is the manifest's design principle; the message keeps the skip visible).
#
# Per-repo selector ([11.3]). The OPTIONAL second arg names which code repo to
# resolve the command FOR, consuming the per-repo `commands` field [11.2]
# forward-declared in the schema:
#
#   bash .claude/guv-cmd.sh <name>          # top-level commands.<name>, cwd = control plane
#   bash .claude/guv-cmd.sh <name> <repo>   # the named repo's commands.<name>,
#                                           # run IN that repo's root (self-location)
#
# Resolution when a repo is named:
#   1. the named repo's own commands.<name> if it declares one (a per-repo OVERRIDE),
#   2. else the top-level commands.<name> (the primary's default — so single-repo
#      manifests, which never carry per-repo commands, are byte-identical).
# The command then runs with cwd = THAT repo's root (resolved through the shared
# [11.2] resolver .claude/roots.sh), so a split-topology command acts on the
# intended code repo, not the control-plane cwd. A misrouted invocation — an
# unknown repo name — FAILS LOUD via the resolver rather than acting in the wrong
# place (Rule 15: a command never silently operates in the wrong repo).
#
# Back-compat (load-bearing): WITHOUT a repo arg the behavior is exactly as
# before — top-level command, cwd = the control plane. On a single-repo plane
# (roots.code "."), naming the primary resolves to "." so running there IS cwd;
# a single-repo plane is unaffected by the selector either way.
#
# Usage: bash .claude/guv-cmd.sh <name> [<repo>]
#   e.g. bash .claude/guv-cmd.sh test
#        bash .claude/guv-cmd.sh test studio      # studio repo's test, in studio
#        bash .claude/guv-cmd.sh install
# Exit: the command's code · 0 on null-skip · 2 usage · 4 no manifest / unknown repo
# (a missing manifest is a caller bug, not a null).
set -u

{ [ $# -ge 1 ] && [ $# -le 2 ]; } || { echo "usage: bash .claude/guv-cmd.sh <command-name> [<repo>]" >&2; exit 2; }
NAME="$1"
REPO="${2:-}"
MANIFEST=".claude/project.json"
[ -f "$MANIFEST" ] || { echo "guv-cmd: no manifest at $MANIFEST (cwd must be the project root)" >&2; exit 4; }
# An unparseable manifest is a loud error, never a null-skip — "skipping"
# would misreport a corrupt manifest as a designed absence (Rule 15).
jq -e . "$MANIFEST" >/dev/null 2>&1 \
  || { echo "guv-cmd: $MANIFEST exists but is not valid JSON — fix the manifest" >&2; exit 4; }

# No repo named → today's path exactly: top-level command, cwd = the control plane.
if [ -z "$REPO" ]; then
  CMD=$(jq -r --arg n "$NAME" '.commands[$n] // empty' "$MANIFEST")
  if [ -z "$CMD" ]; then
    echo "[guv-cmd] commands.$NAME is null — skipping"
    exit 0
  fi
  sh -c "$CMD"
  exit $?
fi

# A repo IS named: resolve WHICH repo through the shared [11.2] resolver. An
# unknown repo name (or a corrupt manifest) is a loud stop there — a command that
# silently ran in the wrong repo is the worst version of this mistake (Rule 15).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/roots.sh"
DIR=$(roots_code_path "$REPO") || exit 4

# Per-repo OVERRIDE wins; an ABSENT per-repo field falls back to the top-level
# default (so a single-repo manifest, which has no per-repo commands, is
# byte-identical). An EXPLICIT per-repo null is NOT a fallback — it is the
# null-means-skip override ("this repo has no such step"), distinct from absence.
# So the field is selected by PRESENCE (has), not by `//` (which would conflate
# an explicit null with absence and wrongly fall through). The override is read
# only for the named-map shape — a string roots.code has no per-repo commands, so
# the top-level default is used, keeping single-repo a no-op.
CMD=$(jq -r --arg r "$REPO" --arg n "$NAME" \
  'if (.roots.code | type) == "object"
       and ((.roots.code[$r].commands // {}) | has($n))
   then (.roots.code[$r].commands[$n] // empty)   # present per-repo: value or null→skip
   else (.commands[$n] // empty)                   # absent per-repo: top-level default
   end' "$MANIFEST")
if [ -z "$CMD" ]; then
  echo "[guv-cmd] commands.$NAME for repo '$REPO' is null — skipping"
  exit 0
fi
# Run IN the resolved repo's root — the self-location. (On a single-repo plane
# DIR is ".", so this is cwd, identical to the bare path.)
( cd "$DIR" && sh -c "$CMD" )
