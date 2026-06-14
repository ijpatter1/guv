#!/bin/bash
# .claude/guv-git.sh — run git against the CODE repo, resolved once ([7.1]).
#
# The git-targeting incantation (git -C "$(jq -r '.roots.code' …)") used to be
# inlined at every call site; this helper is that incantation, once. cwd must
# be the project root (where .claude/project.json lives) — the same contract
# every core script carries. No manifest, or no roots.code, means
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
  # A manifest that exists but cannot be parsed is a loud error, never the
  # single-repo fallback — in a split plane that fallback would silently run
  # git against the wrong repo (Rule 15: loud stop, not an invented path).
  jq -e . .claude/project.json >/dev/null 2>&1 \
    || { echo "guv-git: .claude/project.json exists but is not valid JSON — fix the manifest" >&2; exit 4; }
  CODE=$(jq -r '.roots.code // "."' .claude/project.json)
  { [ -n "$CODE" ] && [ "$CODE" != "null" ]; } || CODE="."
fi
exec git -C "$CODE" "$@"
