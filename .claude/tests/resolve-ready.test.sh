#!/bin/bash
# Tests for .claude/resolve-ready.sh — the deterministic ready-frontier
# resolver ([6.2] of the plan-as-data spec). The contract is fixed in the
# phase-docs skill ("Resolver contract"): ready=/blocked= scoped to the
# current phase, in_progress= unscoped (in-flight work is finished first
# wherever it sits), serial resume = first 🔄 else first ready, exit 5
# naming offenders on unknown ID / duplicate ID / cycle / missing token /
# forward cross-phase dep / bullet-free tracker, LEGACY mode = line text in
# serial= (first 🔄's, else first ⬜'s) with ready=/in_progress=/blocked=
# explicitly empty.
# Pure bash + grep, no test runner. Run: bash .claude/tests/resolve-ready.test.sh
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/resolve-ready.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# Each fixture is a standalone tracker file; the resolver takes the path as $1.
fx() { printf '%s\n' "$WORK/$1.md"; }
val() { echo "$2" | grep -E "^$1=" | head -1 | sed "s/^$1=//"; }

# ── Fixture: this initiative's own shape at plan generation — 6.1 ✅, the
# rest ⬜. Hand-computed frontier: ready = 6.2 6.3 (deps on ✅ 6.1);
# blocked = 6.4 by 6.3 (first unsatisfied, itself ready), 6.5 by 6.2;
# in_progress empty; serial = 6.2. Phase 7 items NOT in ready despite
# 7.1/7.3 having `none` deps — current phase scope.
cat > "$(fx own)" <<'MD'
# Phase Status Tracker

> **Current Phase: 6 — Plan as Data**

## Phase 6 — Plan as Data

- ✅ **[6.1]** Grammar amendment `[deps: none]` (2026-06-12, session-001)
- ⬜ **[6.2]** Resolver `[deps: 6.1]`
- ⬜ **[6.3]** Mutation primitive `[deps: 6.1]`
- ⬜ **[6.4]** Docs sweep `[deps: 6.1, 6.3]`
- ⬜ **[6.5]** Status render `[deps: 6.2]`

## Phase 7 — Execution Surfaces

- ⬜ **[7.1]** Plumbing extraction `[deps: none]`
- ⬜ **[7.3]** Single-writer hook `[deps: none]`
MD

