#!/bin/bash
# Tests for .claude/commands/handoff.md — command-composition hygiene ([10.4]).
# Guards the invariants the deliverable promises:
#   - /handoff REFERENCES /evaluate's procedure by pointer, not by inlining its
#     steps — killing the drift class where the restatement diverges from its
#     source. The canonical evaluator/product-reviewer invocation lives once, in
#     the /evaluate skill; /handoff points at it.
#   - /handoff carries no inlined copy of /evaluate's review steps (asserted: the
#     two prose passages that *were* the inline restatement are gone).
#   - the session-close review is SKIPPED when every commit in the session was
#     already dual-reviewed in-band via /task + /evaluate, and the skip is
#     DISCLOSED — review cost is paid once.
#   - a session with an un-reviewed commit still RUNS the review.
#   - no review is silently dropped (the skip is conditional and disclosed,
#     never an unconditional removal).
# The canonical procedure (the pointer target) must still exist in the /evaluate
# skill, so the pointer is not dangling.
# Tone and exact wording are a human/agent's call; this suite asserts the
# structural invariants only. Pure bash, no test runner required.
# Run: bash .claude/tests/handoff-composition.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HANDOFF="$ROOT/.claude/commands/handoff.md"
EVALUATE="$ROOT/.claude/skills/evaluate/SKILL.md"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# T0 — both files exist. Everything depends on this, so bail loudly if absent.
if [ -f "$HANDOFF" ] && [ -f "$EVALUATE" ]; then
  ok "handoff.md and the evaluate skill both exist"
else
  no "handoff.md or evaluate SKILL.md missing"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# Whitespace-flattened copy for multi-word phrase guards — an innocent reflow
# must not break a phrase grep (the class swept in Phase 5 D4).
HANDOFF_FLAT=$(tr '\n' ' ' < "$HANDOFF" 2>/dev/null | tr -s ' ')

# T1 — the pointer target is intact: /evaluate's skill still canonically defines
# the dual review by invoking BOTH subagents by name. If this regresses, the
# pointer /handoff now carries would be dangling.
grep -q '`evaluator`' "$EVALUATE" && grep -q '`product-reviewer`' "$EVALUATE" \
  && ok "the /evaluate skill still defines the dual-review procedure (pointer target intact)" \
  || no "the /evaluate skill must canonically invoke both reviewers by name"

# T2 — /handoff POINTS at /evaluate for the review procedure. The pointer is the
# whole deliverable: the review steps live once, in /evaluate, and /handoff
# references that one definition rather than restating it.
echo "$HANDOFF_FLAT" | grep -qE '/evaluate' \
  && ok "handoff references /evaluate (the one definition)" \
  || no "handoff must point at /evaluate's procedure instead of inlining it"

# T3 — no inlined copy of /evaluate's review steps. The drift surface was the
# two prose passages that restated, verbatim-ish, /evaluate's Step 2/3 invoke
# instructions ("invoke the `evaluator` subagent using the Agent tool" and
# "Invoke the `product-reviewer` subagent using the Agent tool"). The deliverable
# kills exactly that restatement, so neither inline invoke-instruction may remain
# in handoff.md — they belong to /evaluate now.
if echo "$HANDOFF_FLAT" | grep -qiE 'invoke the .?evaluator.? subagent using the Agent tool'; then
  no "handoff still inlines the 'invoke the evaluator subagent' step (drift surface)"
else
  ok "handoff no longer inlines the evaluator-invocation step"
fi
if echo "$HANDOFF_FLAT" | grep -qiE 'Invoke the .?product-reviewer.? subagent using the Agent tool'; then
  no "handoff still inlines the 'invoke the product-reviewer subagent' step (drift surface)"
else
  ok "handoff no longer inlines the product-reviewer-invocation step"
fi

# T4 — the skip condition is documented: the session-close review is SKIPPED when
# every session commit was already dual-reviewed in-band via /task + /evaluate.
# The condition must name the in-band path (/task) and the all-commits scope, so
# a reader knows precisely when the skip applies.
echo "$HANDOFF_FLAT" | grep -qiE 'skip[^.]*(in-band|already (dual-)?reviewed|/task)' \
  && ok "documents skipping the session-close review for in-band dual-reviewed commits" \
  || no "handoff must document skipping the review when commits were dual-reviewed in-band"
echo "$HANDOFF_FLAT" | grep -qiE 'in-band' \
  && ok "names the in-band review path as the skip precondition" \
  || no "the skip precondition must reference in-band review (via /task + /evaluate)"

# T5 — the skip is DISCLOSED, never silent. The deliverable is explicit: the skip
# is disclosed, and no review is silently dropped.
echo "$HANDOFF_FLAT" | grep -qiE 'disclos' \
  && ok "the skip is disclosed (not silent)" \
  || no "handoff must state the skip is disclosed in the handoff record"
echo "$HANDOFF_FLAT" | grep -qiE '(never|not|no) [^.]*silent|silent[^.]*(drop|skip)' \
  && ok "states no review is silently dropped" \
  || no "handoff must state no review is silently dropped"

# T6 — the skip is CONDITIONAL: a session with any un-reviewed commit still runs
# the review. The skip must not read as an unconditional removal of the review.
echo "$HANDOFF_FLAT" | grep -qiE '(un-?reviewed|not[^.]*reviewed|any[^.]*commit)[^.]*(still|run|review)' \
  && ok "an un-reviewed commit still runs the session-close review" \
  || no "handoff must require the review when any session commit was not reviewed in-band"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
