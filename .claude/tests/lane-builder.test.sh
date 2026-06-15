#!/bin/bash
# Tests for .claude/agents/lane-builder.md ([10.9]) — the calibrated build-fanout lane
# worker. Unlike the read-only evaluator/reviewer it WRITES (red->green TDD) confined to
# its lane worktree, and acquires the harness behavioral core NATIVELY (an Agent-tool
# subagent inherits the control plane's CLAUDE.md + guv-* rules — verified) plus the
# preloaded task skill for red->green TDD. Guards the invariants the driver relies on so
# a future edit can't silently turn it into a read-only or skill-less agent. Pure bash.
# Run: bash .claude/tests/lane-builder.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
A="$ROOT/.claude/agents/lane-builder.md"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# T1 — exists. Everything else reads it.
if [ -f "$A" ]; then ok "lane-builder.md exists in .claude/agents/"; else
  no "missing: $A"; echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1; fi

FM=$(awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$A")
BODY=$(awk 'n>=2{print} /^---$/{n++}' "$A")

# T2 — name matches the file (the agentType the driver spawns by name, Rule 14).
echo "$FM" | grep -q '^name: lane-builder' \
  && ok "frontmatter name is lane-builder (the by-name agentType)" \
  || no "frontmatter must declare name: lane-builder"

# T3 — preloads the task skill for red->green TDD (the resolved behavioral-core
# mechanism: native inheritance + per-lane /task, not prose-injection).
echo "$FM" | awk '/^skills:/{f=1} f' | grep -q 'task' \
  && ok "preloads the task skill (skills: frontmatter)" \
  || no "must preload skills: [task] for red->green TDD"

# T4 — it is a WRITER (not a read-only reviewer): tools include the build set + Skill.
miss=0; for t in Read Edit Write Bash Skill; do echo "$FM" | grep -qw "$t" || { miss=1; echo "    (missing tool: $t)"; }; done
[ "$miss" -eq 0 ] \
  && ok "tools grant a builder: Read/Edit/Write/Bash/Skill" \
  || no "lane-builder must have write + skill tools"

# T5 — NOT read-only: it must NOT carry a PreToolUse deny hook (that enforcement is for
# the reviewers; on a builder it would block the very edits/commits it exists to make).
echo "$FM" | grep -q 'permissionDecision.*deny' \
  && no "lane-builder must NOT carry a read-only deny hook (it writes)" \
  || ok "no read-only deny hook (a builder writes; confinement is gate-detected, [7.5])"

# T6 — body teaches red->green TDD and routes work through /task.
{ echo "$BODY" | grep -qiE 'red.?green' && echo "$BODY" | grep -q '/task'; } \
  && ok "body teaches red->green TDD via /task" \
  || no "body must teach red->green TDD via /task"

# T7 — body teaches confinement: the JOIN owns trackers / derived plugin / shared prose;
# the lane commits SOURCES only. (Confinement is detected at the gate, not prevented —
# so the agent must be TOLD, [7.5].)
{ echo "$BODY" | grep -qiE 'confin|sources only' && echo "$BODY" | grep -qiE 'tracker|JOIN|plugin/'; } \
  && ok "body teaches confinement (JOIN owns trackers/plugin/prose; commit sources only)" \
  || no "body must teach lane confinement"

# T8 — conventions: model inherit + project memory (mirrors evaluator/reviewer).
{ echo "$FM" | grep -q 'model: inherit' && echo "$FM" | grep -q 'memory: project'; } \
  && ok "model: inherit + memory: project (agent conventions)" \
  || no "must set model: inherit and memory: project"

# T9 — plugin namespacing (guards the skills-namespacing pass in
# maintainers/build-plugin.sh): the BUILT plugin agent preloads guv:task, not a bare
# 'task' (which wouldn't resolve under a plugin install, where skills register as
# guv:<name>). Source-shape only — a plugin/fork install has no plugin/ tree to check,
# so it skips visibly ([7.7] convention), never a failure. (This maintainers/ reference
# also classes the suite maintainer-only: agent-shape introspection is a source concern
# — plugin-layout reconstruction has no agents/ to run it against.)
PA="$ROOT/plugin/agents/lane-builder.md"
if [ -f "$PA" ]; then
  awk '/^skills:/{f=1;next} f&&/^[[:space:]]*-/{print} f&&/^[^[:space:]-]/{f=0}' "$PA" | grep -q 'guv:task' \
    && ok "built plugin agent preloads guv:task (skills: namespaced)" \
    || no "plugin agent skills: must be guv:-namespaced (bare 'task' would not resolve)"
else
  echo "  - no built plugin agent ($PA) — skills-namespacing check skips (plugin/fork shape)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
