#!/bin/bash
# Tests for maintainers/setup-control-plane.sh — focused on the copy_core sync
# (what lands in the control plane's .claude/, and what must not).
# Pure bash + git, no test runner required (this template repo ships no JS suite).
# Run: bash .claude/tests/setup-control-plane.test.sh
set -u

REAL_SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/maintainers/setup-control-plane.sh"
REAL_ROOTS_SH="$(cd "$(dirname "$0")/.." && pwd)/roots.sh"  # shipped beside the generated runner ([11.2])
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"   # absolute — $0-relative re-invocation breaks if a cd ever lands in the main shell

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

# [19.5] The hook-registration dedup reads the user's plugin DB to decide whether to
# strip the synced settings.json hooks (plugin authoritative). Pin a NEUTRAL
# (nonexistent) DB suite-wide so the ambient HOST plugin install never leaks into the
# unrelated fixtures — every test except T12 then sees "no plugin → keep hooks",
# host-independently. The T12 dedup cases override GUV_PLUGINS_DB per invocation.
export GUV_PLUGINS_DB="$WORK/no-such-plugins-db.json"

# A fixture guv repo with the real script in place (GUV_DIR is derived from
# the script's own location, so it must live at <fixture>/maintainers/).
# Finder droppings are planted at the item root and one nested level deep —
# the nested one is what distinguishes a recursive scrub from a naive rm.
make_guv() {
  local h="$WORK/guv"
  rm -rf "$h"
  mkdir -p "$h/maintainers" "$h/.claude/skills/status" "$h/.claude/skills/task" "$h/.claude/hooks"
  cp "$REAL_SCRIPT" "$h/maintainers/"
  echo "# task" > "$h/.claude/skills/task/SKILL.md"
  echo "# cmd" > "$h/.claude/skills/status/SKILL.md"
  echo "hook" > "$h/.claude/hooks/guard.sh"
  mkdir -p "$h/.claude/rules" "$h/.claude/workflows/dir-wf"
  printf 'guv rule body v1\n' > "$h/.claude/rules/guv-core.md"
  echo "export const meta = {}" > "$h/.claude/workflows/eval-parallel.js"
  echo "dir-wf main v1" > "$h/.claude/workflows/dir-wf/main.js"
  echo "archive" > "$h/.claude/archive-initiative.sh"
  echo "resolver" > "$h/.claude/resolve-ready.sh"
  # The generated run-core-tests.sh sources roots.sh to resolve the code repo
  # ([11.2]); the real copy_core ships it via the *.sh glob, so the fixture must
  # provide it too or the runner can't source it. A faithful minimal resolver:
  # roots.code string is the primary, '.' / no manifest is single-repo.
  cp "$REAL_ROOTS_SH" "$h/.claude/roots.sh"
  # A realistic settings.json carrying BOTH a hooks block (the [19.5] double-fire
  # surface — what the plugin-dedup strips) and a non-hook key (permissions — the
  # survives-the-strip control). The suite-wide neutral GUV_PLUGINS_DB keeps these
  # hooks in place for every fixture except T12's explicit plugin-present cases.
  cat > "$h/.claude/settings.json" <<'JSON'
{
  "permissions": { "allow": ["Read(*)"], "deny": [] },
  "hooks": {
    "Stop": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR:-$PWD}\"/.claude/hooks/occupancy-meter.sh" }
      ] }
    ]
  }
}
JSON
  touch "$h/.claude/skills/.DS_Store" "$h/.claude/skills/task/.DS_Store" "$h/.claude/skills/status/.DS_Store"
  echo "$h"
}
run_setup() { ( bash "$1/maintainers/setup-control-plane.sh" "$2" ${3:-} ) >> "$WORK/setup.log" 2>&1; }

# T1 — create mode copies the core...
H=$(make_guv)
D="$WORK/control"
run_setup "$H" "$D"
[ -f "$D/.claude/skills/task/SKILL.md" ] && [ -f "$D/.claude/rules/guv-core.md" ] \
  && [ -f "$D/.claude/archive-initiative.sh" ] && [ -f "$D/.claude/resolve-ready.sh" ] \
  && ok "create: core copied (skills, guv rules, archive + resolver scripts present)" \
  || no "create: core should be copied (archive + resolver helpers asserted here; copy_core's hand-enumerated list means an unlisted helper is unreachable by sync — the class is retired by [7.1]'s glob-derived registry)"
[ -f "$D/.claude/workflows/eval-parallel.js" ] \
  && ok "create: workflows dir copied (saved workflows are core)" \
  || no "create: .claude/workflows/ should be copied to the control plane"

# T1b — glob-derived helper registry ([7.1]): a helper the enumeration never
# heard of must reach the plane on create AND refresh on --sync, with zero
# copy_core edits. Red until copy_core derives the .sh set by glob.
H2=$(make_guv)
echo "fixture v1" > "$H2/.claude/zzregistry-fixture.sh"
D2="$WORK/control-registry"
run_setup "$H2" "$D2"
[ -f "$D2/.claude/zzregistry-fixture.sh" ] \
  && ok "create: unlisted helper reaches the plane (registry is glob-derived)" \
  || no "create: a dropped-in helper must be copied without touching copy_core"
echo "fixture v2" > "$H2/.claude/zzregistry-fixture.sh"
run_setup "$H2" "$D2" --sync
grep -q "fixture v2" "$D2/.claude/zzregistry-fixture.sh" 2>/dev/null \
  && ok "sync: unlisted helper refreshed (registry is glob-derived)" \
  || no "sync: a dropped-in helper must refresh without touching copy_core"

# T2 — ...but no .DS_Store comes along, at any depth.
FOUND=$(find "$D/.claude" -name '.DS_Store' 2>/dev/null)
[ -z "$FOUND" ] && ok "create: no .DS_Store copied into the control plane" \
  || no "create: .DS_Store leaked into the control plane: $FOUND"
grep -q '^\.DS_Store$' "$D/.gitignore" && ok "create: generated .gitignore covers .DS_Store" \
  || no "generated .gitignore should ignore .DS_Store (Finder recreates them at the root)"
# The fan-out scratch (.lane-reports/) lives in the CONTROL PLANE, not roots.code —
# the worktrees live in roots.code (covered by the scaffold's guv-core block), so
# the plane's own gitignore must carry the lane-reports dir (UAT-F4).
grep -q '^\.lane-reports/$' "$D/.gitignore" && ok "create: generated .gitignore covers .lane-reports/ (control-plane fan-out scratch)" \
  || no "generated .gitignore should ignore .lane-reports/ (UAT-F4: plane scratch left untracked)"
tr '\n' ' ' < "$D/CLAUDE.md" 2>/dev/null | tr -s ' ' | grep -q "auto memory as hints" \
  && ok "create: generated CLAUDE.md carries the memory-authority line" \
  || no "generated CLAUDE.md should declare manifest+handoff authority over auto memory"
# The heredoc is unquoted (it interpolates $CODE_REL) — an unescaped backtick
# would silently execute as command substitution. Pin the literal backticks.
grep -qF '`.claude/rules/`' "$D/CLAUDE.md" \
  && ok "create: heredoc backticks render literally (escaping intact)" \
  || no "generated CLAUDE.md lost its literal backticks — unquoted-heredoc escaping broke"

# T3 — --sync also scrubs a .DS_Store that already sits in the destination core
# (rm -rf + re-copy of each item must not leave or re-introduce one).
H=$(make_guv)
D="$WORK/control2"
run_setup "$H" "$D"
touch "$D/.claude/skills/.DS_Store"
run_setup "$H" "$D" --sync
FOUND=$(find "$D/.claude" -name '.DS_Store' 2>/dev/null)
[ -z "$FOUND" ] && ok "sync: copied core stays .DS_Store-free" \
  || no "sync: .DS_Store survived/leaked: $FOUND"

# T3c — --sync backfills .lane-reports/ into an EXISTING plane whose .gitignore
# predates the line (create-mode write is skipped when a .gitignore exists), and
# is idempotent (a second --sync does not duplicate it). UAT-F4 + eval Minor.
H=$(make_guv)
D="$WORK/control-gi"
run_setup "$H" "$D"
# Simulate a plane scaffolded before the line shipped: strip it back out.
grep -v '^\.lane-reports/$' "$D/.gitignore" > "$D/.gitignore.tmp" && mv "$D/.gitignore.tmp" "$D/.gitignore"
grep -qxF '.lane-reports/' "$D/.gitignore" && no "precondition: .lane-reports/ should be stripped before the sync test"
run_setup "$H" "$D" --sync
grep -qxF '.lane-reports/' "$D/.gitignore" \
  && ok "sync: backfills .lane-reports/ into an existing plane's .gitignore" \
  || no "sync must ensure .lane-reports/ is ignored on an existing plane (UAT-F4)"
