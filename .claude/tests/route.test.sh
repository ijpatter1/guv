#!/bin/bash
# Tests for .claude/route.sh — the deterministic entry-door router ([8.1] of
# the plan-as-data spec, "routing collapse"). The router reads manifest
# `ceremony`, phase-docs presence, scaffold state, and the resolver's
# mode+frontier (via resolve-ready.sh) and emits which entry door applies —
# with NO user disambiguation. This is the decision table that makes
# "misroutes impossible rather than documented": an ambiguous/unknown state is
# a LOUD STOP (rule 15, exit 3), never a silent wrong door; a wrong-door
# invocation REDIRECTS (names the correct door) rather than errors.
#
# What this suite pins (the acceptance matrix, one fixture per state, asserting
# the routed door — plus the loud-stop on ambiguity and the redirect-not-error
# path):
#   - greenfield (phased, no phase docs)        → init-project
#   - onboard (ceremony=onboard)                → onboard
#   - phased mid-phase (open GRAMMAR frontier)  → next
#   - phased complete (all ✅, empty frontier)  → phase (boundary/next)
#   - LEGACY tracker (token-free)               → next
#   - task ceremony                             → task
#   - unknown ceremony / malformed tracker      → AMBIGUOUS loud stop (exit 3)
#   - no manifest (no project here yet)         → PRE-SCAFFOLD (exit 4): the
#     scaffolding doors PROCEED (they write the manifest); the live-plan doors
#     defer to them. A distinct exit code, NOT the exit-3 stop, so the canonical
#     onboard/init entry is no longer misrouted into a halt.
#   - wrong-door --for <door> redirects (match=no, names the correct door)
#     and confirms (match=yes) when the door is right
#   - --for over an AMBIGUOUS state loud-stops (exit 3, no door, no match) —
#     a redirect is not a route past genuine ambiguity
#
# Each fixture is a standalone project dir; route.sh runs with that dir as cwd
# (the manifest, docs/, and resolver all resolve relative to it, exactly as a
# real session launches). resolve-ready.sh is invoked by the router and lives
# beside it — fixtures symlink the real .claude scripts so the router resolves
# its sibling. stderr is captured on every invocation: this suite runs under
# the empty-stderr gate (run-core-tests.sh fails any suite that writes to
# stderr), so a router that loud-stops must do so via its OWN stdout contract
# (door=/reason=) and reserve stderr for genuine usage/IO errors the gate
# should catch.
# Pure bash + jq, no test runner. Run: bash .claude/tests/route.test.sh
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROUTE="$CLAUDE_DIR/route.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# val name output → the value of a name=value line (the router's stdout shape,
# matching resolve-ready.sh's name=value contract).
val() { echo "$2" | grep -E "^$1=" | head -1 | sed "s/^$1=//"; }

# mkproj <name> — a fixture project dir with a .claude/ that symlinks the real
# router + resolver (so route.sh resolves its sibling resolve-ready.sh from the
# fixture cwd). Returns the dir path on stdout.
mkproj() {
  local d="$WORK/$1"
  mkdir -p "$d/.claude" "$d/docs"
  ln -s "$ROUTE" "$d/.claude/route.sh"
  ln -s "$CLAUDE_DIR/resolve-ready.sh" "$d/.claude/resolve-ready.sh"
  printf '%s\n' "$d"
}

# manifest <dir> <ceremony> [scaffoldCheck] — write a minimal valid manifest.
manifest() {
  local d="$1" ceremony="$2" scaffold="${3:-test -f .scaffolded}"
  cat > "$d/.claude/project.json" <<JSON
{
  "name": "fx",
  "language": "node",
  "roots": { "control": ".", "code": "." },
  "commands": { "test": null },
  "scaffoldCheck": "$scaffold",
  "ceremony": "$ceremony"
}
JSON
}

# run <dir> [args…] — invoke the router from the fixture cwd, capture stdout,
# stderr, and exit code. Sets OUT / ERR / RC. stderr is captured (not leaked)
# so the suite stays under the empty-stderr gate.
run() {
  local d="$1"; shift
  local errf; errf=$(mktemp)
  OUT=$( cd "$d" && bash .claude/route.sh "$@" 2>"$errf" ); RC=$?
  ERR=$(cat "$errf"); rm -f "$errf"
}

