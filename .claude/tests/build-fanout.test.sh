#!/bin/bash
# Tests for .claude/workflows/build-fanout.js ([10.9]) — the saved build-fanout GATE
# workflow (the build-half analog of eval-parallel.js). Guards the invariants the
# driver promises:
#   - the script exists with a literal meta block whose name matches the filename
#     (that name IS the /build-fanout command) and meta.phases is declared
#   - the GATE stage spawns BOTH calibrated reviewers BY NAME via agentType, and no
#     other agentType appears (Rule 14: ad-hoc reviewers prohibited)
#   - the gate tells both reviewers the lane↔join responsibility split (plugin/ regen +
#     the drift battery are the JOIN's, source is the lane's) so neither flags a
#     join-responsibility as a lane defect (the calibration bug [10.9] closes)
#   - structured per-lane verdicts are produced (not a single blob)
#   - the fix loop is excluded and the exclusion stated (conversational, main session)
#   - it drives BOTH a single-lane and a multi-lane shape (operates over a lane LIST)
#   - the script parses as JavaScript (node --check; skipped cleanly when node absent)
# Maintainer-only (not shipped): a workflow smoke test is a source concern — the
# plugin-layout reconstruction (run-plugin-tests.sh) rebuilds .claude/ from
# scripts/hooks/tests, NOT workflows/, so there is nothing to run it against there. It
# guards what maintainers/build-plugin.sh ships + namespaces. (Same reason
# eval-parallel.test.sh is maintainer-only.)
# Pure bash. Run: bash .claude/tests/build-fanout.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$ROOT/.claude/workflows/build-fanout.js"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# T1 — exists. Everything else reads it.
if [ -f "$WF" ]; then ok "build-fanout.js exists in .claude/workflows/"; else
  no "workflow script missing: $WF"; echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1; fi

# T2 — meta block: literal export, name matches the filename, phases declared.
grep -q "^export const meta" "$WF" \
  && ok "meta block exported at top level" || no "must open with: export const meta = { ... }"
grep -q "name: 'build-fanout'" "$WF" \
  && ok "meta.name matches the filename (registers /build-fanout)" || no "meta.name must be 'build-fanout'"
grep -q "phases:" "$WF" \
  && ok "meta declares phases" || no "meta must declare phases"

# T3 — both calibrated reviewers invoked BY NAME via agentType (Rule 14).
grep -q "agentType: 'evaluator'" "$WF" \
  && ok "gate stage spawns the evaluator by name (agentType)" || no "must spawn agentType: 'evaluator'"
grep -q "agentType: 'reviewer'" "$WF" \
  && ok "gate stage spawns the reviewer by name (agentType)" || no "must spawn agentType: 'reviewer'"

# T4 — no ad-hoc reviewer: every agentType is one of the two calibrated agents
# (the gather stage uses the default worker, no agentType).
ROGUE=$(grep -oE "agentType: ['\"][^'\"]*['\"]" "$WF" | grep -vE "['\"](evaluator|reviewer)['\"]" || true)
[ -z "$ROGUE" ] && ok "no ad-hoc reviewer agentType (Rule 14)" || no "unexpected agentType: $ROGUE"

# T5 — the gate carries the lane↔join responsibility split to BOTH reviewers, so a
# join-owned responsibility is not graded as a lane defect.
grep -qiE 'join.?(owned|responsib)|responsibilit' "$WF" && grep -qiE 'plugin/|drift|rebuild' "$WF" \
  && ok "gate states the lane↔join responsibility split (plugin/ regen + drift = the join's)" \
  || no "gate must tell both reviewers the lane↔join responsibility split"

# T6 — structured PER-LANE verdicts (a list/array keyed by lane), not one blob.
grep -qiE 'perLane|per-lane|laneId|lane:' "$WF" \
  && ok "produces structured per-lane verdicts" || no "must return structured per-lane verdicts"

