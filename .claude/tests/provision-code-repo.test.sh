#!/bin/bash
# Tests for .claude/provision-code-repo.sh ([10.10] — the per-repo guv core for a
# split-topology code repo). A foreign code repo gets the deploy-once manifest
# (ceremony=task) a control plane assumes it has, so /task and worktree-isolated
# QA agents route there. Idempotent / no-clobber against an already-provisioned
# repo (the guv self-hosting case — roots.code IS guv — is the already-done
# degenerate, not a skipped exception). The .gitignore half retired with the lane
# cluster at [32.3]: provision writes the manifest and nothing else. Pure bash.
# Run: bash .claude/tests/provision-code-repo.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROV="$ROOT/.claude/provision-code-repo.sh"
ROUTE="$ROOT/.claude/route.sh"
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

# T2 — provision a fresh foreign repo: manifest only, stderr-clean
R1="$WORK/r1"; mkrepo "$R1"
bash "$PROV" "$R1" --test "bash src/app.sh" >/dev/null 2>"$WORK/e1"
[ -s "$WORK/e1" ] && no "provision emitted stderr: $(cat "$WORK/e1")" || ok "provision runs stderr-clean"
[ -f "$R1/.claude/project.json" ] && ok "manifest written" || no "no manifest written"
jq -e '.ceremony=="task"' "$R1/.claude/project.json" >/dev/null 2>&1 \
  && ok "manifest ceremony=task" || no "manifest ceremony not task"
jq -e '.commands.test=="bash src/app.sh"' "$R1/.claude/project.json" >/dev/null 2>&1 \
  && ok "commands.test set from --test" || no "commands.test not set from --test"
# [32.3]: the lane-era gitignore block retired — provision must write NO .gitignore.
[ ! -f "$R1/.gitignore" ] \
  && ok "provision writes no .gitignore (the lane block retired at [32.3])" \
  || no "provision wrote a .gitignore — the [32.3] retirement regressed: $(cat "$R1/.gitignore")"

# T3 — /task routes in the provisioned repo (G2 closed)
( cd "$R1" && bash "$ROUTE" --for task >"$WORK/route.out" 2>&1 )
grep -q '^door=task' "$WORK/route.out" \
  && ok "route.sh --for task -> door=task in the provisioned repo" \
  || no "route did not yield door=task: $(tr '\n' ' ' <"$WORK/route.out")"

# T4 — idempotent / no-clobber (the guv self-hosting invariant): re-run preserves an
# existing manifest.
jq '.commands.test="SENTINEL"' "$R1/.claude/project.json" >"$WORK/m.tmp" 2>/dev/null && mv "$WORK/m.tmp" "$R1/.claude/project.json"
bash "$PROV" "$R1" --test "bash src/app.sh" >/dev/null 2>&1
jq -e '.commands.test=="SENTINEL"' "$R1/.claude/project.json" >/dev/null 2>&1 \
  && ok "re-run did NOT clobber the existing manifest (deploy-once)" \
  || no "re-run overwrote the manifest"

# T5 — a foreign .gitignore already present: provision leaves it byte-identical
# (the append path retired with the gitignore half at [32.3]).
R2="$WORK/r2"; mkrepo "$R2"; printf 'node_modules/\n' > "$R2/.gitignore"
before=$(cksum < "$R2/.gitignore")
bash "$PROV" "$R2" --test "bash src/app.sh" >/dev/null 2>&1
after=$(cksum < "$R2/.gitignore")
[ "$before" = "$after" ] \
  && ok "an existing .gitignore is left byte-identical (no append at [32.3])" \
  || no "provision touched a consumer's .gitignore — the [32.3] retirement regressed"

# (T6, the canonical-block drift guard, retired with the gitignore half at [32.3].)

# T7 — the provisioned core is COMMITTED, so a worktree (a checkout of HEAD)
# inherits it. An untracked manifest passes a working-tree check but is ABSENT from
# every new worktree — a worktree-isolated agent then can't route work there (the
# [10.10] e2e bug).
git -C "$R2" ls-files --error-unmatch .claude/project.json >/dev/null 2>&1 \
  && ok "provisioned manifest is committed (tracked)" \
  || no "manifest must be committed so worktrees inherit it"
git -C "$R2" worktree add -q "$WORK/wt" HEAD 2>/dev/null
[ -f "$WORK/wt/.claude/project.json" ] \
  && ok "a worktree of the provisioned repo carries the manifest (agents can route)" \
  || no "worktree must inherit the provisioned manifest"
# acceptance: `guv-cmd test` runs the provisioned repo's OWN test command in the worktree
( cd "$WORK/wt" && bash "$ROOT/.claude/guv-cmd.sh" test >/dev/null 2>&1 ); GC=$?
[ "$GC" -eq 0 ] \
  && ok "guv-cmd test in the worktree runs the provisioned repo's own test command" \
  || no "guv-cmd test must run the repo's test in the worktree (acceptance; rc=$GC)"
git -C "$R2" worktree remove --force "$WORK/wt" 2>/dev/null

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
