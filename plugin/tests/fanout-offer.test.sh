#!/bin/bash
# Tests for .claude/fanout-offer.sh — the fan-out decision SCAFFOLD ([17.2],
# Phase 17; design of record docs/spikes/17-1-fanout-decision-scaffold.md).
#
# The script surfaces a structured, NON-BLOCKING fan-out offer from the resolver's
# ready frontier + the estimate sidecar. It is the MECHANICAL half of the
# composite fit-judgment (Rule 12): the floor (count(ready=) ≥ 2), per-candidate
# sizing from estimate.sh, and the balloon/unsized guardrail. It does NOT compute
# surface-disjointness (an AGENT judgment over candidate wording, surfaced AS a
# judgment by the skill prose, never a resolver fact) and it NEVER executes a
# fan-out — the structural guarantee that a headless run cannot spawn worktrees is
# that the script does not reference the lane script at all. A chosen fan-out is
# handed to the existing build-fanout flow by the agent, not by this script.
#
# The heart-of-the-deliverable invariants this suite defends:
#   1. the trigger FLOOR — 1 ready → no offer; ≥2 → an offer (deps-only: a
#      cross-phase candidate counts, dispatch is not phase-gated [7.6]);
#   2. an unsized OR balloon candidate routes the verdict to "size first", never
#      "fan out" — the sizing guardrail;
#   3. disjointness is PRESENT and MARKED-AS-JUDGMENT, never emitted as a computed
#      yes/no resolver fact;
#   4. the script NEVER references the lane script (no unattended worktree spawn)
#      and ALWAYS emits default=serial (the Rule-15 designed default);
#   5. the offer NEVER blocks — a malformed (present) sidecar or unreadable
#      resolver input degrades to offer=not-assessed with a reason and the serial
#      pick, exit 0 (a degrade is a route, not a stop).
#
# Pure bash + jq, no test runner. Run: bash .claude/tests/fanout-offer.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"          # .claude/
SCRIPT="$SRC/fanout-offer.sh"
EST="$SRC/estimate.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# A resolver-output fixture in the name=value text form the resolver emits — the
# script consumes THIS (the one-parser rule: it never re-reads the tracker, it
# reads what resolve-ready.sh already computed, exactly like status-line.sh).
frontier() { # $1=ready (space-separated IDs)  $2=serial
  printf 'mode=GRAMMAR\nphase=17\nin_progress=\nready=%s\nblocked=\nserial=%s\n' "$1" "$2"
}

# Run the script over a frontier + sidecar; capture OUT and RC.
run() { # $1=frontier-text  $2=sidecar(optional, "" = default)
  OUT=$(printf '%s' "$1" | bash "$SCRIPT" - "${2:-}" 2>/dev/null); RC=$?
}
field() { printf '%s\n' "$OUT" | grep -E "^$1=" | head -1 | sed "s/^$1=//"; }

# Fresh sidecars built through estimate.sh itself (the real shape, not a hand-rolled
# JSON) — so the test exercises the same set-sized/set/validate surface the script
# consumes at runtime.
SIZED="$WORK/sized.json";   rm -f "$SIZED"
bash "$EST" set-sized 17.2 medium "$SIZED" >/dev/null 2>&1
bash "$EST" set-sized 18.2 medium "$SIZED" >/dev/null 2>&1
bash "$EST" set-sized 21.1 light  "$SIZED" >/dev/null 2>&1

# ════ T1 — the FLOOR: a single ready item yields NO offer ════
# One independent surface cannot be fanned out — there is nothing to parallelize.
run "$(frontier '17.2' '17.2')" "$SIZED"
[ "$RC" -eq 0 ] && [ "$(field offer)" = "no" ] \
  && ok "floor: 1 ready item → offer=no (nothing to parallelize)" \
  || no "1 ready should yield offer=no, exit 0 (rc=$RC, offer=$(field offer))"
[ "$(field default)" = "serial" ] \
  && ok "floor: even with no offer, default=serial is emitted (the designed fallback)" \
  || no "default=serial must always be present (got: $(field default))"

