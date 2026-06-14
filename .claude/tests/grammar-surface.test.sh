#!/bin/bash
# Tests for [10.1] — the phase-docs grammar surface: the canonical deps-token
# grammar quoted verbatim from the shared DEPS_RE the three enforcing scripts
# use, the fifth 🔒 human-gated / awaiting-manual marker taught to the
# marker-counting skills (status, handoff), and a contract-version marker on
# the published surface (the tracker grammar + the status.json shape).
#
# The standard this grades against (guv-verification Rule 8): the doc-drift
# checks fail LOUD if the skill's quoted regex ever diverges from the scripts'
# DEPS_RE, so the documentation can't silently rot away from the enforced rule.
# Pure bash + grep + jq. Run: bash .claude/tests/grammar-surface.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/phase-docs/SKILL.md"
STATUS="$ROOT/commands/status.md"
HANDOFF="$ROOT/commands/handoff.md"
RESOLVER="$ROOT/resolve-ready.sh"
REPLAN="$ROOT/replan.sh"
ARCHIVE="$ROOT/archive-initiative.sh"

PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# The DEPS_RE assignment line as it appears in a script, verbatim:
#   DEPS_RE='`\[deps: (none|[0-9]+\.[0-9]+(, [0-9]+\.[0-9]+)*)\]`'
script_deps_re() { grep -E "^DEPS_RE=" "$1" | head -1; }

# ── 1. The three enforcing scripts share one DEPS_RE (precondition for the
# doc-drift check below to mean anything — if they already disagree, the
# "source of truth" claim is false).
A=$(script_deps_re "$RESOLVER")
B=$(script_deps_re "$REPLAN")
C=$(script_deps_re "$ARCHIVE")
if [ -n "$A" ] && [ "$A" = "$B" ] && [ "$A" = "$C" ]; then
  ok "the three enforcing scripts share one DEPS_RE"
else
  no "DEPS_RE drifted across the scripts (resolver='$A' replan='$B' archive='$C')"
fi

# ── 2. The skill quotes the DEPS_RE regex VERBATIM. We strip the shell
# assignment wrapper down to just the regex value (between the single quotes)
# and require that exact string to appear inside a fenced/inline code span in
# the skill. Byte-identical, or this fails loud — that is the whole point.
REGEX_VALUE=$(printf '%s' "$A" | sed -E "s/^DEPS_RE='//; s/'\$//")
if [ -n "$REGEX_VALUE" ] && grep -Fq "$REGEX_VALUE" "$SKILL"; then
  ok "phase-docs skill quotes the DEPS_RE regex byte-identical to the scripts"
else
  no "the skill must quote the regex verbatim: '$REGEX_VALUE' not found in $SKILL"
fi

# ── 3. The skill names all three scripts as the grammar's source of truth.
miss=""
for s in resolve-ready.sh replan.sh archive-initiative.sh; do
  grep -Fq "$s" "$SKILL" || miss="$miss $s"
done
[ -z "$miss" ] && ok "skill names all three enforcing scripts as source of truth" \
  || no "skill must name the enforcing scripts; missing:$miss"

# Also assert the DEPS_RE *identifier* is named in the skill (so a reader can
# grep the scripts for it, closing the loop the deliverable describes).
grep -Fq "DEPS_RE" "$SKILL" \
  && ok "skill names DEPS_RE by identifier" \
  || no "skill must name DEPS_RE so a reader can locate it in the scripts"

# ── 4. The marker set gains 🔒 alongside the four existing markers, AND it is
# documented as human-gated / awaiting-manual, tracked in docs/manual/.
grep -Fq "🔒" "$SKILL" \
  && ok "skill marker set includes 🔒" \
  || no "skill marker set must gain the fifth 🔒 marker"
grep -Fq "docs/manual/" "$SKILL" \
  && ok "skill ties 🔒 to docs/manual/ (the manual-artifact home)" \
  || no "skill must document 🔒 as tracked in docs/manual/"
# The four existing markers must still be present (not displaced).
for m in ✅ 🔄 ⬜ ❌; do
  grep -Fq "$m" "$SKILL" || no "existing marker $m must remain in the skill marker set"
