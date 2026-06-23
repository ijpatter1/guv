#!/bin/bash
# Tests for [19.2] — onboard's exit-4 (pre-scaffold) path routes to /scaffold
# first. The cold-path bug: /scaffold's own skill names /onboard as the door
# that follows it ("Use … before /guv:onboard"; its Step 3 hands off to
# onboard) — but the handoff was ONE-directional. onboard's Step 0 exit-4
# (pre-scaffold) branch said only "Proceed", so running /onboard DIRECTLY on a
# never-scaffolded repo dead-ends: onboard reads .claude/project.schema.json
# (Step 3, manifest validation) and CLAUDE.template.md (Step 4, render) — both
# of which only exist once the shell is deployed. A first-time user adopting a
# bare repo hits that wall. The fix makes the prerequisite bidirectional:
# onboard's exit-4 branch routes to /scaffold first when the shell is absent,
# and proceeds directly when it is already present (scaffold was run, or a
# dogfooding control plane synced the shell from source).
#
# What this suite pins (asserting the CORE skill's prose — the source of truth;
# the plugin mirror's byte-parity, where /scaffold renders as /guv:scaffold, is
# covered by plugin.test.sh's glob-derived drift guard, not restated here):
#   - the exit-4 (pre-scaffold) branch names /scaffold and orders it FIRST
#     (the actual fix — a routed prerequisite, not an unqualified "Proceed")
#   - it names WHY the shell is a prerequisite (the schema/template onboard
#     reads downstream) — intent, not a bare keyword (rule 8)
#   - it preserves the direct-proceed path for an already-deployed shell
#     (the nuanced fix, not a blanket redirect that breaks the happy path)
# Pure bash, no test runner. Run: bash .claude/tests/onboard-scaffold-prereq.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OB="$ROOT/.claude/skills/onboard/SKILL.md"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$OB" ]; then
  no "onboard skill missing — .claude/skills/onboard/SKILL.md must exist"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
ok "onboard skill exists (.claude/skills/onboard/SKILL.md)"

# Slice out the exit-4 (pre-scaffold) bullet from Step 0: from the "Exit 4"
# line up to the next blockquote/heading that closes the Routing Guard. The
# contract assertions read this branch in isolation so they pin the routing of
# the PRE-SCAFFOLD state specifically, not a /scaffold mention elsewhere.
EXIT4=$(awk '/^- \*\*Exit 4/{f=1} f&&/^(> |## )/{exit} f{print}' "$OB")

if [ -z "$EXIT4" ]; then
  no "could not locate the Exit 4 (pre-scaffold) branch in onboard Step 0"
else
  # The fix: route to /scaffold FIRST (scaffold + an ordering word on one line).
  echo "$EXIT4" | grep -qiE '/scaffold.*(first|before)|(first|before).*/scaffold' \
    && ok "exit-4 branch routes to /scaffold first (a prerequisite, not a bare Proceed)" \
    || no "exit-4 branch must route a never-scaffolded repo to /scaffold first"

  # The WHY, pinned to the CONCRETE downstream reason: the two shell files
  # onboard reads (Step 3 schema validation, Step 4 render). Naming them
  # specifically — not a soft "shell" keyword — keeps a future reword from
  # dropping the actual reason the prerequisite exists (eval finding: a softer
  # guard would survive a reword that lost the concrete files).
  echo "$EXIT4" | grep -qiE 'project\.schema\.json|CLAUDE\.template\.md' \
    && ok "exit-4 branch names the concrete shell files onboard reads downstream" \
    || no "exit-4 branch must name the concrete prerequisite (project.schema.json / CLAUDE.template.md)"

  # Deterministic detection: the branch must give the agent a way to TEST shell
  # absence (a file-existence probe), as every sibling Step-0 branch names a
  # concrete signal — not leave "is the shell absent?" to silent judgment. A
  # cold-path correctness fix must remove the judgment it set out to remove
  # (eval finding: the condition needs an actionable probe, not just a clause).
  echo "$EXIT4" | grep -qiE 'test -f|\[ +-f' \
    && ok "exit-4 branch gives a deterministic shell-absence probe (test -f)" \
    || no "exit-4 branch must name how to DETECT shell absence (a file-existence probe), not only condition on it"

  # The nuance: an already-deployed shell still proceeds directly — the fix is a
  # conditional prerequisite, not a blanket redirect that breaks the happy path.
  echo "$EXIT4" | grep -qi 'proceed' \
    && ok "exit-4 branch preserves the direct-proceed path (shell already present)" \
    || no "exit-4 branch must keep proceeding directly when the shell is already deployed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
