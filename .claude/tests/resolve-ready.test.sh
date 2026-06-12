#!/bin/bash
# Tests for .claude/resolve-ready.sh — the deterministic ready-frontier
# resolver ([6.2] of the plan-as-data spec; cross-phase frontier per [7.6]).
# The contract is fixed in the phase-docs skill ("Resolver contract"):
# ready=/blocked= span ALL phases — every open ⬜ is either ready or blocked;
# deps are the only ordering and phase= demotes to reporting (first phase
# with open work) — in_progress= unscoped (in-flight work is finished first
# wherever it sits), serial resume = first 🔄 else first ready, exit 5
# naming offenders on unknown ID / duplicate ID / cycle / missing token /
# bullet-free tracker (a forward cross-phase dep is an ordinary edge — the
# MALFORMED rule repealed with the phase barrier whose lint companion it
# was), LEGACY mode = line text in serial= (first 🔄's, else first ⬜'s)
# with ready=/in_progress=/blocked= explicitly empty.
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
# rest ⬜. Hand-computed frontier: ready = 6.2 6.3 (deps on ✅ 6.1) and the
# cross-phase 7.1 7.3 (`none` deps — the phase barrier stopped gating
# dispatch at [7.6]); blocked = 6.4 by 6.3 (first unsatisfied, itself
# ready), 6.5 by 6.2; in_progress empty; serial = 6.2 (first ready,
# document order). phase= still reports 6, the first phase with open work.
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
[ "$(val ready "$OUT")" = "6.2 6.3 7.1 7.3" ] && ok "own: ready=6.2 6.3 7.1 7.3 (document order, cross-phase)" || no "expected ready=6.2 6.3 7.1 7.3 (got: $OUT)"
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

# T5 — forward cross-phase dep is an ORDINARY EDGE ([7.6]: the MALFORMED
# rule repealed with the phase barrier whose lint companion it was): the
# fixture RESOLVES — the dependent is blocked with the forward root named,
# the later-phase item is ready while the earlier phase is open, and phase=
# still reports the first open phase — under both output modes.
cat > "$(fx fwd)" <<'MD'
## Phase 6 — Build

- ⬜ **[6.1]** Jumps ahead `[deps: 7.1]`

## Phase 7 — Later

