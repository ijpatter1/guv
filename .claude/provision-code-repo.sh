#!/bin/bash
# .claude/provision-code-repo.sh — give an arbitrary code repo (one not itself a guv
# install) the per-repo guv core a split-topology control plane assumes it has ([10.10];
# the lane-target framing retired with the lane cluster at [32.3]).
#
# (Slash commands named in this file are guv:-namespaced under a plugin install — e.g.
# /guv:task — so /task resolves in either install mode.)
#
# A control plane in the split topology runs commands and QA against roots.code. For
# /task (or a worktree-isolated reviewer) to operate in that repo it needs the guv-core
# a control plane silently ASSUMES it has (setup-control-plane.sh bakes in "roots.code
# gets the guv-core via the scaffold") — true only when roots.code happens to be
# guv-scaffolded (e.g. guv building guv), false for any real consumer code repo. This
# writes that core: a ceremony=task manifest (.claude/project.json), DEPLOY-ONCE —
# never clobber an existing one.
# So it is idempotent / no-clobber: an already-provisioned repo (incl. the guv
# self-hosting case, where roots.code IS guv) is the already-done DEGENERATE case, left
# untouched — not a skipped exception. Helpers (route.sh, guv-cmd.sh) come from the
# user-level plugin (${CLAUDE_PLUGIN_ROOT}); only the per-repo manifest is written here.
#
# Command self-location ([11.3]). When roots.code is a NAMED MAP (N code repos under
# one control plane), a command must act on the INTENDED code repo, never the
# control-plane cwd — a silent wrong-repo operation is the worst failure (Rule 15).
# guv-cmd.sh <name> [<repo>] runs the NAMED repo's commands.<name> (the per-repo
# `commands` override, else the top-level default) IN that repo's root — so a project
# command self-locates instead of running from the plane, keyed on the optional
# trailing <repo> selector and resolved through the shared .claude/roots.sh. A
# misrouted invocation (an unknown <repo>) loud-stops, naming the offender. A string
# roots.code (single-repo) has no repo names, so the selector is a no-op — single-repo
# planes are unaffected (the load-bearing back-compat).
#
# Usage:
#   bash .claude/provision-code-repo.sh <code-repo-path> [--language <lang>] [--test <cmd>]
#
# Exit: 0 ok · 2 usage · 4 path missing / not a directory.
set -u

usage() { echo "usage: bash .claude/provision-code-repo.sh <code-repo-path> [--language <lang>] [--test <cmd>]" >&2; exit 2; }

[ $# -ge 1 ] || usage
DEST="$1"; shift
LANG_="shell"; TEST_CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --language) [ $# -ge 2 ] || usage; LANG_="$2"; shift 2 ;;
    --test)     [ $# -ge 2 ] || usage; TEST_CMD="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ -d "$DEST" ] || { echo "provision: no directory at '$DEST'" >&2; exit 4; }

did=(); wrote=()

# ── manifest: DEPLOY-ONCE (never clobber an existing one) ──
MANIFEST="$DEST/.claude/project.json"
if [ -f "$MANIFEST" ]; then
  echo "provision: manifest exists at .claude/project.json — kept (no clobber)"
else
  mkdir -p "$DEST/.claude"
  name=$(basename "$(cd "$DEST" && pwd)")
  if [ -n "$TEST_CMD" ]; then test_json=$(printf '%s' "$TEST_CMD" | jq -Rs .); else test_json=null; fi
  jq -n --arg name "$name" --arg lang "$LANG_" --argjson test "$test_json" '{
    name: $name, language: $lang, packageManager: null,
    roots: { control: ".", code: "." },
    commands: { test: $test, build: null, lint: null, format: null, dev: null, install: null },
    scaffoldCheck: "test -d .claude", readyCheck: null,
    formatExtensions: [], guards: [], ceremony: "task"
  }' > "$MANIFEST"
  did+=("manifest .claude/project.json (ceremony=task)")
  wrote+=(".claude/project.json")
  [ -n "$TEST_CMD" ] || echo "provision: NOTE commands.test is null — set it (or re-run with --test '<cmd>') so 'guv-cmd test' runs the repo's tests"
fi

# Commit the provisioning so worktrees and clones (checkouts of HEAD) inherit it: an
# untracked manifest satisfies a working-tree check but is ABSENT from every new
# worktree — a worktree-isolated agent then can't route work there (caught in the
# [10.10] e2e).
# Commit ONLY what provision wrote — never the consumer's other work; own git identity
# so it works in a repo with no user.* config; no-op when nothing was written.
if [ ${#wrote[@]} -gt 0 ] && git -C "$DEST" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$DEST" add -- "${wrote[@]}"
  if ! git -C "$DEST" diff --cached --quiet 2>/dev/null; then
    git -C "$DEST" -c user.email=guv@local -c user.name=guv \
      commit -qm "chore: provision the guv code-repo core ([10.10])" 2>/dev/null \
      && echo "provision: committed the guv-core (worktrees and clones inherit it)"
  fi
fi

[ ${#did[@]} -gt 0 ] && printf 'provision: wrote %s\n' "${did[@]}"
echo "provision: $DEST carries the guv code-repo core (ceremony=task)"
exit 0
