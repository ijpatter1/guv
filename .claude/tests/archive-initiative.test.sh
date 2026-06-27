#!/bin/bash
# Tests for .claude/archive-initiative.sh — the scriptable half of initiative
# archival (used by /plan; the judgment half lives in the command).
# Pure bash + git, no test runner required (this template repo ships no JS suite).
# Run: bash .claude/tests/archive-initiative.test.sh
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/archive-initiative.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# A control plane with a tracker. $1 = "complete" | "incomplete" | "none".
make_project() {
  local p="$WORK/proj" mode="$1"
  rm -rf "$p"
  mkdir -p "$p/docs/sessions" "$p/docs/spec"
  echo "# handoff" > "$p/docs/sessions/session-2026-06-10-001.md"
  echo "# spec" > "$p/docs/spec/old-spec.md"
  echo "# arch" > "$p/docs/ARCHITECTURE.md"
  [ "$mode" = "none" ] && { echo "$p"; return; }
  echo "# reqs" > "$p/docs/REQUIREMENTS.md"
  if [ "$mode" = "complete" ]; then
    cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 5 — Wrap-up**

## Phase 4 — Build

- ✅ Deliverable A (2026-06-01, session-2026-06-01-001)
- ✅ Deliverable B

## Phase 5 — Wrap-up

- ✅ Deliverable C
MD
  else
    cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 5 — Wrap-up**

## Phase 4 — Build

- ✅ Deliverable A

## Phase 5 — Wrap-up

- 🔄 Deliverable B still going
- ⬜ Deliverable C not started
MD
  fi
  echo "$p"
}
run() { ( cd "$1" && shift && bash "$SCRIPT" "$@" ) 2>&1; }

# T1 — --check on a fully-✅ tracker: exit 0, reports COMPLETE and max_phase.
P=$(make_project complete)
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 0 ] && ok "check complete: exit 0" || no "check complete should exit 0 (rc=$RC: $OUT)"
echo "$OUT" | grep -q "status=COMPLETE" && ok "check complete: status=COMPLETE" || no "expected status=COMPLETE (got: $OUT)"
echo "$OUT" | grep -q "max_phase=5" && ok "check complete: max_phase=5" || no "expected max_phase=5 (got: $OUT)"

# T2 — --check with incomplete deliverables: exit 3, names each incomplete item.
P=$(make_project incomplete)
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 3 ] && ok "check incomplete: exit 3" || no "check incomplete should exit 3 (rc=$RC)"
echo "$OUT" | grep -q "Deliverable B still going" && echo "$OUT" | grep -q "Deliverable C not started" \
  && ok "check incomplete: names the incomplete items" \
  || no "should name every incomplete item (got: $OUT)"

# T3 — --check with no tracker at all: exit 4 (fresh project, nothing to archive).
P=$(make_project none)
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 4 ] && ok "check no-tracker: exit 4" || no "no tracker should exit 4 (rc=$RC: $OUT)"

# T3b — --check on a freshly-scaffolded tracker: exit 4 NONE, not INCOMPLETE.
# The scaffold seeds docs/PHASE_STATUS.md with verbatim placeholder deliverables
# (`- ⬜ [Deliverable N …]` stubs that /init-project and /plan overwrite). On the
# single most common path — fresh onboard → first /plan — /plan Step 1's --check
# must read a placeholder-ONLY tracker as "no real initiative, nothing to archive,
# number from 1" (NONE/exit 4), NOT INCOMPLETE off the placeholder ⬜s, which would
# refuse a first-time user's first plan ([19.1]). The fixture below is a near-verbatim
# copy of the shipped scaffold skeleton shell/docs/PHASE_STATUS.md (the file
# scaffold-shell.sh copies into a fresh project's docs/) — legend comment and `---`
# separators included — so it exercises the real on-disk form --check sees on the
# fresh-onboard path, not a hand-typed approximation. (Near-, not byte-: the formatter
# normalizes the legend comment's one trailing-whitespace line; that line is inside an
# HTML comment and matches no marker/grammar regex, so it cannot affect the exit code —
# every load-bearing line is exact.) The legend's in-comment ✅/⬜
# glyphs (indented prose, no leading `- `) also prove marker_lines does not miscount
# status emoji inside HTML comments. T2 (real LEGACY prose deliverables —
# `Deliverable C not started`, no bracket) is the companion guard: a genuine
# deliverable is never mistaken for a placeholder, so it still reads INCOMPLETE.
# The discriminator is the verbatim `[Deliverable N` stub, not the word.
P=$(make_project none)
echo "# reqs" > "$P/docs/REQUIREMENTS.md"
cat > "$P/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 1 — [Phase Name]**
> Last updated: YYYY-MM-DD, session-YYYY-MM-DD-NNN (update with actual date and session reference)

