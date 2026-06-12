#!/bin/bash
# Tests for .claude/guv-lane.sh — worktree lane lifecycle ([7.1]).
# Lanes are worktrees of the CODE repo at .worktrees/lane-<id>/ on branch
# lane/<id>-<slug>; destroy = worktree remove + branch delete + prune (the
# full spec lifecycle — a destroy that leaks lane/* branches is a failure).
# Pure bash + git + jq, no test runner required.
# Run: bash .claude/tests/guv-lane.test.sh
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$CLAUDE_DIR/guv-lane.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Split fixture: control plane + sibling code repo with one commit.
setup() {
  rm -rf "$WORK/code" "$WORK/proj"
  CODE="$WORK/code"
  mkdir -p "$CODE"
  git -C "$CODE" init -q
  git -C "$CODE" config user.email t@t
  git -C "$CODE" config user.name t
  echo x > "$CODE/f"
  git -C "$CODE" add f
  git -C "$CODE" commit -qm init
  P="$WORK/proj"
  mkdir -p "$P/.claude"
  jq -n '{roots:{control:".",code:"../code"},name:"t",language:"node",commands:{},scaffoldCheck:"true",ceremony:"phased"}' \
    > "$P/.claude/project.json"
}
run() { ( cd "$P" && bash "$SCRIPT" "$@" ) 2>&1; }

# T1 — create: worktree at .worktrees/lane-<id>/, branch lane/<id>-<slug>,
# worktree list grows to exactly two entries.
setup
OUT=$(run create 9.9 fix-thing); RC=$?
[ $RC -eq 0 ] || no "create failed (rc=$RC): $OUT"
[ -d "$CODE/.worktrees/lane-9.9" ] \
  && ok "create: worktree exists at .worktrees/lane-9.9/" \
  || no "create: worktree missing at .worktrees/lane-9.9/"
git -C "$CODE" show-ref --verify --quiet refs/heads/lane/9.9-fix-thing \
  && ok "create: branch lane/9.9-fix-thing exists" \
  || no "create: branch lane/9.9-fix-thing missing"
N=$(git -C "$CODE" worktree list | wc -l | tr -d ' ')
[ "$N" -eq 2 ] \
  && ok "create: git worktree list shows exactly two entries" \
  || no "create: expected 2 worktree entries, got $N"

# T2 — create with an existing lane id fails loud, mutating nothing.
OUT=$(run create 9.9 other-slug); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -qi "exist" \
  && ok "duplicate create refused loudly" \
  || no "duplicate create must fail naming the existing lane (rc=$RC: $OUT)"
git -C "$CODE" show-ref --verify --quiet refs/heads/lane/9.9-other-slug \
  && no "duplicate create must not leave a second branch" \
  || ok "duplicate create left no stray branch"

# T3 — harvest: structured state (lane=, branch=, head=, ahead=, dirty=).
( cd "$CODE/.worktrees/lane-9.9" \
  && echo y > g && git add g && git -c user.email=t@t -c user.name=t commit -qm lane-work )
OUT=$(run harvest 9.9); RC=$?
[ $RC -eq 0 ] || no "harvest failed (rc=$RC): $OUT"
echo "$OUT" | grep -q "branch=lane/9.9-fix-thing" \
  && ok "harvest: names the lane branch" \
  || no "harvest: must report branch=lane/9.9-fix-thing, got: $OUT"
echo "$OUT" | grep -q "ahead=1" \
  && ok "harvest: reports ahead=1 after one lane commit" \
  || no "harvest: must report ahead=1, got: $OUT"
echo "$OUT" | grep -q "dirty=0" \
  && ok "harvest: clean lane reports dirty=0" \
  || no "harvest: must report dirty=0, got: $OUT"
echo z > "$CODE/.worktrees/lane-9.9/h"
OUT=$(run harvest 9.9)
echo "$OUT" | grep -q "dirty=1" \
  && ok "harvest: uncommitted lane work reports dirty=1" \
  || no "harvest: must report dirty=1, got: $OUT"
rm "$CODE/.worktrees/lane-9.9/h"

# T4 — destroy refuses an unmerged lane without --force, state intact.
OUT=$(run destroy 9.9); RC=$?
[ $RC -ne 0 ] \
  && ok "destroy: unmerged lane refused without --force" \
  || no "destroy must refuse an unmerged lane (rc=$RC: $OUT)"