# ════ T2 — the FLOOR: ≥2 sized ready items yields an offer=yes ════
run "$(frontier '17.2 18.2' '17.2')" "$SIZED"
[ "$RC" -eq 0 ] && [ "$(field offer)" = "yes" ] \
  && ok "floor: ≥2 sized ready items → offer=yes" \
  || no "2 sized ready should yield offer=yes (rc=$RC, offer=$(field offer))"
[ "$(field count)" = "2" ] \
  && ok "offer carries count=2 (the mechanical independent-surface count)" \
  || no "count should be 2 (got: $(field count))"
[ "$(field floor)" = "2" ] \
  && ok "offer makes the trigger floor explicit (floor=2)" \
  || no "floor should be 2 (got: $(field floor))"
case " $(field candidates) " in *" 17.2 "*) case " $(field candidates) " in *" 18.2 "*)
  ok "offer carries the candidate IDs (17.2 18.2)";; *) no "candidates missing 18.2: $(field candidates)";; esac;;
  *) no "candidates missing 17.2: $(field candidates)";; esac
# Their sizes ride the offer (per-candidate, from the sidecar — the guardrail input).
case "$(field sizes)" in *17.2:medium*) ok "offer carries per-candidate sizes (17.2:medium)";;
  *) no "sizes should carry 17.2:medium (got: $(field sizes))";; esac

# ════ T3 — deps-only: a CROSS-PHASE pair still meets the floor (offer=yes) ════
# Dispatch is deps-only ([7.6]) — the floor counts independent surfaces, it does
# not require them to share a phase. 17.2 (Phase 17) + 21.1 (Phase 21) is a valid
# fan-out candidate set.
run "$(frontier '17.2 21.1' '17.2')" "$SIZED"
[ "$(field offer)" = "yes" ] \
  && ok "deps-only: a cross-phase ready pair meets the floor (offer=yes)" \
  || no "cross-phase pair should yield offer=yes (got: $(field offer))"

# ════ T4 — the disjointness signal is PRESENT and MARKED-AS-JUDGMENT ════
# The script must NOT compute disjointness (it cannot — it never reads the
# candidate wording). It emits a judgment SLOT, not a verdict.
run "$(frontier '17.2 18.2' '17.2')" "$SIZED"
[ "$(field disjointness)" = "agent-judgment" ] \
  && ok "disjointness is surfaced as a judgment slot (disjointness=agent-judgment)" \
  || no "disjointness must be marked agent-judgment (got: $(field disjointness))"
# Never a computed resolver fact: no disjointness=yes / =no may appear.
if printf '%s\n' "$OUT" | grep -Eq '^disjointness=(yes|no|true|false)$'; then
  no "disjointness must NEVER be a computed yes/no (it is an agent judgment, not a resolver fact)"
else
  ok "disjointness is never emitted as a computed yes/no (Rule 12 seam preserved)"
fi

# ════ T5 — an UNSIZED candidate routes to "size first", not "fan out" ════
# 18.2 present-and-sized; 99.9 absent from the sidecar (unsized → size unknown).
run "$(frontier '17.2 99.9' '17.2')" "$SIZED"
[ "$(field offer)" = "size-first" ] \
  && ok "guardrail: an unsized candidate routes offer=size-first (not fan-out)" \
  || no "unsized candidate should yield offer=size-first (got: $(field offer))"
case " $(field needs_sizing) " in *" 99.9 "*) ok "the unsized candidate (99.9) is named in needs_sizing";;
  *) no "needs_sizing should name 99.9 (got: $(field needs_sizing))";; esac

# ════ T6 — a BALLOON candidate routes to "size first" and is flagged distinctly ════
# A legacy N>1 entry is a balloon — too big to fan out as-is; it must be SPLIT.
BALLOON="$WORK/balloon.json"; rm -f "$BALLOON"
bash "$EST" set-sized 17.2 medium "$BALLOON" >/dev/null 2>&1
bash "$EST" set 18.2 3 "$BALLOON" >/dev/null 2>&1     # legacy N=3 → balloon
run "$(frontier '17.2 18.2' '17.2')" "$BALLOON"
[ "$(field offer)" = "size-first" ] \
  && ok "guardrail: a balloon candidate routes offer=size-first (split before fan-out)" \
  || no "balloon candidate should yield offer=size-first (got: $(field offer))"