---

<!-- Copy deliverables from REQUIREMENTS.md verbatim. Use these status indicators:
     ✅ complete (add date and session reference)
     🔄 in progress
     ⬜ not started
     ❌ blocked (note what it's blocked on)

     Never remove or reorder deliverables — the list must match REQUIREMENTS.md exactly. -->

## Phase 1 — [Phase Name]

*Goal: [Copy from REQUIREMENTS.md]*

- ⬜ [Deliverable 1 — exact wording from REQUIREMENTS.md]
- ⬜ [Deliverable 2]
- ⬜ [Deliverable 3]

---

## Phase 2 — [Phase Name]

*Goal: [Copy from REQUIREMENTS.md]*

- ⬜ [Deliverable 1]
- ⬜ [Deliverable 2]

---

<!-- Add remaining phases, matching REQUIREMENTS.md exactly -->
MD
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 4 ] && ok "check fresh-scaffold placeholders: exit 4 NONE (not INCOMPLETE off the stubs)" \
  || no "a placeholder-only tracker should read NONE/exit 4, not INCOMPLETE (rc=$RC: $OUT)"
echo "$OUT" | grep -q "status=NONE" && ok "check fresh-scaffold placeholders: status=NONE" \
  || no "expected status=NONE for a placeholder-only tracker (got: $OUT)"

# T4 — --archive on a complete project: pair moved to docs/initiatives/001-<name>/,
# ARCHITECTURE snapshot COPIED (original stays), sessions + spec untouched.
P=$(make_project complete)
OUT=$(run "$P" --archive greenfield); RC=$?
[ "$RC" -eq 0 ] && ok "archive: exit 0" || no "archive should exit 0 (rc=$RC: $OUT)"
A="$P/docs/initiatives/001-greenfield"
[ -f "$A/REQUIREMENTS.md" ] && [ -f "$A/PHASE_STATUS.md" ] \
  && ok "archive: pair moved into 001-greenfield/" || no "pair should be in $A"
[ ! -f "$P/docs/REQUIREMENTS.md" ] && [ ! -f "$P/docs/PHASE_STATUS.md" ] \
  && ok "archive: top-level pair gone" || no "top-level REQUIREMENTS/PHASE_STATUS should be moved away"
[ -f "$P/docs/ARCHITECTURE.md" ] && [ -f "$A/ARCHITECTURE.md" ] \
  && ok "archive: ARCHITECTURE snapshot copied, original kept" \
  || no "ARCHITECTURE should be snapshot-copied, original kept"
[ -f "$P/docs/sessions/session-2026-06-10-001.md" ] && [ -f "$P/docs/spec/old-spec.md" ] \
  && ok "archive: sessions/ and spec/ untouched" || no "sessions and spec must never be archived"
echo "$OUT" | grep -q "phase_range=4-5" && ok "archive: reports phase_range=4-5" \
  || no "expected phase_range=4-5 (got: $OUT)"

# T5 — --archive refuses on incomplete (exit 3) unless --force; --force archives
# and stamps the abandonment note into the archived tracker.
P=$(make_project incomplete)
OUT=$(run "$P" --archive attempt); RC=$?
[ "$RC" -eq 3 ] && ok "archive incomplete: refuses (exit 3)" || no "should refuse without --force (rc=$RC)"
[ -f "$P/docs/PHASE_STATUS.md" ] && ok "archive incomplete: tracker left in place" || no "refusal must not move files"
OUT=$(run "$P" --archive attempt --force); RC=$?
[ "$RC" -eq 0 ] && ok "archive --force: exit 0" || no "--force should archive (rc=$RC: $OUT)"
grep -q "ABANDONED" "$P/docs/initiatives/001-attempt/PHASE_STATUS.md" 2>/dev/null \
  && ok "archive --force: abandonment noted in archived tracker" \
  || no "archived tracker should carry the ABANDONED note"

# T6 — NNN increments: second archive lands in 002-<name>/.
P=$(make_project complete)
run "$P" --archive first >/dev/null
cp "$P/docs/initiatives/001-first/REQUIREMENTS.md" "$P/docs/REQUIREMENTS.md"
cp "$P/docs/initiatives/001-first/PHASE_STATUS.md" "$P/docs/PHASE_STATUS.md"
run "$P" --archive second >/dev/null
[ -d "$P/docs/initiatives/002-second" ] && ok "archive: index increments to 002" \
  || no "second archive should land in 002-second/"

