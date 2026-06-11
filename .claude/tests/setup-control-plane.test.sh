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
  mkdir -p "$h/.claude/rules" "$h/.claude/workflows/dir-wf"
  printf 'guv rule body v1\n' > "$h/.claude/rules/guv-core.md"
  echo "export const meta = {}" > "$h/.claude/workflows/evaluate-parallel.js"
  echo "dir-wf main v1" > "$h/.claude/workflows/dir-wf/main.js"
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
[ -f "$D/.claude/workflows/evaluate-parallel.js" ] \
  && ok "create: workflows dir copied (saved workflows are core)" \
  || no "create: .claude/workflows/ should be copied to the control plane"

# T2 — ...but no .DS_Store comes along, at any depth.
FOUND=$(find "$D/.claude" -name '.DS_Store' 2>/dev/null)
[ -z "$FOUND" ] && ok "create: no .DS_Store copied into the control plane" \
  || no "create: .DS_Store leaked into the control plane: $FOUND"
grep -q '^\.DS_Store$' "$D/.gitignore" && ok "create: generated .gitignore covers .DS_Store" \
  || no "generated .gitignore should ignore .DS_Store (Finder recreates them at the root)"
grep -q "auto memory as hints" "$D/CLAUDE.md" \
  && ok "create: generated CLAUDE.md carries the memory-authority line" \
  || no "generated CLAUDE.md should declare manifest+handoff authority over auto memory"
# The heredoc is unquoted (it interpolates $CODE_REL) — an unescaped backtick
# would silently execute as command substitution. Pin the literal backticks.
grep -qF '`.claude/rules/`' "$D/CLAUDE.md" \
  && ok "create: heredoc backticks render literally (escaping intact)" \
  || no "generated CLAUDE.md lost its literal backticks — unquoted-heredoc escaping broke"

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
cp "$D/.claude/rules/team-style.md" "$WORK/team-style.before"
echo "legacy rules file" > "$D/.claude/RULES.md"
echo "edited" > "$H/.claude/rules/guv-core.md"
echo "consumer workflow — mine" > "$D/.claude/workflows/my-migration.js"
cp "$D/.claude/workflows/my-migration.js" "$WORK/my-migration.before"
echo "wf-edited" > "$H/.claude/workflows/evaluate-parallel.js"
echo "stale" > "$D/.claude/workflows/dir-wf/stale-nested.js"
echo "dir-wf main v2" > "$H/.claude/workflows/dir-wf/main.js"
( bash "$H/maintainers/setup-control-plane.sh" "$D" --sync ) > "$WORK/sync.out" 2>&1
grep -q "edited" "$D/.claude/rules/guv-core.md" 2>/dev/null \
  && ok "sync: stale guv-* rule refreshed" \
  || no "sync: guv-* rules should be refreshed"
cmp -s "$WORK/team-style.before" "$D/.claude/rules/team-style.md" \
  && ok "sync: consumer-authored rule survives byte-for-byte (cmp)" \
  || no "sync: unprefixed consumer rules must never be touched"
grep -q "wf-edited" "$D/.claude/workflows/evaluate-parallel.js" 2>/dev/null \
  && ok "sync: stale harness workflow refreshed" \
  || no "sync: harness-shipped workflows should be refreshed"
cmp -s "$WORK/my-migration.before" "$D/.claude/workflows/my-migration.js" \
  && ok "sync: consumer-saved workflow survives byte-for-byte (cmp)" \
  || no "sync: user-saved workflows must never be touched (native feature saves them here)"
# Directory-entry workflow: refresh must REPLACE the destination dir, not merge
# into it (plain cp -R into an existing dir leaves stale nested files behind —
# the rm-rf-per-basename line is what this guards).
grep -q "dir-wf main v2" "$D/.claude/workflows/dir-wf/main.js" 2>/dev/null \
  && [ ! -e "$D/.claude/workflows/dir-wf/stale-nested.js" ] \
  && ok "sync: directory-entry workflow replaced, stale nested file gone" \
  || no "sync: dir-entry workflows must be replaced wholesale (refresh + no stale nested files)"
[ ! -f "$D/.claude/RULES.md" ] \
  && ok "sync: superseded .claude/RULES.md deleted (no double-load)" \
  || no "sync: legacy .claude/RULES.md should be removed"