run_setup "$H" "$D" --sync
[ "$(grep -cxF '.lane-reports/' "$D/.gitignore")" -eq 1 ] \
  && ok "sync: the .lane-reports/ backfill is idempotent (no duplicate on a second sync)" \
  || no "sync: .lane-reports/ must not be duplicated on repeated --sync"

# T4 — sync refreshes the core but leaves session state alone, byte-for-byte
# (the full contract the script's header states: manifest, CLAUDE.md, docs,
# and feedback untouched). Sentinel CONTENT is asserted, not mere existence —
# a regression that recreated/emptied these files must fail here.
H=$(make_guv)
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
echo "wf-edited" > "$H/.claude/workflows/eval-parallel.js"
echo "stale" > "$D/.claude/workflows/dir-wf/stale-nested.js"
echo "dir-wf main v2" > "$H/.claude/workflows/dir-wf/main.js"
( bash "$H/maintainers/setup-control-plane.sh" "$D" --sync ) > "$WORK/sync.out" 2>&1
grep -q "edited" "$D/.claude/rules/guv-core.md" 2>/dev/null \
  && ok "sync: stale guv-* rule refreshed" \
  || no "sync: guv-* rules should be refreshed"
cmp -s "$WORK/team-style.before" "$D/.claude/rules/team-style.md" \
  && ok "sync: consumer-authored rule survives byte-for-byte (cmp)" \
  || no "sync: unprefixed consumer rules must never be touched"
grep -q "wf-edited" "$D/.claude/workflows/eval-parallel.js" 2>/dev/null \
  && ok "sync: stale guv workflow refreshed" \
  || no "sync: guv-shipped workflows should be refreshed"
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
echo "$OUT2" | grep -q "synced core" || no "second sync should still complete"
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

# T4b — --sync prunes guv-owned artifacts REMOVED upstream ([8.3]). copy_core
# only adds/replaces what EXISTS in source, so a removal can't self-heal: a
# flattened dir (commands/) or a script bundled into a skill (extract-eval-report,
# feedback-submit, check-citations) lingers in an already-synced consumer, dual-
# loading the old surface beside the new. The prune is an explicit list of removed
# core paths — it must clear exactly those, leave renamed-WITHIN-a-wholesale-dir
# cases to the dir replace, and never touch a setup-GENERATED file (run-core-tests.sh,
# which is regenerated, not copied — a blanket mirror would wrongly delete it).
H=$(make_guv)
D="$WORK/control-prune"
run_setup "$H" "$D"
mkdir -p "$D/.claude/commands"
echo "# stale flattened command" > "$D/.claude/commands/handoff.md"
echo "stale script" > "$D/.claude/extract-eval-report.sh"
echo "stale script" > "$D/.claude/feedback-submit.sh"
echo "stale script" > "$D/.claude/check-citations.sh"
# A skill renamed within the wholesale-replaced skills/ dir: the dir replace (not
# the prune) clears it — pinned here so the two mechanisms stay distinct.
mkdir -p "$D/.claude/skills/log-feedback"
echo "# old name" > "$D/.claude/skills/log-feedback/SKILL.md"
run_setup "$H" "$D" --sync
PRUNE_OK=1
for stale in commands extract-eval-report.sh feedback-submit.sh check-citations.sh skills/log-feedback; do
  [ -e "$D/.claude/$stale" ] && { no "sync: stale .claude/$stale must be gone (dual-load)"; PRUNE_OK=0; }
done
[ "$PRUNE_OK" -eq 1 ] && ok "sync: obsolete commands/, bundled scripts, and renamed skill dir all cleared"
[ -f "$D/.claude/run-core-tests.sh" ] \
  && ok "sync: prune leaves the setup-generated run-core-tests.sh in place" \
  || no "sync: prune must not remove the setup-generated run-core-tests.sh"

# T5 — create-mode never-clobber: re-running create on an existing control
# plane must not overwrite the manifest or CLAUDE.md ("write ... ONLY if they
# don't exist yet"). The generated test runner is the exception: it carries no
# consumer state, so it is core-owned and refreshed like guv-* rules
# (entry 2026-06-11T23:17:51Z-15612590 — create-only meant generator
# improvements never reached existing control planes).
H=$(make_guv)
D="$WORK/control4"
run_setup "$H" "$D"
echo "sentinel-claude-md" > "$D/CLAUDE.md"
echo '{"name":"sentinel-manifest"}' > "$D/.claude/project.json"
echo "# sentinel-runner" > "$D/.claude/run-core-tests.sh"
echo "edited-again" > "$H/.claude/rules/guv-core.md"
run_setup "$H" "$D"
grep -q "edited-again" "$D/.claude/rules/guv-core.md" 2>/dev/null \
  && ok "create re-run: executed (core re-synced)" \
  || no "create re-run positive control: second run should re-sync the core"
grep -q "sentinel-claude-md" "$D/CLAUDE.md" 2>/dev/null \
  && grep -q "sentinel-manifest" "$D/.claude/project.json" 2>/dev/null \
  && ok "create re-run: existing manifest/CLAUDE.md not clobbered" \
  || no "create re-run must not clobber the manifest or CLAUDE.md"
if ! grep -q "sentinel-runner" "$D/.claude/run-core-tests.sh" 2>/dev/null \
  && grep -q '\[stderr\]' "$D/.claude/run-core-tests.sh" 2>/dev/null; then
  ok "create re-run: drifted runner refreshed (core-owned, no consumer state)"
else
  no "create re-run should refresh the generated runner — it is core-owned"
fi

# T6 — generated runner enforces the empty-stderr gate: a suite that PASSES but
# writes to stderr must fail the run (a green summary above a parse error is
# how a vacuous guard slipped two review gates — session-2026-06-11-003).
# The clean-suite case first is the positive control for the runner itself.
H=$(make_guv)
D="$WORK/control-runner"
mkdir -p "$H/.claude/tests"
printf '#!/bin/bash\necho "  ok"\nexit 0\n' > "$H/.claude/tests/clean.test.sh"
run_setup "$H" "$D"
( cd "$D" && bash .claude/run-core-tests.sh ) >/dev/null 2>&1 \
  && ok "runner: clean passing suite -> run passes" \
  || no "runner: a clean passing suite should pass the run"
printf '#!/bin/bash\necho "  ok"\necho "boom: parse error" >&2\nexit 0\n' > "$H/.claude/tests/noisy.test.sh"
OUT=$( cd "$D" && bash .claude/run-core-tests.sh 2>&1 )
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '\[stderr\]'; then
  ok "runner: passing suite with stderr output fails the run and surfaces it"
else
  no "runner: stderr from a suite must fail the run (rc=$RC)"
fi