# T7 — name slugging: spaces/case normalize to kebab-case.
P=$(make_project complete)
OUT=$(run "$P" --archive "Native Alignment")
[ -d "$P/docs/initiatives/001-native-alignment" ] && ok "archive: name slugged to kebab-case" \
  || no "expected 001-native-alignment (got: $OUT)"

# T8 — malformed tracker (no marker bullets / no phase headers) fails loud
# (exit 5) from both --check and --archive; nothing reads as COMPLETE.
P=$(make_project complete)
printf '# Phase Status Tracker\n\njust prose, no deliverable bullets\n' > "$P/docs/PHASE_STATUS.md"
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "MALFORMED" \
  && ok "check malformed: exit 5, named" || no "malformed tracker must not read as COMPLETE (rc=$RC: $OUT)"
OUT=$(run "$P" --archive x); RC=$?
[ "$RC" -eq 5 ] && [ -f "$P/docs/PHASE_STATUS.md" ] \
  && ok "archive malformed: refuses, files in place" || no "archive should refuse a malformed tracker (rc=$RC)"
# ...and each OR-branch alone: bullets without phase headers, headers without bullets.
P=$(make_project complete)
printf '# Tracker\n### Milestone 1\n- ✅ Deliverable A\n' > "$P/docs/PHASE_STATUS.md"
run "$P" --check >/dev/null 2>&1; [ $? -eq 5 ] \
  && ok "check malformed: bullets but no '## Phase N' headers → exit 5" \
  || no "missing phase headers should be MALFORMED"
P=$(make_project complete)
printf '# Tracker\n## Phase 2 — Build\nno bullets here\n' > "$P/docs/PHASE_STATUS.md"
run "$P" --check >/dev/null 2>&1; [ $? -eq 5 ] \
  && ok "check malformed: headers but zero marker bullets → exit 5" \
  || no "zero marker bullets should be MALFORMED"

# T9 — numbering is max+1, not count+1: with 001- and 003- present (a gap,
# e.g. after a manual deletion), the next archive is 004 — a frozen archive's
# index is never re-issued, so it can never be merged into.
P=$(make_project complete)
mkdir -p "$P/docs/initiatives/001-a" "$P/docs/initiatives/003-b"
echo frozen > "$P/docs/initiatives/003-b/PHASE_STATUS.md"
OUT=$(run "$P" --archive c); RC=$?
[ -d "$P/docs/initiatives/004-c" ] && ok "archive: index is max+1 across gaps (004)" \
  || no "expected 004-c with a 001/003 gap (got: $OUT)"
grep -q frozen "$P/docs/initiatives/003-b/PHASE_STATUS.md" \
  && ok "archive: frozen archive untouched" || no "existing archives must never be modified"

# T10 — leading-zero indices don't octal-trap the arithmetic: 009 → 010.
P=$(make_project complete)
mkdir -p "$P/docs/initiatives/009-old"
OUT=$(run "$P" --archive next); RC=$?
[ -d "$P/docs/initiatives/010-next" ] && ok "archive: 009 + 1 = 010 (no octal parse)" \
  || no "expected 010-next after 009 (rc=$RC: $OUT)"

# T11 — usage errors exit 2: no subcommand, --archive without a name, and a
# name that slugs to empty.
P=$(make_project complete)
run "$P" >/dev/null 2>&1; [ $? -eq 2 ] && ok "usage: no subcommand → exit 2" || no "no subcommand should exit 2"
run "$P" --archive >/dev/null 2>&1; [ $? -eq 2 ] && ok "usage: --archive without name → exit 2" || no "missing name should exit 2"
run "$P" --archive '!!!' >/dev/null 2>&1; [ $? -eq 2 ] && ok "usage: name slugging to empty → exit 2" || no "empty slug should exit 2"

# ── Tracker grammar validation (the phase-docs skill defines the grammar:
# leading **[N.M]** ID, trailing `[deps: …]` token, mandatory `none`).
# The script validates well-formedness only — dep SEMANTICS (unknown IDs,
# cycles) belong to the resolver, not here.

# Writes a grammar-mode tracker into an existing project. $1 = variant.
write_grammar_tracker() {
  local p="$1" variant="$2"
  case "$variant" in
    complete) cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 6 — Plan as Data**

## Phase 6 — Plan as Data

