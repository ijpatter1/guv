#!/bin/bash
# spike-finding-convention-prose.test.sh — prose contract for the spike-finding
# convention doc ([21.6]).
#
# WHAT THIS PINS — a *prose* contract, not behavior. [21.6] ships the spike-finding
# convention (the shape every spike finding takes) as a core convention doc the
# `spike` skill points at, codifying the shape the S1→S3 road-test settled. The
# load-bearing property is the **ordered 7-part section shape** — a spike finding's
# value is its legibility, and the convention is *which sections, in what order*. A
# test that merely checked "the doc exists" would pass a doc with the parts shuffled
# or missing, which is exactly the failure the road-test existed to prevent (Rule 8 —
# pin the intent, the settled shape, not just presence). So the order assertion is the
# spine of this test.
#
# It also pins: the two refinements that emerged across S2+S3 (prose Decision for a
# composition/placement question vs an Options table for a fork; the up-front asymmetry
# lead), the DRAFTED→RATIFIED status convention, and the **integration contract** —
# the `spike` skill actually *points at* the doc ("in this skill's directory", the same
# sibling-doc pattern `/handoff` uses for handoff-artifact.md / uat-plan.md). Without
# the pointer the doc is an orphan; the convention is only real if the skill routes to it.
#
# PARTITION — references skills/spike/SKILL.md, so the harness auto-partitions this
# MAINTAINER-ONLY (pattern skills/[a-z][a-z-]*/SKILL\.md): it runs in the core battery
# and never ships, exactly like spike-close-prose / spike-doors-prose.
#
# BSD-grep-safe: fixed-string greps (grep -F) and header-anchored line-number lookups
# only — no chained [^.]{0,N} interval quantifiers (which backtrack catastrophically
# under BSD grep on a near-miss, turning a clean ✗ into a multi-minute hang).
#
# Run: bash .claude/tests/spike-finding-convention-prose.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONV="$ROOT/skills/spike/spike-finding-convention.md"
SKILL="$ROOT/skills/spike/SKILL.md"

PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# has() — flatten a file to a whitespace-normalized line, then fixed-string match.
hasF() { # $1=file  $2=literal  $3=label
  if [ ! -f "$1" ]; then no "MISSING FILE for: $3 ($1)"; return; fi
  if tr '\n' ' ' < "$1" | tr -s ' ' | grep -qF "$2"; then ok "$3"
  else no "MISSING in $(basename "$1"): $3 (literal: $2)"; fi
}

# Precondition (Rule 15 — loud, not a vacuous pass on a missing surface).
[ -f "$CONV" ] || no "expected convention doc missing: $CONV"
[ -f "$SKILL" ] || no "expected spike skill missing: $SKILL"

# ── A1 — the ordered 7-part section shape (the spine) ─────────────────────────
# Each part is anchored on a distinctive keyword that must appear in a HEADER line
# (^#…), so a prose mention elsewhere can't satisfy it. The seven first-header line
# numbers must be present and strictly increasing — that IS the settled order.
if [ -f "$CONV" ]; then
  order_ok=1; prev=0; missing=""
  for kw in 'Header' 'Why' 'asymmetry' 'Evidence' 'Designed default' 'gates' 'watch-item'; do
    ln=$(grep -nE "^#+ .*$kw" "$CONV" | head -1 | cut -d: -f1)
    if [ -z "$ln" ]; then missing="$missing $kw"; order_ok=0; continue; fi
    if [ "$ln" -le "$prev" ]; then order_ok=0; fi
    prev=$ln
  done
  if [ "$order_ok" -eq 1 ]; then
    ok "convention doc carries the 7-part shape as ordered section headers"
  else
    no "convention 7-part shape broken — missing/out-of-order:${missing:- (order)}"
  fi
fi

# ── A2 — refinement (a): prose Decision for composition/placement vs Options table for a fork
hasF "$CONV" "Options table" "refinement (a): names the Options-table-for-a-fork form"
if [ -f "$CONV" ] && tr '\n' ' ' < "$CONV" | tr -s ' ' | grep -qiE 'prose (decision|where)'; then
  ok "refinement (a): names the prose-Decision form for composition/placement questions"
else
  no "MISSING in convention doc: prose-Decision form for composition/placement"
fi

# ── A3 — refinement (b): the up-front asymmetry / two-layers lead
hasF "$CONV" "up front" "refinement (b): names the up-front asymmetry lead"

# ── A4 — the DRAFTED → RATIFIED status convention (design vs build gate)
if [ -f "$CONV" ] && grep -qF 'DRAFTED' "$CONV" && grep -qF 'RATIFIED' "$CONV"; then
  ok "status convention: names DRAFTED → RATIFIED (the design→build gate)"
else
  no "MISSING in convention doc: the DRAFTED → RATIFIED status convention"
fi

# ── A5 — Evidence → Decision is the per-question contract (the heart of part 4)
hasF "$CONV" "Evidence" "per-question contract: names Evidence"
hasF "$CONV" "Decision" "per-question contract: names Decision"

# ── A6 — INTEGRATION: the spike skill points at the convention doc, in-directory ──
hasF "$SKILL" "spike-finding-convention.md" "skill points at the convention doc by name"
hasF "$SKILL" "in this skill" "skill uses the in-this-skill's-directory sibling-doc pointer"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
