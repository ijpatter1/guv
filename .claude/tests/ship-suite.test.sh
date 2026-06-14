#!/bin/bash
# Tests for [10.3] — build-plugin.sh ships the consumer-meaningful test suites
# into plugin/tests/, with a layout-reconstructing runner so the location-relative
# suites run unmodified in a plugin install.
#
# The shipped set is the glob-derived suite set MINUS the maintainer-only suites.
# "Maintainer-only" = a suite that reaches for source-tree assets a plugin install
# does NOT reproduce: the named three the deliverable enumerates (maintainers/,
# plugin-src/, .claude/settings.json) PLUS the source command/skill files,
# project.schema.json, and the top-level .claude/ shape docs (estimate.shape.md,
# metering*.md). Those latter assertions are source-shape checks, not consumer
# script behavior — they cannot go green in plugin layout no matter how the tree
# is reconstructed, so they are maintainer-only in the same spirit. See the
# MAINTAINER_ONLY filter in build-plugin.sh for the one definition.
#
# The runner (plugin/tests/run-plugin-tests.sh) rebuilds a temp .claude/-shaped
# tree from the FLATTENED plugin scripts/: scripts at .claude/ top level, hooks in
# .claude/hooks/ recovered from which scripts hooks.json references, rules in
# .claude/rules/, the shipped suites in .claude/tests/ — then runs each suite. The
# consumer suites self-locate via $(dirname "$0")/.. so they find their scripts in
# that reconstructed tree unmodified.
#
# Pure bash + jq, no test runner. Run: bash .claude/tests/ship-suite.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/.claude"
BUILD="$ROOT/maintainers/build-plugin.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
finish() { echo ""; echo "Results: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; }

# A consumer fork that dropped maintainers/ has no build to exercise — skip
# cleanly, never as failures (the plugin.test.sh pattern).
if [ ! -f "$BUILD" ]; then
  echo "  - maintainers/build-plugin.sh absent (consumer fork) — suite skips"
  echo ""
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

# The maintainer-only filter, DERIVED here exactly as build-plugin.sh applies it
# (one rule, asserted in lockstep). A suite is maintainer-only iff it references
# any of these source-tree-only surfaces. The directory-grep forms the green
# consumer suites use (grep -r ... .claude/commands .claude/skills 2>/dev/null)
# do NOT match — the patterns require a trailing /<file>.md or /SKILL.md.
MAINTAINER_ONLY='maintainers/|plugin-src/|\.claude/settings\.json|commands/[a-z][a-z-]*\.md|skills/[a-z][a-z-]*/SKILL\.md|project\.schema\.json|estimate\.shape\.md|/metering[a-z-]*\.md'

is_maint() { grep -qE "$MAINTAINER_ONLY" "$1"; }

# Hand-derive the expected partition from the source glob.
EXPECT_CONSUMER=""
EXPECT_MAINT=""
for t in "$SRC"/tests/*.test.sh; do
  b="$(basename "$t")"
  # the runner and this self-test never ship (they ARE the shipping machinery)
  case "$b" in ship-suite.test.sh) continue ;; esac
  if is_maint "$t"; then EXPECT_MAINT="$EXPECT_MAINT $b"; else EXPECT_CONSUMER="$EXPECT_CONSUMER $b"; fi
done

# Build the plugin into a temp tree.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if ! bash "$BUILD" --out "$TMP/plugin" >/dev/null 2>&1; then
  no "build-plugin.sh failed to produce a plugin tree"
  finish; exit 1
fi
PLUGIN="$TMP/plugin"
PTESTS="$PLUGIN/tests"

# T1 — plugin/tests/ exists and is non-empty.
if [ -d "$PTESTS" ] && [ -n "$(ls "$PTESTS"/*.test.sh 2>/dev/null)" ]; then
  ok "plugin/tests/ exists and ships test suites"
else
  no "plugin/tests/ must exist and contain shipped suites"
  finish; exit 1
fi

# T2 — every consumer suite ships (forward direction).
T2_OK=1
for b in $EXPECT_CONSUMER; do
  [ -f "$PTESTS/$b" ] || { no "consumer suite not shipped: $b"; T2_OK=0; }
done
[ "$T2_OK" -eq 1 ] && ok "all $(echo $EXPECT_CONSUMER | wc -w | tr -d ' ') consumer suites ship in plugin/tests/"

# T3 — no maintainer-only suite ships (reverse direction). This is the assertion
# the deliverable wants "both directions": named maintainer-only suites
# (plugin.test.sh, setup-control-plane.test.sh, …) must NOT leak into the plugin.
T3_OK=1
for b in $EXPECT_MAINT; do
  [ -e "$PTESTS/$b" ] && { no "maintainer-only suite leaked into plugin/tests/: $b"; T3_OK=0; }
done
[ "$T3_OK" -eq 1 ] && ok "no maintainer-only suite ships (none of $(echo $EXPECT_MAINT | wc -w | tr -d ' ') leaked)"

# T3b — the explicitly named maintainer-only suites are absent (the deliverable
# names these as the must-not-ship set; assert by name so a filter regression
# that re-includes one fails loud regardless of the derived partition).
T3B_OK=1
for b in plugin.test.sh setup-control-plane.test.sh single-writer.test.sh release.test.sh scaffold.test.sh; do
  [ -e "$PTESTS/$b" ] && { no "named maintainer-only suite present: $b"; T3B_OK=0; }
done
[ "$T3B_OK" -eq 1 ] && ok "the named maintainer-only suites are absent from plugin/tests/"

# T3c — a consumer suite known to be pure script-behavior IS shipped (positive
# anchor so T2 can't pass vacuously on an empty consumer set).
for b in resolve-ready.test.sh route.test.sh merge-queue.test.sh; do
  [ -f "$PTESTS/$b" ] \
    && ok "consumer suite present: $b" \
    || no "expected consumer suite missing: $b"
done

# T4 — shipped suites are byte-identical to their .claude/tests/ sources (a
# plugin consumer runs the SAME suite the maintainer does, not a fork).
T4_OK=1
for b in $EXPECT_CONSUMER; do
  cmp -s "$SRC/tests/$b" "$PTESTS/$b" || { no "shipped $b differs from its .claude/tests/ source"; T4_OK=0; }
done
[ "$T4_OK" -eq 1 ] && ok "every shipped suite is byte-identical to its .claude/tests/ source"

# T5 — the layout-reconstructing runner ships and is executable.
RUNNER="$PTESTS/run-plugin-tests.sh"
if [ -f "$RUNNER" ] && [ -x "$RUNNER" ]; then
  ok "plugin/tests/run-plugin-tests.sh ships and is executable"
else
  no "plugin/tests/run-plugin-tests.sh must ship executable (the layout-reconstructing runner)"
fi

# T6 — DRIFT ASSERTION: the runner executes the shipped suite GREEN against the
# flattened plugin tree. This proves the location-relative suites resolve their
# scripts after the runner rebuilds the .claude/-shaped tree. A suite that
# couldn't find its script in plugin layout turns this red — exactly the drift
# the guard exists to catch.
if [ -f "$RUNNER" ]; then
  RUN_OUT=$(bash "$RUNNER" 2>"$TMP/runner.err"); RC=$?
  RUN_ERR_SZ=$(wc -c < "$TMP/runner.err" | tr -d ' ')
  if [ "$RC" -eq 0 ]; then
    ok "runner executes the shipped suite GREEN in plugin layout (rc=0)"
  else
    no "runner must run the shipped suite green; rc=$RC, tail: $(printf '%s' "$RUN_OUT" | grep -E 'FAIL|✗' | head -3 | tr '\n' ' ')"
  fi
  # the runner itself must keep stderr clean (the suite stderr gate extends to
  # the reconstruction plumbing — a reconstruction that errors to stderr is a
  # latent drift the gate would otherwise mask)
  [ "$RUN_ERR_SZ" -eq 0 ] \
    && ok "runner reconstruction is stderr-clean" \
    || no "runner emitted $RUN_ERR_SZ bytes to stderr: $(head -c 200 "$TMP/runner.err")"
  # the runner's own summary must report zero failed suites (a deterministic
  # check independent of the exit code, so a swallowed non-zero still surfaces)
  printf '%s\n' "$RUN_OUT" | grep -qE 'suites?:.*0 failed|0 suite\(s\) failed|All [0-9]+ shipped suites? passed' \
    && ok "runner summary reports zero failed suites" \
    || no "runner must print a summary naming zero failed suites (got: $(printf '%s' "$RUN_OUT" | tail -1))"
fi

# T7 — DRIFT GUARD must FAIL LOUD when a shipped suite cannot resolve its scripts
# in plugin layout. Plant a suite that self-locates a script the reconstruction
# can't provide and confirm the runner reports it as a failure (rc!=0). A guard
# that can only report success is not a guard (the plugin.test.sh pass-5 lesson).
if [ -f "$RUNNER" ]; then
  PLANT="$PTESTS/zz-ship-drift-fixture.test.sh"
  trap 'rm -rf "$TMP"; rm -f "$PLANT"' EXIT
  cat > "$PLANT" <<'PLANTED'
#!/bin/bash
# Planted drift: references a script the plugin layout cannot reconstruct.
set -u
MISSING="$(cd "$(dirname "$0")/.." && pwd)/zz-nonexistent-helper.sh"
PASS=0; FAIL=0
if [ -f "$MISSING" ]; then echo "  ✓ found"; PASS=1; else echo "  ✗ script not resolvable in plugin layout"; FAIL=1; fi
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
PLANTED
  PLANT_OUT=$(bash "$RUNNER" 2>/dev/null); PRC=$?
  rm -f "$PLANT"
  if [ "$PRC" -ne 0 ] && printf '%s\n' "$PLANT_OUT" | grep -q 'zz-ship-drift-fixture'; then
    ok "drift guard fails loud when a shipped suite can't resolve its scripts (planted fixture flagged)"
  else
    no "drift guard must fail (rc!=0) and name the offending suite when a shipped suite can't resolve its scripts (rc=$PRC)"
  fi
fi

finish