# T7 — the CI workflow's inline test loop carries the same gate (it is the third
# copy of the loop — the generator-emitted runner above is the behaviorally-tested
# reference; this drift guard keeps the CI copy honest). [15.1] extended it to all
# three legs: the stderr capture, the per-suite timeout, AND the stdout-only-
# failure detector — a CI edit that drops any leg fails here.
# Conditional: forks may delete .github/ along with the rest of maintainer CI.
CI_YML="$(cd "$(dirname "$REAL_SCRIPT")/.." && pwd)/.github/workflows/template-clean.yml"
if [ -f "$CI_YML" ]; then
  grep -q '\[stderr\]' "$CI_YML" && grep -q '2>"\$err"' "$CI_YML" \
    && ok "CI test loop carries the stderr gate (capture + fail markers present)" \
    || no "CI inline loop drifted from the runner: per-suite stderr capture/fail missing"
  # [15.1] fix (a): the CI loop bounds each suite with a timeout (a hang fails
  # loud, not a 6-hour Actions stall).
  grep -qE 'timeout .*bash "\$t"' "$CI_YML" && grep -q '\[timeout\]' "$CI_YML" \
    && ok "CI test loop carries the per-suite timeout gate ([15.1] fix a)" \
    || no "CI inline loop must bound each suite with timeout (a hang must fail loud, not stall CI)"
  # [15.1] fix (c): the CI loop catches a stdout-only failure (the same detector
  # the generated runner uses — a ✗ line or a nonzero failed-count verdict).
  grep -q '\[stdout\]' "$CI_YML" && grep -q "Results:\[\[:space:\]\]" "$CI_YML" \
    && ok "CI test loop carries the stdout-only-failure detector ([15.1] fix c)" \
    || no "CI inline loop must catch a stdout-only failure (the [15.1] gate-integrity hole)"
  # [15.1] fix (b) lockstep CARVE: the local battery splits a serial set out of the
  # parallel pool (plugin.test.sh + ship-suite.test.sh write to / build from the
  # shared live source tree). The CI loop is serial-by-design, which SUBSUMES that
  # carve (every suite runs alone) — so the lockstep invariant here is that CI
  # MUST NOT silently switch to a parallel launch ('& ... wait') that would lose
  # the carve, and its comment must name the carve so the coupling is legible.
  if grep -qE 'bash "\$t".*&[[:space:]]*$' "$CI_YML"; then
    no "CI inline loop backgrounds suites ('&') — a parallel CI form must replicate the serial carve (plugin.test.sh + ship-suite.test.sh), not glob all suites concurrently"
  else
    grep -qiE 'serial.*(carve|hermet|shared|live source|plugin\.test)' "$CI_YML" \
      && ok "CI test loop stays serial and documents the shared-live-tree carve coupling ([15.1] fix b lockstep)" \
      || no "CI inline loop must note the serial carve coupling (plugin.test.sh + ship-suite.test.sh share the live source tree)"
  fi
else
  echo "  - .github workflow absent (fork) — CI gate drift guard skips"
fi

# T8 — --sync refreshes the generated test runner (the same entry as T5's
# exception: the D3 stderr-gate fix changed the runner heredoc and the live
# copy had to be hand-edited to match — any drift from the generator is stale
# guv code, not consumer state).
H=$(make_guv)
D="$WORK/control5"
run_setup "$H" "$D"
# Fresh create is where chmod is load-bearing: cp from mktemp yields a
# non-executable mode, so this fails if the chmod line is dropped.
[ -x "$D/.claude/run-core-tests.sh" ] \
  && ok "create: freshly generated runner is executable" \
  || no "create: freshly generated runner must be executable (cp from mktemp is not)"
echo "# stale-runner" > "$D/.claude/run-core-tests.sh"
OUT=$( (bash "$H/maintainers/setup-control-plane.sh" "$D" --sync) 2>&1 )
if grep -q '\[stderr\]' "$D/.claude/run-core-tests.sh" 2>/dev/null \
  && ! grep -q "stale-runner" "$D/.claude/run-core-tests.sh" 2>/dev/null; then
  ok "sync: drifted runner refreshed to the generator's content"
else
  no "sync must refresh the generated runner (create-only leaves drift in place)"
fi
[ -x "$D/.claude/run-core-tests.sh" ] \
  && ok "sync: refreshed runner stays executable" \
  || no "sync: refreshed runner lost its executable bit"
echo "$OUT" | grep -q "refreshed .claude/run-core-tests.sh" \
  && ok "sync: runner refresh announced (not rewritten silently)" \
  || no "sync must announce the runner refresh"
OUT2=$( (bash "$H/maintainers/setup-control-plane.sh" "$D" --sync) 2>&1 )
echo "$OUT2" | grep -q "refreshed .claude/run-core-tests.sh" \
  && no "sync: refresh notice should not repeat when the runner is already current" \
  || ok "sync: refresh notice fires only on change, silent when current"

# T8b — refresh-only on --sync: the runner is dogfooding tooling, but --sync is
# ALSO the template-clone consumer update path, and a consumer project never had
# the runner. Syncing into a dest without one must not plant it.
H=$(make_guv)
D="$WORK/consumer-clone"
mkdir -p "$D/.claude"
run_setup "$H" "$D" --sync
[ ! -e "$D/.claude/run-core-tests.sh" ] \
  && ok "sync: no runner planted where none existed (consumer-project shape)" \
  || no "sync must not inject the dogfooding runner into a consumer project"

# T8c — legacy runner-name migration ([8.3]): a consumer synced before the rename
# carries run-harness-tests.sh and no run-core-tests.sh. The refresh-only skip must
# NOT read that as "never had a runner" (T8b's case) — that would freeze it at the
# old name forever. --sync must create run-core-tests.sh AND prune the old name.
H=$(make_guv)
D="$WORK/legacy-runner"
run_setup "$H" "$D"
mv "$D/.claude/run-core-tests.sh" "$D/.claude/run-harness-tests.sh"
OUT=$( (bash "$H/maintainers/setup-control-plane.sh" "$D" --sync) 2>&1 )
[ -x "$D/.claude/run-core-tests.sh" ] \
  && ok "sync: legacy runner migrated to run-core-tests.sh (created + executable)" \
  || no "sync must create run-core-tests.sh for a consumer carrying the old runner name (not freeze it)"
[ ! -e "$D/.claude/run-harness-tests.sh" ] \
  && ok "sync: obsolete old-name runner pruned (no dual runner)" \
  || no "sync must prune the pre-rename runner once run-core-tests.sh is in place"
echo "$OUT" | grep -qi 'run-harness-tests\.sh' \
  && ok "sync: runner migration announced (not silent)" \
  || no "sync must announce the runner migration"

# T9 — DOGFOODING.md re-derived against current reality (Phase 5 D4). The doc
# documents this script's loop, so its accuracy guards live with this suite.
# Conditional like T7: a fork may strip individual maintainer docs.
# Prose guards grep a whitespace-flattened copy — an innocent reflow must not
# break a phrase guard (it did once, in this deliverable's own wave). The
# squeeze matters too: a wrapped line ending in a trailing space would
# otherwise leave a double space in the flat copy and break fixed phrases.
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }
DOG="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)/DOGFOODING.md"
if [ -f "$DOG" ]; then
  grep -v '\.github' "$DOG" | grep -q 'workflows' \
    && ok "DOGFOODING: workflows/ present in the synced-core description" \
    || no "DOGFOODING must name workflows/ among the synced core (Phase 4 addition — the .github/workflows CI path does not count)"
  grep -q 'build-plugin\.sh' "$DOG" && grep -q 'plugin-src' "$DOG" \
    && ok "DOGFOODING: plugin generator + authored sources named" \
    || no "DOGFOODING must name build-plugin.sh and plugin-src/ (Phase 5 tooling)"
  grep -q 'RELEASING\.md' "$DOG" \
    && ok "DOGFOODING: RELEASING.md in the what-lives-in-the-guv-repo list" \
    || no "DOGFOODING must list RELEASING.md among durable maintainer tooling"
  grep -q 'unreleased' "$DOG" \
    && ok "DOGFOODING: maintainer disposition — --sync kept for unreleased changes" \
    || no "DOGFOODING must state why --sync survives the plugin (unreleased changes)"
  grep -q 'plan' "$DOG" \
    && ok "DOGFOODING: ceremony flip acknowledged (seeded task, initiative flips it)" \
    || no "DOGFOODING must reflect that /plan can flip the control plane to phased"
  flat "$DOG" | grep -qi 'replaces core-owned surfaces[^.]*wholesale' \
    && ok "DOGFOODING: fallback bullet carries the wholesale-replacement caveat" \
    || no "DOGFOODING must warn that --sync replaces core-owned surfaces wholesale (the fact, not the word, same-sentence)"
  if flat "$DOG" | grep -q 'pinned to the template repo'; then
    no "DOGFOODING: stale single-pin CI phrasing survives ('pinned to the template repo')"
  else
    ok "DOGFOODING: stale single-pin CI phrasing gone"
  fi
  # Positive control: an absence grep passes vacuously if the pattern is typo'd.
  printf 'x pinned to the template repo x\n' | grep -q 'pinned to the template repo' \
    && ok "DOGFOODING: stale-phrase decoder matches a planted violation" \
    || no "DOGFOODING: stale-phrase decoder broken (planted violation not matched)"
  # [7.7] — the taught self-check loop must keep its aggregation + stderr
  # gate + single verdict line (the bare-loop class has bitten twice; a doc
  # edit reverting the snippet must fail here, not silently teach it again).
  grep -q 'self-check: PASS' "$DOG" && grep -q 'self-check: FAIL' "$DOG" \
    && grep -q '\[ -s "\$err" \]' "$DOG" \
    && ok "DOGFOODING: self-check teaching keeps the aggregated, stderr-gated, verdict-line shape" \
    || no "the taught plane self-check must aggregate failures, gate stderr, and end in one verdict line"
