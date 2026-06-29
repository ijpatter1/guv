#!/bin/bash
# Tests for [21.4] (Phase 21) — the four scope-knowing entry doors made spike-aware.
# This is a PROSE-CONTRACT suite: the legibility fix lives in the doors' router-
# unavailable / mode-signal prose, where each must NAME /spike when ceremony=spike
# instead of falling through to /task or /onboard (phase/next/replan) or silently
# running the session as a scoped change (task).
#
# Why a MESSAGE-CONTENT assertion and not a behavioral one: on a spike project there
# is no PHASE_STATUS.md / DAG, so each door's existing tracker-absence disjunct already
# stops it — a "does not fall through to phased logic" test passes WITHOUT the fix
# ([21.4]'s acceptance calls this trap out explicitly). The gap is purely legibility:
# the stop must NAME /spike so a router-down operator is sent to the exploration door,
# not to /task. So this suite pins the positive content — each door recognizes the
# spike ceremony AND names /spike — which only the fix satisfies (the pre-fix doors
# carry no /spike token at all, so every /spike assertion below reddens without it).
#
# This suite references skills/<door>/SKILL.md, so build-plugin.sh auto-partitions it
# MAINTAINER-ONLY (the MAINTAINER_ONLY 'skills/[a-z][a-z-]*/SKILL\.md' pattern) — it
# runs in the core battery and never ships; ship-suite.test.sh derives the SAME
# partition and asserts it. Pure bash + grep, no runner.
# Run: bash .claude/tests/spike-doors-prose.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="$ROOT/skills/phase/SKILL.md"
NEXT="$ROOT/skills/next/SKILL.md"
REPLAN="$ROOT/skills/replan/SKILL.md"
TASK="$ROOT/skills/task/SKILL.md"

PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# Precondition: all four doors exist (a missing door is a loud failure, not a silent
# skip — Rule 15).
for f in "$PHASE" "$NEXT" "$REPLAN" "$TASK"; do
  [ -f "$f" ] || no "expected entry-door prose surface missing: $f"
done

# Flatten the file to one whitespace-normalized line before matching, so a contract
# phrase matches regardless of where markdown soft-wraps it (prose reflows; the
# contract is the words). Mirrors qa-vet-prose.test.sh's has().
has() { # $1=file  $2=pattern  $3=label
  local flat
  flat=$(tr '\n' ' ' < "$1" | tr -s ' ')
  if printf '%s' "$flat" | grep -qE "$2"; then
    ok "$3"
  else
    no "MISSING in $(basename "$(dirname "$1")")/$(basename "$1"): $3 (pattern: $2)"
  fi
}

# ── phase / next / replan — the three with an existing mode-signal stop ──────────
# Each names /task or /onboard today; the fix adds a spike branch that names /spike.
echo "— phase / next / replan: the mode-signal stop names /spike —"
for pair in "phase:$PHASE" "next:$NEXT" "replan:$REPLAN"; do
  name="${pair%%:*}"; file="${pair#*:}"
  # (a) The message-content assertion: the door names the /spike door. Anti-vacuous —
  #     a pre-fix door carries no /spike token, so this reddens without the fix.
  has "$file" '/spike' "$name: names the /spike door in its mode-signal prose"
  # (b) Ties /spike to the spike CEREMONY recognition (not a stray cross-reference):
  #     the literal `ceremony` read, then the spike value, then /spike named, all
  #     within one sentence-window of the recognition.
  has "$file" 'ceremony.{0,80}spike.{0,250}/spike' \
    "$name: recognizes ceremony=spike and routes the stop to /spike (the legibility fix)"
done

# ── task — no existing stop; it must RECOGNIZE spike and redirect to /spike ──────
# task is content-driven ([8.1]) — an explicit change is processed in ANY ceremony, so
# it does not refuse an explicit request. The fix is the session-entry / no-explicit-
# change case: landing in /task on a spike project must name /spike rather than silently
# run the session as a scoped change (the router-down "silently runs as a scoped
# change" gap [21.4] closes).
echo "— task: recognizes spike and redirects to /spike (no silent scoped-change) —"
has "$TASK" '/spike' "task: names the /spike door in its prose"
has "$TASK" 'spike.{0,250}/spike|/spike.{0,250}spike' \
  "task: recognizes the spike ceremony and routes it to /spike"
# The fix must NOT break [8.1]: task stays content-driven (legitimate in any ceremony,
# does not refuse an explicit request). Pin the invariant so a spike redirect that
# over-reaches into refusing explicit requests reddens here.
has "$TASK" 'content-driven' "task: stays content-driven ([8.1] invariant preserved)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
