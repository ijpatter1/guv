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

# T4 — no ad-hoc reviewer sneaks in: every agentType in the script (either
# quote style) is one of the two calibrated agents (the scope-gathering stage
# uses the default worker, which carries no agentType at all).
ROGUE=$(grep -oE "agentType: ['\"][^'\"]*['\"]" "$WF" | grep -vE "['\"](evaluator|product-reviewer)['\"]" || true)
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

# T7 — the script parses as JavaScript. The workflow runtime strips the meta
# export and runs the body inside an async function (that's what legalizes
# top-level await/return), so the check emulates that wrapping — which also
# keeps it CommonJS-parsed and independent of node's ESM-detection version
# threshold. node is not a harness runtime dep: skip cleanly (loudly) if absent.
if command -v node >/dev/null 2>&1; then
  { printf 'async function __wf(){\n'; sed 's/^export //' "$WF"; printf '\n}\n'; } \
    | node --check >/dev/null 2>&1 \
    && ok "script parses as JavaScript (node --check, runtime-wrapped)" \
    || no "node --check failed — syntax error in $WF"
else
  echo "  - node not installed — skipping syntax check"
fi

# T8 — ultracode-guidance touchpoints (Phase 4 D3): the README and
# CLAUDE.template.md carry the planning-/execution-layer guidance, and the
# /evaluate skill + /handoff command cross-reference the workflow variant.
for doc in README.md CLAUDE.template.md \
           .claude/skills/evaluate/SKILL.md .claude/commands/handoff.md; do
  # /init-project replaces README.md with a rendered project README — a
  # post-init consumer shape skips that one guard rather than failing.
  if [ "$doc" = "README.md" ] && [ -f "$ROOT/$doc" ] \
    && ! grep -q '^# Governor (guv)' "$ROOT/$doc"; then
    echo "  - README.md is a rendered project README, not the template's — cross-reference guard skips"
    continue
  fi
  grep -q "evaluate-parallel" "$ROOT/$doc" 2>/dev/null \
    && ok "$doc cross-references /evaluate-parallel" \
    || no "$doc must cross-reference /evaluate-parallel"
done
grep -q "planning layer" "$ROOT/CLAUDE.template.md" \
  && ok "CLAUDE.template.md states the planning/execution layering" \
  || no "CLAUDE.template.md must state planning layer vs execution layer"

# T9 — the phase-label guard BEHAVES correctly (node-gated like T7): the
# extracted const lines are executed against the deviations the guard exists
# for — "Phase Phase" duplication, empty phase, and the non-phased sentinels.
# Two fix-pass behavior changes landed here untested; this closes that gap.
if command -v node >/dev/null 2>&1; then
  SNIPPET=$(grep -E '^const (phaseLabel|phased|fromPhase) ' "$WF")
  if [ "$(echo "$SNIPPET" | wc -l)" -eq 3 ]; then
    run_guard() {
      printf 'const scope={phase:process.argv[2] ?? ""};\n%s\nconsole.log(JSON.stringify([phaseLabel,phased,fromPhase]));\n' "$SNIPPET" \
        | node - "$1" 2>/dev/null
    }
    G_OK=1
    [ "$(run_guard '  Phase 4 — X')" = '["4 — X",true," from Phase 4 — X"]' ] || G_OK=0
    [ "$(run_guard '')" = '["",false,""]' ] || G_OK=0
    [ "$(run_guard 'unknown')" = '["unknown",false,""]' ] || G_OK=0
    [ "$(run_guard 'N/A')" = '["N/A",false,""]' ] || G_OK=0
    [ "$(run_guard '4')" = '["4",true," from Phase 4"]' ] || G_OK=0
    [ "$G_OK" -eq 1 ] \
      && ok "phase-label guard behaves: prefix-strip, empty, sentinels (executed)" \
      || no "phase-label guard misbehaves for a deviation case"
  else
    no "could not extract the three guard const lines from $WF (test setup)"
  fi
else
  echo "  - node not installed — skipping phase-label guard behavior check"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