# ── 1. greenfield: phased ceremony, no phase docs yet → init-project ─────────
GF=$(mkproj greenfield); manifest "$GF" phased
# no docs/PHASE_STATUS.md, no scaffold marker
run "$GF"
[ "$RC" -eq 0 ] && ok "greenfield: exit 0" || no "greenfield should resolve (rc=$RC; err=$ERR)"
[ "$(val door "$OUT")" = "init-project" ] \
  && ok "greenfield (phased, no phase docs) → init-project" \
  || no "greenfield must route to init-project (got door=$(val door "$OUT"))"

# ── 2. onboard ceremony → onboard ────────────────────────────────────────────
OB=$(mkproj onboard); manifest "$OB" onboard
run "$OB"
[ "$(val door "$OUT")" = "onboard" ] \
  && ok "onboard ceremony → onboard" \
  || no "onboard ceremony must route to onboard (got door=$(val door "$OUT"))"

# ── 3. phased mid-phase: open GRAMMAR frontier → next ───────────────────────
MID=$(mkproj phased-mid); manifest "$MID" phased
touch "$MID/.scaffolded"
cat > "$MID/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Build

- ✅ **[6.1]** Done `[deps: none]`
- ⬜ **[6.2]** Open `[deps: 6.1]`
MD
cp "$MID/docs/PHASE_STATUS.md" "$MID/docs/REQUIREMENTS.md"
run "$MID"
[ "$RC" -eq 0 ] && ok "phased-mid: exit 0" || no "phased-mid should resolve (rc=$RC; err=$ERR)"
[ "$(val door "$OUT")" = "next" ] \
  && ok "phased mid-phase (open frontier) → next" \
  || no "phased mid-phase must route to next (got door=$(val door "$OUT"))"

# ── 4. phased complete: all ✅, empty frontier → phase (boundary/next) ──
DONE=$(mkproj phased-complete); manifest "$DONE" phased
touch "$DONE/.scaffolded"
cat > "$DONE/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Build

- ✅ **[6.1]** Done `[deps: none]`
- ✅ **[6.2]** Also done `[deps: 6.1]`
MD
cp "$DONE/docs/PHASE_STATUS.md" "$DONE/docs/REQUIREMENTS.md"
run "$DONE"
[ "$RC" -eq 0 ] && ok "phased-complete: exit 0" || no "phased-complete should resolve (rc=$RC; err=$ERR)"
[ "$(val door "$OUT")" = "phase" ] \
  && ok "phased complete (empty frontier) → phase (boundary/next decision)" \
  || no "phased complete must route to phase (got door=$(val door "$OUT"))"

# ── 5. LEGACY tracker: token-free → next (the LEGACY-appropriate door) ──────
LEG=$(mkproj legacy); manifest "$LEG" phased
touch "$LEG/.scaffolded"
cat > "$LEG/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 1

- ⬜ First thing
- ⬜ Second thing
MD
cp "$LEG/docs/PHASE_STATUS.md" "$LEG/docs/REQUIREMENTS.md"
run "$LEG"
[ "$RC" -eq 0 ] && ok "legacy: exit 0" || no "legacy should resolve (rc=$RC; err=$ERR)"
[ "$(val door "$OUT")" = "next" ] \
  && ok "LEGACY tracker → next (resolver mode=LEGACY; the next door presents the first-⬜ pick)" \
  || no "LEGACY tracker must route to next (got door=$(val door "$OUT"))"
echo "$OUT" | grep -qi 'legacy' \
  && ok "legacy: the routing reason names the LEGACY mode (so the door knows to present a list, not a graph)" \
  || no "legacy routing should surface mode=LEGACY in its reason"

# ── 6. task ceremony → task ──────────────────────────────────────────────────
TASK=$(mkproj task); manifest "$TASK" task
run "$TASK"
[ "$(val door "$OUT")" = "task" ] \
  && ok "task ceremony → task" \
  || no "task ceremony must route to task (got door=$(val door "$OUT"))"