else
  echo "  - maintainers/DOGFOODING.md absent (fork) — re-derivation guards skip"
fi

# T10 — the README's template-clone fallback states the DECIDED consumer
# disposition (Phase 5 D4): an existing clone is told whether to migrate to
# plugin updates or keep syncing — an answer, not an inherited parenthetical.
# Gated on the README being the TEMPLATE's: /init-project replaces README.md
# with a rendered project README, and deleting maintainers/ is optional — a
# post-init consumer shape must skip here, not fail (the consumer-suite
# contract: correct consumer usage never reads as a violation). The detector
# is the explicit guv-template-readme marker comment, not the H1 — a headline
# reword must not silently flip these guards into the skip branch. SCP_TEST_README
# is the self-check seam (T10b re-invokes with a planted rendered README).
RM="${SCP_TEST_README:-$(cd "$(dirname "$REAL_SCRIPT")/.." && pwd)/README.md}"
if [ -f "$RM" ] && ! grep -q 'guv-template-readme' "$RM"; then
  # Detector-drift probe: a marker-less README that still carries template-only
  # content is not a rendered project README — it means the marker (or this
  # detector's literal) drifted, and skipping would silently disable the guards
  # in the canonical repo. Fail loud instead. (The probe literal also lives in
  # eval-parallel.test.sh's README gate — keep the two in step.)
  if flat "$RM" | grep -qi 'replaces core-owned surfaces'; then
    no "README carries template content but no guv-template-readme marker — marker/detector drift"
  else
    echo "  - README.md is a rendered project README, not the template's — disposition guards skip"
  fi
elif [ -f "$RM" ]; then
  flat "$RM" | grep -qiE 'keep the clone|keep syncing' && grep -qi 'migrat' "$RM" \
    && ok "README: existing clones told migrate-or-keep (decided disposition)" \
    || no "README fallback must state the disposition for existing template clones"
  grep -qiE 'double.load|dual.load' "$RM" \
    && ok "README: migration guidance names the double-load hazard" \
    || no "README migration guidance must warn about double-loading the copied core"
  # The two corrections that make the recipe safe to follow verbatim: deleting
  # hooks/ without de-registering them leaves settings.json invoking missing
  # scripts on every tool call, and guv-* rules are project-resident (the plugin
  # cannot supply rules at runtime) so "delete the copied core" must not cover them.
  flat "$RM" | grep -qF 'hooks` block from `.claude/settings.json' \
    && ok "README: migration de-registers the hooks block from settings.json" \
    || no "README migration must say to remove the hooks block from .claude/settings.json"
  flat "$RM" | grep -qF 'Keep `.claude/rules/guv-*.md' \
    && ok "README: migration keeps guv-* rules (plugin cannot supply rules at runtime)" \
    || no "README migration must tell clones to KEEP .claude/rules/guv-*.md"
  # The customized-fork branch must be honest about what --sync does: copy_core
  # replaces core-owned surfaces wholesale, which reverts exactly the edits
  # the fallback audience is invited to make.
  flat "$RM" | grep -qi 'replaces core-owned surfaces[^.]*wholesale' \
    && ok "README: customized forks warned that --sync replaces core-owned surfaces wholesale" \
    || no "README must warn customized forks that --sync reverts core-owned edits"
else
  echo "  - README.md absent (fork) — disposition guards skip"
fi

# T10b — seamed self-checks for the README gate, BOTH directions (the b0310b2
# convention: a skip path is only trusted when a re-invocation proves it fires
# and is visible — and a detector is only trusted when a re-invocation proves
# the guards RUN where it matches; one-directional self-checks are how a
# typo'd detector silently disables guards with every suite green).
if [ -z "${SCP_TEST_INNER:-}" ]; then
  FAKE="$WORK/rendered-readme.md"
  echo "# my-rendered-project" > "$FAKE"
  INNER=$(SCP_TEST_INNER=1 SCP_TEST_README="$FAKE" bash "$SELF" 2>&1)
  if [ $? -eq 0 ] && echo "$INNER" | grep -q "rendered project README" \
    && ! echo "$INNER" | grep -q "decided disposition"; then
    ok "rendered-README shape visibly skips the disposition guards (seamed self-check)"
  else
    no "a rendered README must skip the disposition guards visibly (and not run them)"
  fi
  # Template-shape positive control: a README CARRYING the marker but missing
  # the disposition content must make the guards run and fail — proves the
  # detector matches the real marker and the guards execute behind it.
  FAKE2="$WORK/marker-no-content.md"
  printf '# some readme\n<!-- guv-template-readme -->\n' > "$FAKE2"
  INNER2=$(SCP_TEST_INNER=1 SCP_TEST_README="$FAKE2" bash "$SELF" 2>&1)
  if [ $? -ne 0 ] && echo "$INNER2" | grep -q "must state the disposition"; then
    ok "marker-bearing README runs the disposition guards (template-shape positive control)"
  else
    no "with the marker present the disposition guards must RUN (and fail on empty content)"
  fi
  # Absent branch, same treatment as the sibling suite's three-branch checks.
  INNER3=$(SCP_TEST_INNER=1 SCP_TEST_README="$WORK/no-such-readme.md" bash "$SELF" 2>&1)
  if [ $? -eq 0 ] && echo "$INNER3" | grep -q "README.md absent"; then
    ok "absent-README shape visibly skips the disposition guards (seamed self-check)"
  else
    no "an absent README must skip the disposition guards visibly"
  fi
  # Drift branch: marker-less but phrase-bearing must fail LOUD. Scope is
  # probe↔plant consistency (the fixture is a hand-written copy of the probe
  # literal, not derived from the live README): it catches a typo'd probe, not
  # a coordinated rewording of probe+plant. The LIVE phrase is pinned
  # separately by this suite's running wholesale guard, whose pattern is a
  # superstring of the probe literal.
  FAKE4="$WORK/drifted-readme.md"
  printf '# readme\n--sync replaces core-owned surfaces wholesale.\n' > "$FAKE4"
  INNER4=$(SCP_TEST_INNER=1 SCP_TEST_README="$FAKE4" bash "$SELF" 2>&1)
  if [ $? -ne 0 ] && echo "$INNER4" | grep -q "marker/detector drift"; then
    ok "marker-less template content fails loud (drift-probe self-check)"
  else
    no "a marker-less README with template content must fail loud, not skip"
  fi
fi

# ── the <project>-guv default destination ([6.4]) ──────────────────────────
# No-arg create defaults to a SIBLING of guv named <repo>-guv. This is
# a constructed default, announced loudly — never discovery (no glob; the
# docs-sweep suite pins that boundary repo-wide).
H=$(make_guv)
DH="$WORK/widget"; rm -rf "$DH" "$WORK/widget-guv"; mv "$H" "$DH"
OUT_DEF=$( cd "$WORK" && bash "$DH/maintainers/setup-control-plane.sh" 2>&1 )
if [ -d "$WORK/widget-guv/.claude/skills" ]; then
  ok "no-arg create defaults to sibling <project>-guv (widget → widget-guv)"
else
  no "no-arg create must default to sibling <project>-guv"
fi
if echo "$OUT_DEF" | grep -q "No control-plane dir given.*widget-guv"; then
  ok "the defaulted destination is announced, not silent"
else
  no "defaulting must announce itself (one line: the announcement naming the path)"
fi
# Flag-first WITH a directory must stop loud — never silently discard the
# explicit argument and default elsewhere (rule 15: no improvised path).
OUT_INV=$( cd "$WORK" && bash "$DH/maintainers/setup-control-plane.sh" --sync "$WORK/elsewhere" 2>&1 )
RC_INV=$?
if [ "$RC_INV" -ne 0 ] && echo "$OUT_INV" | grep -q "directory must come first" && [ ! -d "$WORK/elsewhere" ]; then
  ok "flag-first --sync <dir> refuses loud (argument never silently discarded)"
else
  no "--sync <dir> (flag first) must refuse loud, not default with a false announcement"