- ✅ **[6.1]** Tracker grammar amendment `[deps: none]` (2026-06-12, session-2026-06-12-001)
- ✅ **[6.2]** Ready-frontier resolver `[deps: 6.1]`
- ✅ **[6.3]** Plan-mutation primitive `[deps: 6.1, 6.2]`
MD
    ;;
    incomplete) cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 6 — Plan as Data**

## Phase 6 — Plan as Data

- ✅ **[6.1]** Tracker grammar amendment `[deps: none]`
- 🔄 **[6.2]** Ready-frontier resolver `[deps: 6.1]`
- ⬜ **[6.3]** Plan-mutation primitive `[deps: 6.1, 6.2]`
MD
    ;;
    dup-id) cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Plan as Data

- ✅ **[6.1]** Tracker grammar amendment `[deps: none]`
- ⬜ **[6.1]** Ready-frontier resolver `[deps: 6.1]`
MD
    ;;
    missing-token) cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Plan as Data

- ✅ **[6.1]** Tracker grammar amendment `[deps: none]`
- ⬜ **[6.2]** Ready-frontier resolver
MD
    ;;
    malformed-token) cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Plan as Data

- ✅ **[6.1]** Tracker grammar amendment `[deps: ]`
- ⬜ **[6.2]** Ready-frontier resolver `[deps: 6.1]`
MD
    ;;
    unbackticked-token) cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Plan as Data

- ✅ **[6.1]** Tracker grammar amendment [deps: none]
- ⬜ **[6.2]** Ready-frontier resolver `[deps: 6.1]`
MD
    ;;
    token-no-id) cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Plan as Data

- ✅ **[6.1]** Tracker grammar amendment `[deps: none]`
- ⬜ Ready-frontier resolver `[deps: 6.1]`
MD
    ;;
    misplaced-id) cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Plan as Data

- ✅ **[6.1]** Tracker grammar amendment `[deps: none]`
- ⬜ Ready-frontier resolver **[6.2]** mid-wording `[deps: 6.1]`
MD
    ;;
    masked-token) cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Plan as Data

- ✅ **[6.1]** Tracker grammar amendment `[deps: none]`
- ⬜ **[6.2]** Resolver quoting a `[deps: 6.1]` example then malformed `[deps: ]`
MD
    ;;
    cross-ref) cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Plan as Data

- ✅ **[6.1]** Tracker grammar amendment `[deps: none]`
- ⬜ **[6.2]** Resolver building on **[6.1]** and its `[deps: 6.1]` example, for real `[deps: 6.1]`
MD
    ;;
    nospace-sep) cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Plan as Data

- ✅ **[6.1]** Tracker grammar amendment `[deps: none]`
- ✅ **[6.2]** Ready-frontier resolver `[deps: 6.1]`
- ⬜ **[6.3]** Plan-mutation primitive `[deps: 6.1,6.2]`
MD
    ;;
    legacy-cross-ref) cat > "$p/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 5 — Wrap-up

- ✅ Deliverable A, building on **[4.2]** from the prior phase
- ✅ Deliverable B quoting a [deps: discussion in prose
MD
    ;;
  esac
}

# T12 — a fixture tracker in the new grammar passes --check: the marker greps
# tolerate IDs and deps tokens, complete reads COMPLETE, incomplete names items.
P=$(make_project complete); write_grammar_tracker "$P" complete
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 0 ] && ok "grammar check complete: exit 0" || no "grammar tracker should pass --check (rc=$RC: $OUT)"
echo "$OUT" | grep -q "status=COMPLETE" && echo "$OUT" | grep -q "max_phase=6" \
  && ok "grammar check complete: COMPLETE, max_phase=6" || no "expected COMPLETE max_phase=6 (got: $OUT)"
P=$(make_project complete); write_grammar_tracker "$P" incomplete
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 3 ] && echo "$OUT" | grep -q '\[6.2\]' && echo "$OUT" | grep -q '\[6.3\]' \
  && ok "grammar check incomplete: exit 3, names ID'd items" \
  || no "incomplete grammar tracker should exit 3 naming items (rc=$RC: $OUT)"

# T13 — duplicate deliverable IDs are MALFORMED (exit 5), the duplicate named,
# from both --check and --archive; refusal moves nothing.
P=$(make_project complete); write_grammar_tracker "$P" dup-id
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "MALFORMED" && echo "$OUT" | grep -q '\[6.1\]' \
  && ok "grammar dup-id: --check exit 5, duplicate named" \
  || no "duplicate ID should be MALFORMED with the ID named (rc=$RC: $OUT)"
