#!/bin/bash
# Tests for the fan-out offer PROSE invariants ([17.2], Phase 17) — the surfacing
# half of the deliverable, which lives in the `next` and `phase` door SKILL.md.
#
# The fanout-offer.sh script is the MECHANICAL half (pinned by fanout-offer.test.sh);
# this suite pins the JUDGMENT contract the prose must carry, on BOTH doors, so the
# two surfaces cannot drift apart silently (guv-verification Rule 8 — the doc-drift
# guard, modeled on empty-frontier-framing.test.sh / grammar-surface.test.sh):
#   1. each door INVOKES the scaffold;
#   2. each surfaces surface-disjointness AS a judgment (marked agent-judgment,
#      explicitly NOT a resolver fact) — the Rule-12 seam stated where a person reads it;
#   3. each presents the explicit three-way call: fan out / serial / size first;
#   4. a chosen fan-out routes to /build-fanout (surface-and-decide, never execute here);
#   5. size-first routes to /replan (size or split before fan-out);
#   6. the offer NEVER blocks — the "fan-out not assessed" degrade phrasing is present;
#   7. the designed default is SERIAL (Rule 15) — declined-by-absence, never spawns
#      worktrees unattended.
#
# This suite asserts SOURCE SKILL.md prose, so it is MAINTAINER-ONLY by build-plugin.sh's
# partition (it references skills/<door>/SKILL.md) — it runs in the core battery and
# never ships, exactly like empty-frontier-framing.test.sh. ship-suite.test.sh asserts
# that classification.
# Pure bash + grep. Run: bash .claude/tests/fanout-offer-prose.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NEXT="$ROOT/skills/next/SKILL.md"
PHASE="$ROOT/skills/phase/SKILL.md"

PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# Precondition: both door surfaces exist (a missing file is a loud failure, not a
# silent skip — Rule 15).
for f in "$NEXT" "$PHASE"; do
  [ -f "$f" ] || no "expected door surface missing: $f"
done

# The shared invariants both doors must carry — a grep pattern + a human label.
# Looping over both surfaces is what guarantees parity: a contract added to one door
# but not the other reddens here.
check_both() { # $1=pattern  $2=label
  local pat="$1" label="$2" door name flat
  for door in "$NEXT" "$PHASE"; do
    name=$(basename "$(dirname "$door")")
    # Flatten the door to a single whitespace-normalized line before matching, so a
    # multi-word contract phrase matches regardless of where markdown soft-wraps it
    # (a per-line grep would falsely redden on a phrase split across a wrap — a
    # brittleness, not a drift). Prose is free to reflow; the contract is the words.
    flat=$(tr '\n' ' ' < "$door" | tr -s ' ')
    if printf '%s' "$flat" | grep -qE "$pat"; then
      ok "[$name] $label"
    else
      no "[$name] MISSING: $label (pattern: $pat)"
    fi
  done
}

# 1 — each door invokes the scaffold script.
check_both 'fanout-offer\.sh' "invokes the fan-out scaffold (fanout-offer.sh)"

# 2 — surface-disjointness is surfaced AS a judgment, not a resolver fact. Both the
# machine marker and the human framing must be present (the seam is stated, not just
# echoed): the literal disjointness=agent-judgment marker, AND an explicit denial that
# it is a resolver fact.
check_both 'disjointness=agent-judgment' "surfaces the disjointness judgment marker (agent-judgment)"
check_both '[Nn]ot a resolver fact|never a resolver fact|not.*resolver fact' \
  "states disjointness is NOT a resolver fact (the Rule-12 judgment seam)"

# 2b — the disjointness judgment is GROUNDED: the prose tells the agent to judge it
# from the candidates' wording/acceptance, not their IDs (the spike located it there;
# a hurried agent could otherwise judge disjointness from the IDs alone).
check_both 'wording and acceptance' "grounds the disjointness judgment in the candidates' wording/acceptance (not IDs)"

# 2c — sizing is surfaced as a TWO-SIDED guardrail: besides the balloon ceiling, the
# sizes also weigh whether the lanes are WORTH the orchestration (the spike's soft
# lower bound — don't fan out an all-trivial frontier just because it is parallel).
check_both 'worth.*orchestration' "surfaces the worth-it lens (sizing also weighs orchestration cost)"

# 3 — the explicit three-way call: fan out / serial / size first.
check_both '\*\*fan out\*\*' "presents the **fan out** call"
check_both '\*\*serial\*\*' "presents the **serial** call"
check_both '\*\*size first\*\*|size or split|offer=size-first' "presents the **size first** call"

# 4 — a chosen fan-out routes to the existing build-fanout flow (it does NOT execute here).
check_both '/build-fanout' "routes a chosen fan-out to /build-fanout (surface-and-decide, not execute)"

# 5 — size-first routing is SPLIT correctly between the two remediations the script
# itself distinguishes (needs_sizing= vs balloons=): SIZING an unsized candidate is a
# bare estimate.sh set-sized (the authoritative replan/SKILL.md: an estimate revision
# needs NO /replan), and SPLITTING a balloon is a /replan. Both routes must be named —
# collapsing sizing into /replan (the v1 error a reviewer caught) reddens here.
check_both 'estimate\.sh set-sized' "routes the SIZE remediation to a bare estimate.sh set-sized (no /replan for an estimate revision)"
check_both '/replan' "routes the SPLIT remediation (balloon) to /replan"

# 6 — the offer NEVER blocks: the degrade phrasing the deliverable names is present.
check_both 'fan-out not assessed' "carries the non-blocking degrade phrasing (fan-out not assessed)"

# 7 — the designed default is SERIAL (Rule 15): declined-by-absence, no unattended spawn.
check_both 'designed default is SERIAL|default is \*\*SERIAL\*\*|\*\*designed default is SERIAL\*\*|default.*SERIAL.*Rule 15|SERIAL.*\(Rule 15\)' \
  "states the designed default is SERIAL (Rule 15)"
check_both 'declined-by-absence|declined by absence' "records the offer as declined-by-absence on a headless run"
# 7b — the record's HOME is named, not just the fact of the record. The spike punted
# the declined-offer record to a prose responsibility (the session handoff is guv's
# existing home for narrative session decisions); that home is prose-trust, so it is
# the one place the contract must be test-anchored or it could silently drift to a
# different/no home. Pin the home phrase on both doors.
check_both 'declined-by-absence in the session handoff|declined by absence in the session handoff' \
  "names the declined-offer record home (the session handoff)"
check_both 'never spawns? worktrees unattended|never spawn worktrees unattended' \
  "guarantees it never spawns worktrees unattended"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