fi
# Sole-arg --sync targets the same constructed default.
echo "# cmd v2" > "$DH/.claude/skills/status/SKILL.md"
( cd "$WORK" && bash "$DH/maintainers/setup-control-plane.sh" --sync ) >> "$WORK/setup.log" 2>&1
if grep -q "cmd v2" "$WORK/widget-guv/.claude/skills/status/SKILL.md" 2>/dev/null; then
  ok "sole-arg --sync syncs the defaulted <project>-guv plane"
else
  no "--sync without a dir must sync the default <project>-guv plane"
fi
# Sync against an ABSENT destination refuses — it must never manufacture an
# empty half-plane and report success while the real plane stays stale.
H=$(make_guv)
DH2="$WORK/phantom"; rm -rf "$DH2" "$WORK/phantom-guv"; mv "$H" "$DH2"
OUT_ABS=$( cd "$WORK" && bash "$DH2/maintainers/setup-control-plane.sh" --sync 2>&1 )
RC_ABS=$?
if [ "$RC_ABS" -ne 0 ] && echo "$OUT_ABS" | grep -q "not an existing control plane" && [ ! -d "$WORK/phantom-guv" ]; then
  ok "--sync against an absent plane refuses loud (no phantom half-plane)"
else
  no "--sync against an absent destination must refuse, not mkdir + report success"
fi
# An unrecognized second argument refuses — a typo'd --sync must not silently
# run create mode.
OUT_UNK=$( cd "$WORK" && bash "$DH2/maintainers/setup-control-plane.sh" "$WORK/nowhere" --synk 2>&1 )
RC_UNK=$?
if [ "$RC_UNK" -ne 0 ] && echo "$OUT_UNK" | grep -q "unknown argument" && [ ! -d "$WORK/nowhere" ]; then
  ok "unknown second argument refuses loud (typo'd --sync never runs create)"
else
  no "an unrecognized mode argument must refuse loud, not fall back to create"
fi
# A typo'd SOLE-ARG flag must refuse too — never become the destination,
# cascade errors, and exit 0 under a false success banner.
OUT_SOLO=$( cd "$WORK" && bash "$DH2/maintainers/setup-control-plane.sh" --synk 2>&1 )
RC_SOLO=$?
if [ "$RC_SOLO" -ne 0 ] && echo "$OUT_SOLO" | grep -q "unknown argument" && ! echo "$OUT_SOLO" | grep -q "Control plane ready"; then
  ok "typo'd sole-arg flag refuses loud (no cascade, no false success banner)"
else
  no "a flag-shaped first argument must refuse loud, not become the destination"
fi
# The allow-list is the documented grammar: bare 'sync' (no dashes) is refused,
# not accepted as an undocumented alias.
OUT_BARE=$( cd "$WORK" && bash "$DH2/maintainers/setup-control-plane.sh" "$WORK/widget-guv" sync 2>&1 )
RC_BARE=$?
if [ "$RC_BARE" -ne 0 ] && echo "$OUT_BARE" | grep -q "unknown argument"; then
  ok "bare 'sync' second argument refuses (allow-list = documented grammar)"
else
  no "undocumented mode aliases must refuse, not silently run sync"
fi

# ── [7.7] — control planes carry the installed test suite. The suites are
# location-relative by design, so the plane's copy verifies the plane's
# INSTALLED scripts — the installation tests itself, one sync behind the
# source. The fixture guv repo gets the REAL resolver + its REAL suite so
# the divergence proof below is genuine, plus the REAL copy of this very
# suite to prove the maintainers-shape skip in the plane. Outer-run only
# (the T10b seamed self-invocations re-run this whole file; real-suite
# executions in every inner run would multiply runtime and couple T10b's
# exit-code assertions to this block's state).
if [ -z "${SCP_TEST_INNER:-}" ]; then
REALROOT="$(cd "$(dirname "$REAL_SCRIPT")/.." && pwd)"
H77=$(make_guv)
mkdir -p "$H77/.claude/tests"
cp "$REALROOT/.claude/resolve-ready.sh" "$H77/.claude/resolve-ready.sh"
# The resolver suite cross-checks regex parity against its sibling
# archive-initiative.sh — the fixture needs the real one beside it.
cp "$REALROOT/.claude/archive-initiative.sh" "$H77/.claude/archive-initiative.sh"
cp "$REALROOT/.claude/tests/resolve-ready.test.sh" "$H77/.claude/tests/"
cp "$REALROOT/.claude/tests/setup-control-plane.test.sh" "$H77/.claude/tests/"
D77="$WORK/plane77"
run_setup "$H77" "$D77"
[ -d "$D77/.claude/tests" ] \
  && cmp -s "$H77/.claude/tests/resolve-ready.test.sh" "$D77/.claude/tests/resolve-ready.test.sh" \
  && cmp -s "$H77/.claude/tests/setup-control-plane.test.sh" "$D77/.claude/tests/setup-control-plane.test.sh" \
  && ok "[7.7] create: plane carries .claude/tests byte-identical to the source's" \
  || no "[7.7] create must copy the test suite beside the installed scripts"
{ echo "drifted" > "$D77/.claude/tests/resolve-ready.test.sh"; } 2>/dev/null
run_setup "$H77" "$D77" --sync
cmp -s "$H77/.claude/tests/resolve-ready.test.sh" "$D77/.claude/tests/resolve-ready.test.sh" \
  && ok "[7.7] sync: a drifted plane suite is refreshed (core-owned, like the core)" \
  || no "[7.7] --sync must refresh the plane's tests copy"

# The point of the whole deliverable: the plane's suite tests the plane's
# INSTALLED copies, not the source. Green against the intact installation;
# corrupt the installed resolver and the plane-local suite goes red while
# the source's own suite stays green.
P_OUT=$(cd "$D77" && bash .claude/tests/resolve-ready.test.sh 2>&1); P_RC=$?
[ "$P_RC" -eq 0 ] \
  && ok "[7.7] self-check: plane-local resolver suite green against the intact installation" \
  || no "[7.7] plane-local suite must pass on a healthy plane (rc=$P_RC: $(echo "$P_OUT" | tail -2))"
printf '#!/bin/bash\necho CORRUPTED; exit 99\n' > "$D77/.claude/resolve-ready.sh"
P_OUT=$(cd "$D77" && bash .claude/tests/resolve-ready.test.sh 2>&1); P_RC=$?
bash "$H77/.claude/tests/resolve-ready.test.sh" >/dev/null 2>&1; S_RC=$?
[ "$P_RC" -ne 0 ] && [ "$S_RC" -eq 0 ] \
  && ok "[7.7] divergence: corrupted installed copy turns the PLANE suite red, source suite stays green" \
  || no "[7.7] the plane copy must test the installation, not the source (plane rc=$P_RC, source rc=$S_RC)"

# Maintainers-dependent suites skip cleanly in the plane shape (no
# maintainers/ there) — the consumer-shape guard, exercised from a plane.
SKIP_OUT=$(cd "$D77" && bash .claude/tests/setup-control-plane.test.sh 2>&1); SKIP_RC=$?
[ "$SKIP_RC" -eq 0 ] && echo "$SKIP_OUT" | grep -q "skipping" \
  && ok "[7.7] plane shape: maintainers-dependent suite skips cleanly, exit 0" \
  || no "[7.7] a maintainers suite run from a plane must skip, not fail (rc=$SKIP_RC)"
fi  # SCP_TEST_INNER guard ([7.7] block)

