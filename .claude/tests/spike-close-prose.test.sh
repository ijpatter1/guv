#!/bin/bash
# Tests for [21.5] (Phase 21) — the findings-drain CLOSE for the `spike` skill.
# A spike's value is its finding; [21.5] adds the skill's EXIT step: on close, drain
# the finding to one of four destinations (/plan · /replan insert · /feedback · an
# archive note in docs/spikes/), or — if none was chosen — surface a loud-but-NON-
# blocking undrained-finding notice (declared, not gated: the exit-0 rung, mirroring
# the handoff's feedback-drain step). Ratified in docs/spikes/21-1-exploration-
# ceremony.md ("Loud path 3 — drain owed" + build-set item #4).
#
# Why a PROSE-CONTRACT suite (like spike-doors-prose.test.sh) and not a behavioral
# one: the spike skill is LLM-executed prose — there is no close SCRIPT to run (the
# skill's own contract is "compose, don't build … adds a goal and a destination,
# nothing more"). So the close is prose the model executes, and the contract is the
# words: this suite pins that the close (a) names all four drains as the OWED set,
# (b) carries a LOUD undrained-finding notice, and (c) pins that notice as DECLARED-
# NOT-GATED — loud but non-blocking. (c) is the load-bearing property (Rule 8): a
# regression that silenced the notice OR turned it into a hard stop must RED here —
# pinning the token alone would pass either way, exactly the trap [21.4]'s ordering
# pin called out.
#
# References skills/spike/SKILL.md, so build-plugin.sh auto-partitions it MAINTAINER-
# ONLY (the 'skills/[a-z][a-z-]*/SKILL\.md' pattern) — runs in the core battery,
# never ships; ship-suite.test.sh derives the SAME partition. Pure bash + grep.
# Run: bash .claude/tests/spike-close-prose.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPIKE="$ROOT/skills/spike/SKILL.md"

PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# Precondition: the spike skill exists (a missing skill is a loud failure, not a
# silent skip — Rule 15).
[ -f "$SPIKE" ] || no "expected spike skill surface missing: $SPIKE"

# Flatten the file to one whitespace-normalized line before matching, so a contract
# phrase matches regardless of where markdown soft-wraps it (prose reflows; the
# contract is the words). Mirrors spike-doors-prose.test.sh's has().
has() { # $1=file  $2=pattern  $3=label
  local flat
  flat=$(tr '\n' ' ' < "$1" | tr -s ' ')
  if printf '%s' "$flat" | grep -qE "$2"; then
    ok "$3"
  else
    no "MISSING in $(basename "$(dirname "$1")")/$(basename "$1"): $3 (pattern: $2)"
  fi
}

echo "— spike close: the exit step drains the finding or declares it undrained —"

# (1) The close is its own EXIT step — not just a clause tacked onto "begin". Pin a
#     Close step whose subject is draining the finding on exit. Pre-[21.5] the skill
#     ends at Step 4 (Begin) with no dedicated close, so this reddens without the fix.
has "$SPIKE" '#+ Step 5[^#]{0,60}[Cc]lose' \
  "close: the skill has a dedicated Step 5 close step"

# (2) The undrained notice enumerates ALL FOUR drains as the OWED set. Anchored on
#     'owed' so it cannot be satisfied by Step 3's up-front drain NAMING (which lists
#     the drains in a non-owed context) — the four must appear together as what the
#     finding is owed to at close. (Anti-vacuity: token-presence alone passes via
#     Step 3; the 'owed → four drains' window is unique to the [21.5] close.)
has "$SPIKE" 'owed[^.]{0,140}/plan[^.]{0,80}/replan insert[^.]{0,80}/feedback[^.]{0,80}archive' \
  "close: the undrained notice names all four owed drains (/plan · /replan insert · /feedback · archive)"

# (3) The notice is LOUD — a named, visible undrained-finding signal, not a silent
#     drop. Pre-[21.5] there is no such token, so this reddens without the fix.
has "$SPIKE" 'UNDRAINED[ -]FINDING' \
  "close: the undrained-finding notice is loud (named UNDRAINED FINDING)"

# (4) LOAD-BEARING (Rule 8) — the notice is DECLARED, NOT GATED: loud but non-blocking,
#     the exit-0 rung, the close PROCEEDS. This is the [13.5]/[13.6] 'declare, never
#     stop' rung the meter BALLOON and budget-gate FORESEEN OVERRUN ride. The pin
#     catches BOTH drift directions a token-only assertion would miss: if the notice
#     were silenced (3 fails) OR hardened into a stop/gate (this fails). A spike's
#     finding is fuzzy — a human call, never a mid-flight stop (Rule 15: wrong rung).
has "$SPIKE" '(DECLARATION|declared)[^.]{0,40}not[^.]{0,20}(a )?stop|not gated|exit-0 rung|close proceeds' \
  "close: the undrained notice is DECLARED-NOT-GATED — loud but non-blocking (exit-0 rung)"

# (5) The notice fires precisely on the NO-DRAIN branch (the behavioral condition: a
#     close reached with no drain chosen → the notice). Pins the trigger, not just the
#     message — the half of the red→green that says WHEN it surfaces.
has "$SPIKE" 'no drain[^.]{0,80}(undrained|notice|declare)|undrained[^.]{0,140}no drain' \
  "close: the notice fires when the close is reached with NO drain chosen"

# (6) The drain branch RECORDS — a drained finding's destination IS the durable record
#     (the note / deliverable(s) / feedback entry), nothing else owed. The 'records it'
#     half of the acceptance: a chosen drain leaves a record, the undrained case does not.
has "$SPIKE" '[Rr]ecord(ed|s)?[^.]{0,80}(note|deliverable|feedback|drain)|(note|deliverable|entry)[^.]{0,30}is the[^.]{0,20}(record|artifact)' \
  "close: a chosen drain RECORDS the finding (its destination is the durable artifact)"

# (7) The close mirrors the handoff's feedback-drain step — the ratified design lineage
#     ([21.1] Loud path 3: 'mirroring the handoff's feedback-drain step'). Ties the
#     undrained notice to the existing drain pattern, not a bespoke invention.
has "$SPIKE" '(handoff|feedback)[^.]{0,60}(feedback|drain)[^.]{0,40}(step|drain)' \
  "close: the undrained notice mirrors the handoff's feedback-drain step (composed, not invented)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
