#!/bin/bash
# Tests for the empty-frontier framing invariant ([23.3], v0.8.1): the
# session-start router's empty-frontier explanation must acknowledge that a
# deliverable can be TERMINAL by descope (a `❌` from /replan), not only by
# completion (`✅`). The canonical phrasing lives in route.sh's EMITTED reason;
# the /next door's doc bullet and archive-initiative.sh's --check Exit-0 contract
# comment are DOC MIRRORS of that same framing.
#
# Why this suite exists (guv-verification Rule 8): the route.sh emit is unit-pinned
# by route.test.sh's descoped-complete case, but its doc mirrors were NOT — so when
# the emit was corrected (v0.8.1), the byte-identical false claim "every deliverable
# is ✅" survived in those mirrors and took two fix passes to find. This guard pins
# the doc mirrors to the canonical stem, so a future fourth surface (or a regression
# in these two) fails LOUD instead of drifting silently. The qualified comment forms
# that legitimately keep "✅ (or ❌)" / "✅-or-descoped-❌" (route.sh:231, archive:42)
# and the route.test.sh assertions that police the lie's ABSENCE are out of scope —
# this suite guards only the three surfaces a person reads the empty-frontier
# explanation from.
# Pure bash + grep. Run: bash .claude/tests/empty-frontier-framing.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUTE="$ROOT/route.sh"
NEXT="$ROOT/skills/next/SKILL.md"
ARCHIVE="$ROOT/archive-initiative.sh"

PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# The canonical framing stem the three surfaces must share. A revert to the old
# bare claim ("every deliverable is ✅") loses this stem, so a positive match is a
# sufficient drift guard.
STEM="every deliverable is terminal"

# Precondition: the three surfaces exist (a missing file is a loud failure, not a
# silent skip — Rule 15).
for f in "$ROUTE" "$NEXT" "$ARCHIVE"; do
  [ -f "$f" ] || { no "expected surface missing: $f"; }
done

# ── 1. route.sh's EMITTED empty-frontier reason is the canonical, terminal-aware
# framing (the source the doc mirrors echo). Anchored to the emit line, which pairs
# the stem with "empty frontier" — distinct from the route.sh:231 comment.
if grep -q "empty frontier — $STEM" "$ROUTE"; then
  ok "route.sh empty-frontier emit names the terminal/descoped state (canonical framing)"
else
  no "route.sh empty-frontier emit is not terminal-aware — expected 'empty frontier — $STEM'"
fi

# ── 2. The /next door's empty-frontier bullet (USER-FACING — the door a person
# meets mid-phase) mirrors the canonical stem.
if grep -q "$STEM" "$NEXT"; then
  ok "/next door's empty-frontier bullet mirrors the canonical terminal framing"
else
  no "/next door's empty-frontier bullet drifted from the canonical '$STEM' framing"
fi

# ── 3. ...and carries NO standalone bare claim. next/SKILL.md has no legitimate
# "every deliverable is ✅" occurrence (no qualified parenthetical lives here), so a
# bare match is unambiguously the regression this suite guards against.
if grep -q "every deliverable is ✅" "$NEXT"; then
  no "/next door reverted to the bare 'every deliverable is ✅' claim (false on a descoped plane)"
else
  ok "/next door carries no standalone 'every deliverable is ✅' claim"
fi

# ── 4. archive-initiative.sh's --check Exit-0 COMPLETE contract comment mirrors the
# canonical stem (anchored to the Exit-0 usage line, not the :42 body prose).
if grep -E "Exit 0[[:space:]]+status=COMPLETE" "$ARCHIVE" | grep -q "$STEM"; then
  ok "archive --check Exit-0 COMPLETE comment names the terminal/descoped state"
else
  no "archive --check Exit-0 COMPLETE comment drifted from the canonical '$STEM' framing"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
