#!/bin/bash
# .claude/guv-git.sh — run git against the CODE repo, resolved once ([7.1]).
#
# The git-targeting incantation (git -C "$(jq -r '.roots.code' …)") used to be
# inlined at every call site; this helper is that incantation, once. cwd must
# be the project root (where .claude/project.json lives) — the same contract
# every harness script carries. No manifest, or no roots.code, means
# single-repo: git runs in cwd.
#
# Usage: bash .claude/guv-git.sh <git args…>
#   e.g. bash .claude/guv-git.sh log --oneline -15
#        bash .claude/guv-git.sh status
# The git exit code propagates.
# (Ships byte-identical into both install modes; sibling scripts resolve it
# location-relative, per the [7.7] precedent.)
set -u

CODE="."
if [ -f .claude/project.json ]; then
  CODE=$(jq -r '.roots.code // "."' .claude/project.json 2>/dev/null) || CODE="."
  { [ -n "$CODE" ] && [ "$CODE" != "null" ]; } || CODE="."
fi
exec git -C "$CODE" "$@"