grep -q "removed superseded .claude/RULES.md" "$WORK/sync.out" \
  && ok "sync: deletion announced (where customizations belong, import-line edit)" \
  || no "sync must announce the RULES.md removal, not delete silently"
OUT2=$( (bash "$H/maintainers/setup-control-plane.sh" "$D" --sync) 2>&1 )
echo "$OUT2" | grep -q "synced harness core" || no "second sync should still complete"
echo "$OUT2" | grep -q "removed superseded" \
  && no "sync: deletion notice should not repeat once the file is gone" \
  || ok "sync: deletion notice fires once, silent thereafter"
grep -q "sentinel-feedback" "$D/.claude/feedback/feedback.ndjson" 2>/dev/null \
  && grep -q "sentinel-handoff" "$D/docs/sessions/session-1.md" 2>/dev/null \
  && ok "sync: feedback + session artifact contents untouched" \
  || no "sync: must not touch control-plane session state"
grep -q "sentinel-claude-md" "$D/CLAUDE.md" 2>/dev/null \
  && grep -q "sentinel-manifest" "$D/.claude/project.json" 2>/dev/null \
  && ok "sync: CLAUDE.md + manifest contents untouched" \
  || no "sync: must not touch CLAUDE.md or the manifest"

# T5 — create-mode never-clobber: re-running create on an existing control
# plane must not overwrite the manifest or CLAUDE.md ("write ... ONLY if they
# don't exist yet"). The generated test runner is the exception: it carries no
# consumer state, so it is harness-owned and refreshed like guv-* rules
# (entry 2026-06-11T23:17:51Z-15612590 — create-only meant generator
# improvements never reached existing control planes).
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
  && ok "create re-run: existing manifest/CLAUDE.md not clobbered" \
  || no "create re-run must not clobber the manifest or CLAUDE.md"
if ! grep -q "sentinel-runner" "$D/.claude/run-harness-tests.sh" 2>/dev/null \
  && grep -q '\[stderr\]' "$D/.claude/run-harness-tests.sh" 2>/dev/null; then
  ok "create re-run: drifted runner refreshed (harness-owned, no consumer state)"
else
  no "create re-run should refresh the generated runner — it is harness-owned"
fi

# T6 — generated runner enforces the empty-stderr gate: a suite that PASSES but
# writes to stderr must fail the run (a green summary above a parse error is
# how a vacuous guard slipped two review gates — session-2026-06-11-003).
# The clean-suite case first is the positive control for the runner itself.
H=$(make_harness)
D="$WORK/control-runner"
mkdir -p "$H/.claude/tests"
printf '#!/bin/bash\necho "  ok"\nexit 0\n' > "$H/.claude/tests/clean.test.sh"
run_setup "$H" "$D"
( cd "$D" && bash .claude/run-harness-tests.sh ) >/dev/null 2>&1 \
  && ok "runner: clean passing suite -> run passes" \
  || no "runner: a clean passing suite should pass the run"
printf '#!/bin/bash\necho "  ok"\necho "boom: parse error" >&2\nexit 0\n' > "$H/.claude/tests/noisy.test.sh"
OUT=$( cd "$D" && bash .claude/run-harness-tests.sh 2>&1 )
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '\[stderr\]'; then
  ok "runner: passing suite with stderr output fails the run and surfaces it"
else
  no "runner: stderr from a suite must fail the run (rc=$RC)"
fi

# T7 — the CI workflow's inline test loop carries the same stderr gate (it is
# the third copy of the loop — the generator-emitted runner above is the
# behaviorally-tested reference; this drift guard keeps the CI copy honest).
# Conditional: forks may delete .github/ along with the rest of maintainer CI.
CI_YML="$(cd "$(dirname "$REAL_SCRIPT")/.." && pwd)/.github/workflows/template-clean.yml"
if [ -f "$CI_YML" ]; then
  grep -q '\[stderr\]' "$CI_YML" && grep -q '2>"\$err"' "$CI_YML" \
    && ok "CI test loop carries the stderr gate (capture + fail markers present)" \
    || no "CI inline loop drifted from the runner: per-suite stderr capture/fail missing"
else
  echo "  - .github workflow absent (fork) — CI stderr-gate drift guard skips"
fi