OUT=$(run "$P" --archive x); RC=$?
[ "$RC" -eq 5 ] && [ -f "$P/docs/PHASE_STATUS.md" ] \
  && ok "grammar dup-id: --archive refuses, files in place" \
  || no "--archive should refuse a duplicate-ID tracker (rc=$RC)"

# T14 — an ID'd tracker with a token-free line is MALFORMED (exit 5) and the
# offending line is named: mandatory `[deps: none]` — a forgotten annotation
# must fail loud, not read as no-deps.
P=$(make_project complete); write_grammar_tracker "$P" missing-token
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "MALFORMED" && echo "$OUT" | grep -q "Ready-frontier resolver" \
  && ok "grammar missing-token: exit 5, offending line named" \
  || no "missing deps token should be MALFORMED naming the line (rc=$RC: $OUT)"

# T15 — malformed tokens are MALFORMED (exit 5) with the offender named:
# empty deps list, a token without the backticks the grammar mandates, and a
# comma-only separator (the grammar pins comma-space exactly).
P=$(make_project complete); write_grammar_tracker "$P" malformed-token
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "Tracker grammar amendment" \
  && ok "grammar malformed-token (empty deps): exit 5, offender named" \
  || no "empty deps list should be MALFORMED naming the line (rc=$RC: $OUT)"
P=$(make_project complete); write_grammar_tracker "$P" unbackticked-token
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "Tracker grammar amendment" \
  && ok "grammar unbackticked token: exit 5, offender named" \
  || no "unbackticked deps token should be MALFORMED naming the line (rc=$RC: $OUT)"
P=$(make_project complete); write_grammar_tracker "$P" nospace-sep
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "Plan-mutation primitive" \
  && ok "grammar comma-only separator: exit 5, offender named" \
  || no "a comma-only separator should be MALFORMED (rc=$RC: $OUT)"

# T15b — mixing is MALFORMED in both directions: a deps token on a line with
# no ID (exit 5), and an ID not in lead position (exit 5).
P=$(make_project complete); write_grammar_tracker "$P" token-no-id
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 5 ] && ok "grammar token-without-ID line: exit 5" \
  || no "a token'd line with no leading ID should be MALFORMED (rc=$RC: $OUT)"
P=$(make_project complete); write_grammar_tracker "$P" misplaced-id
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "misplaced" \
  && ok "grammar misplaced ID: exit 5, named as misplaced" \
  || no "an ID not in lead position should be MALFORMED (rc=$RC: $OUT)"

# T15c — position discipline: the deliverable's own token is the LAST
# deps-shaped construct on the line, so a well-formed example quoted in the
# wording neither masks a malformed real token (exit 5) nor false-fails a
# valid line; a bold cross-reference mid-wording is not a duplicate ID.
P=$(make_project complete); write_grammar_tracker "$P" masked-token
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "Resolver quoting" \
  && ok "grammar masked malformed token: exit 5 despite valid example earlier, offender named" \
  || no "a valid example must not mask a malformed trailing token (rc=$RC: $OUT)"
P=$(make_project complete); write_grammar_tracker "$P" cross-ref
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 3 ] && ok "grammar cross-ref + example: valid line passes (exit 3, incomplete)" \
  || no "**[6.1]** cross-ref and quoted example must not false-fail (rc=$RC: $OUT)"

# T16 — LEGACY: a token-free tracker parses exactly as today — grammar
# validation must not fire at all (T1/T2 are the behavioral baseline; this
# pins the exact --check output).
P=$(make_project complete)
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "status=COMPLETE
max_phase=5" ] && ok "LEGACY tracker: byte-exact --check output unchanged" \
  || no "token-free tracker must parse exactly as today (rc=$RC: $OUT)"
# ...and the LEGACY gate is position-aware: a bold cross-reference or a stray
# "[deps:" substring in legacy prose must not flip the tracker into grammar
# mode (a mid-wording bold ref is a cross-reference, not an ID).
P=$(make_project complete); write_grammar_tracker "$P" legacy-cross-ref
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "status=COMPLETE" \
  && ok "LEGACY tracker with cross-ref + [deps: prose: still LEGACY, exit 0" \
  || no "legacy prose must not trigger grammar mode (rc=$RC: $OUT)"

# T17 — a complete grammar tracker archives normally: tokens flow through
# verbatim into the frozen copy.
P=$(make_project complete); write_grammar_tracker "$P" complete
OUT=$(run "$P" --archive plan-as-data); RC=$?
[ "$RC" -eq 0 ] && grep -q '`\[deps: 6.1, 6.2\]`' "$P/docs/initiatives/001-plan-as-data/PHASE_STATUS.md" \
  && ok "grammar archive: exit 0, tokens frozen verbatim" \
  || no "grammar tracker should archive with tokens intact (rc=$RC: $OUT)"

