#!/bin/bash
# .claude/provision-code-repo.sh — make an arbitrary code repo (one not itself a guv
# install) a functional guv lane target ([10.10]).
#
# (Slash commands named in this file are guv:-namespaced under a plugin install — e.g.
# /guv:task — so a lane builder's /task resolves in either install mode.)
#
# A control plane in the split topology orchestrates lanes (guv-lane.sh) that are
# worktrees of roots.code. For a lane builder to run /task in such a worktree the code
# repo needs the guv-core a control plane silently ASSUMES it has (setup-control-plane.sh
# bakes in "roots.code gets the guv-core block via the scaffold") — true only when
# roots.code happens to be guv-scaffolded (e.g. guv building guv), false for any real
# consumer code repo. This writes that core:
#   - a ceremony=task manifest (.claude/project.json), DEPLOY-ONCE — never clobber an
#     existing one
#   - the guv-core .gitignore block (lane worktrees + scratch), MARKER-IDEMPOTENT —
#     never duplicate when already present
# So it is idempotent / no-clobber: an already-provisioned repo (incl. the guv
# self-hosting case, where roots.code IS guv) is the already-done DEGENERATE case, left
# untouched — not a skipped exception. Helpers (route.sh, guv-cmd.sh, the lane scripts)
# come from the user-level plugin (${CLAUDE_PLUGIN_ROOT}); only the per-repo manifest +
# gitignore are written here.
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

# ── .gitignore: MARKER-IDEMPOTENT guv-core block (lane worktrees + scratch) ──
# Same marker (guv-gitignore) and guv-core-start/end delimiters as scaffold-shell.sh,
# so the two recognize each other's block and never double-append. Only the lane-
# relevant entries are written (a code repo lane target needs no more); the
# provision-code-repo test's drift guard keeps these in step with the canonical block.
GI="$DEST/.gitignore"
GI_MARKER="guv-gitignore"
GI_MARKER_LEGACY="guv-harness-gitignore"
gi_block() {
  printf '# %s — appended by provision-code-repo.sh ([10.10])\n' "$GI_MARKER"
  printf '# guv-core-start\n'
  printf '# guv lane worktrees (guv-lane.sh — fan-out dispatch)\n.worktrees/\n'
  printf '# guv lane failure reports + collected lane outputs (lane-dispatch.sh — scratch)\n.lane-reports/\n'
  printf '# guv-core-end\n'
}
if [ ! -f "$GI" ]; then
  gi_block > "$GI"
  did+=(".gitignore (guv-core block)")
  wrote+=(".gitignore")
elif ! grep -qe "$GI_MARKER" -e "$GI_MARKER_LEGACY" "$GI"; then
  { printf '\n'; gi_block; } >> "$GI"
  did+=(".gitignore (guv-core block appended)")
  wrote+=(".gitignore")
else
  echo "provision: .gitignore already carries the guv-core block — kept (no duplicate)"
fi

# Commit the provisioning so lane worktrees (checkouts of HEAD) inherit it: an
# untracked manifest satisfies a working-tree check but is ABSENT from every new
# worktree, so a lane builder can't route work there (caught in the [10.10] e2e).
# Commit ONLY what provision wrote — never the consumer's other work; own git identity
# so it works in a repo with no user.* config; no-op when nothing was written.
if [ ${#wrote[@]} -gt 0 ] && git -C "$DEST" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$DEST" add -- "${wrote[@]}"
  if ! git -C "$DEST" diff --cached --quiet 2>/dev/null; then
    git -C "$DEST" -c user.email=guv@local -c user.name=guv \
      commit -qm "chore: provision as a guv lane target ([10.10])" 2>/dev/null \
      && echo "provision: committed the guv-core (lane worktrees inherit it)"
  fi
fi

[ ${#did[@]} -gt 0 ] && printf 'provision: wrote %s\n' "${did[@]}"
echo "provision: $DEST is a guv lane target (ceremony=task)"
exit 0