done
grep -Fq "✅" "$SKILL" && grep -Fq "❌" "$SKILL" \
  && ok "the four existing markers survive alongside 🔒" || true

# ── 5. The marker-counting skills (status, handoff) are taught 🔒 and
# distinguish human-gated from dependency-blocked. The deliverable's bar:
# a 🔒 item counts as human-gated, NOT blocked.
for f in "$STATUS" "$HANDOFF"; do
  n=$(basename "$f")
  if grep -Fq "🔒" "$f"; then
    ok "$n recognizes the 🔒 marker"
  else
    no "$n must recognize the 🔒 human-gated marker in its marker tally"
  fi
done
# The distinction must be explicit somewhere in each counter: human-gated is
# its own bucket, not folded into blocked.
for f in "$STATUS" "$HANDOFF"; do
  n=$(basename "$f")
  if grep -Fiq "human-gated" "$f" || grep -Fiq "awaiting-manual" "$f"; then
    ok "$n names the human-gated / awaiting-manual category"
  else
    no "$n must name 🔒 as human-gated/awaiting-manual (distinct from blocked)"
  fi
done

# ── 6. Contract-version marker on BOTH published surfaces: the grammar docs
# and the status.json shape. We require the literal token 'contract_version'
# to appear in the skill (it documents both surfaces) and that the resolver
# emits it in --json so the doc claim is machine-backed, not prose-only.
grep -Fq "contract_version" "$SKILL" \
  && ok "skill documents the contract_version marker on the published surface" \
  || no "skill must carry a contract_version marker on the grammar + status.json surface"

# ── 7. resolve-ready.sh --json emits contract_version (the status.json shape
# is the machine surface; the marker must live in the bytes, not only the doc).
cat > "$WORK/own.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Build

- ✅ **[6.1]** A `[deps: none]`
- 🔄 **[6.2]** B `[deps: 6.1]`
- ⬜ **[6.3]** C `[deps: 6.1]`
- ❌ **[6.4]** D `[deps: 6.1]`
MD
if command -v jq >/dev/null 2>&1; then
  J=$(bash "$RESOLVER" "$WORK/own.md" --json 2>/dev/null); RCJ=$?
  if [ "$RCJ" -eq 0 ] && echo "$J" | jq -e 'has("contract_version")' >/dev/null 2>&1; then
    ok "status.json carries a contract_version field"
  else
    no "resolve-ready.sh --json must emit contract_version (rc=$RCJ)"
  fi
  # The version the doc states must equal the version the resolver emits — one
  # number, two surfaces. Extract the documented value from the skill's JSON
  # block (a "contract_version": N line) and compare.
  DOCV=$(grep -oE '"contract_version"[[:space:]]*:[[:space:]]*[0-9]+' "$SKILL" | grep -oE '[0-9]+' | head -1)
  EMITV=$(echo "$J" | jq -r '.contract_version' 2>/dev/null)
  if [ -n "$DOCV" ] && [ "$DOCV" = "$EMITV" ]; then
    ok "documented contract_version ($DOCV) matches the emitted value"
  else
    no "doc/emit contract_version must agree (doc='$DOCV' emit='$EMITV')"
  fi

  # ── 8. The existing four-marker fixtures are UNAFFECTED: the status
  # vocabulary is exactly done/in_progress/todo/descoped, in order. This is the
  # regression guard the deliverable's acceptance demands.
  if echo "$J" | jq -e '[.deliverables[].status] == ["done","in_progress","todo","descoped"]' >/dev/null 2>&1; then
    ok "four-marker fixture still maps to done/in_progress/todo/descoped (unaffected)"
  else
    no "the four existing markers must resolve unchanged (got $(echo "$J" | jq -c '[.deliverables[].status]'))"
  fi
  # And the frontier is unchanged: 6.3 is the lone ⬜ with a ✅ dep → ready.
  if echo "$J" | jq -e '.frontier.ready == ["6.3"]' >/dev/null 2>&1; then
    ok "four-marker frontier unchanged (6.3 ready)"
  else
    no "four-marker frontier must be unaffected (ready should be [6.3])"
  fi

  # ── 9. The fifth 🔒 marker must NOT silently drop out of the resolver — the
  # parser this edit promotes to the grammar's source of truth has to make a
  # 🔒 line VISIBLE, never vanish from the parse / JSON / counts (Rule 10,
  # fail loud). This is the regression guard for the silent-drop the gate
  # found: before 🔒 joined the marker class, a 🔒 line was excluded from
  # $LINES entirely — invisible to deliverables[], absent from the open-phase
  # reckoning, and a ⬜ depending on it exit-5'd MALFORMED ("ID does not
  # exist"). The fixture: 6.1 ✅ → 6.2 🔒 (depends on 6.1) → 6.3 ⬜ (depends
  # on the 🔒). We pin three things: (a) 6.2 is present and surfaces as
  # status="human_gated"; (b) the phase reckoning still treats the 🔒 phase as
  # open; (c) the downstream ⬜ on the 🔒 ID RESOLVES (blocked, root named)
  # instead of crashing, proving 🔒 is a valid dep target.
  cat > "$WORK/locked.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Build

