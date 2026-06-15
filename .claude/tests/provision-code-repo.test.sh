#!/bin/bash
# Tests for .claude/provision-code-repo.sh ([10.10] — code-repo-agnostic lane machinery).
# A foreign code repo becomes a functional guv lane target: a deploy-once manifest
# (ceremony=task) + the marker-idempotent guv-core .gitignore block, so /task routes in
# a lane worktree and .worktrees/ doesn't leak. Idempotent / no-clobber against an
# already-provisioned repo (the guv self-hosting case — roots.code IS guv — is the
# already-done degenerate, not a skipped exception). Pure bash.
# Run: bash .claude/tests/provision-code-repo.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROV="$ROOT/.claude/provision-code-repo.sh"
ROUTE="$ROOT/.claude/route.sh"
TMPL="$ROOT/plugin/shell/gitignore"     # canonical guv-core block (drift guard; source-shape only)
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# T1 — script exists. Everything else reads it; bail loudly if absent.
if [ -f "$PROV" ]; then
  ok "provision-code-repo.sh exists"
else
  no "missing: $PROV"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkrepo() {  # $1 = dir — a plain foreign git repo (no .claude/, no .gitignore)
  mkdir -p "$1/src"; printf 'echo hi\n' > "$1/src/app.sh"
  git -C "$1" init -q >/dev/null 2>&1
  git -C "$1" config user.email t@t >/dev/null 2>&1
  git -C "$1" config user.name t >/dev/null 2>&1
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" commit -qm init >/dev/null 2>&1
}

# T2 — provision a fresh foreign repo: manifest + gitignore, stderr-clean
R1="$WORK/r1"; mkrepo "$R1"
bash "$PROV" "$R1" --test "bash src/app.sh" >/dev/null 2>"$WORK/e1"
[ -s "$WORK/e1" ] && no "provision emitted stderr: $(cat "$WORK/e1")" || ok "provision runs stderr-clean"
[ -f "$R1/.claude/project.json" ] && ok "manifest written" || no "no manifest written"
jq -e '.ceremony=="task"' "$R1/.claude/project.json" >/dev/null 2>&1 \
  && ok "manifest ceremony=task" || no "manifest ceremony not task"
jq -e '.commands.test=="bash src/app.sh"' "$R1/.claude/project.json" >/dev/null 2>&1 \
  && ok "commands.test set from --test" || no "commands.test not set from --test"
grep -qF '.worktrees/' "$R1/.gitignore" 2>/dev/null \
  && ok ".worktrees/ is gitignored (G1 closed)" || no ".worktrees/ not gitignored"

# T3 — /task routes in the provisioned repo (G2 closed)
( cd "$R1" && bash "$ROUTE" --for task >"$WORK/route.out" 2>&1 )
grep -q '^door=task' "$WORK/route.out" \
  && ok "route.sh --for task -> door=task in the provisioned repo" \
  || no "route did not yield door=task: $(tr '\n' ' ' <"$WORK/route.out")"

# T4 — idempotent / no-clobber (the guv self-hosting invariant): re-run preserves an
# existing manifest and never duplicates the gitignore block.
jq '.commands.test="SENTINEL"' "$R1/.claude/project.json" >"$WORK/m.tmp" 2>/dev/null && mv "$WORK/m.tmp" "$R1/.claude/project.json"
before_gi=$(grep -cF '.worktrees/' "$R1/.gitignore" 2>/dev/null)
bash "$PROV" "$R1" --test "bash src/app.sh" >/dev/null 2>&1
jq -e '.commands.test=="SENTINEL"' "$R1/.claude/project.json" >/dev/null 2>&1 \
  && ok "re-run did NOT clobber the existing manifest (deploy-once)" \
  || no "re-run overwrote the manifest"
after_gi=$(grep -cF '.worktrees/' "$R1/.gitignore" 2>/dev/null)
[ "$before_gi" = "$after_gi" ] \
  && ok "re-run did NOT duplicate the gitignore block (marker-idempotent)" \
  || no "gitignore block duplicated ($before_gi -> $after_gi)"

# T5 — a foreign .gitignore already present (no guv marker): block appended, prior preserved
R2="$WORK/r2"; mkrepo "$R2"; printf 'node_modules/\n' > "$R2/.gitignore"
bash "$PROV" "$R2" >/dev/null 2>&1
{ grep -qF 'node_modules/' "$R2/.gitignore" && grep -qF '.worktrees/' "$R2/.gitignore"; } \
  && ok "appended guv-core block while preserving the existing .gitignore" \
  || no "append/preserve failed"

# T6 — drift guard: the canonical guv-core block still carries the lane entries this
# script writes (so a hardcoded subset can't silently diverge). Source-shape only.
if [ -f "$TMPL" ]; then
  block=$(awk '/^# guv-core-start/,/^# guv-core-end/' "$TMPL")
  miss=0
  for e in '.worktrees/' '.lane-reports/'; do printf '%s\n' "$block" | grep -qF "$e" || miss=1; done
  [ "$miss" -eq 0 ] \
    && ok "lane entries present in the canonical guv-core block (drift guard)" \
    || no "provision's lane entries drifted from the canonical guv-core block"
else
  echo "  - canonical gitignore template absent ($TMPL) — drift guard skips (plugin/fork shape)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