# T8 — --sync refreshes the generated test runner (the same entry as T5's
# exception: the D3 stderr-gate fix changed the runner heredoc and the live
# copy had to be hand-edited to match — any drift from the generator is stale
# harness code, not consumer state).
H=$(make_harness)
D="$WORK/control5"
run_setup "$H" "$D"
echo "# stale-runner" > "$D/.claude/run-harness-tests.sh"
OUT=$( (bash "$H/maintainers/setup-control-plane.sh" "$D" --sync) 2>&1 )
if grep -q '\[stderr\]' "$D/.claude/run-harness-tests.sh" 2>/dev/null \
  && ! grep -q "stale-runner" "$D/.claude/run-harness-tests.sh" 2>/dev/null; then
  ok "sync: drifted runner refreshed to the generator's content"
else
  no "sync must refresh the generated runner (create-only leaves drift in place)"
fi
[ -x "$D/.claude/run-harness-tests.sh" ] \
  && ok "sync: refreshed runner stays executable" \
  || no "sync: refreshed runner lost its executable bit"
echo "$OUT" | grep -q "refreshed .claude/run-harness-tests.sh" \
  && ok "sync: runner refresh announced (not rewritten silently)" \
  || no "sync must announce the runner refresh"
OUT2=$( (bash "$H/maintainers/setup-control-plane.sh" "$D" --sync) 2>&1 )
echo "$OUT2" | grep -q "refreshed .claude/run-harness-tests.sh" \
  && no "sync: refresh notice should not repeat when the runner is already current" \
  || ok "sync: refresh notice fires only on change, silent when current"

# T9 — DOGFOODING.md re-derived against current reality (Phase 5 D4). The doc
# documents this script's loop, so its accuracy guards live with this suite.
# Conditional like T7: a fork may strip individual maintainer docs.
DOG="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)/DOGFOODING.md"
if [ -f "$DOG" ]; then
  grep -v '\.github' "$DOG" | grep -q 'workflows' \
    && ok "DOGFOODING: workflows/ present in the synced-core description" \
    || no "DOGFOODING must name workflows/ among the synced core (Phase 4 addition — the .github/workflows CI path does not count)"
  grep -q 'build-plugin\.sh' "$DOG" && grep -q 'plugin-src' "$DOG" \
    && ok "DOGFOODING: plugin generator + authored sources named" \
    || no "DOGFOODING must name build-plugin.sh and plugin-src/ (Phase 5 tooling)"
  grep -q 'RELEASING\.md' "$DOG" \
    && ok "DOGFOODING: RELEASING.md in the what-lives-in-the-harness-repo list" \
    || no "DOGFOODING must list RELEASING.md among durable maintainer tooling"
  grep -q 'unreleased' "$DOG" \
    && ok "DOGFOODING: maintainer disposition — --sync kept for unreleased changes" \
    || no "DOGFOODING must state why --sync survives the plugin (unreleased changes)"
  grep -q 'plan-initiative' "$DOG" \
    && ok "DOGFOODING: ceremony flip acknowledged (seeded task, initiative flips it)" \
    || no "DOGFOODING must reflect that /plan-initiative can flip the control plane to phased"
  if grep -q 'pinned to the template repo' "$DOG"; then
    no "DOGFOODING: stale single-pin CI phrasing survives ('pinned to the template repo')"
  else
    ok "DOGFOODING: stale single-pin CI phrasing gone"
  fi
  # Positive control: an absence grep passes vacuously if the pattern is typo'd.
  printf 'x pinned to the template repo x\n' | grep -q 'pinned to the template repo' \
    && ok "DOGFOODING: stale-phrase decoder matches a planted violation" \
    || no "DOGFOODING: stale-phrase decoder broken (planted violation not matched)"
else
  echo "  - maintainers/DOGFOODING.md absent (fork) — re-derivation guards skip"
fi

# T10 — the README's template-clone fallback states the DECIDED consumer
# disposition (Phase 5 D4): an existing clone is told whether to migrate to
# plugin updates or keep syncing — an answer, not an inherited parenthetical.
RM="$(cd "$(dirname "$REAL_SCRIPT")/.." && pwd)/README.md"
if [ -f "$RM" ]; then
  grep -qi 'keep syncing' "$RM" && grep -qi 'migrat' "$RM" \
    && ok "README: existing clones told migrate-or-keep-syncing (decided disposition)" \
    || no "README fallback must state the disposition for existing template clones"
  grep -qiE 'double.load|dual.load' "$RM" \
    && ok "README: migration guidance names the double-load hazard" \
    || no "README migration guidance must warn about double-loading the copied core"
else
  echo "  - README.md absent (fork) — disposition guards skip"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
