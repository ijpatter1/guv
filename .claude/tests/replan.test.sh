#!/bin/bash
# Tests for .claude/replan.sh — the deterministic tracker-mutation engine
# behind /replan ([6.3] of the plan-as-data spec). The grammar is defined once
# in the phase-docs skill ("Tracker grammar"); the engine mutates the tracker
# only (REQUIREMENTS and ARCHITECTURE edits are judgment, owned by the
# command), validates every candidate result with resolve-ready.sh (one
# dialect, no third validator), and writes atomically — a rejected mutation
# leaves the tracker byte-identical. Exit codes: 0 ok · 2 usage · 4 no
# tracker · 5 MALFORMED (incl. rejected post-state, unknown target, sync
# drift) · 6 REFUSED (completed phase, LEGACY, ✅ descope, ordinal mismatch).
# Pure bash + grep, no test runner. Run: bash .claude/tests/replan.test.sh
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/replan.sh"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

SESH="session-2026-06-12-002"
DATE_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}'

# ── Base fixture: completed phase 5, open phase 6 (current), future phase 7.
cat > "$WORK/base.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 6 — Build**
> Last updated: 2026-06-12, session-2026-06-12-001

---

## Phase 5 — Old Things

_Goal: done._

- ✅ **[5.1]** First old thing `[deps: none]` (2026-06-01, session-x)
- ❌ **[5.2]** Old descoped thing `[deps: none]` (descoped 2026-06-02: overtaken)

---

## Phase 6 — Build

_Goal: build._

- ✅ **[6.1]** Grammar `[deps: none]` (2026-06-12, session-2026-06-12-001)
- ⬜ **[6.2]** Resolver `[deps: 6.1]`
- ⬜ **[6.3]** Mutation door `[deps: 6.1]`

---

## Phase 7 — Later

_Goal: later._

- ⬜ **[7.1]** Plumbing `[deps: none]`
MD

cat > "$WORK/legacy.md" <<'MD'
## Phase 1 — Old Style

- ✅ First thing, no tokens
- ⬜ Second thing, no tokens
MD

fresh() { cp "$WORK/base.md" "$WORK/t.md"; printf '%s\n' "$WORK/t.md"; }

# ════ T1 — guard: completed phases refuse, open targets pass ════
T="$(fresh)"
OUT=$(bash "$SCRIPT" guard 5 "$T" 2>&1); RC=$?
[ "$RC" -eq 6 ] && ok "guard: completed phase 5 refused (exit 6)" || no "guard 5 should exit 6 (rc=$RC: $OUT)"
echo "$OUT" | grep -q "5" && echo "$OUT" | grep -qi "immutable" \
  && ok "guard: refusal names the phase and says immutable" || no "refusal should name phase 5 + immutable (got: $OUT)"
echo "$OUT" | grep -qiE "current or a future phase|append-only" \
  && ok "guard: refusal is actionable (points at an allowed move)" || no "refusal should suggest the allowed move (got: $OUT)"

OUT=$(bash "$SCRIPT" guard 5.2 "$T" 2>&1); RC=$?
[ "$RC" -eq 6 ] && ok "guard: ID inside completed phase refused" || no "guard 5.2 should exit 6 (rc=$RC: $OUT)"

bash "$SCRIPT" guard 6 "$T" >/dev/null 2>&1 && ok "guard: open phase 6 passes" || no "guard 6 should exit 0"
bash "$SCRIPT" guard 6.2 "$T" >/dev/null 2>&1 && ok "guard: open ID 6.2 passes" || no "guard 6.2 should exit 0"
bash "$SCRIPT" guard 7 "$T" >/dev/null 2>&1 && ok "guard: future open phase 7 passes" || no "guard 7 should exit 0"

OUT=$(bash "$SCRIPT" guard 9 "$T" 2>&1); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "9" && ok "guard: unknown phase exits 5, named" || no "guard 9 should exit 5 naming it (rc=$RC: $OUT)"
OUT=$(bash "$SCRIPT" guard 6.9 "$T" 2>&1); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "6.9" && ok "guard: unknown ID exits 5, named" || no "guard 6.9 should exit 5 naming it (rc=$RC: $OUT)"