[ -d "$CODE/.worktrees/lane-9.9" ] && git -C "$CODE" show-ref --verify --quiet refs/heads/lane/9.9-fix-thing \
  && ok "destroy refusal mutated nothing" \
  || no "a refused destroy must leave worktree and branch intact"

# T5 — destroy --force: the full lifecycle invariant. Worktree gone, branch
# gone (no lane/* leak), metadata pruned, worktree list back to exactly one.
OUT=$(run destroy 9.9 --force); RC=$?
[ $RC -eq 0 ] || no "destroy --force failed (rc=$RC): $OUT"
N=$(git -C "$CODE" worktree list | wc -l | tr -d ' ')
[ "$N" -eq 1 ] \
  && ok "destroy: git worktree list shows exactly one entry (lifecycle invariant)" \
  || no "destroy: expected 1 worktree entry after create->destroy, got $N"
[ -z "$(git -C "$CODE" branch --list 'lane/*')" ] \
  && ok "destroy: no lane/* branch survives (no branch leak)" \
  || no "destroy: leaked branch(es): $(git -C "$CODE" branch --list 'lane/*' | tr '\n' ' ')"
git -C "$CODE" worktree list --porcelain | grep -q "lane-9.9" \
  && no "destroy: stale worktree metadata survives (prune missing)" \
  || ok "destroy: worktree metadata pruned"

# T6 — a clean, merged lane destroys WITHOUT --force (the landed-lane path).
setup
run create 4.2 merged-lane >/dev/null 2>&1
OUT=$(run destroy 4.2); RC=$?
[ $RC -eq 0 ] && [ -z "$(git -C "$CODE" branch --list 'lane/*')" ] \
  && ok "merged clean lane destroys without --force" \
  || no "a merged clean lane must destroy without --force (rc=$RC: $OUT)"

# T7 — unknown lane id: harvest and destroy fail loud, naming the id.
OUT=$(run harvest 8.8); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -q "8.8" \
  && ok "harvest of unknown lane fails naming the id" \
  || no "harvest of unknown lane must fail naming it (rc=$RC: $OUT)"
OUT=$(run destroy 8.8); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -q "8.8" \
  && ok "destroy of unknown lane fails naming the id" \
  || no "destroy of unknown lane must fail naming it (rc=$RC: $OUT)"

# T8 — single-repo: roots.code "." lanes work in cwd.
P="$WORK/single"
mkdir -p "$P/.claude"
jq -n '{roots:{control:".",code:"."},name:"t",language:"node",commands:{},scaffoldCheck:"true",ceremony:"phased"}' \
  > "$P/.claude/project.json"
git -C "$P" init -q
git -C "$P" config user.email t@t
git -C "$P" config user.name t
( cd "$P" && git add -A && git commit -qm init )
OUT=$(run create 1.1 single); RC=$?
[ $RC -eq 0 ] && [ -d "$P/.worktrees/lane-1.1" ] \
  && ok "single-repo: lane created in cwd" \
  || no "single-repo create failed (rc=$RC): $OUT"
run destroy 1.1 >/dev/null 2>&1
[ "$(git -C "$P" worktree list | wc -l | tr -d ' ')" -eq 1 ] \
  && ok "single-repo: lifecycle invariant holds" \
  || no "single-repo: worktree count != 1 after destroy"

# T9 — .worktrees/ is gitignored via the guv-core block (single source: the
# repo-root .gitignore between the guv-core-start/end markers, which the build
# extracts for the scaffold shell). Only the harness repo carries the block —
# a control plane's generated .gitignore has no markers, so the plane shape
# skips visibly ([7.7] convention), never as a failure.
ROOT="$(cd "$CLAUDE_DIR/.." && pwd)"
if grep -q '^# guv-core-start' "$ROOT/.gitignore" 2>/dev/null; then
  awk '/^# guv-core-start/,/^# guv-core-end/' "$ROOT/.gitignore" | grep -q '^\.worktrees/$' \
    && ok ".worktrees/ line present in the guv-core gitignore block" \
    || no ".worktrees/ must be in the guv-core gitignore block"
else
  echo "  - no guv-core gitignore block at repo root (plane/consumer shape) — gitignore check skips"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
