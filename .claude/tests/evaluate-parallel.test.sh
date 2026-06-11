#!/bin/bash
# Tests for .claude/workflows/evaluate-parallel.js — the saved dual-QA workflow
# (Phase 4 D2: both calibrated reviewers concurrently over a commit-range scope).
# Guards the invariants the workflow promises:
#   - the script exists in .claude/workflows/ with a literal meta block whose
#     name matches the filename (that name IS the /evaluate-parallel command)
#   - the review stage invokes BOTH calibrated reviewers by name via agentType,
#     and no other agentType appears (rule 14: ad-hoc reviewers prohibited)
#   - the combined summary (the /evaluate skill's Step 4 block) is produced
#   - the fix loop is explicitly excluded (Step 5 stays conversational —
#     workflow subagents run in acceptEdits mode, which conflicts with it)
#   - the script parses as JavaScript (node --check; skipped cleanly when node
#     is absent — the harness's own runtime deps stay bash + jq + git)
# Pure bash, no test runner required.
# Run: bash .claude/tests/evaluate-parallel.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$ROOT/.claude/workflows/evaluate-parallel.js"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# T1 — workflow script exists. Everything else reads it, so bail loudly if absent.
if [ -f "$WF" ]; then
  ok "evaluate-parallel.js exists in .claude/workflows/"
else
  no "workflow script missing: $WF"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# T2 — meta block: literal export with name matching the filename (the saved
# name is what registers the /evaluate-parallel command).
grep -q "^export const meta" "$WF" \
  && ok "meta block exported at top level" \
  || no "script must open with: export const meta = { ... }"
grep -q "name: 'evaluate-parallel'" "$WF" \
  && ok "meta.name matches the filename (registers /evaluate-parallel)" \
  || no "meta.name must be 'evaluate-parallel'"

# T3 — both calibrated reviewers invoked BY NAME via agentType (rule 14).
grep -q "agentType: 'evaluator'" "$WF" \
  && ok "review stage spawns the evaluator by name (agentType)" \
  || no "must spawn agentType: 'evaluator'"
grep -q "agentType: 'product-reviewer'" "$WF" \
  && ok "review stage spawns the product-reviewer by name (agentType)" \
  || no "must spawn agentType: 'product-reviewer'"

# T4 — no ad-hoc reviewer sneaks in: every agentType in the script is one of
# the two calibrated agents (the scope-gathering stage uses the default worker,
# which carries no agentType at all).
ROGUE=$(grep -o "agentType: '[^']*'" "$WF" | grep -v "'evaluator'\|'product-reviewer'" || true)
[ -z "$ROGUE" ] \
  && ok "no ad-hoc reviewer agentType present (rule 14)" \
  || no "unexpected agentType in workflow: $ROGUE"

# T5 — the combined summary block (skill Step 4) is produced by the script.
grep -q "Evaluation Summary" "$WF" \
  && ok "combined summary block present (mirrors /evaluate Step 4)" \
  || no "script must produce the combined Evaluation Summary"

# T6 — the fix loop is excluded and the exclusion is stated, not silent:
# Step 5 stays conversational, outside the workflow.
grep -qi "fix loop" "$WF" && grep -qi "conversational" "$WF" \
  && ok "fix-loop exclusion stated (Step 5 stays conversational)" \
  || no "script must state that the fix loop stays conversational, outside the workflow"

# T7 — the script parses as JavaScript. node is not a harness runtime dep, so
# skip cleanly (loudly) when absent rather than failing.
if command -v node >/dev/null 2>&1; then
  node --check "$WF" >/dev/null 2>&1 \
    && ok "script parses as JavaScript (node --check)" \
    || no "node --check failed — syntax error in $WF"
else
  echo "  - node not installed — skipping syntax check"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
