#!/bin/bash
# .claude/fanout-offer.sh
# The fan-out decision SCAFFOLD ([17.2] of the pre-beta-hardening initiative;
# design of record docs/spikes/17-1-fanout-decision-scaffold.md). It surfaces a
# structured, NON-BLOCKING fan-out offer from the resolver's ready frontier and
# the estimate sidecar — the MECHANICAL half of the composite fit-judgment the
# `next`/`phase` doors present.
#
# What it computes (Rule 12 — deterministic, no judgment, no LLM):
#   - the trigger FLOOR: count(ready=) ≥ 2 (one independent surface cannot be
#     parallelized; dispatch is deps-only [7.6], so a cross-phase pair counts);
#   - per-candidate sizing, read from estimate.sh (the sidecar is the guardrail);
#   - the unsized/BALLOON guardrail: any candidate with no ratified rubric class
#     (unsized) or a legacy N>1 estimate (balloon) routes the verdict to
#     "size first" — you size/split before you fan out, never fan out blind.
#
# What it deliberately does NOT do — the seam left for agent judgment and the
# structural safety guarantee:
#   - it does NOT compute surface-DISJOINTNESS. Whether two candidates touch
#     independent code is a judgment over their wording; the resolver has no such
#     fact. The script emits `disjointness=agent-judgment` — a SLOT the skill
#     prose fills, surfaced AS a judgment — never a computed yes/no.
#   - it does NOT execute a fan-out and contains NO reference to the lane
#     machinery. A chosen fan-out is handed by the agent to the existing
#     build-fanout flow; this script surfaces and decides, it never spawns a
#     worktree. That a headless run cannot escalate to parallel work unattended is
#     guaranteed structurally here: there is nothing in this file to invoke.
#
# It consumes the resolver's name=value output (the one-parser rule [A-001]: it
# reads what resolve-ready.sh already computed — like status-line.sh — and never
# re-reads the tracker). The designed default is SERIAL (Rule 15): `default=serial`
# rides every output, so a headless or unanswered run takes the serial pick and the
# offer is declined-by-absence — fan-out is a human-gated acceleration, never a
# silent auto-escalation.
#
# Usage:
#   bash .claude/fanout-offer.sh <resolver-output|-> [SIDECAR]
#   bash .claude/resolve-ready.sh | bash .claude/fanout-offer.sh -
#
#   "-" reads the resolver output from stdin; otherwise the first argument is a
#   file holding it. SIDECAR defaults to estimate.sh's default (docs/estimates.json).
#
# Output (name=value, one per line — the resolve-ready.sh contract shape):
#   offer=yes|no|size-first|not-assessed
#   floor=2          the trigger floor (count(ready=) ≥ 2)
#   count=N          the independent-surface count (mechanical)
#   candidates=…     the ready IDs
#   sizes=ID:CLASS…  per-candidate rubric class ("?" = unsized)
#   needs_sizing=…   candidates with no ratified class (unsized or balloon)
#   balloons=…       candidates that are balloons specifically (split, don't size)
#   disjointness=agent-judgment   the judgment SLOT (never a computed fact)
#   default=serial   the Rule-15 designed default (always present)
#   serial=ID        the resolver's serial pick, passed through
#   reason=…         (degrade only) why the offer was not assessed
#
# Exit: 0 — an offer was computed (yes/no/size-first) OR a non-blocking degrade
#           (not-assessed). The offer NEVER blocks: a malformed sidecar or
#           unreadable resolver input is a degrade (a route), not a stop.
#       2 — usage: no input argument, OR a named input FILE that does not exist.
#           Both are misinvocations (the real invocation pipes resolver output via
#           "-"; a missing file arg can only be a wiring typo) — distinct from a
#           runtime degrade, which is for resolver/sidecar CONTENT that is present
#           but unusable.
set -u