# ── 7. AMBIGUOUS (exit 3) vs PRE-SCAFFOLD (exit 4): two different states ──────
# Two distinct refusals, two distinct exit codes (rule 15 / the misroute fix):
#   exit 3 = AMBIGUOUS existing state (malformed plan, unknown ceremony) — a
#            genuine loud stop, no door, every door's Step 0 halts.
#   exit 4 = PRE-SCAFFOLD (no manifest here yet) — NOT a stop. The scaffolding
#            doors (init-project/onboard) are about to WRITE the manifest this
#            guard would have read, so they PROCEED; the live-plan doors
#            (next/phase/task) have nothing to resume and defer to a
#            scaffolding door. The doors key off the EXIT CODE uniformly, not
#            prose — so the canonical onboard/init entry is no longer misrouted
#            into a stop.
# 7a — no manifest at all → PRE-SCAFFOLD (exit 4), distinct from ambiguous.
NOMAN=$(mkproj no-manifest)  # mkproj leaves no project.json
run "$NOMAN"
[ "$RC" -eq 4 ] \
  && ok "no manifest → PRE-SCAFFOLD (exit 4), distinct from ambiguous exit 3" \
  || no "a missing manifest must be pre-scaffold exit 4, not exit 3 (got rc=$RC, door=$(val door "$OUT"))"
[ -z "$(val door "$OUT")" ] \
  && ok "pre-scaffold: no door is emitted (the scaffold-door choice is content-driven, not state-driven)" \
  || no "pre-scaffold must not emit a single door (got door=$(val door "$OUT"))"
echo "$OUT" | grep -qi 'manifest' \
  && ok "pre-scaffold: the reason names the missing manifest (state preserved for a person)" \
  || no "pre-scaffold should name why (missing manifest)"
echo "$OUT" | grep -qiE 'init-project|onboard|scaffold' \
  && ok "pre-scaffold: the reason points at the scaffolding doors (init-project/onboard), not 'stop'" \
  || no "pre-scaffold reason should name the scaffolding route"

# 7a' — under --for, the SCAFFOLDING doors PROCEED on a pre-scaffold repo: asking
# --for init-project / --for onboard confirms (match=yes, exit 0) — they own the
# pre-scaffold state because they are about to write the manifest.
run "$NOMAN" --for onboard
[ "$RC" -eq 0 ] && [ "$(val match "$OUT")" = "yes" ] \
  && ok "pre-scaffold + --for onboard → PROCEED (match=yes, exit 0) — the canonical fresh-onboard case is no longer a stop" \
  || no "onboard must proceed on a manifest-less repo (got rc=$RC match=$(val match "$OUT"))"
run "$NOMAN" --for init-project
[ "$RC" -eq 0 ] && [ "$(val match "$OUT")" = "yes" ] \
  && ok "pre-scaffold + --for init-project → PROCEED (match=yes, exit 0)" \
  || no "init-project must proceed on a manifest-less repo (got rc=$RC match=$(val match "$OUT"))"

# 7a'' — under --for, the LIVE-PLAN doors do NOT proceed on a pre-scaffold repo:
# resume/phase/task have nothing to resume; the router surfaces exit 4 so
# their Step 0 defers to a scaffolding door rather than running off no project.
run "$NOMAN" --for next
[ "$RC" -eq 4 ] && [ "$(val match "$OUT")" = "no" ] \
  && ok "pre-scaffold + --for next → NOT this door (exit 4, match=no) — defer to a scaffolding door" \
  || no "next must not proceed on a pre-scaffold repo (got rc=$RC match=$(val match "$OUT"))"

# 7b — unknown ceremony (not in the schema enum) → AMBIGUOUS loud stop (exit 3).
BADCER=$(mkproj bad-ceremony); manifest "$BADCER" zooglemorph
run "$BADCER"
[ "$RC" -eq 3 ] \
  && ok "unknown ceremony → AMBIGUOUS loud stop (exit 3), distinct from pre-scaffold" \
  || no "an unrecognized ceremony must loud-stop exit 3 (got rc=$RC, door=$(val door "$OUT"))"
[ -z "$(val door "$OUT")" ] \
  && ok "unknown ceremony: no door guessed" \
  || no "unknown ceremony must not emit a door (got door=$(val door "$OUT"))"
# An ambiguous existing state stays a stop even for a scaffolding door — a
# malformed/unknown manifest is NOT pre-scaffold; you must not scaffold over it.
run "$BADCER" --for onboard
[ "$RC" -eq 3 ] \
  && ok "unknown ceremony + --for onboard → still exit 3 (genuine ambiguity is not pre-scaffold; don't onboard over it)" \
  || no "onboard over an ambiguous existing manifest must stay exit 3 (got rc=$RC)"

# 7c — phased project whose tracker is MALFORMED (resolver exit 5): the router
# cannot determine mid/complete/legacy, so it loud-stops rather than guess.
MAL=$(mkproj phased-malformed); manifest "$MAL" phased
touch "$MAL/.scaffolded"
cat > "$MAL/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Build