OUT=$(bash "$SCRIPT" guard 1 "$WORK/legacy.md" 2>&1); RC=$?
[ "$RC" -eq 6 ] && echo "$OUT" | grep -qi "LEGACY" \
  && ok "guard: LEGACY tracker refused with LEGACY named" || no "LEGACY guard should exit 6 naming LEGACY (rc=$RC: $OUT)"

# ════ T2 — next-ordinal: max+1, ❌ counts, unknown phase fails ════
T="$(fresh)"
[ "$(bash "$SCRIPT" next-ordinal 6 "$T" 2>&1)" = "6.4" ] && ok "next-ordinal: 6 -> 6.4" || no "next-ordinal 6 should print 6.4"
[ "$(bash "$SCRIPT" next-ordinal 7 "$T" 2>&1)" = "7.2" ] && ok "next-ordinal: 7 -> 7.2" || no "next-ordinal 7 should print 7.2"
[ "$(bash "$SCRIPT" next-ordinal 5 "$T" 2>&1)" = "5.3" ] \
  && ok "next-ordinal: ❌ ordinal counts (5 -> 5.3, never reused)" || no "next-ordinal 5 should print 5.3 (❌ 5.2 counts)"
OUT=$(bash "$SCRIPT" next-ordinal 9 "$T" 2>&1); RC=$?
[ "$RC" -eq 5 ] && ok "next-ordinal: unknown phase exits 5" || no "next-ordinal 9 should exit 5 (rc=$RC: $OUT)"

