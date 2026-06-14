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
# Pure bash + jq. Run: bash <plugin>/tests/run-plugin-tests.sh
set -u

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

PASS_SUITES=0; FAIL_SUITES=0; FAILED_NAMES=""
for t in "$REC/tests"/*.test.sh; do
  b="$(basename "$t")"
  echo "── $b ──"
  if bash "$t"; then
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
[ "$FAIL_SUITES" -eq 0 ]