# ── Spike-gated lone-deliverable phase ([15.7] completion-oracle reconcile) ──
# The engine's phase_completed treats a phase whose *single* deliverable is ✅/❌
# as "open until SEALED" — sealed by an explicit `phase-close [N]` amendment
# record. archive-initiative is a SIBLING completion oracle reasoning at the
# initiative level; it must agree. A lone-deliverable FINAL phase that is ✅ but
# NOT sealed has zero open-marker lines, so the old incomplete_lines() check read
# it as COMPLETE/archivable — exactly the stranding the carve exists to prevent,
# reachable through the archive door. These pin: unsealed lone phase → INCOMPLETE
# (not archivable); after a phase-close seal record → COMPLETE (archivable).
# Writes a tracker whose FINAL phase holds a single ✅ deliverable. $2 = sealed?
write_lone_phase_tracker() {
  local p="$1" sealed="$2"
  local seal=""
  [ "$sealed" = "sealed" ] && seal='> - 2026-06-19 — phase-close [7] (session-2026-06-19-001) — lone-deliverable phase sealed'
  cat > "$p/docs/PHASE_STATUS.md" <<MD
# Phase Status Tracker

> **Current Phase: 7 — Spike**
>
> **Amendments:**
$seal

## Phase 6 — Plan as Data

- ✅ **[6.1]** Tracker grammar amendment \`[deps: none]\`
- ✅ **[6.2]** Ready-frontier resolver \`[deps: 6.1]\`

## Phase 7 — Spike

- ✅ **[7.1]** Gating spike — gates the rest of Phase 7 \`[deps: none]\`
MD
}

# T18 — a lone-deliverable FINAL phase that is ✅ but UNSEALED is NOT COMPLETE:
# --check exits 3 (INCOMPLETE) naming the unsealed lone phase, and --archive
# refuses (exit 3) leaving the files in place. This is the RED case the fix
# closes — before the fix, zero open-marker lines read as COMPLETE/archivable.
P=$(make_project complete); write_lone_phase_tracker "$P" unsealed
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 3 ] && echo "$OUT" | grep -q "status=INCOMPLETE" && echo "$OUT" | grep -q "Phase 7" \
  && ok "lone unsealed phase: --check exit 3 INCOMPLETE, names the unsealed phase" \
  || no "an unsealed lone-deliverable phase must read INCOMPLETE, not COMPLETE (rc=$RC: $OUT)"
OUT=$(run "$P" --archive spike); RC=$?
[ "$RC" -eq 3 ] && [ -f "$P/docs/PHASE_STATUS.md" ] \
  && ok "lone unsealed phase: --archive refuses (exit 3), files in place" \
  || no "--archive should refuse an unsealed lone-deliverable phase (rc=$RC: $OUT)"

# T19 — once the lone phase carries an explicit phase-close seal record, both
# oracles agree it is done: --check exits 0 COMPLETE, --archive succeeds. This
# mirrors the engine's phase_sealed predicate exactly (a phase-close [N] record).
P=$(make_project complete); write_lone_phase_tracker "$P" sealed
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "status=COMPLETE" && echo "$OUT" | grep -q "max_phase=7" \
  && ok "lone sealed phase: --check exit 0 COMPLETE (seal record honored)" \
  || no "a SEALED lone-deliverable phase must read COMPLETE (rc=$RC: $OUT)"
OUT=$(run "$P" --archive spike); RC=$?
[ "$RC" -eq 0 ] && [ -f "$P/docs/initiatives/001-spike/PHASE_STATUS.md" ] \
  && ok "lone sealed phase: --archive succeeds (exit 0)" \
  || no "a SEALED lone-deliverable phase should archive (rc=$RC: $OUT)"

# T20 — a lone-deliverable phase that is NOT the final phase but still ✅/unsealed
# is equally open: a mid-tracker lone-spike phase blocks the initiative-COMPLETE
# determination just as the engine keeps it mutable. (Phase 6 lone+unsealed, with
# a later multi-deliverable phase fully done.)
P=$(make_project complete)
cat > "$P/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 8 — Wrap**

## Phase 6 — Spike

- ✅ **[6.1]** Gating spike `[deps: none]`

## Phase 8 — Wrap

- ✅ **[8.1]** Thing one `[deps: none]`
- ✅ **[8.2]** Thing two `[deps: 8.1]`
MD
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 3 ] && echo "$OUT" | grep -q "Phase 6" \
  && ok "lone unsealed non-final phase: INCOMPLETE, names the lone phase" \
  || no "a mid-tracker lone unsealed phase must block COMPLETE (rc=$RC: $OUT)"

# T21 — a lone-deliverable phase that is ❌ (descoped) and unsealed is likewise
# open: the engine's phase_completed treats a lone ❌/unsealed phase as not-done.
# ❌ is TERMINAL on its own ([23.3]) — it does NOT count as incomplete — so this
# phase is INCOMPLETE purely because it is a lone-deliverable phase awaiting its
# phase-close seal (the [15.7] carve), caught by unsealed_lone_phases(), exactly as
# a lone-✅ unsealed phase is. Pinned so the carve still flags a lone ❌ as open.
P=$(make_project complete)
cat > "$P/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 7 — Spike**

## Phase 6 — Plan

- ✅ **[6.1]** Thing `[deps: none]`

## Phase 7 — Spike

- ❌ **[7.1]** Abandoned spike (descoped 2026-06-19: pivoted) `[deps: none]`
MD
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 3 ] \
  && ok "lone ❌ unsealed phase: INCOMPLETE (not silently read as done)" \
  || no "a lone ❌ unsealed phase must read INCOMPLETE (rc=$RC: $OUT)"

# T21b — the lone-❌ unsealed phase must be listed exactly ONCE, not double-listed.
# After the [23.3] fix the ❌ bullet is terminal, so incomplete_lines() no longer
# reports it; unsealed_lone_phases() is the sole emitter, naming the '## Phase 7'
# header once. The two sibling listers must never both fire for the same phase or
# --check (and --archive's refusal) name the one blocker twice. Reuses T21's tracker;
# counts every reference to phase 7 in the INCOMPLETE listing — must be exactly 1.
N7=$(echo "$OUT" | grep -cE '7\.1|## Phase 7')
[ "$N7" -eq 1 ] \
  && ok "lone ❌ unsealed phase: listed once, not double-listed (n=$N7)" \
  || no "a lone ❌ unsealed phase must appear once in the INCOMPLETE listing, not twice (n=$N7: $OUT)"

# T22 — a LEGACY (token-free) lone-✅-final-phase tracker is unaffected: the
# spike-gated carve is a grammar-mode notion (phase-close records live in the
# grammar lifecycle), so a legacy tracker with one ✅ in its final phase still
# reads COMPLETE exactly as before — the new predicate must not regress LEGACY.
P=$(make_project complete)
cat > "$P/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 5 — Wrap-up**

## Phase 4 — Build

- ✅ Deliverable A

## Phase 5 — Wrap-up

- ✅ Deliverable C
MD
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "status=COMPLETE" \
  && ok "LEGACY lone-✅ final phase: COMPLETE unchanged (carve is grammar-only)" \
  || no "a LEGACY lone-deliverable phase must still read COMPLETE (rc=$RC: $OUT)"

# ── T23 — a multi-deliverable phase with a ❌-descoped line reads COMPLETE ──────
# The reported bug ([23.3]): an initiative that used `/replan descope` carries ❌
# deliverables; archive --check counted ❌ as INCOMPLETE (the ❌ in incomplete_lines),
# so a genuinely-finished initiative could not archive without --force (which falsely
# stamps ABANDONED, corrupting the frozen record). ❌ is TERMINAL (descoped/abandoned)
# — exactly as the resolver's open set (resolve-ready.sh) and replan's phase_completed
# already treat it. A multi-deliverable phase of all-✅-or-descoped-❌ auto-tallies
# COMPLETE (no seal needed — the lone-phase carve below is the only seal path), so the
# initiative must --check exit 0 COMPLETE.
P=$(make_project complete)
cat > "$P/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 6 — Plan as Data**

## Phase 6 — Plan as Data

- ✅ **[6.1]** Tracker grammar amendment `[deps: none]` (2026-06-12)
- ❌ **[6.2]** Ready-frontier resolver `[deps: 6.1]` (descoped 2026-06-23: superseded by [6.3])
- ✅ **[6.3]** Revised resolver `[deps: 6.1]` (2026-06-23)
MD
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "status=COMPLETE" \
  && ok "all-✅-or-descoped-❌ multi-deliverable phase: --check exit 0 COMPLETE (descope is terminal)" \
  || no "a ✅+descoped-❌ initiative must read COMPLETE, not be blocked by the ❌ (rc=$RC: $OUT)"

# ── T24 — a real open line still refuses, naming the open line not the ❌ ───────
# Dropping ❌ from incomplete_lines() must NOT blind archive to genuine open work: a
# ⬜/🔄/🔒 line still blocks (exit 3), and the listed blocker is the open line,
# never the descoped ❌ in the same phase (the ❌ is terminal — it must not be named
# as a blocker). Multi-deliverable phase, so the lone-phase seal carve does not apply.
P=$(make_project complete)
cat > "$P/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 6 — Plan as Data**

## Phase 6 — Plan as Data

- ✅ **[6.1]** Done `[deps: none]`
- ❌ **[6.2]** Abandoned approach `[deps: none]` (abandoned 2026-06-23: dead end)
- ⬜ **[6.3]** Genuinely not started `[deps: 6.1]`
MD
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 3 ] && echo "$OUT" | grep -q '\[6.3\]' && ! echo "$OUT" | grep -q '\[6.2\]' \
  && ok "a real ⬜ still refuses (exit 3) and names the open line, not the descoped ❌" \
  || no "a genuine open line must still block, listing the ⬜ not the ❌ (rc=$RC: $OUT)"

# ── T25 — lone-❌ SEALED → COMPLETE (the seal half T21/T21b above do not cover) ──
# T21/T21b pin the lone-❌ UNSEALED case (INCOMPLETE, listed once). This pins the
# other half of the carve: once a lone-❌ phase carries a phase-close seal it reads
# COMPLETE — coherent with replan's phase_completed (a lone ✅/❌ phase is complete
# only once phase-close-sealed). After the [23.3] fix the lone-❌ phase is now caught
# by unsealed_lone_phases() (naming '## Phase N'), not incomplete_lines() — so this
# also guards that the unsealed→sealed transition flips the verdict. Phase 6 is
# multi-✅ here so only the lone-❌ Phase 7 exercises the carve.
P=$(make_project complete)
cat > "$P/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 7 — Spike**

## Phase 6 — Plan as Data

- ✅ **[6.1]** Done `[deps: none]`
- ✅ **[6.2]** Also done `[deps: 6.1]`

## Phase 7 — Spike

- ❌ **[7.1]** Gating spike, abandoned before its build set `[deps: none]` (abandoned 2026-06-23: direction dropped)
MD
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 3 ] && echo "$OUT" | grep -qE 'Phase 7' \
  && ok "lone-❌ unsealed micro-phase is open-until-sealed (exit 3, matches replan)" \
  || no "a lone-❌ unsealed phase must read INCOMPLETE until sealed (rc=$RC: $OUT)"
# Seal Phase 7 with a phase-close record — a lone-❌ SEALED phase reads COMPLETE.
printf '> - 2026-06-23 — phase-close [7] (session-2026-06-23-001)\n' >> "$P/docs/PHASE_STATUS.md"
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "status=COMPLETE" \
  && ok "a lone-❌ SEALED micro-phase reads COMPLETE (the seal is the deliberate close)" \
  || no "a sealed lone-❌ phase must read COMPLETE (rc=$RC: $OUT)"

# ── T26 — a FULLY-descoped (all-❌, zero ✅) tracker reads COMPLETE, not MALFORMED ──
# The malformed() rebase onto marker_lines() ([23.3]) exists precisely for this edge.
# Once ❌ left incomplete_lines() (it is terminal), an all-❌ tracker has zero ✅ AND
# zero open-marker lines — so the OLD `done_count==0 && incomplete_lines empty`
# predicate would have misread it as MALFORMED (exit 5). marker_lines() still counts
# the ❌ bullets, so the no-bullets invariant holds and the tracker is recognized as
# valid; being multi-deliverable all-terminal (≥2 lines, so no [15.7] lone-seal
# carve), it reads COMPLETE. An initiative whose every deliverable was abandoned is a
# real, reachable state — without this assertion a regression re-breaking malformed()
# for the all-descoped case passes the suite green.
P=$(make_project complete)
cat > "$P/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 6 — Plan as Data**

## Phase 6 — Plan as Data

- ❌ **[6.1]** First approach `[deps: none]` (abandoned 2026-06-23: dead end)
- ❌ **[6.2]** Second approach `[deps: none]` (abandoned 2026-06-23: superseded)
MD
OUT=$(run "$P" --check); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "status=COMPLETE" \
  && ok "fully-descoped all-❌ multi-deliverable tracker reads COMPLETE, not MALFORMED (malformed() rebase)" \
  || no "an all-❌ tracker must read COMPLETE (valid + terminal), never MALFORMED (rc=$RC: $OUT)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
