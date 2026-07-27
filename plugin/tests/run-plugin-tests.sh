#!/bin/bash
# Layout-reconstructing runner for the shipped guv test suites ([10.3]).
# The plugin ships scripts FLATTENED into scripts/; the consumer suites self-
# locate via $(dirname "$0")/.. expecting a .claude/-shaped tree (scripts at the
# top level, hooks in hooks/, tests in tests/). This runner rebuilds that shape in
# a temp dir and runs every shipped suite against it, so the location-relative
# suites verify the plugin's INSTALLED script copies unmodified.
#
# Hooks are recovered deterministically: a script is a hook iff hooks.json
# references it (the build flattens both into scripts/; hooks.json is the only
# record of which were hooks). Everything else in scripts/ is a top-level helper.
#
# Pure bash + jq. Run: bash <plugin>/tests/run-plugin-tests.sh [--only <pattern>]
set -u

# --only <pattern> ([22.1]): run just the shipped suites whose basename matches
# the glob PATTERN. The reconstruction below is always FULL (the filter gates
# suite execution, never the rebuild), so a placement probe run under --only
# still inspects the complete reconstructed tree. A pattern that matches no
# suite fails LOUD at the filter — never a vacuous green.
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      shift
      { [ $# -gt 0 ] && [ -n "$1" ]; } || { echo "run-plugin-tests: --only requires a non-empty pattern" >&2; exit 2; }
      ONLY="$1"; shift ;;
    *) echo "run-plugin-tests: unknown argument: $1 (supported: --only <pattern>)" >&2; exit 2 ;;
  esac
done

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$PLUGIN/scripts"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
TESTS="$PLUGIN/tests"
RULES="$PLUGIN/rules"

if [ ! -d "$SCRIPTS" ] || [ ! -f "$HOOKS_JSON" ]; then
  echo "run-plugin-tests: not a plugin tree (missing scripts/ or hooks/hooks.json): $PLUGIN" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REC="$WORK/.claude"
mkdir -p "$REC/hooks" "$REC/tests" "$REC/rules"

# the hook basenames hooks.json references — these scripts were .claude/hooks/X.sh
HOOK_NAMES="$(jq -r '.hooks[][]?.hooks[]?.command' "$HOOKS_JSON" 2>/dev/null \
  | grep -oE '[A-Za-z0-9_-]+\.sh' | sort -u)"
is_hook() { printf '%s\n' "$HOOK_NAMES" | grep -qx "$1"; }

for s in "$SCRIPTS"/*.sh; do
  [ -e "$s" ] || continue
  b="$(basename "$s")"
  if is_hook "$b"; then cp "$s" "$REC/hooks/$b"; else cp "$s" "$REC/$b"; fi
done
chmod +x "$REC"/*.sh "$REC/hooks"/*.sh 2>/dev/null || true

# bundled single-owner scripts ([8.3]) live under skills/<name>/scripts/ in the
# plugin (resolved via ${CLAUDE_SKILL_DIR}); reconstruct them at the same path so
# a shipped suite testing a bundled script resolves it from the rebuilt .claude/.
for sd in "$PLUGIN"/skills/*/scripts/*.sh; do
  [ -e "$sd" ] || continue
  sn="$(basename "$(dirname "$(dirname "$sd")")")"
  mkdir -p "$REC/skills/$sn/scripts"
  cp "$sd" "$REC/skills/$sn/scripts/$(basename "$sd")"
  chmod +x "$REC/skills/$sn/scripts/$(basename "$sd")"
done

# rules ship as plugin assets; some location-relative suites read .claude/rules/
[ -d "$RULES" ] && cp "$RULES"/*.md "$REC/rules/" 2>/dev/null || true

# the suites themselves, into the reconstructed tests/ so $(dirname "$0")/.. lands
# on the reconstructed .claude/
SHIPPED=0
for t in "$TESTS"/*.test.sh; do
  [ -e "$t" ] || continue
  b="$(basename "$t")"
  case "$b" in run-plugin-tests.sh) continue ;; esac
  cp "$t" "$REC/tests/$b"
  SHIPPED=$((SHIPPED + 1))
done

if [ "$SHIPPED" -eq 0 ]; then
  echo "run-plugin-tests: no shipped suites found in $TESTS" >&2
  exit 2
fi

# ── gate integrity ([15.1]): the plugin battery shares the core runner's three
# coupled guards, so a shipped suite that hangs, errors to stderr, or reports a
# stdout-only failure can never show green here either.
#  (a) per-suite timeout — a hung shipped suite fails LOUD with a named timeout
#      (rc 124), never a silent stall; a missing timeout binary degrades to an
#      announced unbounded run (Rule 15).
#  (b) bounded parallel pool + deterministic aggregation — EVERY suite runs
#      concurrently (≤ POOL_JOBS), each into its own out/err/rc; a final pass
#      replays them in sorted name order so wall-clock drops toward the slowest
#      while output + verdict stay deterministic.
#
#      There is no serial carve here, and — unlike the core runner — no
#      hermeticity fingerprint either, both for the same reason: this battery has
#      NO live source tree to protect. The suites are copied into the
#      reconstructed $REC tree above, so a suite's own $(dirname "$0")/.. resolves
#      to that scratch copy and a fixture planted at a "fixed path" lands inside a
#      throwaway directory. The core runner's guard exists because its suites run
#      against the real repo; that hazard has no analogue on this side.
#
#      (The carve this replaced named plugin.test.sh + ship-suite.test.sh, per
#      maintainers/BATTERY-HERMETICITY.md. It was retired when spike Prong B made
#      both suites hermetic and the core runner began verifying the property
#      directly instead of quarantining a hand-maintained list. Here it was doubly
#      redundant: both suites are maintainer-only and rarely reach the SHIPPED
#      partition at all.)
#  (c) no exit-masking / no stdout-only blindness — the gate fails a suite on ANY
#      of: nonzero rc, ANY stderr byte, or a failure-shaped stdout verdict (a ✗
#      line or "Results: N passed, M failed" with M>0) even at exit 0. The runner's
#      final statement is its exit on the aggregated verdict.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
fi
SUITE_TIMEOUT="${PLUGIN_TEST_TIMEOUT:-300}"
[ -z "$TIMEOUT_BIN" ] && echo "[run-plugin-tests] no timeout/gtimeout on PATH — suites run UNBOUNDED (a hang will not be caught; install coreutils to restore the per-suite timeout guard)"
POOL_JOBS="${PLUGIN_TEST_JOBS:-}"
if [ -z "$POOL_JOBS" ]; then
  POOL_JOBS=$( { command -v nproc >/dev/null 2>&1 && nproc; } \
            || { command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu; } \
            || echo 4 )
fi
case "$POOL_JOBS" in ''|*[!0-9]*) POOL_JOBS=4 ;; esac
[ "$POOL_JOBS" -lt 1 ] && POOL_JOBS=1

# collect the reconstructed suites in stable sorted order — the spine of the
# launch list and the aggregation pass
SUITES=()
while IFS= read -r t; do SUITES+=("$t"); done < <(
  for t in "$REC/tests"/*.test.sh; do [ -e "$t" ] && printf '%s\n' "$t"; done | LC_ALL=C sort
)

# apply the --only filter ([22.1]): keep the matching basenames. Zero matches is
# a loud failure, never a vacuous green — a typo'd pattern silently running zero
# suites would let every --only consumer's proof pass on nothing.
if [ -n "$ONLY" ]; then
  KEEP=()
  for t in "${SUITES[@]}"; do
    # shellcheck disable=SC2254 — $ONLY is deliberately an unquoted glob pattern
    case "$(basename "$t")" in $ONLY) KEEP+=("$t") ;; esac
  done
  if [ "${#KEEP[@]}" -eq 0 ]; then
    echo "run-plugin-tests: --only '$ONLY' matched no shipped suite" >&2
    exit 2
  fi
  SUITES=("${KEEP[@]}")
fi

run_one() {  # $1 = suite path  $2 = scratch key
  local t="$1" key="$2"
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" -k 5 "$SUITE_TIMEOUT" bash "$t" \
      >"$WORK/$key.out" 2>"$WORK/$key.err"
  else
    bash "$t" >"$WORK/$key.out" 2>"$WORK/$key.err"
  fi
  printf '%s\n' "$?" > "$WORK/$key.rc"
}

# bounded pool — every suite, at most $POOL_JOBS in flight. No carve: the suites
# run out of the reconstructed $REC tree, so there is no shared live source tree
# for them to collide over.
running=0
for i in "${!SUITES[@]}"; do
  run_one "${SUITES[$i]}" "rps-$i" &
  running=$((running + 1))
  if [ "$running" -ge "$POOL_JOBS" ]; then
    wait -n 2>/dev/null || wait
    running=$((running - 1))
  fi
done
wait

# deterministic SERIAL aggregation under the identical gate
PASS_SUITES=0; FAIL_SUITES=0; FAILED_NAMES=""
for i in "${!SUITES[@]}"; do
  t="${SUITES[$i]}"; b="$(basename "$t")"
  echo "── $b ──"
  cat "$WORK/rps-$i.out" 2>/dev/null
  rc=$(cat "$WORK/rps-$i.rc" 2>/dev/null || echo 1)
  suite_failed=0
  if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
    echo "[timeout] $b TIMED OUT after ${SUITE_TIMEOUT}s (rc=$rc) — failing the run (a hang, not slowness)"
    suite_failed=1
  elif [ "$rc" != "0" ]; then
    suite_failed=1
  fi
  if [ -s "$WORK/rps-$i.err" ]; then
    echo "[stderr] $b wrote to stderr — failing the run:"
    cat "$WORK/rps-$i.err"
    suite_failed=1
  fi
  if grep -q '✗' "$WORK/rps-$i.out" 2>/dev/null \
     || grep -qE 'Results:[[:space:]]*[0-9]+[[:space:]]*passed,[[:space:]]*[1-9][0-9]*[[:space:]]*failed' "$WORK/rps-$i.out" 2>/dev/null; then
    echo "[stdout] $b reported a FAILURE on stdout while exit was $rc — failing the run"
    suite_failed=1
  fi
  if [ "$suite_failed" -eq 0 ]; then
    PASS_SUITES=$((PASS_SUITES + 1))
  else
    FAIL_SUITES=$((FAIL_SUITES + 1))
    FAILED_NAMES="$FAILED_NAMES $b"
  fi
  echo ""
done

echo "════════════════════════════════════════"
if [ "$FAIL_SUITES" -eq 0 ]; then
  echo "All $PASS_SUITES shipped suites passed in plugin layout (suites: 0 failed)"
else
  echo "Plugin-layout suites: $PASS_SUITES passed, $FAIL_SUITES failed —$FAILED_NAMES"
fi
# the verdict IS the exit, and nothing follows it (no trailing-command masking)
exit "$([ "$FAIL_SUITES" -eq 0 ] && echo 0 || echo 1)"