- ✅ **[6.1]** A `[deps: none]`
- 🔒 **[6.2]** Manual deploy `[deps: 6.1]`
- ⬜ **[6.3]** C `[deps: 6.2]`
MD
  L=$(bash "$RESOLVER" "$WORK/locked.md" --json 2>/dev/null); RCL=$?
  if [ "$RCL" -eq 0 ] \
     && echo "$L" | jq -e '[.deliverables[].id] == ["6.1","6.2","6.3"]' >/dev/null 2>&1; then
    ok "🔒 line is VISIBLE in deliverables[] — not silently dropped from the parse"
  else
    no "the 🔒-marked deliverable must appear in deliverables[] (rc=$RCL got $(echo "$L" | jq -c '[.deliverables[].id]' 2>/dev/null))"
  fi
  if echo "$L" | jq -e '(.deliverables[] | select(.id=="6.2") | .status) == "human_gated"' >/dev/null 2>&1; then
    ok "🔒 surfaces as status=human_gated (its own category, not done/todo/descoped)"
  else
    no "🔒 must map to a distinct human_gated status (got $(echo "$L" | jq -c '.deliverables[]|select(.id=="6.2")|.status' 2>/dev/null))"
  fi
  # 🔒 is open work → the phase stays open (not skipped as complete).
  if echo "$L" | jq -e '.phase == 6' >/dev/null 2>&1; then
    ok "a 🔒-only-open phase is counted open (phase=6), not skipped as complete"
  else
    no "🔒 is open work; the phase must stay open (got $(echo "$L" | jq -c '.phase' 2>/dev/null))"
  fi
  # 🔒 is open-but-non-dispatchable: never in ready=, and a dep on it resolves
  # (blocked with the 🔒 named) rather than exit-5 MALFORMED.
  if echo "$L" | jq -e '.frontier.ready == [] and (.frontier.blocked[]? | select(.id=="6.3") | .blocked_by == "6.2")' >/dev/null 2>&1; then
    ok "a ⬜ depending on the 🔒 ID RESOLVES — blocked, 🔒 named as root (no MALFORMED crash)"
  else
    no "a dep on a 🔒 ID must resolve as blocked-by the 🔒, not crash (frontier=$(echo "$L" | jq -c '.frontier' 2>/dev/null))"
  fi
  # And the non-JSON path agrees — the 🔒 dep target is recognized there too
  # (this is the path that exit-5'd before: 6.2 was never in $ids).
  NV=$(bash "$RESOLVER" "$WORK/locked.md" 2>/dev/null); RCN=$?
  if [ "$RCN" -eq 0 ] && printf '%s\n' "$NV" | grep -q '^blocked=6.3:6.2$'; then
    ok "name=value path also resolves the 🔒 dep (blocked=6.3:6.2), not exit-5"
  else
    no "name=value path must resolve the 🔒 dep target without crashing (rc=$RCN)"
  fi
else
  no "jq is required for the status.json contract-version assertions"
fi

echo ""
echo "  grammar-surface: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