- ⬜ **[6.1]** A `[deps: none]`
- ⬜ **[6.1]** dup id `[deps: none]`
MD
cp "$MAL/docs/PHASE_STATUS.md" "$MAL/docs/REQUIREMENTS.md"
run "$MAL"
[ "$RC" -eq 3 ] \
  && ok "phased + MALFORMED tracker → loud stop (exit 3), not a guessed door" \
  || no "a malformed tracker under phased must loud-stop exit 3 (got rc=$RC, door=$(val door "$OUT"))"
echo "$OUT" | grep -qiE 'malformed|tracker' \
  && ok "malformed: the loud-stop reason names the broken tracker" \
  || no "loud stop should name the malformed tracker"

# ── 8. WRONG-DOOR REDIRECT (not error): --for <door> confirms or redirects ───
# In the mid-phase project the correct door is next. Asking --for next
# CONFIRMS (match=yes); asking --for phase REDIRECTS (match=no, names
# resume) WITHOUT erroring (exit 0 — a redirect is a route, not a failure).
run "$MID" --for next
[ "$RC" -eq 0 ] && [ "$(val match "$OUT")" = "yes" ] \
  && ok "right-door (--for next in a mid-phase project) confirms (match=yes, exit 0)" \
  || no "the correct door must confirm match=yes exit 0 (got rc=$RC match=$(val match "$OUT"))"

run "$MID" --for phase
[ "$RC" -eq 0 ] \
  && ok "wrong-door redirect does NOT error (exit 0 — a redirect is a route)" \
  || no "a wrong-door invocation must redirect, not error (got rc=$RC)"
[ "$(val match "$OUT")" = "no" ] \
  && ok "wrong-door: match=no (the invoked door does not apply here)" \
  || no "wrong-door must report match=no (got match=$(val match "$OUT"))"
[ "$(val door "$OUT")" = "next" ] \
  && ok "wrong-door redirect NAMES the correct door (phase → next)" \
  || no "wrong-door must name the correct door next (got door=$(val door "$OUT"))"

# A wrong-door invocation in a NON-phased project also redirects rather than
# errors: invoking the phased boundary door (phase) in a task project is
# redirected to task.
run "$TASK" --for phase
[ "$RC" -eq 0 ] && [ "$(val match "$OUT")" = "no" ] && [ "$(val door "$OUT")" = "task" ] \
  && ok "wrong-door in a task project: phase → redirected to task (no error)" \
  || no "phase in a task project must redirect to task (got rc=$RC match=$(val match "$OUT") door=$(val door "$OUT"))"

# An unknown door name passed to --for is a usage error (exit 2) — the router
# knows its own door vocabulary; a typo'd door is a caller bug, not a redirect.
run "$MID" --for not-a-real-door
[ "$RC" -eq 2 ] \
  && ok "--for <unknown-door> is a usage error (exit 2), not a silent redirect" \
  || no "an unknown --for door must be a usage error exit 2 (got rc=$RC)"

# ── 8b. LOUD STOP under --for: a redirect is not a route past an AMBIGUOUS
# state. When a door asks "is this me?" against a project the router cannot
# resolve (a phased project with a MALFORMED tracker — $MAL from 7c), the answer
# is neither confirm nor redirect: it is the same exit-3 loud stop, with NO door
# and NO match, and a reason that names the state. The redirect path (exit 0)
# must not swallow genuine ambiguity into a guessed door.
run "$MAL" --for next
[ "$RC" -eq 3 ] \
  && ok "--for next against a MALFORMED-tracker project → loud stop (exit 3), not a redirect" \
  || no "--for over an ambiguous state must loud-stop exit 3, not redirect (got rc=$RC, door=$(val door "$OUT"))"
[ -z "$(val door "$OUT")" ] \
  && ok "loud-stop-under-{-}-for: no door= is emitted (ambiguity is never papered over with a redirect)" \
  || no "loud stop under --for must not emit a door (got door=$(val door "$OUT"))"
[ -z "$(val match "$OUT")" ] \
  && ok "loud-stop-under-{-}-for: no match= is emitted (there is no door to confirm or deny)" \
  || no "loud stop under --for must not emit a match verdict (got match=$(val match "$OUT"))"
echo "$OUT" | grep -qiE 'malformed|tracker' \
  && ok "loud-stop-under-{-}-for: the reason names the broken-tracker state for a person" \
  || no "loud stop under --for should name the state (malformed tracker)"

