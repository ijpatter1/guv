#!/bin/bash
# .claude/guv-git.sh — run git against the CODE repo, resolved once ([7.1]).
#
# The git-targeting incantation used to be inlined at every call site; this
# helper is that incantation, once. cwd must be the project root (where
# .claude/project.json lives) — the same contract every core script carries.
#
# As of [11.2] the resolution of WHICH code repo lives in .claude/roots.sh (the
# string-or-named-map resolver): `roots.code` is a string (single-repo
# shorthand — the string is the primary) or a named map of code repos. This
# helper is a thin, back-compatible front for `roots.sh git`: an unqualified
# `guv-git.sh <args>` targets the primary (single-repo behavior, unchanged), and
# an optional leading repo name targets a named repo in a multi-repo plane.
#
# Usage: bash .claude/guv-git.sh [<repo>] <git args…>
#   e.g. bash .claude/guv-git.sh log --oneline -15        # primary
#        bash .claude/guv-git.sh studio log --oneline -1  # the 'studio' repo
# No manifest, or no roots.code, means single-repo: git runs in cwd. A manifest
# that exists but cannot be parsed is a loud error, never the single-repo
# fallback (in a split plane that would silently run git against the wrong repo
# — Rule 15: loud stop, not an invented path). The git exit code propagates.
# (Ships byte-identical into both install modes; sibling scripts resolve it
# location-relative, per the [7.7] precedent.)
set -u

# Resolve roots.sh location-relative ([7.7]) so it works from either install mode.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/roots.sh"

roots_code_git "$@"