# T1 — the initiative's own tracker: output matches the hand-computed frontier.
OUT=$(bash "$SCRIPT" "$(fx own)" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "own: exit 0" || no "own tracker should resolve (rc=$RC: $OUT)"
[ "$(val mode "$OUT")" = "GRAMMAR" ] && ok "own: mode=GRAMMAR" || no "expected mode=GRAMMAR (got: $OUT)"
[ "$(val phase "$OUT")" = "6" ] && ok "own: phase=6" || no "expected phase=6 (got: $OUT)"
[ "$(val in_progress "$OUT")" = "" ] && ok "own: in_progress empty" || no "expected empty in_progress (got: $OUT)"
[ "$(val ready "$OUT")" = "6.2 6.3" ] && ok "own: ready=6.2 6.3 (document order)" || no "expected ready=6.2 6.3 (got: $OUT)"
[ "$(val blocked "$OUT")" = "6.4:6.3 6.5:6.2" ] && ok "own: blocked named with root blocker" \
  || no "expected blocked=6.4:6.3 6.5:6.2 (got: $OUT)"
[ "$(val serial "$OUT")" = "6.2" ] && ok "own: serial=6.2 (first ready)" || no "expected serial=6.2 (got: $OUT)"

# T2 — finish-before-start: a 🔄 line appears in in_progress= and wins serial.
cat > "$(fx wip)" <<'MD'
## Phase 6 — Build

- ✅ **[6.1]** Done `[deps: none]`
- 🔄 **[6.2]** Going `[deps: 6.1]`
- ⬜ **[6.3]** Waiting `[deps: 6.1]`
MD
OUT=$(bash "$SCRIPT" "$(fx wip)" 2>&1); RC=$?
[ "$(val in_progress "$OUT")" = "6.2" ] && ok "wip: in_progress=6.2" || no "expected in_progress=6.2 (got: $OUT)"
[ "$(val serial "$OUT")" = "6.2" ] && ok "wip: serial = first 🔄, not first ready" || no "serial should be 6.2 (got: $OUT)"
echo "$(val ready "$OUT")" | grep -q "6.3" && ok "wip: 6.3 still ready" || no "6.3 should be ready (got: $OUT)"

# T3 — transitive blocking: C depends on B depends on A (A ready) — C's named
# blocker is A, the transitive root, not B.
cat > "$(fx chain)" <<'MD'
## Phase 6 — Build

- ⬜ **[6.1]** A `[deps: none]`
- ⬜ **[6.2]** B `[deps: 6.1]`
- ⬜ **[6.3]** C `[deps: 6.2]`
MD
OUT=$(bash "$SCRIPT" "$(fx chain)" 2>&1)
[ "$(val blocked "$OUT")" = "6.2:6.1 6.3:6.1" ] && ok "chain: transitive root named (6.3 blocked by 6.1)" \
  || no "expected blocked=6.2:6.1 6.3:6.1 (got: $OUT)"

# T4 — ❌ propagation across a backward cross-phase dep (legal): a current-
# phase item depending on a prior-phase ❌ is blocked with the ❌ ID named.
cat > "$(fx crossback)" <<'MD'
## Phase 5 — Old

- ✅ **[5.1]** Done `[deps: none]`
- ❌ **[5.2]** Descoped 2026-06-01 `[deps: none]`

## Phase 6 — Build

- ⬜ **[6.1]** Needs the descoped thing `[deps: 5.2]`
- ⬜ **[6.2]** Fine `[deps: 5.1]`
MD
OUT=$(bash "$SCRIPT" "$(fx crossback)" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "crossback: backward cross-phase dep is legal (exit 0)" \
  || no "backward cross-phase deps must not error (rc=$RC: $OUT)"
[ "$(val blocked "$OUT")" = "6.1:5.2" ] && ok "crossback: ❌ propagates, named as blocker" \
  || no "expected blocked=6.1:5.2 (got: $OUT)"
[ "$(val ready "$OUT")" = "6.2" ] && ok "crossback: ✅ prior-phase dep satisfies" || no "expected ready=6.2 (got: $OUT)"

# T5 — forward cross-phase dep is MALFORMED: exit 5, offending ID named.
cat > "$(fx fwd)" <<'MD'
## Phase 6 — Build

- ⬜ **[6.1]** Jumps ahead `[deps: 7.1]`

## Phase 7 — Later

- ⬜ **[7.1]** Future `[deps: none]`
MD
OUT=$(bash "$SCRIPT" "$(fx fwd)" 2>&1); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "6.1" && echo "$OUT" | grep -qi "forward" \
  && ok "forward dep: exit 5, offender named" || no "forward cross-phase dep should exit 5 naming 6.1 (rc=$RC: $OUT)"

# T6 — cycle: exit 5, the cycle's IDs named.
cat > "$(fx cycle)" <<'MD'
## Phase 6 — Build

- ⬜ **[6.1]** A `[deps: 6.3]`
- ⬜ **[6.2]** B `[deps: 6.1]`
- ⬜ **[6.3]** C `[deps: 6.2]`
MD
OUT=$(bash "$SCRIPT" "$(fx cycle)" 2>&1); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -qi "cycle" && echo "$OUT" | grep -q "6.1" && echo "$OUT" | grep -q "6.3" \
  && ok "cycle: exit 5, cycle IDs named" || no "cycle should exit 5 naming its IDs (rc=$RC: $OUT)"

# T7 — unknown dep ID: exit 5, both the referrer and the missing ID named.
cat > "$(fx unknown)" <<'MD'
## Phase 6 — Build

- ⬜ **[6.1]** A `[deps: 6.9]`
MD
OUT=$(bash "$SCRIPT" "$(fx unknown)" 2>&1); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "6.9" \
  && ok "unknown dep: exit 5, missing ID named" || no "unknown dep should exit 5 naming 6.9 (rc=$RC: $OUT)"

# T8 — duplicate ID and missing token: exit 5 (well-formedness, same grammar
# as archive-initiative.sh).
cat > "$(fx dup)" <<'MD'
## Phase 6 — Build

- ⬜ **[6.1]** A `[deps: none]`
- ⬜ **[6.1]** B `[deps: none]`
MD
OUT=$(bash "$SCRIPT" "$(fx dup)" 2>&1); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "6.1" && ok "duplicate ID: exit 5, named" \
  || no "duplicate ID should exit 5 (rc=$RC: $OUT)"
cat > "$(fx notoken)" <<'MD'
## Phase 6 — Build

- ⬜ **[6.1]** A `[deps: none]`
- ⬜ **[6.2]** B has no token
MD
OUT=$(bash "$SCRIPT" "$(fx notoken)" 2>&1); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "B has no token" \
  && ok "missing token: exit 5, offending line named" \
  || no "missing token should exit 5 naming the line (rc=$RC: $OUT)"

# T9 — LEGACY (token-free): first ⬜ in document order as the serial resume,
# parallel set explicitly empty; a 🔄 wins serial per today's semantics.
cat > "$(fx legacy)" <<'MD'
## Phase 4 — Build

- ✅ Deliverable A
- ⬜ Deliverable B not started
- ⬜ Deliverable C not started
MD
OUT=$(bash "$SCRIPT" "$(fx legacy)" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$(val mode "$OUT")" = "LEGACY" ] && ok "legacy: exit 0, mode=LEGACY" \
  || no "token-free tracker should resolve as LEGACY (rc=$RC: $OUT)"
[ "$(val ready "$OUT")" = "" ] && ok "legacy: parallel set explicitly empty" || no "legacy ready= must be empty (got: $OUT)"
echo "$OUT" | grep -q '^blocked=$' && echo "$OUT" | grep -q '^in_progress=$' \
  && ok "legacy: blocked= and in_progress= emitted explicitly empty (parser symmetry)" \
  || no "legacy must emit blocked=/in_progress= as empty lines, not omit them (got: $OUT)"
[ "$(val serial "$OUT")" = "Deliverable B not started" ] && ok "legacy: serial = first ⬜ in document order" \
  || no "expected serial=Deliverable B not started (got: $OUT)"
cat > "$(fx legacywip)" <<'MD'
## Phase 4 — Build

- ✅ Deliverable A
- ⬜ Deliverable B not started
- 🔄 Deliverable C going
MD
OUT=$(bash "$SCRIPT" "$(fx legacywip)" 2>&1)
[ "$(val serial "$OUT")" = "Deliverable C going" ] && ok "legacy: 🔄 wins serial (finish before start)" \
  || no "expected serial=Deliverable C going (got: $OUT)"

# T9b — two deps-shaped constructs on one line: the resolver parses the LAST
# construct as the deliverable's own, exactly like archive-initiative.sh —
# no second dialect. A valid example earlier never masks a malformed real
# token (exit 5), and a well-formed shadow AFTER the real token is read in
# its place (the grammar's authoring rule — examples precede the token —
# is undetectable by tooling; this pins the documented last-construct
# outcome so dispatch behavior is deliberate, not accidental).
cat > "$(fx masked)" <<'MD'
## Phase 6 — Build

- ✅ **[6.1]** A `[deps: none]`
- ⬜ **[6.2]** Quoting a `[deps: 6.1]` example then malformed `[deps: ]`
MD
OUT=$(bash "$SCRIPT" "$(fx masked)" 2>&1); RC=$?
[ "$RC" -eq 5 ] && ok "masked malformed token: exit 5 despite valid example earlier" \
  || no "a valid example must not mask a malformed trailing token (rc=$RC: $OUT)"
cat > "$(fx examplefirst)" <<'MD'
## Phase 6 — Build

- ✅ **[6.1]** A `[deps: none]`
- ⬜ **[6.2]** Building on **[6.1]** and its `[deps: 6.1]` example, for real `[deps: 6.1]`
MD
OUT=$(bash "$SCRIPT" "$(fx examplefirst)" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$(val ready "$OUT")" = "6.2" ] \
  && ok "example-before-token: parses the real trailing token, 6.2 ready" \
  || no "a preceding example must not confuse the parse (rc=$RC: $OUT)"
cat > "$(fx shadow)" <<'MD'
## Phase 6 — Build

- ✅ **[6.1]** A `[deps: none]`
- 🔄 **[6.2]** B `[deps: 6.1]`
- ⬜ **[6.3]** C `[deps: 6.2]` (note quoting `[deps: none]` in the annotation)
MD
OUT=$(bash "$SCRIPT" "$(fx shadow)" 2>&1)
[ "$(val ready "$OUT")" = "6.3" ] \
  && ok "annotation shadow: last construct wins (documented hazard, pinned)" \
  || no "the last-construct rule should read the annotation's token (got: $OUT)"

# T9c — parser parity guard: the grammar regexes are byte-identical between
# the resolver and archive-initiative.sh. The two scripts deliberately share
# one dialect; this catches a future edit to one drifting from the other.
ARCHIVE="$(dirname "$SCRIPT")/archive-initiative.sh"
for var in ID_RE DEPS_RE; do
  a=$(grep -E "^$var=" "$SCRIPT"); b=$(grep -E "^$var=" "$ARCHIVE")
  [ -n "$a" ] && [ "$a" = "$b" ] && ok "parity: $var identical in both scripts" \
    || no "$var drifted between resolver and archive-initiative ('$a' vs '$b')"
done

# T9d — root blocker that is itself in progress: a ⬜ whose chain ends at a
# 🔄 names the 🔄 as the root.
cat > "$(fx wiproot)" <<'MD'
## Phase 6 — Build

- 🔄 **[6.1]** A going `[deps: none]`
- ⬜ **[6.2]** B `[deps: 6.1]`
MD
OUT=$(bash "$SCRIPT" "$(fx wiproot)" 2>&1)
[ "$(val blocked "$OUT")" = "6.2:6.1" ] && ok "wip root: blocked by the in-progress dep" \
  || no "expected blocked=6.2:6.1 (got: $OUT)"

# T9e — a later-phase 🔄 still wins serial (in-flight work is finished first,
# wherever it sits) while phase= reports the first open phase. Pinned: the
# contract's finish-before-start rule is global, the scope rule applies to
# ready/blocked only.
cat > "$(fx latewip)" <<'MD'
## Phase 6 — Build

- ⬜ **[6.1]** Open `[deps: none]`

## Phase 7 — Later

- 🔄 **[7.1]** In flight `[deps: none]`
MD
OUT=$(bash "$SCRIPT" "$(fx latewip)" 2>&1)
[ "$(val phase "$OUT")" = "6" ] && [ "$(val serial "$OUT")" = "7.1" ] && [ "$(val ready "$OUT")" = "6.1" ] \
  && ok "later-phase 🔄: phase=6, serial=7.1 (finish in-flight first)" \
  || no "expected phase=6 serial=7.1 ready=6.1 (got: $OUT)"

# T9f — multi-digit IDs: 1.2 and 10.2 never substring-confuse the
# space-bounded membership checks.
cat > "$(fx widephase)" <<'MD'
## Phase 1 — Early

- ✅ **[1.2]** Old `[deps: none]`

## Phase 10 — Wide

- ⬜ **[10.2]** New `[deps: 1.2]`
- ⬜ **[10.3]** Newer `[deps: 10.2]`
MD
OUT=$(bash "$SCRIPT" "$(fx widephase)" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$(val ready "$OUT")" = "10.2" ] && [ "$(val blocked "$OUT")" = "10.3:10.2" ] \
  && ok "multi-digit IDs: 10.x vs 1.x resolve without substring confusion" \
  || no "expected ready=10.2 blocked=10.3:10.2 (rc=$RC: $OUT)"

# T9g — a tracker with headers but zero deliverable bullets is MALFORMED
# (exit 5), matching archive-initiative.sh — a corrupt tracker must not read
# as "nothing to do" to the resume door.
printf '# Tracker\n## Phase 6 — Build\nno bullets here\n' > "$(fx empty)"
OUT=$(bash "$SCRIPT" "$(fx empty)" 2>&1); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "MALFORMED" \
  && ok "bullet-free tracker: exit 5, fail loud" \
  || no "a tracker with no bullets should be MALFORMED (rc=$RC: $OUT)"

# T10 — completed tracker: empty frontier, exit 0 (a resting state, not an error).
cat > "$(fx done)" <<'MD'
## Phase 6 — Build

- ✅ **[6.1]** A `[deps: none]`
- ✅ **[6.2]** B `[deps: 6.1]`
MD
OUT=$(bash "$SCRIPT" "$(fx done)" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$(val ready "$OUT")" = "" ] && [ "$(val serial "$OUT")" = "" ] \
  && ok "complete: exit 0, empty frontier" || no "complete tracker should resolve empty (rc=$RC: $OUT)"

# T11 — usage and missing file: no arg uses docs/PHASE_STATUS.md (exit 4 when
# absent from cwd); explicit missing path exits 4.
( cd "$WORK" && bash "$SCRIPT" ) >/dev/null 2>&1; RC=$?
[ "$RC" -eq 4 ] && ok "no tracker: exit 4" || no "missing default tracker should exit 4 (rc=$RC)"
bash "$SCRIPT" "$WORK/nope.md" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 4 ] && ok "missing path: exit 4" || no "missing explicit path should exit 4 (rc=$RC)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