# ── 9. usage ─────────────────────────────────────────────────────────────────
run "$MID" --bogus
[ "$RC" -eq 2 ] && ok "unknown flag → usage exit 2" || no "unknown flag must exit 2 (got rc=$RC)"

# Bare --for with no door name is a usage error (the flag needs an argument).
run "$MID" --for
[ "$RC" -eq 2 ] \
  && ok "bare --for (no door) → usage exit 2 (the flag requires a door argument)" \
  || no "bare --for must be a usage error exit 2 (got rc=$RC)"

# A trailing extra argument after --for <door> is a usage error (the grammar has
# exactly two positions; an extra is a caller bug, not silently ignored).
run "$MID" --for next extra-arg
[ "$RC" -eq 2 ] \
  && ok "--for next <extra-arg> → usage exit 2 (no trailing positionals)" \
  || no "an extra argument after --for <door> must be a usage error exit 2 (got rc=$RC)"

# ── 10. BOUNDARY: first entry to a freshly-planned phase → phase ([23.1]) ─────
# The first misroute: the router read a populated-but-UNSTARTED phase as a
# mid-phase resume. A Current Phase with an open GRAMMAR frontier but ZERO started
# (✅/🔄) deliverables is a BOUNDARY — you just crossed into it — and the boundary
# door (phase) runs the spec-alignment + deep-architecture + UAT ritual the light
# door (next) skips. Before the fix this returned door=next, sending the boundary
# ritual to the door that drops it. Fixture: Phase 6 fully ✅ (done), Phase 7 all
# ⬜ (freshly planned) — the resolver reports phase=7, open frontier, zero ✅/🔄 in 7.
BND=$(mkproj phased-boundary); manifest "$BND" phased
touch "$BND/.scaffolded"
cat > "$BND/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Build

- ✅ **[6.1]** Done `[deps: none]`
- ✅ **[6.2]** Done `[deps: 6.1]`

## Phase 7 — Harden

- ⬜ **[7.1]** Fresh `[deps: none]`
- ⬜ **[7.2]** Fresh `[deps: 7.1]`
MD
cp "$BND/docs/PHASE_STATUS.md" "$BND/docs/REQUIREMENTS.md"
run "$BND"
[ "$RC" -eq 0 ] && ok "boundary: exit 0" || no "boundary should resolve (rc=$RC; err=$ERR)"
[ "$(val door "$OUT")" = "phase" ] \
  && ok "first entry to a freshly-planned phase (open frontier, zero ✅/🔄 in Current Phase) → phase" \
  || no "a boundary (zero-started Current Phase) must route to phase, not the light door (got door=$(val door "$OUT"))"
# The reason must distinguish this from the empty-frontier→phase path: it is a
# boundary BECAUSE the phase is unstarted, not because the initiative is complete.
echo "$OUT" | grep -qiE 'boundary|first entry|unstarted|zero' \
  && ok "boundary: the reason names the first-entry/boundary state (not 'every deliverable ✅')" \
  || no "boundary reason should explain the first-entry state (got: $(val reason "$OUT"))"

# 10b — at a boundary, --for phase CONFIRMS (this IS the right door).
run "$BND" --for phase
[ "$RC" -eq 0 ] && [ "$(val match "$OUT")" = "yes" ] \
  && ok "boundary + --for phase → confirm (match=yes) — the boundary door is correct here" \
  || no "the boundary door (phase) must confirm at a boundary (got rc=$RC match=$(val match "$OUT"))"

# 10c — at a boundary, --for next REDIRECTS to phase (the light door is wrong on
# first entry — it would skip the spec-alignment ritual). Redirect, not error.
run "$BND" --for next
[ "$RC" -eq 0 ] && [ "$(val match "$OUT")" = "no" ] && [ "$(val door "$OUT")" = "phase" ] \
  && ok "boundary + --for next → redirect to phase (the light door skips the boundary ritual)" \
  || no "next at a boundary must redirect to phase (got rc=$RC match=$(val match "$OUT") door=$(val door "$OUT"))"

# 10d — GUARD: a 🔄 in the Current Phase is WORK UNDERWAY, not a boundary → next.
# Pins that 'started' counts 🔄 too, not only ✅ — a phase with an in-progress
# deliverable is mid-phase even with no ✅ yet.
INPROG=$(mkproj phased-inprogress); manifest "$INPROG" phased
touch "$INPROG/.scaffolded"
cat > "$INPROG/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 7 — Harden