# T7 — fix loop excluded + the exclusion stated (conversational, main session).
grep -qi "fix" "$WF" && grep -qi "conversational" "$WF" \
  && ok "fix-loop exclusion stated (stays conversational, main session)" \
  || no "must state the fix loop stays conversational, outside the workflow"

# T8 — drives BOTH single- and multi-lane shapes: it maps over a LANE LIST (pipeline or
# parallel over the parsed ids), not a single hardcoded lane.
grep -qE 'pipeline\(|parallel\(' "$WF" && grep -qiE 'lanes|ids|\.map\(|\.split\(' "$WF" \
  && ok "operates over a lane list (single- and multi-lane both drive)" \
  || no "must drive a list of lanes (single + multi shapes)"

# T10 — the SPLIT carries the IN-PLACE protected-prose clause ([15.5]): an in-place edit
# to protected prose (README/CHANGELOG/*.template — e.g. a "recommended"→"default" flip
# or a topology rewrite) is orchestrator JOIN work, NOT a lane edit and NOT an
# append-only docFragment. Extract the SPLIT constant and assert against it (not the
# whole file) so a stray mention elsewhere can't satisfy the check. Reviewers read the
# SPLIT, so the clause must live THERE. The pre-existing SPLIT already names README/
# docFragment/JOIN in its docFragment-ASSEMBLY sentence, so the new clause is anchored on
# "in-place" and the surrounding tokens are required to co-occur with it on the same
# logical clause (single line) — a separate pre-existing sentence cannot satisfy these.
SPLIT=$(awk '/^const SPLIT = `/{f=1} f{print} f&&/`$/{exit}' "$WF")
if [ -n "$SPLIT" ]; then
  # the in-place clause names the protected-prose surface (README/CHANGELOG/.template)
  printf '%s' "$SPLIT" | grep -qiE 'in.?place.*(README|CHANGELOG|\.template)|(README|CHANGELOG|\.template).*in.?place' \
    && ok "SPLIT ties an IN-PLACE edit to the protected-prose surface (README/CHANGELOG/.template)" \
    || no "SPLIT must address an IN-PLACE edit to protected prose (README/CHANGELOG/.template)"
  # the in-place clause assigns the edit to the orchestrator/JOIN
  printf '%s' "$SPLIT" | grep -qiE 'in.?place.*(orchestrator|JOIN)|(orchestrator|JOIN).*in.?place' \
    && ok "SPLIT assigns the in-place edit to the orchestrator/JOIN" \
    || no "SPLIT must assign the in-place protected-prose edit to the orchestrator JOIN"
  # the in-place clause states it is NOT a docFragment (docFragments are append-only) —
  # this is the three-way distinction that stops the Rule-10 false-positive.
  printf '%s' "$SPLIT" | grep -qiE 'in.?place.*docFragment|docFragment.*in.?place' \
    && ok "SPLIT distinguishes the in-place edit from an append-only docFragment" \
    || no "SPLIT must state an in-place edit is NOT a docFragment (append-only)"
  # the 8d3edc5 precedent is cited so the clause is anchored to a real JOIN commit.
  printf '%s' "$SPLIT" | grep -qE '8d3edc5' \
    && ok "SPLIT cites the 8d3edc5 in-place-flip precedent" \
    || no "SPLIT must cite the 8d3edc5 precedent (the orchestrator JOIN in-place flip)"
else
  no "could not extract the SPLIT constant from $WF"
fi

# T9 — parses as JavaScript (runtime-wrapped, CommonJS; node not a guv runtime dep).
if command -v node >/dev/null 2>&1; then
  { printf 'async function __wf(){\n'; sed 's/^export //' "$WF"; printf '\n}\n'; } \
    | node --check >/dev/null 2>&1 \
    && ok "script parses as JavaScript (node --check, runtime-wrapped)" \
    || no "node --check failed — syntax error in $WF"
else
  echo "  - node not installed — skipping syntax check"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