# ── [15.1] — core-test battery hardening and gate integrity ─────────────────
# THE credibility-load-bearing property: the generated run-core-tests.sh can no
# longer report green over a suite that did not pass. Three coupled guards,
# exercised against the REAL generated runner (build a scratch plane, plant
# pathological suites under its roots.code, run the runner, assert the verdict).
# Outer-run only — these stand up real fixtures + run suites concurrently, so the
# T10b inner self-invocations must not multiply the cost or re-stand the planes.
if [ -z "${SCP_TEST_INNER:-}" ]; then
# A scratch plane whose roots.code points at a fixture code repo we control, so
# we can drop pathological suites into <code>/.claude/tests/ and run the real
# generated runner against them. make_guv already ships the real roots.sh; we add
# a manifest naming an absolute roots.code (the resolver returns the string as the
# primary) and a code repo with a .claude/tests/ dir.
mk_battery_plane() {  # echoes "<plane-dir>|<code-dir>"
  local h d code
  h=$(make_guv)
  d="$WORK/battery-$RANDOM"
  code="$WORK/battery-code-$RANDOM"
  mkdir -p "$code/.claude/tests"
  run_setup "$h" "$d"
  # Point the generated runner's resolver at our fixture code repo. The runner
  # sources roots.sh and calls roots_code_path, which reads roots.code from the
  # plane manifest as the primary string — set it to the fixture's absolute path.
  jq --arg c "$code" '.roots.code = $c' "$d/.claude/project.json" > "$d/.claude/project.json.tmp" \
    && mv "$d/.claude/project.json.tmp" "$d/.claude/project.json"
  echo "$d|$code"
}
plant_suite() {  # $1=code-dir $2=name $3=body
  printf '%s' "$3" > "$1/.claude/tests/$2"
}
BATT_OUT=""  # set by run_battery; read directly (NOT via $(...) which would
BATT_RC=0    # swallow BATT_RC in a subshell). Globals on purpose.
run_battery() {  # $1=plane-dir [$2=timeout-override] ; sets BATT_OUT + BATT_RC
  local of; of=$(mktemp)
  if [ -n "${2:-}" ]; then
    ( cd "$1" && CORE_TEST_TIMEOUT="$2" bash .claude/run-core-tests.sh ) >"$of" 2>&1
  else
    ( cd "$1" && bash .claude/run-core-tests.sh ) >"$of" 2>&1
  fi
  BATT_RC=$?
  BATT_OUT=$(cat "$of"); rm -f "$of"
}

# T11 — positive control: a clean passing suite leaves the battery green. If this
# fails the rest of the [15.1] block is meaningless (the runner can't even pass).
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
plant_suite "$BC" "clean.test.sh" $'#!/bin/bash\necho "  ✓ all good"\necho "Results: 1 passed, 0 failed"\nexit 0\n'
run_battery "$BP"
[ "$BATT_RC" -eq 0 ] \
  && ok "[15.1] battery: a clean passing suite keeps the run green (positive control)" \
  || no "[15.1] battery must pass a clean suite (rc=$BATT_RC: $(printf '%s' "$BATT_OUT" | tail -2))"

# T11a — fix (c) stdout-only-failure blindness: a suite that announces its FAILURE
# only on stdout AND lies with exit 0 must NOT yield a green battery. This is the
# exact hole that once let a red suite show green (roots-map.test.sh writes its ✗
# to stdout); the gate must catch the failure verdict on stdout, not only rc/stderr.
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
plant_suite "$BC" "stdout-fail.test.sh" $'#!/bin/bash\necho "  \xe2\x9c\x97 this assertion FAILED"\necho "Results: 0 passed, 1 failed"\nexit 0\n'
run_battery "$BP"
if [ "$BATT_RC" -ne 0 ] && printf '%s' "$BATT_OUT" | grep -qi 'stdout-fail.test.sh'; then
  ok "[15.1] fix(c): a stdout-only failure (exit 0) fails the battery and names the suite"
else
  no "[15.1] fix(c): a suite failing on stdout-only must fail the run (rc=$BATT_RC out=$(printf '%s' "$BATT_OUT" | tail -3))"
fi

# T11b — fix (c) the verdict line: a suite reporting "N failed" with N>0 on stdout
# while exiting 0 must also fail, even without a ✗ glyph (the Results line is the
# other universal failure signal across the suite set).
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
plant_suite "$BC" "results-fail.test.sh" $'#!/bin/bash\necho "Results: 3 passed, 2 failed"\nexit 0\n'
run_battery "$BP"
[ "$BATT_RC" -ne 0 ] \
  && ok "[15.1] fix(c): a 'Results: N passed, M failed' (M>0) verdict fails the run despite exit 0" \
  || no "[15.1] fix(c): a nonzero failed-count verdict on stdout must fail the run (rc=$BATT_RC)"

# T11c — fix (c) NO false positives: the failure-shaped stdout detector must NOT
# trip on a clean suite that merely PRINTS the words (a 'Results: N passed, 0
# failed' line, the ✓ glyph). A detector that reads "0 failed" as a failure
# would red the whole battery — this is the regression that keeps the gate usable.
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
plant_suite "$BC" "zero-failed.test.sh" $'#!/bin/bash\necho "  \xe2\x9c\x93 ok"\necho "Results: 5 passed, 0 failed"\nexit 0\n'
run_battery "$BP"
[ "$BATT_RC" -eq 0 ] \
  && ok "[15.1] fix(c): a clean 'Results: N passed, 0 failed' suite stays green (no false positive)" \
  || no "[15.1] fix(c): the stdout detector must not trip on a 0-failed verdict (rc=$BATT_RC out=$(printf '%s' "$BATT_OUT" | tail -3))"

# T11d — fix (c) the rc/stderr gate is preserved: a suite that exits nonzero, and
# one that writes to stderr, both still fail. These are the original gate's two
# legs — the stdout closure must add to them, never replace them.
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
plant_suite "$BC" "rc-fail.test.sh" $'#!/bin/bash\necho "  \xe2\x9c\x93 looks ok on stdout"\nexit 1\n'
run_battery "$BP"
[ "$BATT_RC" -ne 0 ] \
  && ok "[15.1] gate: a nonzero exit still fails the run (rc leg preserved)" \
  || no "[15.1] gate: a nonzero-exit suite must fail the run (rc=$BATT_RC)"
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
plant_suite "$BC" "stderr-fail.test.sh" $'#!/bin/bash\necho "  \xe2\x9c\x93 ok"\necho "boom: a parse error" >&2\nexit 0\n'
run_battery "$BP"
if [ "$BATT_RC" -ne 0 ] && printf '%s' "$BATT_OUT" | grep -q '\[stderr\]'; then
  ok "[15.1] gate: a passing suite that writes to stderr still fails (stderr leg preserved)"
else
  no "[15.1] gate: any stderr byte must fail the run (rc=$BATT_RC)"
fi

# T11e — fix (a) per-suite timeout: a HUNG suite must fail the battery LOUD with a
# NAMED timeout, distinguishable from sandbox slowness — never a silent stall
# (Rule 15). Skipped only where no timeout binary exists (the runner must then
# degrade to a documented serial path, asserted in T11i).
HAVE_TIMEOUT=0
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
command -v gtimeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
if [ "$HAVE_TIMEOUT" -eq 1 ]; then
  IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
  plant_suite "$BC" "clean.test.sh" $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
  plant_suite "$BC" "hang.test.sh" $'#!/bin/bash\nsleep 600\n'
  # Bound the per-suite timeout low so the test itself is fast; the runner reads
  # the override from the environment (CORE_TEST_TIMEOUT) so the suite can pin it.
  T_START=$(date +%s)
  run_battery "$BP" 2
  T_END=$(date +%s)
  if [ "$BATT_RC" -ne 0 ] \
     && printf '%s' "$BATT_OUT" | grep -qi 'hang.test.sh' \
     && printf '%s' "$BATT_OUT" | grep -qi 'timed out\|timeout'; then
    ok "[15.1] fix(a): a hung suite fails the battery LOUD with a named timeout (not a silent stall)"
  else
    no "[15.1] fix(a): a hang must fail loud naming the suite + timeout (rc=$BATT_RC out=$(printf '%s' "$BATT_OUT" | tail -3))"
  fi
  # The hang must not have stalled the whole run — the timeout bounds it.
  [ $((T_END - T_START)) -lt 60 ] \
    && ok "[15.1] fix(a): the timeout bounds wall-clock (hung suite did not stall the run)" \
    || no "[15.1] fix(a): a hung suite stalled the run past the per-suite bound ($((T_END - T_START))s)"
else
  echo "  - no timeout/gtimeout on PATH — fix(a) hang test skipped (degradation asserted in T11i)"
fi

# T11f — fix (b) bounded parallel pool with deterministic aggregation: suites run
# concurrently (wall-clock toward the slowest, not the sum), and the aggregated
# output is DETERMINISTIC and applies the identical gate. Three independent
# clean suites that each sleep should finish in well under their serial sum.
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
for n in a b c; do
  plant_suite "$BC" "slow-$n.test.sh" $'#!/bin/bash\nsleep 2\necho "Results: 1 passed, 0 failed"\nexit 0\n'
done
T_START=$(date +%s)
run_battery "$BP"
T_END=$(date +%s)
[ "$BATT_RC" -eq 0 ] \
  && ok "[15.1] fix(b): independent clean suites pass under the parallel pool" \
  || no "[15.1] fix(b): clean concurrent suites must pass (rc=$BATT_RC out=$(printf '%s' "$BATT_OUT" | tail -3))"
