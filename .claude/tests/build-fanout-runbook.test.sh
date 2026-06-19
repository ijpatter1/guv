#!/bin/bash
# Tests for .claude/skills/build-fanout/SKILL.md ([10.9]) — the fan-out RUNBOOK (the
# first-class door). Guards that the captured recipe documents what a fan-out is
# reconstructed-by-hand without: the three-stage seam, the by-name agents/scripts, the
# fix-and-re-review loop + convergence, the behavioral-core mechanism, and the
# single-writer JOIN ownership. Content checks, not tone (tone is reviewed by a human).
# Maintainer-only: it reads skills/build-fanout/SKILL.md, a source artifact. Pure bash.
# Run: bash .claude/tests/build-fanout-runbook.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/.claude/skills/build-fanout/SKILL.md"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
has() { grep -qiE "$1" "$S"; }

# T1 — exists with frontmatter (the user-invocable door).
if [ -f "$S" ] && grep -q '^name: build-fanout' "$S" && grep -q '^user-invocable: true' "$S"; then
  ok "build-fanout SKILL.md exists and is a user-invocable door"
else
  no "missing or non-invocable: $S"; echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# T2 — the three-stage seam, stated.
has 'the gate decides[,;]? *dispatch lands' \
  && ok "states the seam: the gate decides, dispatch lands" || no "must state the gate decides, dispatch lands"
{ has 'execut' && has 'gate' && has 'join'; } \
  && ok "names all three stages (execute / gate / join)" || no "must document execute → gate → join"

# T3 — the by-name agents + scripts the recipe composes (Rule 14 / the four scripts).
miss=0
for tok in 'lane-builder' 'build-fanout' 'lane-dispatch' 'gate-input' 'guv-lane' 'provision-code-repo'; do
  has "$tok" || { miss=1; echo "    (missing reference: $tok)"; }
done
[ "$miss" -eq 0 ] && ok "names the agents + scripts the recipe composes" || no "runbook must name lane-builder/build-fanout/lane-dispatch/gate-input/guv-lane/provision-code-repo"
{ has 'evaluator' && has 'reviewer'; } \
  && ok "names the calibrated reviewers (Rule 14, by name)" || no "must name the evaluator + reviewer"

# T4 — the fix-and-re-review loop with the convergence criterion + chosen model.
has 'critical and major|critical/major|all critical' \
  && ok "states the convergence criterion (all Critical/Major closed before land)" \
  || no "must state the convergence criterion"
has 'conversational' \
  && ok "documents the conversational fix model" || no "must document the fix model (conversational)"

# T5 — the behavioral-core mechanism (native inheritance + preloaded task), not injection.
{ has 'nativ' && has 'inherit' && has 'task'; } \
  && ok "documents native behavioral-core inheritance + the preloaded task skill" \
  || no "must document how a lane builder acquires the behavioral core (native + task)"

# T6 — single-writer JOIN ownership: trackers / docFragments / plugin rebuild.
{ has 'single.?writer' && has 'tracker' && has 'docfragment' && has 'plugin/'; } \
  && ok "documents single-writer JOIN ownership (trackers / docFragments / plugin/)" \
  || no "must document the single-writer JOIN ownership"

# T7 — the conservative posture (human-triggered, conversational build half).
{ has 'human.?triggered' && has 'conversational build half'; } \
  && ok "documents the conservative posture (human-triggered, conversational build half)" \
  || no "must document the conservative posture"

# T8 — [14.5] recovery rungs: a lane gets no SessionStart re-injection, so the runbook
# must teach the PRIMARY rung (size each lane under one window, [13.2]) and the FALLBACK
# (assess → re-spawn a fresh builder from the lane's checkpoint, not in-place continue).
{ has 're.?inject|SessionStart' && has 'lane-recovery' && has 're.?spawn'; } \
  && ok "documents the [14.5] recovery ladder (size-under-window primary; assess → re-spawn fallback)" \
  || no "must document [14.5] lane recovery (no re-injection → size-under-window / re-spawn via lane-recovery.sh)"

# T10 — the SKILL bullet mirrors the SPLIT's IN-PLACE protected-prose clause ([15.5]):
# an in-place edit to protected prose (README/CHANGELOG/*.template) is orchestrator JOIN
# work, distinct from an append-only docFragment. The runbook's single-writer JOIN
# section must say this so the SKILL and the workflow SPLIT do not contradict. Match on a
# SINGLE line that ties "in-place" to the protected-prose surface — so the unrelated
# "resumed in place" / "in-place continue" recovery wording can't satisfy the check.
grep -qiE 'in.?place.*(README|CHANGELOG|\.template)|(README|CHANGELOG|\.template).*in.?place' "$S" \
  && ok "runbook ties an IN-PLACE edit to the protected-prose surface (README/CHANGELOG/.template)" \
  || no "runbook must address an IN-PLACE edit to protected prose (README/CHANGELOG/.template)"
grep -qiE 'in.?place.*docfragment|docfragment.*in.?place' "$S" \
  && ok "runbook distinguishes the in-place edit from an append-only docFragment" \
  || no "runbook must distinguish the in-place edit from an append-only docFragment"
has '8d3edc5' \
  && ok "runbook cites the 8d3edc5 in-place-flip precedent" \
  || no "runbook must cite the 8d3edc5 precedent (the orchestrator JOIN in-place flip)"

# T9 — plugin namespacing (guards the agent-namespacing pass in
# maintainers/build-plugin.sh): the BUILT plugin runbook namespaces @lane-builder ->
# @guv:lane-builder (agents resolve only as guv:<name> under a plugin install). Source
# shape only; an absent plugin/ tree skips visibly ([7.7] convention).
PS="$ROOT/plugin/skills/build-fanout/SKILL.md"
if [ -f "$PS" ]; then
  { ! grep -qF '@lane-builder' "$PS" && grep -qF '@guv:lane-builder' "$PS"; } \
    && ok "built plugin runbook namespaces @lane-builder -> @guv:lane-builder" \
    || no "plugin runbook must namespace @lane-builder (bare @lane-builder would not resolve)"
else
  echo "  - no built plugin runbook ($PS) — namespacing check skips (plugin/fork shape)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