- 🔄 **[7.1]** Underway `[deps: none]`
- ⬜ **[7.2]** Fresh `[deps: 7.1]`
MD
cp "$INPROG/docs/PHASE_STATUS.md" "$INPROG/docs/REQUIREMENTS.md"
run "$INPROG"
[ "$(val door "$OUT")" = "next" ] \
  && ok "a 🔄 in the Current Phase is mid-phase (work underway) → next, not a boundary" \
  || no "a phase with an in-progress 🔄 must route to next (got door=$(val door "$OUT"))"

# ── 11. UNAUTHORED GREENFIELD: placeholder-only tracker → init-project ([23.1]) ─
# The second misroute, same root cause: a skeleton scaffold writes docs/PHASE_STATUS.md
# FIRST (so the `! -f` greenfield probe does not fire), seeded with verbatim
# `- ⬜ [Deliverable N …]` stubs that init-project/plan overwrite. A tracker that
# carries ONLY those stubs is UNAUTHORED — still greenfield ([19.1] placeholder-as-
# unauthored) — and the door that AUTHORS the plan is init-project. Before the fix
# the resolver read the ⬜ stubs as an open frontier and the router said door=next.
UNAUTH=$(mkproj phased-unauthored); manifest "$UNAUTH" phased
touch "$UNAUTH/.scaffolded"
cat > "$UNAUTH/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 1 — TBD

- ⬜ [Deliverable 1 — first thing the plan will author]
- ⬜ [Deliverable 2 — second thing]
MD
cp "$UNAUTH/docs/PHASE_STATUS.md" "$UNAUTH/docs/REQUIREMENTS.md"
run "$UNAUTH"
[ "$RC" -eq 0 ] && ok "unauthored: exit 0" || no "unauthored should resolve (rc=$RC; err=$ERR)"
[ "$(val door "$OUT")" = "init-project" ] \
  && ok "a placeholder-only (unauthored) tracker is greenfield → init-project, not next" \
  || no "an unauthored placeholder tracker must route to init-project (got door=$(val door "$OUT"))"
echo "$OUT" | grep -qiE 'placeholder|unauthored|greenfield' \
  && ok "unauthored: the reason names the placeholder/unauthored state" \
  || no "unauthored reason should explain the placeholder state (got: $(val reason "$OUT"))"

# 11b — under --for, init-project CONFIRMS on a placeholder tracker (it owns the
# author-the-plan job); next REDIRECTS to init-project.
run "$UNAUTH" --for init-project
[ "$RC" -eq 0 ] && [ "$(val match "$OUT")" = "yes" ] \
  && ok "unauthored + --for init-project → confirm (match=yes) — init-project authors the plan" \
  || no "init-project must confirm on an unauthored tracker (got rc=$RC match=$(val match "$OUT"))"
run "$UNAUTH" --for next
[ "$RC" -eq 0 ] && [ "$(val match "$OUT")" = "no" ] && [ "$(val door "$OUT")" = "init-project" ] \
  && ok "unauthored + --for next → redirect to init-project (nothing authored to resume)" \
  || no "next on an unauthored tracker must redirect to init-project (got rc=$RC match=$(val match "$OUT") door=$(val door "$OUT"))"

# 11c — GUARD: an AUTHORED tracker whose prose merely contains the word
# "Deliverable" (not the verbatim `[Deliverable N` stub) is NOT a placeholder —
# it routes by its real frontier (here: a started ✅ → mid-phase → next), never
# hijacked to init-project. This is the exact false-positive the placeholder regex
# guards against (the literal bracket is required).
NOTPH=$(mkproj phased-deliverable-prose); manifest "$NOTPH" phased
touch "$NOTPH/.scaffolded"
cat > "$NOTPH/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Build

- ✅ **[6.1]** Deliverable registry loader `[deps: none]`
- ⬜ **[6.2]** Deliverable diff renderer `[deps: 6.1]`
MD
cp "$NOTPH/docs/PHASE_STATUS.md" "$NOTPH/docs/REQUIREMENTS.md"
run "$NOTPH"
[ "$(val door "$OUT")" = "next" ] \
  && ok "authored prose containing 'Deliverable' is NOT a placeholder → routes by frontier (next), not init-project" \
  || no "an authored tracker must not be misread as a placeholder greenfield (got door=$(val door "$OUT"))"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