# Serial would be ~6s; parallel should be ~2-3s. Assert strictly under the sum.
[ $((T_END - T_START)) -lt 5 ] \
  && ok "[15.1] fix(b): wall-clock drops toward the slowest suite (parallel, $((T_END - T_START))s < serial 6s)" \
  || no "[15.1] fix(b): suites did not run concurrently ($((T_END - T_START))s ≈ serial sum — pool not enabled)"
# Determinism: each suite's banner appears in the aggregated output regardless
# of completion order (the serial aggregation pass orders by suite name).
printf '%s' "$BATT_OUT" | grep -q 'slow-a.test.sh' \
  && printf '%s' "$BATT_OUT" | grep -q 'slow-b.test.sh' \
  && printf '%s' "$BATT_OUT" | grep -q 'slow-c.test.sh' \
  && ok "[15.1] fix(b): every suite's output is present in the deterministic aggregation" \
  || no "[15.1] fix(b): aggregated output must carry every suite's banner (got: $(printf '%s' "$BATT_OUT" | grep -c '==') headers)"
# Determinism, stronger: the serial aggregation orders banners by suite NAME, so
# two runs of the same set produce byte-identical banner ORDER regardless of which
# concurrent suite finished first — the property that makes the parallel run safe.
ORDER1=$(printf '%s' "$BATT_OUT" | grep '^== ')
run_battery "$BP"
ORDER2=$(printf '%s' "$BATT_OUT" | grep '^== ')
[ "$ORDER1" = "$ORDER2" ] && printf '%s' "$ORDER1" | grep -q 'slow-a' \
  && ok "[15.1] fix(b): banner ORDER is deterministic across runs (name-sorted aggregation)" \
  || no "[15.1] fix(b): aggregation order must be deterministic (run1≠run2 — nondeterministic output)"

# T11g — fix (b) the gate is identical under parallelism: a failure mixed among
# passing suites is still caught (the concurrency must not lose a verdict). Run a
# failing suite alongside clean ones and assert the whole run goes red and names it.
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
plant_suite "$BC" "ok-1.test.sh" $'#!/bin/bash\nsleep 1\necho "Results: 1 passed, 0 failed"\nexit 0\n'
plant_suite "$BC" "ok-2.test.sh" $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
plant_suite "$BC" "bad.test.sh" $'#!/bin/bash\necho "  \xe2\x9c\x97 a real failure"\necho "Results: 0 passed, 1 failed"\nexit 1\n'
run_battery "$BP"
[ "$BATT_RC" -ne 0 ] && printf '%s' "$BATT_OUT" | grep -qi 'bad.test.sh' \
  && ok "[15.1] fix(b): a failure among concurrent passes still fails the run and names it" \
  || no "[15.1] fix(b): concurrency must not lose a verdict (rc=$BATT_RC)"

# T11h — fix (c) trailing-post-runner-command masking: the runner's exit status is
# the gate verdict and nothing may follow it. A background-run battery whose own
# last act is the runner must not be able to mask a suite failure behind a
# trailing command. Assert the generated runner ENDS with `exit` on the aggregated
# status (no command after it) — a structural guard on the heredoc text.
RUNNER_SRC="$BP/.claude/run-core-tests.sh"
LAST_NONBLANK=$(grep -vE '^\s*$|^\s*#' "$RUNNER_SRC" | tail -1)
printf '%s' "$LAST_NONBLANK" | grep -qE '^\s*exit ' \
  && ok "[15.1] fix(c): the runner's final statement is its exit (no trailing command can mask the verdict)" \
  || no "[15.1] fix(c): the runner must END on exit \$status — a trailing command masks the gate (last line: $LAST_NONBLANK)"

# T11i — fix (a) graceful degradation when no timeout binary exists: the runner
# must not break — it runs the suite (no bound) and announces the missing binary
# rather than silently dropping the timeout protection (Rule 15: a designed path,
# announced). Asserted via the heredoc carrying the degradation notice.
grep -qiE 'timeout.*(not (found|available)|absent|unavailable)|no timeout' "$RUNNER_SRC" \
  && ok "[15.1] fix(a): the runner announces a missing timeout binary (degradation is designed + loud)" \
  || no "[15.1] fix(a): a missing timeout binary must be announced, not silently unbounded"

# T11i2 — fix (a) the degradation announcement actually FIRES on the no-timeout
# path (Major 2). T11e's hang test self-skips where no timeout binary exists, so
# the loud-stop is unproven on a timeout-less box — closing that coverage void,
# this test shadows timeout/gtimeout OFF a synthetic PATH and runs the REAL
# generated runner, asserting the unbounded-degradation WARNING is emitted to the
# operator (not merely present as heredoc text). A box WITH timeout is exercised
# by forcing the no-binary branch; a box WITHOUT one runs the same path natively.
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
plant_suite "$BC" "clean.test.sh" $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
# A PATH with only the interpreters the runner needs, but NO timeout/gtimeout, so
# the runner takes its `[ -z "$TIMEOUT_BIN" ]` branch even where the host has one.
NOTO_BIN="$WORK/noto-bin-$RANDOM"; mkdir -p "$NOTO_BIN"
for c in bash sh env cat grep sed printf mktemp dirname basename sort rm mkdir cp mv chmod jq nproc sysctl date sleep wait wc tr head tail cmp; do
  p=$(command -v "$c" 2>/dev/null) && ln -s "$p" "$NOTO_BIN/$c" 2>/dev/null
done
NOTO_OUT=$( cd "$BP" && PATH="$NOTO_BIN" bash .claude/run-core-tests.sh 2>&1 ); NOTO_RC=$?
if printf '%s' "$NOTO_OUT" | grep -qiE 'no timeout.*UNBOUNDED|UNBOUNDED.*hang' ; then
  ok "[15.1] fix(a): the unbounded-degradation WARNING fires on the no-timeout path (loud, not a silent coverage void)"
else
  no "[15.1] fix(a): a timeout-less run must ANNOUNCE the unbounded degradation at runtime (rc=$NOTO_RC out=$(printf '%s' "$NOTO_OUT" | tail -4))"
fi

# T11j — fix (b) HERMETICITY CARVE (Critical): parallelism was enabled, but two
# suites WRITE TO / BUILD FROM the SHARED LIVE SOURCE TREE at fixed (non-mktemp)
# paths — plugin.test.sh plants throwaway fixtures into $ROOT/.claude and builds
# reading it; ship-suite.test.sh builds the plugin reading the same live source.
# They CANNOT run concurrently (the build picks up the planted fixtures or hits
# the skill-name-collision exit 2 → intermittent flake). The runner must carve
# these into a SERIAL pass while keeping the genuinely-hermetic suites parallel.
# Behavioral proof: plant suites named exactly plugin.test.sh and ship-suite.test.sh
# that DETECT concurrency (each marks itself "running", sleeps, then fails if the
# other was running in the same window). If they were serialized they never
# overlap → both pass; if they were thrown in the parallel pool they overlap →
# at least one fails. A third generic suite stays in the pool. Red until the
# carve lands.
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
# Concurrency-detector body: $1 = this suite's tag. Writes a per-suite "live"
# marker into the SHARED code-repo .claude dir (NOT mktemp — exactly the
# shared-live-tree hazard the carve resolves), sleeps so an overlapping run is
# observable, then fails if a sibling serial suite was concurrently live.
CONC_BODY='#!/bin/bash
set -u
SHARED="$(cd "$(dirname "$0")/.." && pwd)"   # the code repo .claude (shared live tree)
SELFTAG="__TAG__"
SIB="$([ "$SELFTAG" = serialA ] && echo serialB || echo serialA)"
: > "$SHARED/conc.$SELFTAG.live"
sleep 1
if [ -e "$SHARED/conc.$SIB.live" ]; then
  echo "  ✗ serial suites $SELFTAG and $SIB overlapped — NOT serialized"
  echo "Results: 0 passed, 1 failed"
  rm -f "$SHARED/conc.$SELFTAG.live"
  exit 1
