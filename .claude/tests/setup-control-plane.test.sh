#!/bin/bash
# Tests for maintainers/setup-control-plane.sh — focused on the copy_core sync
# (what lands in the control plane's .claude/, and what must not).
# Pure bash + git, no test runner required (this template repo ships no JS suite).
# Run: bash .claude/tests/setup-control-plane.test.sh
set -u

REAL_SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/maintainers/setup-control-plane.sh"

# Maintainer tooling — a consumer repo that deleted maintainers/ still ships
# this suite, so skip cleanly instead of failing.
if [ ! -f "$REAL_SCRIPT" ]; then
  echo "  - maintainers/setup-control-plane.sh not present — skipping (consumer repo)"
  echo ""
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
# Keep fixtures + setup.log around on failure — they ARE the diagnostics.
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures + setup.log kept at $WORK)"' EXIT

# A fixture harness with the real script in place (HARNESS_DIR is derived from
# the script's own location, so it must live at <fixture>/maintainers/).
# Finder droppings are planted at the item root and one nested level deep —
# the nested one is what distinguishes a recursive scrub from a naive rm.
make_harness() {
  local h="$WORK/harness"
  rm -rf "$h"
  mkdir -p "$h/maintainers" "$h/.claude/commands" "$h/.claude/skills/task" "$h/.claude/hooks"
  cp "$REAL_SCRIPT" "$h/maintainers/"
  echo "# task" > "$h/.claude/skills/task/SKILL.md"
  echo "# cmd" > "$h/.claude/commands/status.md"
  echo "hook" > "$h/.claude/hooks/guard.sh"
  mkdir -p "$h/.claude/rules"
  printf 'guv rule body v1\n' > "$h/.claude/rules/guv-core.md"
  echo "archive" > "$h/.claude/archive-initiative.sh"
  echo '{}' > "$h/.claude/settings.json"
  touch "$h/.claude/skills/.DS_Store" "$h/.claude/skills/task/.DS_Store" "$h/.claude/commands/.DS_Store"
  echo "$h"
}
run_setup() { ( bash "$1/maintainers/setup-control-plane.sh" "$2" ${3:-} ) >> "$WORK/setup.log" 2>&1; }

# T1 — create mode copies the core...
H=$(make_harness)
D="$WORK/control"
run_setup "$H" "$D"
[ -f "$D/.claude/skills/task/SKILL.md" ] && [ -f "$D/.claude/rules/guv-core.md" ] \
  && [ -f "$D/.claude/archive-initiative.sh" ] \
  && ok "create: core copied (skills, guv rules, archive-initiative.sh present)" \
  || no "create: core (incl. .claude/rules/guv-*) should be copied to the control plane"

# T2 — ...but no .DS_Store comes along, at any depth.
FOUND=$(find "$D/.claude" -name '.DS_Store' 2>/dev/null)
[ -z "$FOUND" ] && ok "create: no .DS_Store copied into the control plane" \
  || no "create: .DS_Store leaked into the control plane: $FOUND"
grep -q '^\.DS_Store$' "$D/.gitignore" && ok "create: generated .gitignore covers .DS_Store" \
  || no "generated .gitignore should ignore .DS_Store (Finder recreates them at the root)"
grep -q "auto memory as hints" "$D/CLAUDE.md" \
  && ok "create: generated CLAUDE.md carries the memory-authority line" \
  || no "generated CLAUDE.md should declare manifest+handoff authority over auto memory"

# T3 — --sync also scrubs a .DS_Store that already sits in the destination core
# (rm -rf + re-copy of each item must not leave or re-introduce one).
H=$(make_harness)
D="$WORK/control2"
run_setup "$H" "$D"
touch "$D/.claude/skills/.DS_Store"
run_setup "$H" "$D" --sync
FOUND=$(find "$D/.claude" -name '.DS_Store' 2>/dev/null)
[ -z "$FOUND" ] && ok "sync: copied core stays .DS_Store-free" \
  || no "sync: .DS_Store survived/leaked: $FOUND"

# T4 — sync refreshes the core but leaves session state alone, byte-for-byte
# (the full contract the script's header states: manifest, CLAUDE.md, docs,
# and feedback untouched). Sentinel CONTENT is asserted, not mere existence —
# a regression that recreated/emptied these files must fail here.
H=$(make_harness)
D="$WORK/control3"
run_setup "$H" "$D"
mkdir -p "$D/.claude/feedback" "$D/docs/sessions"
echo '{"id":"sentinel-feedback"}' > "$D/.claude/feedback/feedback.ndjson"
echo "# sentinel-handoff" > "$D/docs/sessions/session-1.md"
echo "sentinel-claude-md" > "$D/CLAUDE.md"
echo '{"name":"sentinel-manifest"}' > "$D/.claude/project.json"
mkdir -p "$D/.claude/rules"
echo "consumer rule — mine" > "$D/.claude/rules/team-style.md"
echo "legacy rules file" > "$D/.claude/RULES.md"
echo "edited" > "$H/.claude/rules/guv-core.md"
run_setup "$H" "$D" --sync
grep -q "edited" "$D/.claude/rules/guv-core.md" 2>/dev/null \
  && ok "sync: stale guv-* rule refreshed" \
  || no "sync: guv-* rules should be refreshed"
grep -qx "consumer rule — mine" "$D/.claude/rules/team-style.md" 2>/dev/null \
  && ok "sync: consumer-authored rule survives byte-for-byte" \
  || no "sync: unprefixed consumer rules must never be touched"
[ ! -f "$D/.claude/RULES.md" ] \
  && ok "sync: superseded .claude/RULES.md deleted (no double-load)" \
  || no "sync: legacy .claude/RULES.md should be removed"
grep -q "sentinel-feedback" "$D/.claude/feedback/feedback.ndjson" 2>/dev/null \
  && grep -q "sentinel-handoff" "$D/docs/sessions/session-1.md" 2>/dev/null \
  && ok "sync: feedback + session artifact contents untouched" \
  || no "sync: must not touch control-plane session state"
grep -q "sentinel-claude-md" "$D/CLAUDE.md" 2>/dev/null \
  && grep -q "sentinel-manifest" "$D/.claude/project.json" 2>/dev/null \
  && ok "sync: CLAUDE.md + manifest contents untouched" \
  || no "sync: must not touch CLAUDE.md or the manifest"

# T5 — create-mode never-clobber: re-running create on an existing control
# plane must not overwrite the manifest, CLAUDE.md, or the test runner
# ("write ... ONLY if they don't exist yet").
H=$(make_harness)
D="$WORK/control4"
run_setup "$H" "$D"
echo "sentinel-claude-md" > "$D/CLAUDE.md"
echo '{"name":"sentinel-manifest"}' > "$D/.claude/project.json"
echo "# sentinel-runner" > "$D/.claude/run-harness-tests.sh"
echo "edited-again" > "$H/.claude/rules/guv-core.md"
run_setup "$H" "$D"
grep -q "edited-again" "$D/.claude/rules/guv-core.md" 2>/dev/null \
  && ok "create re-run: executed (core re-synced)" \
  || no "create re-run positive control: second run should re-sync the core"
grep -q "sentinel-claude-md" "$D/CLAUDE.md" 2>/dev/null \
  && grep -q "sentinel-manifest" "$D/.claude/project.json" 2>/dev/null \
  && grep -q "sentinel-runner" "$D/.claude/run-harness-tests.sh" 2>/dev/null \
  && ok "create re-run: existing manifest/CLAUDE.md/runner not clobbered" \
  || no "create re-run must not clobber existing control-plane files"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