case " $(field balloons) " in *" 18.2 "*) ok "the balloon (18.2) is flagged distinctly in balloons=";;
  *) no "balloons should name 18.2 (got: $(field balloons))";; esac

# ════ T7 — the script NEVER references the lane script (no unattended spawn) ════
# This is the structural guarantee behind "never spawns worktrees unattended": the
# scaffold surfaces and decides; it cannot execute a fan-out. Asserted against the
# source, so a future edit that wires in the lane script reddens here.
if grep -q 'guv-lane' "$SCRIPT"; then
  no "fanout-offer.sh must NEVER reference the lane script (it surfaces, it does not execute)"
else
  ok "structural: the script contains no lane-script reference (cannot spawn worktrees)"
fi

# ════ T8 — NEVER blocks: unreadable resolver input degrades, exit 0 ════
# Garbage that is not resolver output must not error out — it degrades to a named
# non-assessment and proceeds (the offer never blocks the session).
OUT=$(printf 'this is not resolver output\n' | bash "$SCRIPT" - "$SIZED" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ "$(field offer)" = "not-assessed" ] \
  && ok "degrade: unreadable resolver input → offer=not-assessed, exit 0 (never blocks)" \
  || no "unreadable input should degrade to not-assessed/exit-0 (rc=$RC, offer=$(field offer))"
[ -n "$(field reason)" ] \
  && ok "degrade: a reason= names why the offer was not assessed" \
  || no "a degrade must carry a reason= (got empty)"

# ════ T9 — NEVER blocks: a malformed (present) sidecar degrades, exit 0 ════
# A broken sidecar is not a stop — the size guardrail simply cannot run, so the
# offer is not assessed; the serial pick is preserved for the caller.
BADCAR="$WORK/malformed.json"; printf '{ this is not json\n' > "$BADCAR"
run "$(frontier '17.2 18.2' '17.2')" "$BADCAR"
[ "$RC" -eq 0 ] && [ "$(field offer)" = "not-assessed" ] \
  && ok "degrade: a malformed sidecar → offer=not-assessed, exit 0 (never blocks)" \
  || no "malformed sidecar should degrade to not-assessed/exit-0 (rc=$RC, offer=$(field offer))"
[ "$(field serial)" = "17.2" ] \
  && ok "degrade: the serial pick is preserved in the degrade (serial=17.2)" \
  || no "degrade should pass through serial=17.2 (got: $(field serial))"

# ════ T10 — usage: no input argument is a misinvocation (exit 2), not a degrade ════
# A degrade is a RUNTIME route; a missing argument is a wiring bug — distinct exit.
bash "$SCRIPT" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] \
  && ok "usage: no input argument exits 2 (a misinvocation, not a runtime degrade)" \
  || no "no-arg invocation should exit 2 (got rc=$RC)"

# ════ T11 — an empty frontier (every deliverable terminal) yields no offer ════
# ready= is legitimately empty; count=0 < floor → offer=no, exit 0 (not a degrade).
run "$(frontier '' '')" "$SIZED"
[ "$RC" -eq 0 ] && [ "$(field offer)" = "no" ] \
  && ok "empty frontier → offer=no, exit 0 (a state, not an error)" \
  || no "empty frontier should yield offer=no/exit-0 (rc=$RC, offer=$(field offer))"

# ════ T12 — usage: a named input FILE that does not exist is a misinvocation ════
# The real invocation pipes resolver output via "-"; a missing file ARG can only be
# a wiring typo, so it exits 2 (loud, a designed stop) rather than silently
# composing a non-assessment off nothing. This pins the deliberate boundary between
# a USAGE error (exit 2) and a runtime DEGRADE (exit 0, for present-but-unusable
# content) — the two must not blur.
bash "$SCRIPT" /no/such/resolver/output.txt "$SIZED" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] \
  && ok "usage: a non-existent input file exits 2 (misinvocation, NOT a runtime degrade)" \
  || no "a missing input file should exit 2 (got rc=$RC)"

echo ""
# "Results:" is load-bearing, not cosmetic: the runner's [15.1] stdout-verdict
# guard and its assertion tally both key on it. This suite used its own bare
# "<name>: N passed, M failed" and was one of two that made the whole-battery
# tally withhold (all-or-nothing) on 2026-07-27.
echo "  fanout-offer.test.sh Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
