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
#   - phased mid-phase (open GRAMMAR frontier)  → resume
#   - phased complete (all ✅, empty frontier)  → start-phase (boundary/next)
#   - LEGACY tracker (token-free)               → resume
#   - task ceremony                             → task
#   - no manifest / unknown ceremony / malformed tracker → loud stop (exit 3)
#   - wrong-door --for <door> redirects (match=no, names the correct door)
#     and confirms (match=yes) when the door is right
#
# Each fixture is a standalone project dir; route.sh runs with that dir as cwd
# (the manifest, docs/, and resolver all resolve relative to it, exactly as a
# real session launches). resolve-ready.sh is invoked by the router and lives
# beside it — fixtures symlink the real .claude scripts so the router resolves
# its sibling. stderr is captured on every invocation: this suite runs under
# the empty-stderr gate (run-harness-tests.sh fails any suite that writes to
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

# ── 3. phased mid-phase: open GRAMMAR frontier → resume ───────────────────────
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
[ "$(val door "$OUT")" = "resume" ] \
  && ok "phased mid-phase (open frontier) → resume" \
  || no "phased mid-phase must route to resume (got door=$(val door "$OUT"))"

# ── 4. phased complete: all ✅, empty frontier → start-phase (boundary/next) ──
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
[ "$(val door "$OUT")" = "start-phase" ] \
  && ok "phased complete (empty frontier) → start-phase (boundary/next decision)" \
  || no "phased complete must route to start-phase (got door=$(val door "$OUT"))"

# ── 5. LEGACY tracker: token-free → resume (the LEGACY-appropriate door) ──────
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
[ "$(val door "$OUT")" = "resume" ] \
  && ok "LEGACY tracker → resume (resolver mode=LEGACY; the resume door presents the first-⬜ pick)" \
  || no "LEGACY tracker must route to resume (got door=$(val door "$OUT"))"
echo "$OUT" | grep -qi 'legacy' \
  && ok "legacy: the routing reason names the LEGACY mode (so the door knows to present a list, not a graph)" \
  || no "legacy routing should surface mode=LEGACY in its reason"

# ── 6. task ceremony → task ──────────────────────────────────────────────────
TASK=$(mkproj task); manifest "$TASK" task
run "$TASK"
[ "$(val door "$OUT")" = "task" ] \
  && ok "task ceremony → task" \
  || no "task ceremony must route to task (got door=$(val door "$OUT"))"

# ── 7. LOUD STOP (rule 15): ambiguous/unknown states never pick a door ───────
# 7a — no manifest at all.
NOMAN=$(mkproj no-manifest)  # mkproj leaves no project.json
run "$NOMAN"
[ "$RC" -eq 3 ] \
  && ok "no manifest → loud stop (exit 3), not a silent default door" \
  || no "a missing manifest must be a loud stop exit 3 (got rc=$RC, door=$(val door "$OUT"))"
[ -z "$(val door "$OUT")" ] \
  && ok "no manifest: no door is emitted (ambiguity is never papered over with a guess)" \
  || no "loud stop must not emit a door (got door=$(val door "$OUT"))"
echo "$OUT" | grep -qi 'manifest' \
  && ok "no manifest: the loud-stop reason names the missing manifest (state preserved for a person)" \
  || no "loud stop should name why it stopped (missing manifest)"

# 7b — unknown ceremony (not in the schema enum).
BADCER=$(mkproj bad-ceremony); manifest "$BADCER" zooglemorph
run "$BADCER"
[ "$RC" -eq 3 ] \
  && ok "unknown ceremony → loud stop (exit 3)" \
  || no "an unrecognized ceremony must loud-stop exit 3 (got rc=$RC, door=$(val door "$OUT"))"
[ -z "$(val door "$OUT")" ] \
  && ok "unknown ceremony: no door guessed" \
  || no "unknown ceremony must not emit a door (got door=$(val door "$OUT"))"

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
# In the mid-phase project the correct door is resume. Asking --for resume
# CONFIRMS (match=yes); asking --for start-phase REDIRECTS (match=no, names
# resume) WITHOUT erroring (exit 0 — a redirect is a route, not a failure).
run "$MID" --for resume
[ "$RC" -eq 0 ] && [ "$(val match "$OUT")" = "yes" ] \
  && ok "right-door (--for resume in a mid-phase project) confirms (match=yes, exit 0)" \
  || no "the correct door must confirm match=yes exit 0 (got rc=$RC match=$(val match "$OUT"))"

run "$MID" --for start-phase
[ "$RC" -eq 0 ] \
  && ok "wrong-door redirect does NOT error (exit 0 — a redirect is a route)" \
  || no "a wrong-door invocation must redirect, not error (got rc=$RC)"
[ "$(val match "$OUT")" = "no" ] \
  && ok "wrong-door: match=no (the invoked door does not apply here)" \
  || no "wrong-door must report match=no (got match=$(val match "$OUT"))"
[ "$(val door "$OUT")" = "resume" ] \
  && ok "wrong-door redirect NAMES the correct door (start-phase → resume)" \
  || no "wrong-door must name the correct door resume (got door=$(val door "$OUT"))"

# A wrong-door invocation in a NON-phased project also redirects rather than
# errors: invoking the phased boundary door (start-phase) in a task project is
# redirected to task.
run "$TASK" --for start-phase
[ "$RC" -eq 0 ] && [ "$(val match "$OUT")" = "no" ] && [ "$(val door "$OUT")" = "task" ] \
  && ok "wrong-door in a task project: start-phase → redirected to task (no error)" \
  || no "start-phase in a task project must redirect to task (got rc=$RC match=$(val match "$OUT") door=$(val door "$OUT"))"

# An unknown door name passed to --for is a usage error (exit 2) — the router
# knows its own door vocabulary; a typo'd door is a caller bug, not a redirect.
run "$MID" --for not-a-real-door
[ "$RC" -eq 2 ] \
  && ok "--for <unknown-door> is a usage error (exit 2), not a silent redirect" \
  || no "an unknown --for door must be a usage error exit 2 (got rc=$RC)"

# ── 9. usage ─────────────────────────────────────────────────────────────────
run "$MID" --bogus
[ "$RC" -eq 2 ] && ok "unknown flag → usage exit 2" || no "unknown flag must exit 2 (got rc=$RC)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