- ⬜ **[7.1]** Future `[deps: none]`
MD
OUT=$(bash "$SCRIPT" "$(fx fwd)" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "forward dep: resolves (ordinary edge, exit 0)" \
  || no "forward cross-phase dep must resolve (rc=$RC: $OUT)"
[ "$(val phase "$OUT")" = "6" ] && ok "forward dep: phase= still reports the first open phase" \
  || no "expected phase=6 (got: $OUT)"
[ "$(val ready "$OUT")" = "7.1" ] && ok "forward dep: later-phase item ready while an earlier phase is open" \
  || no "expected ready=7.1 (got: $OUT)"
[ "$(val blocked "$OUT")" = "6.1:7.1" ] && ok "forward dep: dependent blocked with the forward root named" \
  || no "expected blocked=6.1:7.1 (got: $OUT)"
JF=$(bash "$SCRIPT" "$(fx fwd)" --json 2>/dev/null); RCJ=$?
[ "$RCJ" -eq 0 ] && echo "$JF" | jq -e '.phase==6 and .frontier.ready==["7.1"]
  and (.frontier.blocked|map(.id+":"+.blocked_by))==["6.1:7.1"]' >/dev/null \
  && ok "forward dep: --json agrees (ready, blocked root, reporting phase)" \
  || no "forward-dep fixture must resolve identically under --json (rc=$RCJ: $JF)"

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

# ── [6.6] status.json emission: --json is the SAME resolver — same parse,
# same exit codes — emitting the one canonical JSON shape every other reader
# of plan state consumes (shape documented in the phase-docs skill alongside
# the grammar; contract surface per the A-001 one-parser decision, versioning
# question parked in feedback entry 2026-06-12T14:53:17Z-218718043).

# T12 — field-for-field frontier parity on the own fixture: every shell
# variable agrees with its JSON counterpart.
OUT=$(bash "$SCRIPT" "$(fx own)" 2>/dev/null)
J=$(bash "$SCRIPT" "$(fx own)" --json 2>/dev/null); RCJ=$?
if [ "$RCJ" -eq 0 ] && echo "$J" | jq -e . >/dev/null 2>&1; then
  ok "json: exit 0 and valid JSON on the own fixture"
else
  no "--json must emit valid JSON with exit 0 (rc=$RCJ: $J)"
fi
[ "$(echo "$J" | jq -r '.mode')" = "$(val mode "$OUT")" ] \
  && ok "json: mode agrees with shell output" || no "json .mode must equal shell mode="
[ "$(echo "$J" | jq -r '.phase')" = "$(val phase "$OUT")" ] \
  && ok "json: phase agrees" || no "json .phase must equal shell phase="
[ "$(echo "$J" | jq -r '.frontier.in_progress | join(" ")')" = "$(val in_progress "$OUT")" ] \
  && ok "json: in_progress agrees" || no "json frontier.in_progress must equal shell in_progress="
[ "$(echo "$J" | jq -r '.frontier.ready | join(" ")')" = "$(val ready "$OUT")" ] \
  && ok "json: ready agrees field for field" || no "json frontier.ready must equal shell ready="
[ "$(echo "$J" | jq -r '.frontier.blocked | map(.id + ":" + .blocked_by) | join(" ")')" = "$(val blocked "$OUT")" ] \
  && ok "json: blocked agrees (id + transitive root blocker)" || no "json frontier.blocked must equal shell blocked="
[ "$(echo "$J" | jq -r '.frontier.serial // ""')" = "$(val serial "$OUT")" ] \
  && ok "json: serial agrees" || no "json frontier.serial must equal shell serial="

# T12b — deliverable objects carry (id, phase, status, deps, text); phases
# list the boundaries in document order; generated is ISO-8601 UTC.
echo "$J" | jq -e '.deliverables | length == 7' >/dev/null \
  && ok "json: all seven own-fixture deliverables emitted" || no "expected 7 deliverables in own fixture JSON"
echo "$J" | jq -e '.deliverables[0] | .id=="6.1" and .phase==6 and .status=="done" and .deps==[] and (.text|length>0)' >/dev/null \
  && ok "json: deliverable carries id/phase/status/deps/text" || no "deliverables[0] must be 6.1 done with empty deps and text"
echo "$J" | jq -e '.deliverables[3] | .id=="6.4" and .status=="todo" and .deps==["6.1","6.3"]' >/dev/null \
  && ok "json: multi-dep deliverable splits deps into an array" || no "deliverables[3] must be 6.4 todo deps [6.1,6.3]"
echo "$J" | jq -e '.phases == [6,7]' >/dev/null \
  && ok "json: phase boundaries in document order" || no "expected .phases == [6,7]"
echo "$J" | jq -r '.generated' | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  && ok "json: generation timestamp is ISO-8601 UTC" || no ".generated must be an ISO-8601 UTC stamp"

# T12c — every marker maps to its status word (the JSON never carries emoji).
cat > "$(fx statuses)" <<'MD'
## Phase 3 — Build

- ✅ **[3.1]** A `[deps: none]`
- 🔄 **[3.2]** B `[deps: none]`
- ⬜ **[3.3]** C `[deps: none]`
- ❌ **[3.4]** D `[deps: none]`
MD
JS=$(bash "$SCRIPT" "$(fx statuses)" --json 2>/dev/null)
echo "$JS" | jq -e '[.deliverables[].status] == ["done","in_progress","todo","descoped"]' >/dev/null \
  && ok "json: markers map to done/in_progress/todo/descoped" \
  || no "status vocabulary must be done/in_progress/todo/descoped (got: $(echo "$JS" | jq -c '[.deliverables[].status]'))"

# T12d — exit-5 parity: cycle and unknown-dep fixtures fail identically
# under both output modes (same rc, same stderr — one resolver, one gate;
# unknown ID + cycle are the whole semantic MALFORMED set post-[7.6]).
for bad in cycle unknown; do
  E1=$(bash "$SCRIPT" "$(fx $bad)" 2>&1 >/dev/null); R1=$?
  E2=$(bash "$SCRIPT" "$(fx $bad)" --json 2>&1 >/dev/null); R2=$?
  if [ "$R1" -eq 5 ] && [ "$R2" -eq 5 ] && [ "$E1" = "$E2" ]; then
    ok "json: $bad fixture exits 5 identically under both output modes"
  else
    no "$bad must exit 5 with identical stderr under --json (rc $R1/$R2)"
  fi
done

# T12e — LEGACY: valid JSON, document order, EMPTY edges (never invented),
# null ids/phase, text carried (the renderer's list needs it), LEGACY
# frontier semantics intact.
JL=$(bash "$SCRIPT" "$(fx legacy)" --json 2>/dev/null); RCL=$?
[ "$RCL" -eq 0 ] && echo "$JL" | jq -e . >/dev/null 2>&1 \
  && ok "json: LEGACY fixture emits valid JSON" || no "LEGACY --json must be valid JSON (rc=$RCL)"
echo "$JL" | jq -e '.mode=="LEGACY" and .phase==null and .phases==[]
  and (.deliverables|length==3)
  and ([.deliverables[].deps]|flatten==[])
  and ([.deliverables[].id]|unique==[null])
  and (.deliverables[1].text=="Deliverable B not started")' >/dev/null \
  && ok "json: LEGACY deliverables in document order, empty deps, null ids, text carried" \
  || no "LEGACY JSON shape wrong (got: $(echo "$JL" | jq -c .))"
echo "$JL" | jq -e '.frontier.in_progress==[] and .frontier.ready==[] and .frontier.blocked==[]
  and .frontier.serial=="Deliverable B not started"' >/dev/null \
  && ok "json: LEGACY frontier semantics intact (empty sets, text serial)" \
  || no "LEGACY frontier must be empty sets with the first-⬜ text as serial"

# T12f — completed tracker: serial is null (not empty string), frontier empty.
JD=$(bash "$SCRIPT" "$(fx done)" --json 2>/dev/null)
echo "$JD" | jq -e '.frontier.serial==null and .frontier.ready==[] and .phase==null' >/dev/null \
  && ok "json: completed tracker emits null serial and empty frontier" \
  || no "completed tracker JSON must carry null serial/phase, empty ready"

# T12g — the argument grammar is designed, not improvised: only --json is
# recognized in second position; anything else refuses loud (exit 2).
OUT=$(bash "$SCRIPT" "$(fx own)" --jsno 2>&1); RC=$?
[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "unknown argument" \
  && ok "json: typo'd flag refuses loud (exit 2, named)" \
  || no "an unrecognized second argument must exit 2 naming itself (rc=$RC: $OUT)"
# Flag-first with a path refuses with an order-correcting message (the
# likeliest real-world misuse — most tools accept flag-anywhere).
OUT=$(bash "$SCRIPT" --json "$(fx own)" 2>&1); RC=$?
[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "tracker path comes first" \
  && ok "json: flag-first refuses with the order named, not 'unknown argument <path>'" \
  || no "--json <path> must exit 2 saying the path comes first (rc=$RC: $OUT)"
OUT=$(bash "$SCRIPT" --json --json 2>&1); RC=$?
[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "duplicate" \
  && ok "json: duplicate --json refuses with the right diagnosis" \
  || no "--json --json must exit 2 naming the duplication (rc=$RC: $OUT)"
# Position 3+ refuses too — the grammar has exactly two positions; an extra
# argument is never silently discarded.
OUT=$(bash "$SCRIPT" "$(fx own)" --json extra 2>&1); RC=$?
[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "unexpected argument" \
  && ok "json: a third argument refuses loud (never silently discarded)" \
  || no "<path> --json <extra> must exit 2 naming the extra (rc=$RC: $OUT)"
# A flag-shaped FIRST argument that isn't --json is a usage error (exit 2),
# not a missing tracker named '--jsno' (exit 4).
OUT=$(bash "$SCRIPT" --jsno 2>&1); RC=$?
[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "unknown argument" \
  && ok "json: flag-shaped first argument refuses as usage, not missing-tracker" \
  || no "a sole typo'd flag must exit 2 as usage (rc=$RC: $OUT)"

# T12h — jq absent: --json refuses LOUD before resolving (a silently-empty
# status.json under exit 0 is the stale-view failure class this surface
# exists to prevent); the name=value path stays jq-free and is untouched.
OUT=$(PATH=/nonexistent /bin/bash "$SCRIPT" "$(fx own)" --json 2>&1); RC=$?
[ "$RC" -eq 2 ] && echo "$OUT" | grep -qi "requires jq" \
  && ok "json: missing jq refuses loud (exit 2, dependency named) — never empty exit-0 output" \
  || no "--json without jq must exit 2 naming the dependency (rc=$RC: $OUT)"

# T12i — the post-A-001 shape of this initiative's own tracker (7 Phase-6
# deliverables, 6.5 re-pointed at 6.6, 6.7 chained behind 6.5), hand-computed:
# ready = 6.6 plus the cross-phase 7.1 ([7.6]); 6.5 and 6.7 both blocked
# with root 6.6; serial = 6.6 (first ready, document order).
cat > "$(fx own2)" <<'MD'
## Phase 6 — Plan as Data

- ✅ **[6.1]** Grammar amendment `[deps: none]`
- ✅ **[6.2]** Resolver `[deps: 6.1]`
- ✅ **[6.3]** Mutation primitive `[deps: 6.1]`
- ✅ **[6.4]** Docs sweep `[deps: 6.1, 6.3]`
- ⬜ **[6.5]** Status render `[deps: 6.6]`
- ⬜ **[6.6]** status.json emission `[deps: 6.2]`
- ⬜ **[6.7]** Self-aware regeneration `[deps: 6.5]`

## Phase 7 — Execution Surfaces

- ⬜ **[7.1]** Plumbing extraction `[deps: none]`
MD
J2=$(bash "$SCRIPT" "$(fx own2)" --json 2>/dev/null)
echo "$J2" | jq -e '.frontier.ready==["6.6","7.1"] and .frontier.serial=="6.6"
  and (.frontier.blocked|map(.id+":"+.blocked_by))==["6.5:6.6","6.7:6.6"]
  and .phases==[6,7] and (.deliverables|length==8)' >/dev/null \
  && ok "json: post-amendment own-tracker shape matches the hand-computed frontier" \
  || no "post-A-001 fixture frontier wrong (got: $(echo "$J2" | jq -c .frontier))"

# T13 — the [7.6] acceptance fixture: this initiative's own tracker with
# Phase 6 complete and Phases 7–8 open (the live shape at [7.6]'s landing,
# 7.7 already ✅). Hand-computed: ready = 7.1 7.2 7.3 7.6 (7.2's dep 6.2 is
# ✅); blocked = 7.4 and 7.5 by 7.1, every 8.x by 7.2 (transitive roots);
# phase=7 reports the first open phase; serial = 7.1.
cat > "$(fx own3)" <<'MD'
## Phase 6 — Plan as Data

- ✅ **[6.1]** Grammar amendment `[deps: none]`
- ✅ **[6.2]** Resolver `[deps: 6.1]`
- ✅ **[6.3]** Mutation primitive `[deps: 6.1]`
- ✅ **[6.4]** Docs sweep `[deps: 6.1, 6.3]`
- ✅ **[6.5]** Status render `[deps: 6.6]`
- ✅ **[6.6]** status.json emission `[deps: 6.2]`
- ✅ **[6.7]** Self-aware regeneration `[deps: 6.5]`

## Phase 7 — Execution Surfaces

- ⬜ **[7.1]** Plumbing extraction `[deps: none]`
- ⬜ **[7.2]** Entry split `[deps: 6.2]`
- ⬜ **[7.3]** Single-writer hook `[deps: none]`
- ⬜ **[7.4]** Gated merge queue `[deps: 7.1, 7.3]`
- ⬜ **[7.5]** Lane dispatch `[deps: 6.2, 7.4]`
- ⬜ **[7.6]** Cross-phase frontier `[deps: 6.2, 6.6]`
- ✅ **[7.7]** Installed test suite `[deps: none]`

## Phase 8 — Grammar, Rename, Go-Public Prep

- ⬜ **[8.1]** Routing collapse `[deps: 7.2]`
- ⬜ **[8.2]** Verb grammar `[deps: 8.1, 7.5]`
- ⬜ **[8.3]** Rename sweep `[deps: 8.2, 7.5]`
- ⬜ **[8.4]** Go-public gate `[deps: 8.3]`
MD
OUT=$(bash "$SCRIPT" "$(fx own3)" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$(val phase "$OUT")" = "7" ] \
  && ok "own3: resolves with phase=7 (first open phase, reporting)" \
  || no "own3 should resolve with phase=7 (rc=$RC: $OUT)"
[ "$(val ready "$OUT")" = "7.1 7.2 7.3 7.6" ] \
  && ok "own3: frontier spans Phases 7 AND 8 — deps-satisfied items of both listed" \
  || no "expected ready=7.1 7.2 7.3 7.6 (got: $OUT)"
[ "$(val blocked "$OUT")" = "7.4:7.1 7.5:7.1 8.1:7.2 8.2:7.2 8.3:7.2 8.4:7.2" ] \
  && ok "own3: 8.x blocked with transitive roots named" \
  || no "expected 8.x blocked by 7.2, 7.4/7.5 by 7.1 (got: $OUT)"
[ "$(val serial "$OUT")" = "7.1" ] && ok "own3: serial=7.1 (first ready, document order)" \
  || no "expected serial=7.1 (got: $OUT)"
J3=$(bash "$SCRIPT" "$(fx own3)" --json 2>/dev/null)
echo "$J3" | jq -e '.phase==7 and .frontier.ready==["7.1","7.2","7.3","7.6"]' >/dev/null \
  && ok "own3: --json agrees (cross-phase ready under both output modes)" \
  || no "own3 --json frontier wrong (got: $(echo "$J3" | jq -c .frontier))"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