usage() { echo "usage: fanout-offer.sh <resolver-output|-> [SIDECAR]" >&2; exit 2; }
[ $# -ge 1 ] || usage

SRC_IN="$1"
SIDECAR="${2:-}"
EST="$(cd "$(dirname "$0")" && pwd)/estimate.sh"

# Read the resolver output (stdin via "-", else a file).
if [ "$SRC_IN" = "-" ]; then
  INPUT="$(cat)"
else
  [ -f "$SRC_IN" ] || { echo "fanout-offer: no such file: $SRC_IN" >&2; exit 2; }
  INPUT="$(cat "$SRC_IN")"
fi

field_in() { printf '%s\n' "$INPUT" | grep -E "^$1=" | head -1 | sed "s/^$1=//"; }
has_line() { printf '%s\n' "$INPUT" | grep -qE "^$1="; }

# Pull the serial pick early so even a degrade can pass it through (empty if the
# input carried none).
SERIAL=""
has_line serial && SERIAL="$(field_in serial)"

# degrade REASON — the non-blocking route (Rule 15 designed degradation): the
# offer could not be assessed, but the session is NOT stopped. The serial pick is
# preserved so the caller proceeds serially; exit 0 (a route, not a failure).
degrade() {
  echo "offer=not-assessed"
  echo "reason=$1"
  echo "default=serial"
  echo "serial=$SERIAL"
  exit 0
}

# The input must be resolver output — the name=value frontier carries mode=,
# ready=, and serial= lines (ready= may be empty: an empty frontier is valid). If
# it does not look like resolver output, degrade rather than compose an offer off
# something that isn't the frontier.
if ! { has_line mode && has_line ready && has_line serial; }; then
  degrade "resolver output unreadable — missing mode=/ready=/serial= (not resolve-ready.sh output)"
fi

READY="$(field_in ready)"
# The independent-surface count — plain word count of the ready ID list.
set -- $READY
COUNT=$#

# Validate the sidecar up front: an ABSENT sidecar is fine (every candidate reads
# unsized → the size guardrail simply routes to size-first), but a PRESENT-and-
# MALFORMED sidecar means the guardrail cannot run — degrade, never block.
if ! bash "$EST" validate "$SIDECAR" >/dev/null 2>&1; then
  degrade "estimate sidecar is malformed or the sizing helper is unavailable — the guardrail cannot run"
fi

# The FLOOR: fewer than two independent surfaces → no offer (nothing to
# parallelize). A state, not a degrade — exit 0.
if [ "$COUNT" -lt 2 ]; then
  echo "offer=no"
  echo "floor=2"
  echo "count=$COUNT"
  echo "candidates=$READY"
  echo "default=serial"
  echo "serial=$SERIAL"
  exit 0
fi

# Floor met — assess each candidate's sizing (the mechanical guardrail input).
SIZES=""; NEEDS=""
for id in $READY; do
  cls="$(bash "$EST" size "$id" "$SIDECAR" 2>/dev/null)"
  if [ -n "$cls" ]; then
    SIZES="$SIZES $id:$cls"
  else
    SIZES="$SIZES $id:?"
    NEEDS="$NEEDS $id"
  fi
done

# Balloons are a sub-class of the unsized set (a legacy N>1 entry has no rubric
# class, so it is already in NEEDS) — surfaced distinctly so the human message can
# say "split", not merely "size". estimate.sh balloons emits "ID (N)" per line.
BALLOONS=""
for bl in $(bash "$EST" balloons "$SIDECAR" 2>/dev/null | awk '{print $1}'); do
  for id in $READY; do [ "$bl" = "$id" ] && BALLOONS="$BALLOONS $id"; done
done

# The mechanical verdict: any unsized/balloon candidate routes to "size first"
# (you cannot responsibly fan out a set whose cost you have not ratified); else
# the floor is met and the candidates are sized → "yes" (an offer to fan out,
# pending the agent's disjointness judgment).
if [ -n "${NEEDS# }" ]; then
  OFFER="size-first"
else
  OFFER="yes"
fi

echo "offer=$OFFER"
echo "floor=2"
echo "count=$COUNT"
echo "candidates=$READY"
echo "sizes=$(echo $SIZES)"
echo "needs_sizing=$(echo $NEEDS)"
echo "balloons=$(echo $BALLOONS)"
echo "disjointness=agent-judgment"
echo "default=serial"
echo "serial=$SERIAL"
exit 0
