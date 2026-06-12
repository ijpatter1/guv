#!/bin/bash
# Tests for .claude/guv-git.sh — the git -C incantation, once ([7.1]).
# Pure bash + git + jq, no test runner required.
# Run: bash .claude/tests/guv-git.test.sh
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$CLAUDE_DIR/guv-git.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A code repo with one commit, and a control plane pointing at it.
CODE="$WORK/code"
mkdir -p "$CODE"
git -C "$CODE" init -q
git -C "$CODE" config user.email t@t
git -C "$CODE" config user.name t
echo x > "$CODE/f"
git -C "$CODE" add f
git -C "$CODE" commit -qm "code-repo-commit"

make_project() {  # $1 = roots.code value
  local p="$WORK/proj"
  rm -rf "$p"
  mkdir -p "$p/.claude"
  jq -n --arg code "$1" \
    '{roots:{control:".",code:$code},name:"t",language:"node",commands:{},scaffoldCheck:"true",ceremony:"task"}' \
    > "$p/.claude/project.json"
  echo "$p"
}

# T1 — split: git runs against roots.code from the project cwd.
P=$(make_project "../code")
OUT=$( (cd "$P" && bash "$SCRIPT" log --oneline -1) 2>&1 )
echo "$OUT" | grep -q "code-repo-commit" \
  && ok "split: log targets the code repo via roots.code" \
  || no "split: expected the code repo's commit, got: $OUT"

# T2 — single-repo: roots.code "." runs git in cwd.
P=$(make_project ".")
git -C "$P" init -q
git -C "$P" config user.email t@t
git -C "$P" config user.name t
( cd "$P" && git add -A && git commit -qm "single-repo-commit" )
OUT=$( (cd "$P" && bash "$SCRIPT" log --oneline -1) 2>&1 )
echo "$OUT" | grep -q "single-repo-commit" \
  && ok "single-repo: roots.code '.' targets cwd" \
  || no "single-repo: expected cwd commit, got: $OUT"

# T3 — no manifest: defaults to "." (same as single-repo) rather than erroring.
OUT=$( (cd "$P" && rm .claude/project.json && bash "$SCRIPT" log --oneline -1) 2>&1 )
echo "$OUT" | grep -q "single-repo-commit" \
  && ok "no manifest: defaults to cwd" \
  || no "no manifest: should default to '.', got: $OUT"

# T4 — exit code propagates from git.
P=$(make_project "../code")
( cd "$P" && bash "$SCRIPT" rev-parse --verify not-a-ref ) >/dev/null 2>&1
[ $? -ne 0 ] \
  && ok "git failure exit code propagates" \
  || no "a failing git command must exit non-zero"

# T5 — the teaching surfaces route through the helper: no inline
# git -C "$(jq -r '.roots.code' …)" incantation survives in executable
# command/skill/agent markdown (prose explaining roots.code topology is
# legitimate; the retired pattern is the inline command substitution).
ROOT="$(cd "$CLAUDE_DIR/.." && pwd)"
INLINE=$(grep -r "git -C \"\$(jq -r '\.roots\.code'" \
  "$ROOT/.claude/commands" "$ROOT/.claude/skills" "$ROOT/.claude/agents" 2>/dev/null | wc -l | tr -d ' ')
[ "$INLINE" -eq 0 ] \
  && ok "no inline roots.code git incantation on the teaching surfaces" \
  || no "$INLINE inline git -C incantation(s) remain on teaching surfaces (route through guv-git.sh)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
