#!/bin/bash
# Tests for .claude/guv-cmd.sh — manifest command read + null-skip, once ([7.1]).
# Pure bash + jq, no test runner required.
# Run: bash .claude/tests/guv-cmd.test.sh
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$CLAUDE_DIR/guv-cmd.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

make_project() {  # $1 = commands object as JSON
  local p="$WORK/proj"
  rm -rf "$p"
  mkdir -p "$p/.claude"
  jq -n --argjson cmds "$1" \
    '{roots:{control:".",code:"."},name:"t",language:"node",commands:$cmds,scaffoldCheck:"true",ceremony:"task"}' \
    > "$p/.claude/project.json"
  echo "$p"
}

# T1 — defined command runs, stdout reaches the caller, exit 0.
P=$(make_project '{"test":"echo ran-the-tests"}')
OUT=$( (cd "$P" && bash "$SCRIPT" test) 2>&1 ); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q "ran-the-tests" \
  && ok "defined command runs and exits 0" \
  || no "commands.test should run (rc=$RC, out: $OUT)"

# T2 — null command: loud skip on stdout, exit 0 (null-means-skip).
P=$(make_project '{"test":null}')
OUT=$( (cd "$P" && bash "$SCRIPT" test) 2>&1 ); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qi "skip" \
  && ok "null command: loud skip, exit 0" \
  || no "null command must skip loudly with exit 0 (rc=$RC, out: $OUT)"

# T3 — absent key behaves like null.
P=$(make_project '{}')
OUT=$( (cd "$P" && bash "$SCRIPT" lint) 2>&1 ); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qi "skip" \
  && ok "absent key: loud skip, exit 0" \
  || no "absent command must skip loudly with exit 0 (rc=$RC, out: $OUT)"

# T4 — a failing command's exit code propagates.
P=$(make_project '{"test":"exit 7"}')
( cd "$P" && bash "$SCRIPT" test ) >/dev/null 2>&1
[ $? -eq 7 ] \
  && ok "failing command's exit code propagates" \
  || no "exit code must propagate from the command"

# T5 — usage: no argument is a loud usage error.
P=$(make_project '{}')
( cd "$P" && bash "$SCRIPT" ) >/dev/null 2>&1
[ $? -eq 2 ] \
  && ok "missing argument -> usage error (exit 2)" \
  || no "missing argument must exit 2"

# T6 — no manifest is a loud error, not a silent skip (a project without a
# manifest has no commands to read — that is a caller bug, not a null).
rm -rf "$WORK/proj"; mkdir -p "$WORK/proj"
( cd "$WORK/proj" && bash "$SCRIPT" test ) >/dev/null 2>&1
[ $? -eq 4 ] \
  && ok "no manifest -> loud error (exit 4)" \
  || no "missing manifest must exit 4"

# T6b — a manifest that exists but cannot be parsed is a LOUD error, never a
# null-skip ("skipping" would misreport corruption as designed absence).
P=$(make_project '{}')
echo '{not json' > "$P/.claude/project.json"
OUT=$( (cd "$P" && bash "$SCRIPT" test) 2>&1 ); RC=$?
[ $RC -eq 4 ] && echo "$OUT" | grep -q "not valid JSON" && ! echo "$OUT" | grep -qi "skip" \
  && ok "corrupt manifest -> loud error (exit 4), never a skip" \
  || no "corrupt manifest must fail loud, not skip (rc=$RC: $OUT)"

# T7 — the teaching surfaces route through the helper: no inline
# jq -r '.commands.…' read survives in executable command/skill markdown
# (prose naming commands.test as a manifest field is legitimate; the retired
# pattern is the inline jq read).
ROOT="$(cd "$CLAUDE_DIR/.." && pwd)"
INLINE=$(grep -r "jq -r '\.commands\." \
  "$ROOT/.claude/commands" "$ROOT/.claude/skills" "$ROOT/.claude/agents" 2>/dev/null | wc -l | tr -d ' ')
[ "$INLINE" -eq 0 ] \
  && ok "no inline commands.* jq read on the teaching surfaces" \
  || no "$INLINE inline commands.* read(s) remain on teaching surfaces (route through guv-cmd.sh)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
