#!/bin/bash
# .claude/roots.sh — resolve the CODE repo(s) from the manifest, once ([11.2]).
#
# `roots.code` is a STRING (single-repo shorthand — the string IS the primary)
# OR a named MAP of code repos { name: { path, commands? } } with `codePrimary`
# naming the default. This helper is the ONE place that knows both shapes: every
# root-aware reader resolves a NAMED repo through it (default = the primary), so
# no call site assumes a single code root.
#
# Back-compat (load-bearing): a string `roots.code` resolves to itself as the
# primary, every op a no-op exactly as the string-`.` is today. No manifest, or
# no roots.code, means single-repo: the path is ".". An unparseable manifest is
# a LOUD error, never the "." fallback (a split plane would silently run git
# against the wrong repo — Rule 15).
#
# Two ways to use it:
#   1. EXEC (the guv-git.sh successor):
#        bash .claude/roots.sh path [<repo>]        # → resolved path (default: primary)
#        bash .claude/roots.sh git  [<repo>] <args> # → git -C "<path>" <args>
#   2. SOURCE (for siblings that already resolved CODE inline):
#        . "<dir>/roots.sh"            # defines roots_code_path / roots_code_git
#        CODE=$(roots_code_path)       # the primary's path (the old CODE= read)
#        roots_code_git <repo> <args>  # git against a named repo
#
# cwd must be the project root (where .claude/project.json lives) — the contract
# every core script carries. Exit: 0 ok · 2 usage · 4 no/bad manifest or unknown
# repo · the git exit code propagates from `git`.
set -u

ROOTS_MANIFEST="${ROOTS_MANIFEST:-.claude/project.json}"

# roots_code_path [<repo>] → echo the resolved path; non-zero + stderr on error.
roots_code_path() {
  local want="${1:-}"
  # No manifest → single-repo "." (the historical bare-read fallback).
  if [ ! -f "$ROOTS_MANIFEST" ]; then
    if [ -n "$want" ]; then
      echo "roots: no manifest, but a repo name ('$want') was requested" >&2
      return 4
    fi
    echo "."
    return 0
  fi
  # A manifest that exists but won't parse is a loud stop, never the fallback.
  if ! jq -e . "$ROOTS_MANIFEST" >/dev/null 2>&1; then
    echo "roots: $ROOTS_MANIFEST exists but is not valid JSON — fix the manifest" >&2
    return 4
  fi

  local kind
  kind=$(jq -r '.roots.code | type' "$ROOTS_MANIFEST" 2>/dev/null)

  case "$kind" in
    string|null)
      # String shorthand: the string IS the primary. (null/absent → ".".)
      local code
      code=$(jq -r '.roots.code // "."' "$ROOTS_MANIFEST")
      { [ -n "$code" ] && [ "$code" != "null" ]; } || code="."
      if [ -n "$want" ]; then
        # A single-repo plane has exactly one code repo (the primary). Addressing
        # any OTHER name is a wrong-repo request → loud stop. Naming the primary
        # by its conventional aliases is accepted.
        case "$want" in
          "$code"|code|primary) : ;;
          *)
            echo "roots: '$want' is not a code repo — roots.code is a single repo ('$code')" >&2
            return 4 ;;
        esac
      fi
      echo "$code"
      return 0
      ;;
    object)
      # Named map. roots.codePrimary names the default; a requested name overrides it.
      local primary target path
      primary=$(jq -r '.roots.codePrimary // empty' "$ROOTS_MANIFEST")
      if [ -z "$primary" ]; then
        echo "roots: roots.code is a named map but codePrimary is missing — which repo is the default?" >&2
        return 4
      fi
      target="${want:-$primary}"
      path=$(jq -r --arg n "$target" '.roots.code[$n].path // empty' "$ROOTS_MANIFEST")
      if [ -z "$path" ]; then
        echo "roots: unknown code repo '$target' — known: $(jq -r '.roots.code | keys | join(", ")' "$ROOTS_MANIFEST")" >&2
        return 4
      fi
      echo "$path"
      return 0
      ;;
    *)
      echo "roots: roots.code has an unexpected type ('$kind') — expected a string or a named map" >&2
      return 4
      ;;
  esac
}

# roots_code_git [<repo>] <git args…> → git -C "<resolved path>" <args>.
# The repo selector is OPTIONAL and positional-first: if the first arg names a
# known code repo it selects that repo, otherwise it is treated as the first git
# arg against the primary. (A bare `roots_code_git log …` keeps single-repo
# behavior; `roots_code_git studio log …` targets the named repo.)
roots_code_git() {
  local repo="" path
  if [ $# -gt 0 ] && _roots_is_repo_name "$1"; then
    repo="$1"; shift
  fi
  path=$(roots_code_path "$repo") || return $?
  git -C "$path" "$@"
}

# _roots_is_repo_name <token> → 0 if <token> is a declared code-repo key (only
# meaningful for the named-map shape; a string roots.code has no named keys, so
# the first arg is always a git arg there).
_roots_is_repo_name() {
  [ -f "$ROOTS_MANIFEST" ] || return 1
  jq -e . "$ROOTS_MANIFEST" >/dev/null 2>&1 || return 1
  [ "$(jq -r '.roots.code | type' "$ROOTS_MANIFEST" 2>/dev/null)" = "object" ] || return 1
  jq -e --arg n "$1" '.roots.code | has($n)' "$ROOTS_MANIFEST" >/dev/null 2>&1
}

# ── EXEC entry point: only when run directly, not when sourced. ──
# (BASH_SOURCE[0] == $0 means "run as a script", the standard guard.)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ $# -ge 1 ] || { echo "usage: bash .claude/roots.sh path [<repo>] | git [<repo>] <git args…>" >&2; exit 2; }
  verb="$1"; shift
  case "$verb" in
    path)
      [ $# -le 1 ] || { echo "usage: bash .claude/roots.sh path [<repo>]" >&2; exit 2; }
      roots_code_path "${1:-}"
      ;;
    git)
      roots_code_git "$@"
      ;;
    *)
      echo "roots: unknown verb '$verb' (expected: path | git)" >&2
      exit 2
      ;;
  esac
fi
