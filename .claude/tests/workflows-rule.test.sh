#!/bin/bash
# Tests for .claude/rules/guv-workflows.md — the workflow-verification rule
# (Phase 4: workflows are a dispatch target the process layer controls).
# Guards the invariants the rule promises:
#   - the rule file exists in the natively-loaded rules dir with the guv- prefix
#     (the acceptance criterion: "rule file loads")
#   - both calibrated reviewers are named verbatim (evaluator, product-reviewer)
#     and ad-hoc reviewer agents are prohibited
#   - the plan-of-record boundary is stated (workflows execute; phase docs plan)
#   - the ultracode posture is stated (wide mechanical fan-out, dropped back after)
#   - rule numbering stays unique across ALL rules files (drift guard: a new rule
#     file must continue the numbering, never collide with an existing rule)
# Tone ("judgment layer, not process restatement") is reviewed by a human/agent,
# not this suite. Pure bash, no test runner required.
# Run: bash .claude/tests/workflows-rule.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RULES_DIR="$ROOT/.claude/rules"
RULE="$RULES_DIR/guv-workflows.md"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# T1 — rule file exists in the rules dir with the guv- ownership prefix and a
# top-level heading. Everything else depends on this, so bail loudly if absent.
if [ -f "$RULE" ] && grep -q '^# ' "$RULE"; then
  ok "guv-workflows.md exists in .claude/rules/ with a top-level heading"
else
  no "rule file missing or headingless: $RULE"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# T2 — both calibrated reviewers are invoked BY NAME. The rule's whole point is
# routing workflow QA to these two agents, so the literal agent names must appear.
grep -q '`evaluator`' "$RULE" \
  && ok "names the evaluator agent verbatim" \
  || no "rule must name the \`evaluator\` agent verbatim"
grep -q '`product-reviewer`' "$RULE" \
  && ok "names the product-reviewer agent verbatim" \
  || no "rule must name the \`product-reviewer\` agent verbatim"

# T3 — ad-hoc reviewers are prohibited, stated as a prohibition (the anchor
# requires the prohibition verb in the same sentence, not just the term;
# newlines are flattened first since prose wraps mid-sentence).
tr '\n' ' ' < "$RULE" | grep -qiE 'ad-hoc [^.]*prohibit|prohibit[^.]* ad-hoc' \
  && ok "prohibits ad-hoc reviewer agents" \
  || no "rule must prohibit ad-hoc reviewer agents (as a prohibition)"

# T4 — the planning/execution boundary: workflows are an execution primitive;
# the plan of record stays in the phase docs.
grep -qi 'plan of record' "$RULE" \
  && ok "states the plan-of-record boundary" \
  || no "rule must state that the plan of record stays in the phase docs"
grep -qi 'execution primitive' "$RULE" \
  && ok "frames workflows as an execution primitive" \
  || no "rule must frame workflows as an execution primitive"

# T5 — ultracode posture: wide mechanical fan-out only, dropped back after.
grep -qi 'fan-out' "$RULE" \
  && ok "scopes ultracode to wide mechanical fan-out" \
  || no "rule must scope ultracode to wide mechanical fan-out"
grep -qi 'dropped back' "$RULE" \
  && ok "says ultracode is dropped back after" \
  || no "rule must say ultracode is dropped back after the fan-out"

# T6 — numbering drift guard: '## N —' rule numbers must be unique across every
# rules file (this file included), so a new rules file can never silently reuse
# an existing rule number.
NUMS=$(grep -h '^## [0-9]\+ —' "$RULES_DIR"/*.md | grep -o '^## [0-9]\+' | grep -o '[0-9]\+' | sort -n)
if [ -n "$NUMS" ] && [ "$(echo "$NUMS" | wc -l)" -eq "$(echo "$NUMS" | sort -nu | wc -l)" ]; then
  ok "rule numbering unique across all rules files (drift guard)"
else
  no "duplicate rule numbers across rules files: $(echo "$NUMS" | sort -n | uniq -d | tr '\n' ' ')"
fi

# T7 — this rule file participates in the numbering scheme: at least one
# '## N —' heading, and its numbers extend past the pre-existing 1–12 set.
SELF_NUMS=$(grep -o '^## [0-9]\+' "$RULE" | grep -o '[0-9]\+')
if [ -n "$SELF_NUMS" ] && [ "$(echo "$SELF_NUMS" | sort -n | head -1)" -gt 12 ]; then
  ok "rule numbers continue the scheme (all > 12)"
else
  no "guv-workflows.md must carry numbered rules continuing past 12"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