# ════ T3 — insert: next-ordinal-at-phase-end, validated, recorded ════
T="$(fresh)"
OUT=$(bash "$SCRIPT" insert "$SESH" insert '**[6.4]** New thing `[deps: 6.2]`' "$T" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "insert: clean insert exits 0" || no "insert should succeed (rc=$RC: $OUT)"
last=$(sed -n '/^## Phase 6/,/^## Phase 7/p' "$T" | grep -E '^\s*-\s*(✅|🔄|⬜|❌)' | tail -1)
echo "$last" | grep -q '\*\*\[6\.4\]\*\*' && ok "insert: lands as LAST bullet of its phase" || no "6.4 should be phase 6's last bullet (got: $last)"
echo "$last" | grep -q '^- ⬜' && ok "insert: lands ⬜" || no "inserted line should be ⬜ (got: $last)"
RES=$(bash "$SRC/resolve-ready.sh" "$T" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "insert: result passes the resolver" || no "post-insert tracker should resolve (rc=$RC: $RES)"
echo "$RES" | grep -E '^blocked=' | grep -q '6.4:6.2' \
  && ok "insert: deps express logical position (6.4 blocked by 6.2)" || no "6.4 should be blocked by 6.2 (got: $RES)"
grep -qE "^> - $DATE_RE — insert \[6\.4\] \($SESH\)" "$T" \
  && ok "insert: amendment record names op, ID, session, dated" || no "record line missing/misshapen: $(grep '^> -' "$T")"
[ "$(grep -c '^> \*\*Amendments:\*\*' "$T")" = "1" ] && ok "insert: one Amendments block created" || no "expected exactly one Amendments block"

# Refusals — each against a fresh copy; failed mutations leave the file byte-identical.
T="$(fresh)"
OUT=$(bash "$SCRIPT" insert "$SESH" insert '**[6.9]** Skips ahead `[deps: none]`' "$T" 2>&1); RC=$?
[ "$RC" -eq 6 ] && echo "$OUT" | grep -q '6.4' \
  && ok "insert: ordinal skip refused, expected ordinal named" || no "6.9 insert should exit 6 naming 6.4 (rc=$RC: $OUT)"
cmp -s "$T" "$WORK/base.md" && ok "insert: refused mutation leaves tracker byte-identical" || no "tracker changed on refused insert"

T="$(fresh)"
OUT=$(bash "$SCRIPT" insert "$SESH" insert '**[6.4]** No token here' "$T" 2>&1); RC=$?
[ "$RC" -eq 5 ] && cmp -s "$T" "$WORK/base.md" \
  && ok "insert: token-less wording exits 5, tracker untouched" || no "token-less insert should exit 5 unchanged (rc=$RC: $OUT)"

T="$(fresh)"
OUT=$(bash "$SCRIPT" insert "$SESH" insert '**[6.4]** Ghost dep `[deps: 6.99]`' "$T" 2>&1); RC=$?
[ "$RC" -eq 5 ] && cmp -s "$T" "$WORK/base.md" \
  && ok "insert: unknown dep rejected by validation, tracker untouched" || no "ghost-dep insert should exit 5 unchanged (rc=$RC: $OUT)"

# A forward cross-phase dep is an ordinary edge ([7.6] repealed the lint
# with the phase barrier) — the engine accepts it like any other dep.
T="$(fresh)"
OUT=$(bash "$SCRIPT" insert "$SESH" insert '**[6.4]** Jumps ahead `[deps: 7.1]`' "$T" 2>&1); RC=$?
[ "$RC" -eq 0 ] && grep -q '^- ⬜ \*\*\[6\.4\]\*\* Jumps ahead `\[deps: 7\.1\]`$' "$T" \
  && ok "insert: forward cross-phase dep accepted (ordinary edge per [7.6])" \
  || no "forward-dep insert should land like any other (rc=$RC: $OUT)"
RES=$(bash "$SRC/resolve-ready.sh" "$T" 2>&1)
echo "$RES" | grep -E '^blocked=' | grep -q '6.4:7.1' \
  && ok "insert: forward edge resolves with the forward root named" \
  || no "6.4 should be blocked by 7.1 (got: $RES)"

T="$(fresh)"
OUT=$(bash "$SCRIPT" insert "$SESH" insert '**[5.3]** Into history `[deps: none]`' "$T" 2>&1); RC=$?
[ "$RC" -eq 6 ] && cmp -s "$T" "$WORK/base.md" \
  && ok "insert: completed phase refused, tracker untouched" || no "phase-5 insert should exit 6 unchanged (rc=$RC: $OUT)"

cp "$WORK/legacy.md" "$WORK/tl.md"
OUT=$(bash "$SCRIPT" insert "$SESH" insert '**[1.3]** Grammar thing `[deps: none]`' "$WORK/tl.md" 2>&1); RC=$?
[ "$RC" -eq 6 ] && cmp -s "$WORK/tl.md" "$WORK/legacy.md" \
  && ok "insert: LEGACY tracker refused, untouched" || no "LEGACY insert should exit 6 unchanged (rc=$RC: $OUT)"

# A malformed tracker refuses mutation up front (preflight, not post-state).
cat > "$WORK/dup.md" <<'MD'
## Phase 6 — Build

- ⬜ **[6.1]** A `[deps: none]`
- ⬜ **[6.1]** A again `[deps: none]`
MD
cp "$WORK/dup.md" "$WORK/td.md"
OUT=$(bash "$SCRIPT" descope "$SESH" descope 6.1 "nope" "$WORK/td.md" 2>&1); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -qi "before any mutation" && cmp -s "$WORK/td.md" "$WORK/dup.md" \
  && ok "preflight: malformed tracker refused before any mutation, untouched" \
  || no "duplicate-ID tracker should exit 5 pre-mutation (rc=$RC: $OUT)"

# An empty phase takes its first insert below the goal line, not above it.
cat > "$WORK/empty.md" <<'MD'
## Phase 6 — Build

_Goal: build._

- ✅ **[6.1]** Done `[deps: none]`

---

## Phase 7 — Later

_Goal: later._

---
MD
OUT=$(bash "$SCRIPT" insert "$SESH" insert '**[7.1]** First of its phase `[deps: none]`' "$WORK/empty.md" 2>&1); RC=$?
goal_at=$(grep -n '^_Goal: later' "$WORK/empty.md" | cut -d: -f1)
new_at=$(grep -n '^- ⬜ \*\*\[7\.1\]' "$WORK/empty.md" | head -1 | cut -d: -f1)
[ "$RC" -eq 0 ] && [ -n "$new_at" ] && [ "$new_at" -gt "$goal_at" ] \
  && ok "insert: empty phase lands below its goal line" || no "7.1 should land after the goal line (rc=$RC, goal=$goal_at, new=$new_at)"

# Future-phase insert lands at THAT phase's end (placement is per-phase).
T="$(fresh)"
OUT=$(bash "$SCRIPT" insert "$SESH" insert '**[7.2]** More plumbing `[deps: 7.1]`' "$T" 2>&1); RC=$?
[ "$RC" -eq 0 ] && sed -n '/^## Phase 7/,$p' "$T" | grep -E '^\s*-' | tail -1 | grep -q '7\.2' \
  && ok "insert: future-phase insert lands at phase 7's end" || no "7.2 should land at end of phase 7 (rc=$RC: $OUT)"

# ════ T4 — descope: ❌ + dated note, line survives ════
T="$(fresh)"
NBEFORE=$(grep -cE '^\s*-\s*(✅|🔄|⬜|❌)' "$T")
OUT=$(bash "$SCRIPT" descope "$SESH" descope 6.3 "superseded by 6.4" "$T" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "descope: clean descope exits 0" || no "descope should succeed (rc=$RC: $OUT)"
line=$(grep '\*\*\[6\.3\]\*\*' "$T" | grep -v '^>')
echo "$line" | grep -q '^- ❌' && ok "descope: marker flipped to ❌" || no "6.3 should be ❌ (got: $line)"
echo "$line" | grep -q 'Mutation door `\[deps: 6.1\]`' \
  && ok "descope: wording and token survive untouched" || no "wording should survive (got: $line)"
echo "$line" | grep -qE "\(descoped $DATE_RE: superseded by 6.4\)" \
  && ok "descope: dated note appended in the annotation zone" || no "dated note missing (got: $line)"
[ "$(grep -cE '^\s*-\s*(✅|🔄|⬜|❌)' "$T")" = "$NBEFORE" ] \
  && ok "descope: the line survives (deletion does not exist)" || no "bullet count changed on descope"
grep -qE "^> - $DATE_RE — descope \[6\.3\] \($SESH\) — superseded by 6.4" "$T" \
  && ok "descope: record carries op, ID, session, note" || no "descope record missing/misshapen: $(grep '^> -' "$T")"

T="$(fresh)"
OUT=$(bash "$SCRIPT" descope "$SESH" descope 6.1 "nope" "$T" 2>&1); RC=$?
[ "$RC" -eq 6 ] && echo "$OUT" | grep -qi "complete" \
  && ok "descope: ✅ deliverable refused" || no "descoping ✅ 6.1 should exit 6 (rc=$RC: $OUT)"
OUT=$(bash "$SCRIPT" descope "$SESH" descope 5.2 "again" "$T" 2>&1); RC=$?
[ "$RC" -eq 6 ] && ok "descope: completed-phase target refused" || no "descoping 5.2 should exit 6 (rc=$RC: $OUT)"
OUT=$(bash "$SCRIPT" descope "$SESH" descope 6.3 "" "$T" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "descope: empty note is a usage error (the note is mandatory)" || no "empty note should exit 2 (rc=$RC: $OUT)"

# abandon rides the descope primitive; the record and annotation say abandon.
T="$(fresh)"
OUT=$(bash "$SCRIPT" descope "$SESH" abandon 6.3 "approach dead-ended" "$T" 2>&1); RC=$?
[ "$RC" -eq 0 ] && grep '\*\*\[6\.3\]\*\*' "$T" | grep -v '^>' | grep -qE "\(abandoned $DATE_RE: approach dead-ended\)" \
  && grep -qE "^> - $DATE_RE — abandon \[6\.3\]" "$T" \
  && ok "descope: abandon verb annotates and records as abandon" || no "abandon should annotate+record as abandon (rc=$RC)"

# ════ T5 — reword: wording/deps amended in place, annotations preserved ════
T="$(fresh)"
OUT=$(bash "$SCRIPT" reword "$SESH" deps-amend 6.3 '**[6.3]** Mutation door `[deps: 6.1, 6.2]`' "$T" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "reword: deps-amend exits 0" || no "deps-amend should succeed (rc=$RC: $OUT)"
line=$(grep '\*\*\[6\.3\]\*\*' "$T" | grep -v '^>')
echo "$line" | grep -q '^- ⬜ \*\*\[6\.3\]\*\* Mutation door `\[deps: 6.1, 6.2\]`' \
  && ok "reword: marker kept, token updated" || no "expected ⬜ with new token (got: $line)"
grep -qE "^> - $DATE_RE — deps-amend \[6\.3\] \($SESH\) — deps: 6\.1 → 6\.1, 6\.2" "$T" \
  && ok "reword: record shows the deps diff" || no "deps diff missing from record: $(grep '^> -' "$T")"

# Rewording a ✅ line keeps its marker and its tracker-local annotation.
T="$(fresh)"
OUT=$(bash "$SCRIPT" reword "$SESH" deps-amend 6.1 '**[6.1]** Grammar, clarified `[deps: none]`' "$T" 2>&1); RC=$?
line=$(grep '\*\*\[6\.1\]\*\*' "$T" | grep -v '^>')
[ "$RC" -eq 0 ] && echo "$line" | grep -q '^- ✅' && echo "$line" | grep -q '(2026-06-12, session-2026-06-12-001)' \
  && ok "reword: ✅ marker and annotation zone preserved" || no "✅ reword should keep marker+annotation (rc=$RC, got: $line)"

# A reword that creates a cycle is rejected whole; tracker untouched.
cat > "$WORK/cyc.md" <<'MD'
## Phase 6 — Build

- ⬜ **[6.1]** A `[deps: none]`
- ⬜ **[6.2]** B `[deps: 6.1]`
MD
cp "$WORK/cyc.md" "$WORK/tc.md"
OUT=$(bash "$SCRIPT" reword "$SESH" reorder 6.1 '**[6.1]** A `[deps: 6.2]`' "$WORK/tc.md" 2>&1); RC=$?
[ "$RC" -eq 5 ] && cmp -s "$WORK/tc.md" "$WORK/cyc.md" \
  && ok "reword: cycle-creating amendment rejected, tracker untouched" || no "cycle reword should exit 5 unchanged (rc=$RC: $OUT)"

# A wording-only reword must still tell what changed: caller summary wins,
# "wording amended" is the floor — a record never goes out detail-less.
T="$(fresh)"
bash "$SCRIPT" reword "$SESH" deps-amend 6.3 '**[6.3]** Mutation portal `[deps: 6.1]`' "$T" "four lists, not three" >/dev/null 2>&1
grep -qE "^> - $DATE_RE — deps-amend \[6\.3\] \($SESH\) — four lists, not three" "$T" \
  && ok "reword: wording-only record carries the caller's summary" || no "summary missing from record: $(grep '^> -' "$T")"
T="$(fresh)"
bash "$SCRIPT" reword "$SESH" deps-amend 6.3 '**[6.3]** Mutation portal `[deps: 6.1]`' "$T" >/dev/null 2>&1
grep -qE "^> - $DATE_RE — deps-amend \[6\.3\] \($SESH\) — wording amended" "$T" \
  && ok "reword: wording-only record defaults to 'wording amended', never empty" \
  || no "default detail missing from record: $(grep '^> -' "$T")"

T="$(fresh)"
OUT=$(bash "$SCRIPT" reword "$SESH" deps-amend 6.9 '**[6.9]** Ghost `[deps: none]`' "$T" 2>&1); RC=$?
[ "$RC" -eq 5 ] && ok "reword: unknown target ID exits 5" || no "reword 6.9 should exit 5 (rc=$RC: $OUT)"
OUT=$(bash "$SCRIPT" reword "$SESH" deps-amend 6.3 '**[6.5]** Identity theft `[deps: none]`' "$T" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "reword: wording ID must match target (IDs are immutable)" || no "ID-mismatch reword should exit 2 (rc=$RC: $OUT)"

# ════ T6 — amendment records: one block, header-local, parse-inert ════
T="$(fresh)"
bash "$SCRIPT" insert "$SESH" insert '**[6.4]** New thing `[deps: 6.2]`' "$T" >/dev/null 2>&1
bash "$SCRIPT" descope "$SESH" descope 6.3 "folded into 6.4" "$T" >/dev/null 2>&1
[ "$(grep -c '^> \*\*Amendments:\*\*' "$T")" = "1" ] && ok "records: second mutation reuses the one Amendments block" \
  || no "expected one Amendments block after two mutations"
[ "$(grep -c '^> - ' "$T")" = "2" ] && ok "records: two record lines for two mutations" || no "expected two record lines"
firsthdr=$(grep -n '^## ' "$T" | head -1 | cut -d: -f1)
lastrec=$(grep -n '^> - ' "$T" | tail -1 | cut -d: -f1)
[ "$lastrec" -lt "$firsthdr" ] && ok "records: live in the header, before the first phase section" \
  || no "records leaked past the header (record line $lastrec, first ## at $firsthdr)"
RES=$(bash "$SRC/resolve-ready.sh" "$T" 2>&1); RC=$?
[ "$RC" -eq 0 ] && echo "$RES" | grep -E '^ready=' | grep -qv '\[' \
  && ok "records: record lines are inert to the resolver" || no "resolver tripped on record lines (rc=$RC: $RES)"

# A title-less, header-less tracker still gets a block (created at the top).
cp "$WORK/cyc.md" "$WORK/th.md"
OUT=$(bash "$SCRIPT" descope "$SESH" descope 6.2 "not needed" "$WORK/th.md" 2>&1); RC=$?
[ "$RC" -eq 0 ] && head -1 "$WORK/th.md" | grep -q '^> \*\*Amendments:\*\*' \
  && ok "records: headerless tracker gets a block at the top" || no "headerless tracker should gain a top block (rc=$RC)"

# ════ T7 — sync-check: tracker wording vs REQUIREMENTS, verbatim ════
T="$(fresh)"
cat > "$WORK/reqs.md" <<'MD'
## Phase 6 — Build

1. **[6.1]** Grammar `[deps: none]`
   - *Acceptance:* defined once.
2. **[6.3]** Mutation door `[deps: 6.1]`
   - *Acceptance:* seven verbs.
MD
bash "$SCRIPT" sync-check 6.3 "$T" "$WORK/reqs.md" >/dev/null 2>&1 \
  && ok "sync-check: verbatim match passes" || no "6.3 should be in sync"
bash "$SCRIPT" sync-check 6.1 "$T" "$WORK/reqs.md" >/dev/null 2>&1 \
  && ok "sync-check: tracker-local annotations are excluded from the comparison" \
  || no "6.1 should be in sync (annotation zone must not count)"
OUT=$(bash "$SCRIPT" sync-check 6.2 "$T" "$WORK/reqs.md" 2>&1); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q '6.2' \
  && ok "sync-check: ID missing from REQUIREMENTS exits 5, named" || no "6.2 absent should exit 5 (rc=$RC: $OUT)"
sed -i.bak 's/Mutation door `\[deps: 6.1\]`/Mutation portal `[deps: 6.1]`/' "$WORK/reqs.md" && rm -f "$WORK/reqs.md.bak"
OUT=$(bash "$SCRIPT" sync-check 6.3 "$T" "$WORK/reqs.md" 2>&1); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q "door" && echo "$OUT" | grep -q "portal" \
  && ok "sync-check: drift exits 5 showing both wordings" || no "drift should exit 5 with both sides (rc=$RC: $OUT)"

# ════ T8 — usage and op-verb discipline ════
T="$(fresh)"
OUT=$(bash "$SCRIPT" frobnicate 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "usage: unknown subcommand exits 2" || no "unknown subcommand should exit 2 (rc=$RC)"
OUT=$(bash "$SCRIPT" insert "$SESH" tweak '**[6.4]** X `[deps: none]`' "$T" 2>&1); RC=$?
[ "$RC" -eq 2 ] && echo "$OUT" | grep -q 'deps-amend' \
  && ok "usage: unknown op exits 2 listing the legal verbs" || no "op 'tweak' should exit 2 listing verbs (rc=$RC: $OUT)"
OUT=$(bash "$SCRIPT" insert "" insert '**[6.4]** X `[deps: none]`' "$T" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "usage: empty session exits 2 (records must name the session)" || no "empty session should exit 2 (rc=$RC)"
OUT=$(bash "$SCRIPT" guard 6 "$WORK/absent.md" 2>&1); RC=$?
[ "$RC" -eq 4 ] && ok "usage: missing tracker exits 4" || no "missing tracker should exit 4 (rc=$RC)"

# ════ T9 — parser parity: one grammar dialect across the three scripts ════
ARCHIVE="$SRC/archive-initiative.sh"
for var in ID_RE DEPS_RE; do
  a=$(grep -E "^$var=" "$SCRIPT"); b=$(grep -E "^$var=" "$ARCHIVE")
  [ -n "$a" ] && [ "$a" = "$b" ] && ok "parity: $var identical to archive-initiative.sh" \
    || no "$var drifted between replan and archive-initiative ('$a' vs '$b')"
done

# ════ T10 — prose contracts: the command shell and its routing ════
CMD="$SRC/skills/replan/SKILL.md"
if [ -f "$CMD" ]; then
  ok "replan.md exists"
  ALL7=1
  for verb in reorder split merge insert descope abandon deps-amend; do
    grep -q "$verb" "$CMD" || { no "replan.md missing verb: $verb"; ALL7=0; }
  done
  [ "$ALL7" -eq 1 ] && ok "replan.md names all seven verbs"
  grep -qi "confirm" "$CMD" && ok "replan.md carries the confirm gate" || no "replan.md must require confirmation before writes"
  grep -q "REQUIREMENTS first" "$CMD" && ok "replan.md states REQUIREMENTS-first order" || no "replan.md must state REQUIREMENTS-first"
  grep -q "replan.sh" "$CMD" && ok "replan.md routes mutations through the engine" || no "replan.md must reference replan.sh"
  grep -qi "completed phase" "$CMD" && ok "replan.md states completed phases refuse" || no "replan.md must state the completed-phase refusal"
  grep -q "sync-check" "$CMD" && ok "replan.md verifies verbatim sync" || no "replan.md must run sync-check"
else
  no "skills/replan/SKILL.md missing"
fi

SP="$SRC/skills/phase/SKILL.md"
grep -q "/replan" "$SP" && ok "phase.md routes spec-alignment to /replan" || no "phase.md Step 5 must route to /replan"
grep -q "update the project docs immediately" "$SP" \
  && no "phase.md still instructs direct doc mutation (Step 5 must be detect-and-route)" \
  || ok "phase.md no longer mutates docs directly"

PD="$SRC/skills/phase-docs/SKILL.md"
grep -q '\*\*Amendments:\*\*' "$PD" && ok "phase-docs defines the amendment-record format" \
  || no "phase-docs SKILL.md must define the Amendments block"
grep -q '/replan' "$PD" && ok "phase-docs names /replan as the mutation door" || no "phase-docs must name /replan"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