fi
rm -f "$SHARED/conc.$SELFTAG.live"
echo "Results: 1 passed, 0 failed"
exit 0
'
plant_suite "$BC" "plugin.test.sh"     "${CONC_BODY/__TAG__/serialA}"
plant_suite "$BC" "ship-suite.test.sh" "${CONC_BODY/__TAG__/serialB}"
# a genuinely-hermetic generic suite that stays parallel — its presence proves the
# carve removes only the named suites, not the whole pool.
plant_suite "$BC" "generic.test.sh" $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
run_battery "$BP"
if [ "$BATT_RC" -eq 0 ] && ! printf '%s' "$BATT_OUT" | grep -qi 'overlapped'; then
  ok "[15.1] fix(b): the shared-live-tree suites (plugin.test.sh, ship-suite.test.sh) run SERIALLY (no fixture-collision under concurrency)"
else
  no "[15.1] fix(b): shared-live-tree-writing suites must be carved into the serial pass — they overlapped under the pool (rc=$BATT_RC out=$(printf '%s' "$BATT_OUT" | grep -i 'overlap\|serial\|Results' | tail -4))"
fi

# T11k — fix (b) the carve is keyed by the AUDITED serial set, declared in the
# runner heredoc itself (structural guard): the generator must name the live-tree
# suites so a future suite added to the shared-tree-writing set is enrolled by
# editing one list, and the carve can be read at the source. Red until the set
# exists.
grep -qE 'plugin\.test\.sh' "$RUNNER_SRC" && grep -qE 'ship-suite\.test\.sh' "$RUNNER_SRC" \
  && grep -qiE 'serial' "$RUNNER_SRC" \
  && ok "[15.1] fix(b): the runner declares the audited SERIAL set (plugin.test.sh, ship-suite.test.sh)" \
  || no "[15.1] fix(b): the runner must declare the serial set naming the shared-live-tree suites (audit not encoded)"
fi  # SCP_TEST_INNER guard ([15.1] block)

# ── T12 [19.5] — hook-registration dedup: --sync + plugin double-fire ────────────
# When the guv PLUGIN is also installed, the synced settings.json must ship
# hooks-free so the plugin's hooks.json is the SINGLE authoritative registration —
# otherwise every hook is registered twice (project-mode settings.json AND
# plugin-mode hooks.json) and fires twice, the double metering write. Detection is
# the user-level plugin DB (installed_plugins.json — the plugin installs at user
# scope, with no per-plane marker); GUV_PLUGINS_DB is the test seam. This pins the
# REGISTRATION-level dedup (the synced settings.json content), the deterministic
# property — NOT a live end-to-end check that both registrations fire (that needs
# a real Claude session with both paths active). Rule-15 safe degradation: no DB / no guv entry /
# unparseable → KEEP hooks (a plane without the plugin needs its project-mode hooks;
# a detection failure must never strip them — a hookless plane is the one new break).
# Outer-only (like the [15.1] block): stands up fixtures + runs setup several times,
# and the T10b inner self-invocations exist only to exercise the README gate seams.
if [ -z "${SCP_TEST_INNER:-}" ]; then
DB_PRESENT="$WORK/plugins-present.json"
printf '%s\n' '{"version":2,"plugins":{"guv@guv":[{"scope":"user","version":"0.7.0"}]}}' > "$DB_PRESENT"

# T12a — plugin installed: create strips the hooks block, preserves the rest, announces it.
H=$(make_guv); D="$WORK/dedup-plugin"
OUT12=$( GUV_PLUGINS_DB="$DB_PRESENT" bash "$H/maintainers/setup-control-plane.sh" "$D" 2>&1 )
if jq -e 'has("hooks") | not' "$D/.claude/settings.json" >/dev/null 2>&1; then
  ok "[19.5] plugin installed → synced settings.json ships hooks-free (single authoritative registration)"
else
  no "[19.5] plugin installed → synced settings.json must drop its hooks block (double-fire persists)"
fi
jq -e '.permissions.allow | index("Read(*)")' "$D/.claude/settings.json" >/dev/null 2>&1 \
  && ok "[19.5] the strip is surgical — non-hook settings (permissions) survive (jq del(.hooks))" \
  || no "[19.5] stripping hooks must preserve the rest of settings.json"
printf '%s' "$OUT12" | grep -qi 'hooks-free' && printf '%s' "$OUT12" | grep -qi 'double-fire' \
  && ok "[19.5] the dedup is announced (hooks-free + double-fire named), not silent (Rule 15)" \
  || no "[19.5] the strip must be announced — a designed path is loud, never silent"

# T12b — no plugin (DB absent): hooks RETAINED — a plane without the plugin needs them.
H=$(make_guv); D="$WORK/dedup-noplugin"
( GUV_PLUGINS_DB="$WORK/absent-db.json" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
jq -e 'has("hooks")' "$D/.claude/settings.json" >/dev/null 2>&1 \
  && ok "[19.5] no plugin DB → synced settings.json KEEPS its hooks (project-mode authoritative; no breakage)" \
  || no "[19.5] without the plugin the synced hooks must be retained (a hookless plane is a NEW break)"

# T12c — DB present but NO guv-family (guv@*) entry: hooks retained (an unrelated
# plugin must not trigger the strip).
H=$(make_guv); D="$WORK/dedup-otherplugin"
DB_OTHER="$WORK/plugins-other.json"
printf '%s\n' '{"version":2,"plugins":{"other@mkt":[{"scope":"user"}]}}' > "$DB_OTHER"
( GUV_PLUGINS_DB="$DB_OTHER" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
jq -e 'has("hooks")' "$D/.claude/settings.json" >/dev/null 2>&1 \
  && ok "[19.5] a non-guv plugin DB → hooks retained (an unrelated plugin must not trigger the strip)" \
  || no "[19.5] only a guv-family plugin entry makes the plugin authoritative for guv's hooks"

# T12c2 — the guv plugin from ANY marketplace (guv@<other>) is still authoritative.
# Detection keys on the "guv@" plugin NAME, not a literal guv@guv, by design: a guv
# fork served from a renamed marketplace must still dedup. This pins that intended
# breadth — without it, tightening the predicate to `== "guv@guv"` would silently
# reintroduce the double-fire for a forked-marketplace install and no test would fail.
H=$(make_guv); D="$WORK/dedup-guvfork"
DB_FORK="$WORK/plugins-guvfork.json"
printf '%s\n' '{"version":2,"plugins":{"guv@someotherfork":[{"scope":"user"}]}}' > "$DB_FORK"
( GUV_PLUGINS_DB="$DB_FORK" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
jq -e 'has("hooks") | not' "$D/.claude/settings.json" >/dev/null 2>&1 \
  && ok "[19.5] a guv plugin from a DIFFERENT marketplace (guv@someotherfork) still strips — detection is marketplace-agnostic by design (fork robustness)" \
  || no "[19.5] the dedup must key on the guv plugin NAME (guv@*), not a literal guv@guv — a forked-marketplace install would double-fire otherwise"

# T12d — unparseable DB: safe degradation KEEPS hooks (never strip on a detection failure).
H=$(make_guv); D="$WORK/dedup-garbage"
DB_BAD="$WORK/plugins-garbage.json"
printf 'not json at all' > "$DB_BAD"
( GUV_PLUGINS_DB="$DB_BAD" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
jq -e 'has("hooks")' "$D/.claude/settings.json" >/dev/null 2>&1 \
  && ok "[19.5] unparseable plugin DB → hooks retained (Rule 15: a detection failure is safe, never destructive)" \
  || no "[19.5] a garbage plugin DB must not strip hooks (safe degradation, not a hookless plane)"

# T12e — the dedup runs on --sync too (the operative path for an EXISTING plane like
# guv-guv): create with no plugin (hooks kept), then the plugin appears and a --sync
# refreshes the plane → the now-redundant project hooks are stripped. copy_core runs
# in both modes; this pins the --sync case directly, the real remediation path.
H=$(make_guv); D="$WORK/dedup-sync"
( GUV_PLUGINS_DB="$WORK/absent-db.json" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
jq -e 'has("hooks")' "$D/.claude/settings.json" >/dev/null 2>&1 \
  || no "[19.5] precondition: a no-plugin create should leave the hooks in place"
( GUV_PLUGINS_DB="$DB_PRESENT" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync ) >>"$WORK/setup.log" 2>&1
if jq -e 'has("hooks") | not' "$D/.claude/settings.json" >/dev/null 2>&1; then
  ok "[19.5] --sync after a plugin install strips the now-redundant project hooks (the real guv-guv path)"
else
  no "[19.5] --sync must also dedup (an existing plane that later installed the plugin keeps double-firing)"
fi
fi  # SCP_TEST_INNER guard (T12 [19.5] block)

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
