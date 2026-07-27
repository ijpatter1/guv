#!/bin/bash
# Tests for maintainers/setup-control-plane.sh — focused on the copy_core sync
# (what lands in the control plane's .claude/, and what must not).
# Pure bash + git, no test runner required (this template repo ships no JS suite).
# Run: bash .claude/tests/setup-control-plane.test.sh
set -u

REAL_SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/maintainers/setup-control-plane.sh"
REAL_ROOTS_SH="$(cd "$(dirname "$0")/.." && pwd)/roots.sh"  # shipped beside the generated runner ([11.2])
REAL_BATTERY_RESULT="$(cd "$(dirname "$0")/.." && pwd)/battery-result.sh"  # the [prong-A2] recorder, same glob
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
  # battery-result.sh — the [prong-A2] recorded verdict the generated runner calls
  # at the end of a run. Shipped the same way (copy_core's *.sh glob), so carrying
  # the REAL one here keeps T11r a test of the SHIPPED path: a hand-planted copy in
  # the plane would pass while the recorder never reached a real install.
  cp "$REAL_BATTERY_RESULT" "$h/.claude/battery-result.sh"
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
  # The rest of what build-plugin.sh copies VERBATIM, so the behind-build detector has
  # something real to measure on every surface it claims. shell/ is here because it was
  # the gap found at review: it is the scaffold payload deployed into every project guv
  # creates, and it entered cache scope in the same commit that first shipped the
  # detector — the newest tree was the unwatched one.
  mkdir -p "$h/sandbox" "$h/docs" \
           "$h/maintainers/plugin-src/scripts" "$h/maintainers/plugin-src/skills/zen" \
           "$h/.claude/skills/status/assets"
  printf 'CLAUDE template v1\n'  > "$h/CLAUDE.template.md"
  printf 'README template v1\n'  > "$h/README.template.md"
  printf 'all:\n\t@echo v1\n'    > "$h/Makefile"
  printf 'sandbox image v1\n'    > "$h/sandbox/Dockerfile"
  printf '# REQUIREMENTS v1\n'   > "$h/docs/REQUIREMENTS.md"
  printf '# ARCHITECTURE v1\n'   > "$h/docs/ARCHITECTURE.md"
  printf '# PHASE_STATUS v1\n'   > "$h/docs/PHASE_STATUS.md"
  printf 'readonly guard v1\n'   > "$h/maintainers/plugin-src/scripts/reviewer-readonly.sh"
  printf '# zen v1\n'            > "$h/maintainers/plugin-src/skills/zen/SKILL.md"
  # A bundled skill asset that is neither under scripts/ nor a .sh file — the builder
  # cp -R's ANY subdir of a skill byte-identical, so the detector's walk has to be that
  # wide too. The narrower glob it shipped with would never have looked here.
  printf 'legend v1\n'           > "$h/.claude/skills/status/assets/legend.txt"
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
  # [15.1] fix (b) lockstep HERMETICITY: the local battery verifies the property
  # that makes its pool sound — it fingerprints the code repo before the first suite
  # and after the last, failing on a moved tree. That guard took over the SAFETY
  # argument from the serial carve of plugin.test.sh + ship-suite.test.sh; the carve
  # itself remains locally for a separate, measured SCHEDULING reason (see
  # SERIAL_SET in the generator), which is why this comment must not describe the
  # guard as having replaced it.
  #
  # The CI loop is serial-by-design, and the distinction matters enough to assert:
  # serial subsumes the CARVE (non-overlap — run alone, nothing collides) but
  # does NOT subsume HERMETICITY (a suite that writes the live tree still writes it
  # when run alone; CI simply never notices). So the lockstep invariant is narrower
  # than it was — CI must not silently go parallel without carrying the fingerprint
  # guard, and its comment must name the coupling INCLUDING what serial does not
  # buy, so the next editor does not read "serial" as "hermetic".
  if grep -qE 'bash "\$t".*&[[:space:]]*$' "$CI_YML"; then
    no "CI inline loop backgrounds suites ('&') — a parallel CI form must carry the before/after hermeticity fingerprint guard, not glob all suites concurrently over the shared live tree"
  else
    grep -qiE 'hermetic' "$CI_YML" && grep -qiE 'fingerprint' "$CI_YML" \
       && grep -qiE 'does not subsume|NOT subsume' "$CI_YML" \
      && ok "CI test loop stays serial and documents the hermeticity coupling — including what serial does NOT subsume ([15.1] fix b lockstep)" \
      || no "CI inline loop must name the hermeticity guard coupling (the local battery's before/after fingerprint over the shared live source tree) and state that serial execution does not subsume it"
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
# Gated on the README being the TEMPLATE's: /init replaces README.md
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

# T11p — PROGRESS INSTRUMENTATION (Prong C of the battery-cost attack). The runner
# used to print NOTHING until every suite had finished, so a 12-minute battery was
# indistinguishable from a hang — the misread recorded in friction entry
# 2026-07-18T17:37:57Z-2084922661, where a contended full battery was killed as a
# suspected single-suite hang. On a machine with no timeout binary (this one) there
# is no per-suite ceiling either, so silence is the ONLY signal a hang has.
#
# Why this asserts on the STREAM and not merely on presence: the battery's own gate
# fails a suite on ANY stderr byte, so instrumentation that leaked into a suite's
# captured stream would red the battery it exists to measure. Progress therefore
# belongs on the RUNNER's stderr, and stdout must stay clean so the deterministic
# sorted aggregation — the thing that makes the verdict reproducible — is unchanged.
# A test that only checked "some progress appears" would pass an implementation
# that breaks either property.
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
plant_suite "$BC" "alpha.test.sh" $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
plant_suite "$BC" "beta.test.sh"  $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
PROG_O=$(mktemp); PROG_E=$(mktemp)
( cd "$BP" && bash .claude/run-core-tests.sh ) >"$PROG_O" 2>"$PROG_E"; PROG_RC=$?
PROG_OUT=$(cat "$PROG_O"); PROG_ERR=$(cat "$PROG_E"); rm -f "$PROG_O" "$PROG_E"

printf '%s' "$PROG_ERR" | grep -q 'alpha.test.sh' \
  && printf '%s' "$PROG_ERR" | grep -q 'beta.test.sh' \
  && [ "$PROG_RC" -eq 0 ] \
  && ok "[prong-C] the runner announces each suite's completion on stderr as it lands (a long battery is no longer a silent void)" \
  || no "[prong-C] a battery that prints nothing until the end is indistinguishable from a hang — each suite must announce completion (rc=$PROG_RC err=$(printf '%s' "$PROG_ERR" | tail -3))"

# The run's SHAPE must be announced BEFORE the first suite finishes. Completion
# lines alone are not enough: on the real battery nothing lands for the first
# minutes of a run, which is the exact window in which a contended battery was
# once killed as a suspected hang. Asserted on ORDER, not presence, because a
# shape line printed at the end would satisfy a presence check and inform nobody.
PROG_SHAPE=$(printf '%s\n' "$PROG_ERR" | grep -n 'running .* suites' | head -1 | cut -d: -f1)
PROG_FIRSTDONE=$(printf '%s\n' "$PROG_ERR" | grep -n 'done ' | head -1 | cut -d: -f1)
[ -n "$PROG_SHAPE" ] && [ -n "$PROG_FIRSTDONE" ] && [ "$PROG_SHAPE" -lt "$PROG_FIRSTDONE" ] \
  && ok "[prong-C] the run's shape is announced before the first suite completes (silence at startup, not just at the end, is what gets a battery killed)" \
  || no "[prong-C] the runner must say what it is about to do before it does it — a shape line after the first completion informs nobody (shape=$PROG_SHAPE first-done=$PROG_FIRSTDONE)"

# Discriminate on the PROGRESS markers, not on the "[run-core-tests]" prefix alone:
# the pre-existing no-timeout degradation notice legitimately carries that prefix on
# stdout, so a prefix-only check would red on a correct implementation.
printf '%s' "$PROG_OUT" | grep -qE 'run-core-tests\] done |per-suite wall-clock' \
  && no "[prong-C] progress leaked into STDOUT — the deterministic sorted aggregation must stay clean, or a reproducible verdict was traded for a progress bar" \
  || ok "[prong-C] progress stays off stdout; the deterministic aggregation is unchanged"

# And the timings must be RETAINED, not merely streamed — the census that sizes
# Prong A1 and Prong B needs the distribution, and [22.1] Q3 is the standing lesson
# that a MODELED suite-time distribution was ~4x wrong and was caught only by
# measurement.
printf '%s' "$PROG_ERR" | grep -qiE 'per-suite|slowest' \
  && printf '%s' "$PROG_ERR" | grep -qE '[0-9]+s[[:space:]]+(alpha|beta)\.test\.sh' \
  && ok "[prong-C] per-suite wall-clock is retained and reported, so the next sizing decision is measured rather than modeled" \
  || no "[prong-C] per-suite durations must be reported, not just completion events — without the distribution neither A1 nor B can be sized honestly (err=$(printf '%s' "$PROG_ERR" | tail -5))"

# T11q — FOCUSED-SUITE PATH (Prong A1 of the battery-cost attack). The runner had
# NO positional-argument handling at all, so `commands.test` could only ever run the
# whole battery — and passing a filter SILENTLY ran every suite anyway. That silent
# swallow is the actual complaint in friction entry 2026-07-18T17:37:57Z-2084922661,
# and it is what makes a one-suite fix loop cost a full battery. The census landed
# with Prong C shows why it matters: 42 of 71 suites finish under 30s, so the common
# mid-loop iteration pays ~800s to re-verify seconds of work. (Counts re-measured
# 2026-07-26; the figures here were 41-of-68 from an unverified earlier estimate.)
#
# The precedent is the plugin runner's --only (maintainers/build-plugin.sh), and the
# invariant carried over from it is the one that keeps Rule 8 intact: a pattern that
# matches NOTHING fails LOUD. A filtered proof that silently runs zero suites would
# let every --only consumer pass on nothing — a vacuous green is worse than no filter.
only_run() {  # $1=plane-dir, rest=args ; sets ONLY_OUT / ONLY_ERR / ONLY_RC
  local d="$1"; shift
  local oo oe; oo=$(mktemp); oe=$(mktemp)
  ( cd "$d" && bash .claude/run-core-tests.sh "$@" ) >"$oo" 2>"$oe"; ONLY_RC=$?
  ONLY_OUT=$(cat "$oo"); ONLY_ERR=$(cat "$oe"); rm -f "$oo" "$oe"
}
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
plant_suite "$BC" "wanted.test.sh"   $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
plant_suite "$BC" "unwanted.test.sh" $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'

# The filter must actually EXCLUDE. Asserted on the unwanted suite's ABSENCE, not
# just the wanted one's presence: an implementation that accepts --only and then
# runs everything anyway (today's behavior) satisfies a presence-only check.
only_run "$BP" --only 'wanted.test.sh'
[ "$ONLY_RC" -eq 0 ] \
  && printf '%s' "$ONLY_OUT$ONLY_ERR" | grep -q 'wanted.test.sh' \
  && ! printf '%s' "$ONLY_OUT$ONLY_ERR" | grep -q 'unwanted.test.sh' \
  && ok "[prong-A1] --only <pattern> runs just the matching suite and EXCLUDES the rest (a one-suite fix loop stops paying for the whole battery)" \
  || no "[prong-A1] --only must gate suite execution, not be accepted and ignored — a filter that silently runs everything is the friction entry's exact complaint (rc=$ONLY_RC)"

# Zero matches is the vacuous-green trap: a typo'd pattern that runs nothing and
# exits 0 turns every downstream "the suite passes under --only" claim into a proof
# about the empty set. It must fail loud AND name the pattern, or the operator
# cannot tell a typo from a genuinely-passing filtered run.
only_run "$BP" --only 'nosuch*.test.sh'
[ "$ONLY_RC" -ne 0 ] \
  && printf '%s' "$ONLY_ERR" | grep -q 'nosuch' \
  && ok "[prong-A1] a pattern matching no suite fails LOUD and names the pattern (a filtered proof can never pass vacuously)" \
  || no "[prong-A1] --only with zero matches must not exit green — a filter that runs nothing and reports success proves nothing (rc=$ONLY_RC err=$(printf '%s' "$ONLY_ERR" | tail -2))"

# The silent swallow itself. An unrecognized argument that is quietly dropped is how
# a person believes they ran one suite while the machine ran all of them — which is
# the recorded misread, not a hypothetical.
only_run "$BP" --bogus
[ "$ONLY_RC" -ne 0 ] \
  && printf '%s' "$ONLY_ERR" | grep -qi 'bogus' \
  && ok "[prong-A1] an unrecognized argument fails loud and names itself (never a silent swallow that runs the full battery instead)" \
  || no "[prong-A1] arguments must never be silently ignored — the operator has to be able to trust that what they asked for is what ran (rc=$ONLY_RC err=$(printf '%s' "$ONLY_ERR" | tail -2))"

# --only with no operand: the shift-past-the-end case. Left unguarded this reads an
# empty pattern, which matches nothing and would take the zero-match path — right
# exit, wrong message. The operator needs to know the flag was malformed, not that
# their (absent) pattern missed.
only_run "$BP" --only
[ "$ONLY_RC" -ne 0 ] \
  && printf '%s' "$ONLY_ERR" | grep -qi 'only' \
  && ok "[prong-A1] --only with no pattern fails loud on the malformed flag (distinct from a pattern that simply missed)" \
  || no "[prong-A1] --only requires a non-empty pattern; a bare flag must not fall through to an empty-glob run (rc=$ONLY_RC err=$(printf '%s' "$ONLY_ERR" | tail -2))"

# The unfiltered path must be byte-identical in BEHAVIOR — this change is additive or
# it is a regression in the gate that every other assertion here depends on.
only_run "$BP"
[ "$ONLY_RC" -eq 0 ] \
  && printf '%s' "$ONLY_OUT$ONLY_ERR" | grep -q 'wanted.test.sh' \
  && printf '%s' "$ONLY_OUT$ONLY_ERR" | grep -q 'unwanted.test.sh' \
  && ok "[prong-A1] no arguments still runs the full battery unchanged (the filter is additive; the session-close gate is untouched)" \
  || no "[prong-A1] argument handling must not change the unfiltered run — the full battery is still the gate at session close (rc=$ONLY_RC)"

# T11r — RECORDED VERDICT (Prong A2). The runner is the single owner of suite
# execution; everything downstream is supposed to read its result rather than pay
# ~800s for its own. That only works if the runner actually records, and if a
# FILTERED run is marked as filtered — a --only verdict consumed as a whole-tree
# proof is the vacuous green A1's zero-match rule prevents, one level up.
#
# The provenance semantics themselves live in battery-result.test.sh; what is
# asserted HERE is only the wiring: the runner calls the recorder, with the right
# counts, and marks the filter.
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
plant_suite "$BC" "reca.test.sh" $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
plant_suite "$BC" "recb.test.sh" $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
( cd "$BC" && git init -q . && git config user.email t@t && git config user.name t \
  && git add -A && git commit -qm init ) >/dev/null 2>&1
run_battery "$BP"
REC="$BP/.claude/metering/.last-battery-result"
[ "$BATT_RC" -eq 0 ] && [ -f "$REC" ] \
  && [ "$(jq -r '.suites' "$REC" 2>/dev/null)" = "2" ] \
  && [ "$(jq -r '.failed' "$REC" 2>/dev/null)" = "0" ] \
  && [ "$(jq -r '.filtered' "$REC" 2>/dev/null)" = "null" ] \
  && ok "[prong-A2] a full run records its verdict with suite counts and no filter (the single owner leaves something for the others to read)" \
  || no "[prong-A2] the runner must record the verdict it just produced, or every QA stage pays for its own battery (rc=$BATT_RC rec=$(cat "$REC" 2>/dev/null))"

# T11r2 — the ASSERTION TALLY, producer side. `suites` and `assertions` differ by
# more than an order of magnitude on the real battery (71 vs ~2,500), and reading one
# as the other understated a run ~35x. The consumer half is covered in
# battery-result.test.sh; the harvest that produces the number was shipped with no
# test at all (guv eval, 2026-07-27) — deleting the withhold or flipping `tail -1`
# to `head -1` left the whole battery green.
#
# Both fixtures print `Results: 1 passed, 0 failed`, so the tally is 2 — a number
# that cannot be confused with the suite count of 2 by accident, hence the second
# fixture below.
[ "$(jq -r '.assertions_passed' "$REC" 2>/dev/null)" = "2" ] \
  && [ "$(jq -r '.assertions_failed' "$REC" 2>/dev/null)" = "0" ] \
  && ok "[prong-A2] the runner harvests the ASSERTION totals, not just the suite counts (the two are different units and were reported as one)" \
  || no "[prong-A2] a recorded verdict without assertion totals sends the next reader back to the suite count as if it were the test count (rec=$(cat "$REC" 2>/dev/null))"

# T11r3 — the tally takes each suite's LAST `Results:` line, and withholds ENTIRELY
# when any suite does not report one. Two properties, one plane, because they are
# the two ways the tally can silently lie:
#   - `nested` prints a child runner's line first and its own grand total last.
#     `head -1` would record 5 instead of 9 and nothing would look wrong.
#   - `silent` prints no `Results:` line at all (two real suites did exactly this
#     until 2026-07-27). A partial tally is worse than none, so the harvest is
#     all-or-nothing: suites still records, assertions must come back null.
IFS='|' read -r BP5 BC5 <<<"$(mk_battery_plane)"
plant_suite "$BC5" "nested.test.sh" $'#!/bin/bash\necho "  Results: 5 passed, 0 failed"\necho "Results: 9 passed, 0 failed"\nexit 0\n'
plant_suite "$BC5" "silent.test.sh" $'#!/bin/bash\necho "  ran, but reports no verdict line"\nexit 0\n'
( cd "$BC5" && git init -q . && git config user.email t@t && git config user.name t \
  && git add -A && git commit -qm init ) >/dev/null 2>&1
run_battery "$BP5"
REC5="$BP5/.claude/metering/.last-battery-result"
[ "$BATT_RC" -eq 0 ] \
  && [ "$(jq -r '.suites' "$REC5" 2>/dev/null)" = "2" ] \
  && [ "$(jq -r '.assertions_passed' "$REC5" 2>/dev/null)" = "null" ] \
  && [ "$(jq -r '.assertions_failed' "$REC5" 2>/dev/null)" = "null" ] \
  && ok "[prong-A2] one non-reporting suite withholds the WHOLE assertion tally while the suite counts still record (a partial tally reads as a total and is worse than none)" \
  || no "[prong-A2] the assertion harvest must be all-or-nothing: a tally missing a suite's contribution would be quoted as the test count (rc=$BATT_RC rec=$(cat "$REC5" 2>/dev/null))"

# T11r4 — and with every suite reporting, the tally lands on the LAST line. Same
# `nested` fixture (5 then 9) plus a plain 1-assertion suite: the total must be 10.
# `head -1` would give 6, `tail -1` gives 10, and neither collides with the suite
# count of 2 — the arithmetic is what discriminates, so this cannot pass by accident.
IFS='|' read -r BP6 BC6 <<<"$(mk_battery_plane)"
plant_suite "$BC6" "nested.test.sh" $'#!/bin/bash\necho "  Results: 5 passed, 0 failed"\necho "Results: 9 passed, 0 failed"\nexit 0\n'
plant_suite "$BC6" "plain.test.sh" $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
( cd "$BC6" && git init -q . && git config user.email t@t && git config user.name t \
  && git add -A && git commit -qm init ) >/dev/null 2>&1
run_battery "$BP6"
REC6="$BP6/.claude/metering/.last-battery-result"
[ "$BATT_RC" -eq 0 ] && [ "$(jq -r '.assertions_passed' "$REC6" 2>/dev/null)" = "10" ] \
  && ok "[prong-A2] a suite's LAST Results: line is its total — a nested runner's inner line is not harvested as the suite's count (10, not 6)" \
  || no "[prong-A2] harvesting the first Results: line instead of the last silently under-counts every suite that wraps another runner (rec=$(cat "$REC6" 2>/dev/null))"

# A filtered run must NOT RECORD AT ALL, and the whole-tree record must survive it.
# `read` refusing a filtered verdict is the safe direction and is covered directly
# in battery-result.test.sh — but recording one FIRST is not safe: it destroys a
# still-valid whole-tree green, so the very loop --only exists to make cheap (fix,
# --only, eval) would hand the next QA stage a ~800s battery it did not owe (guv
# eval, 2026-07-27). Leaving the prior record alone costs nothing: its own
# fingerprint is what decides whether it still describes this tree, so if the fix
# moved the tree it refuses on its own.
REC_BEFORE="$(cat "$REC" 2>/dev/null)"
FILT_ERR="$( cd "$BP" && bash .claude/run-core-tests.sh --only 'reca.test.sh' 2>&1 >/dev/null )"
[ -n "$REC_BEFORE" ] && [ "$(cat "$REC" 2>/dev/null)" = "$REC_BEFORE" ] \
  && [ "$(jq -r '.suites' "$REC" 2>/dev/null)" = "2" ] \
  && [ "$(jq -r '.filtered' "$REC" 2>/dev/null)" = "null" ] \
  && printf '%s' "$FILT_ERR" | grep -q 'NOT recorded' \
  && ok "[prong-A2] a --only run leaves the whole-tree record intact and says so (a one-suite verdict must never overwrite a full one)" \
  || no "[prong-A2] a filtered run overwrote the recorded whole-tree verdict — the next QA stage now pays for a battery it did not owe (rec=$(cat "$REC" 2>/dev/null) err=$(printf '%s' "$FILT_ERR" | tail -2))"

# The recorder must never be able to change the verdict. This is the [15.1]
# exit-masking invariant: a red battery stays red even if recording is impossible,
# and a green one is not turned red by a recorder that fails.
rm -f "$BP/.claude/battery-result.sh"
run_battery "$BP"
# Two things must hold, and the banner is the one that was going untested: with the
# script gone the guard cannot fingerprint either, so this is also the SECOND cause
# of the degradation banner (T11l covers the not-a-git-repo cause). Asserting rc
# alone let a silent unchecked run pass for a clean one — the exact failure the
# announcement exists to prevent.
[ "$BATT_RC" -eq 0 ] \
  && printf '%s' "$BATT_OUT" | grep -qE 'hermeticity NOT CHECKED' \
  && ok "[prong-A2] a missing recorder degrades to today's behavior, cannot alter the verdict, and ANNOUNCES that hermeticity went unchecked (the second cause of that banner)" \
  || no "[prong-A2] recording is bookkeeping — its absence must not fail a green battery, but it must not silently disable the guard either (rc=$BATT_RC out=$(printf '%s' "$BATT_OUT" | grep -i 'hermetic' | tail -2))"

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

# ── fix (b): the HERMETICITY GUARD (T11j–T11l) + the SERIAL CARVE (T11m–T11n) ──
# Two mechanisms, tested separately, because they were once the same thing and are
# no longer. Read this before changing either.
#
# Parallelism was originally made safe by a SERIAL CARVE: plugin.test.sh and
# ship-suite.test.sh wrote to / built from the shared live source tree at fixed
# paths, so they were quarantined and run one-at-a-time ahead of the pool. Spike
# Prong B made both suites hermetic, which retired that reason.
#
# The GUARD (T11j–T11l) is what replaced the safety argument. The runner
# fingerprints the code repo before the first suite and after the last, and fails
# on a moved tree. It is strictly stronger than the quarantine ever was: the carve
# only protected the suites someone had already thought to name, while the guard
# holds for every suite including ones not yet written. These tests ask "did ANY
# suite write to the live tree, and does the runner notice?" — detection (T11j),
# no-false-red (T11k), and the announced degradation where the check cannot run at
# all (T11l). The guard is WHOLE-BATTERY by necessity: under a parallel pool the
# suites overlap, so a tree change cannot be attributed to one suite without
# serializing them again.
#
# The CARVE (T11m–T11n) survived the guard, on a different and now MEASURED
# justification: scheduling. It was removed once (guv d1be3dd) and reverted, because
# the pool is saturated and folding the two heaviest suites into it inflated every
# other suite instead of filling idle lanes — aggregate suite-seconds 3860 -> 5733
# (+48%) for a 65s wall-clock gain, with the battery going 71/0 -> 66/5 on
# contention alone. These tests ask the same question the old T11j/T11k asked
# ("were the two named suites kept apart?") but for the scheduling reason, not the
# hermeticity one. Do not delete them believing the guard covers this: the guard
# checks correctness, the carve manages load, and neither substitutes for the other.

# T11j — DETECTION of a PERSISTING write. A suite that leaves a fixture in the live
# source tree must fail the battery. Be precise about the scope, because the audit
# doc once overstated it (corrected 2026-07-27): the guard compares before against
# after, so this covers RESIDUE, not every live-tree write — T11j2 below pins the
# plant-and-clean case that it deliberately cannot see. The fixture code repo must
# be a real git repo here (the fingerprint needs one), and the baseline is committed
# AFTER the suites are planted so the only thing that moves the tree is the leak.
IFS='|' read -r BP BC <<<"$(mk_battery_plane)"
plant_suite "$BC" "leaky.test.sh" $'#!/bin/bash\n# Plants a fixture in the SHARED LIVE TREE — the exact hazard the carve used to\n# quarantine. Reports itself green, so only the hermeticity guard can catch it.\nSHARED="$(cd "$(dirname "$0")/.." && pwd)"\n: > "$SHARED/zz-leaked-fixture"\necho "Results: 1 passed, 0 failed"\nexit 0\n'
plant_suite "$BC" "clean.test.sh" $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
( cd "$BC" && git init -q . && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm baseline ) >/dev/null 2>&1
run_battery "$BP"
# Match the BREACH banner specifically, not the word "hermeticity" — the
# degradation banner ("hermeticity NOT CHECKED") carries that word too, i.e. the
# guard-is-OFF state, which is the opposite outcome from the one under test.
if [ "$BATT_RC" -ne 0 ] && printf '%s' "$BATT_OUT" | grep -q 'THE CODE REPO MOVED'; then
  ok "[15.1] fix(b): a suite that LEAVES a write in the live source tree FAILS the battery, named as a hermeticity breach"
else
  no "[15.1] fix(b): a persisting live-tree write must fail the run — unnoticed residue is the fixture-collision flake class running unguarded (rc=$BATT_RC out=$(printf '%s' "$BATT_OUT" | grep -i 'hermetic\|Results' | tail -4))"
fi
# The breach report must NAME the path, not just assert that something moved. The
# guard cannot say WHICH suite wrote (they overlap in the pool), so the path is
# the only thing that turns "a suite leaked" into an actionable fix.
printf '%s' "$BATT_OUT" | grep -q 'zz-leaked-fixture' \
  && ok "[15.1] fix(b): the breach report names the path that appeared (the whole-battery guard cannot name the suite, so the path is what makes it actionable)" \
  || no "[15.1] fix(b): a hermeticity breach must print the porcelain diff naming the changed path — 'the tree moved' alone sends the reader hunting (out=$(printf '%s' "$BATT_OUT" | grep -iA6 'hermeticity' | tail -8))"

# T11j2 — the guard's KNOWN BLIND SPOT, pinned on purpose. A suite that plants a
# fixture and removes it before exiting leaves before == after, so the guard sees
# nothing and the battery is green. That is not an oversight to be fixed quietly —
# it is the shape EVERY offender in maintainers/BATTERY-HERMETICITY.md actually had
# (each carried an rm -f and an EXIT trap so its fixture would not survive), which
# is precisely why hermeticity is provided by the suite AUTHOR and this guard is
# only a residue backstop.
#
# Pinned because the audit doc spent a release telling suite authors the opposite
# ("you do not have to remember to do this — the fingerprint fails the battery on
# any live-tree write"), and an unwritten limit gets re-forgotten. If this ever
# RED-lights, the guard grew teeth: that is an improvement, not a regression —
# update the third limit in BATTERY-HERMETICITY.md and the guard comment in
# setup-control-plane.sh to match, then invert this assertion.
# Two legs beyond "rc=0 and no breach banner", because that pair is ALSO what a
# guard that never ran produces — the identical can't-fail shape this suite fixed
# 250 lines above at the missing-recorder case (guv eval, 2026-07-27). So: the
# fixture VERIFIES ITS OWN PLANT and reds the suite if the write never landed
# (a blind spot is only pinned if the thing it is blind to actually happened), and
# the assertion requires the degradation banner to be ABSENT, which is what says
# the guard was armed and looked.
IFS='|' read -r BP1B BC1B <<<"$(mk_battery_plane)"
plant_suite "$BC1B" "transient.test.sh" $'#!/bin/bash\n# Plants into the SHARED LIVE TREE, then cleans up — invisible to a before/after check.\nSHARED="$(cd "$(dirname "$0")/.." && pwd)"\n: > "$SHARED/zz-transient-fixture" 2>/dev/null\n[ -f "$SHARED/zz-transient-fixture" ] || { echo "  \xe2\x9c\x97 the plant never landed — this suite proves nothing about the guard"; echo "Results: 0 passed, 1 failed"; exit 1; }\nsleep 1\nrm -f "$SHARED/zz-transient-fixture"\necho "Results: 1 passed, 0 failed"\nexit 0\n'
( cd "$BC1B" && git init -q . && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm baseline ) >/dev/null 2>&1
run_battery "$BP1B"
[ "$BATT_RC" -eq 0 ] && ! printf '%s' "$BATT_OUT" | grep -q 'THE CODE REPO MOVED' \
  && ! printf '%s' "$BATT_OUT" | grep -qE 'hermeticity NOT CHECKED' \
  && ok "[15.1] fix(b): a plant-and-clean live-tree write passes an ARMED guard — the documented blind spot, pinned so the claim cannot drift back to 'any live-tree write'" \
  || no "[15.1] fix(b): T11j2 pins a KNOWN LIMIT and it just changed. If you strengthened the guard to catch transient writes, that is good news — update BATTERY-HERMETICITY.md's third limit and the guard comment in setup-control-plane.sh, then invert this assertion. (If the run shows 'hermeticity NOT CHECKED' the guard was OFF and this test proved nothing.) (rc=$BATT_RC out=$(printf '%s' "$BATT_OUT" | grep -i 'hermetic\|Results' | tail -4))"

# T11j3 — the guard still catches a mid-run COMMIT, which the provenance
# fingerprint deliberately stopped seeing. The fingerprint went content-only so a
# verdict would survive the commit boundary (battery-result.sh, T11d/T11e); the
# cost is that `git commit` moves no working-tree byte, so a suite committing into
# the developer's repo would slip through a content-only comparison. The guard
# carries its own HEAD check for exactly that, and this pins the pair: the record
# stops caring about HEAD, the guard does not. --allow-empty is the sharp case —
# it changes HEAD and NOTHING else, so only the HEAD check can see it.
IFS='|' read -r BP1C BC1C <<<"$(mk_battery_plane)"
plant_suite "$BC1C" "committer.test.sh" $'#!/bin/bash\nREPO="$(cd "$(dirname "$0")/../.." && pwd)"\ngit -C "$REPO" commit -q --allow-empty -m "a suite committed into the live repo" 2>/dev/null\necho "Results: 1 passed, 0 failed"\nexit 0\n'
( cd "$BC1C" && git init -q . && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm baseline ) >/dev/null 2>&1
run_battery "$BP1C"
[ "$BATT_RC" -ne 0 ] && printf '%s' "$BATT_OUT" | grep -q 'THE CODE REPO MOVED' \
  && printf '%s' "$BATT_OUT" | grep -qi 'HEAD moved' \
  && ok "[15.1] fix(b): a suite that COMMITS into the live repo fails the battery and the breach names HEAD (content-only provenance cannot see this; the guard's own HEAD check is what does)" \
  || no "[15.1] fix(b): a mid-run commit must still breach the guard — the fingerprint went content-only so the verdict survives committing, and the HEAD check is the half that keeps a suite from committing into someone's repo unnoticed (rc=$BATT_RC out=$(printf '%s' "$BATT_OUT" | grep -i 'hermetic\|HEAD\|Results' | tail -5))"

# T11j4 — the guard's THIRD leg: a mid-run `git add`. When the fingerprint went
# content-only it dropped `git status --porcelain`, and for one unreleased revision
# nothing picked the index back up — a suite could stage into the developer's live
# repo and breach nothing, silently changing what their next `git commit` sweeps
# up (guv eval, 2026-07-27). The record cannot take the index back (staging is the
# first half of the ordinary commit whose verdict-survival is the whole point of
# the rewrite), so it belongs to the guard alone.
#
# The fixture isolates the index the way T11j3 isolates HEAD. The planted file is
# created BEFORE the battery starts, so its bytes are already in the before-hash;
# the suite only runs `git add` on it. Content identical, HEAD identical, index
# moved — the porcelain comparison is the only check that can see it, so a pass
# here cannot be bought by either of the other two legs.
IFS='|' read -r BP1D BC1D <<<"$(mk_battery_plane)"
plant_suite "$BC1D" "stager.test.sh" $'#!/bin/bash\nREPO="$(cd "$(dirname "$0")/../.." && pwd)"\n[ -f "$REPO/zz-preexisting-untracked" ] || { echo "  \xe2\x9c\x97 the pre-planted file is missing — this suite proves nothing about the index"; echo "Results: 0 passed, 1 failed"; exit 1; }\ngit -C "$REPO" add zz-preexisting-untracked 2>/dev/null\necho "Results: 1 passed, 0 failed"\nexit 0\n'
( cd "$BC1D" && git init -q . && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm baseline ) >/dev/null 2>&1
# After the baseline commit, so it is untracked-but-present when the guard takes
# its BEFORE reading. The suite stages it; no byte moves either way.
echo "planted before the battery" > "$BC1D/zz-preexisting-untracked"
run_battery "$BP1D"
[ "$BATT_RC" -ne 0 ] && printf '%s' "$BATT_OUT" | grep -q 'THE CODE REPO MOVED' \
  && printf '%s' "$BATT_OUT" | grep -qi 'the INDEX moved' \
  && ! printf '%s' "$BATT_OUT" | grep -qi 'HEAD moved' \
  && ok "[15.1] fix(b): a suite that STAGES into the live repo fails the battery and the breach names the INDEX — the leg the content-only rewrite dropped, restored and pinned (no byte moved, so neither the content hash nor the HEAD check could have caught this)" \
  || no "[15.1] fix(b): a mid-run \`git add\` must breach the guard. Content-only provenance cannot see staging and neither can the HEAD check, so the porcelain comparison is the only leg that can — if this went green, that leg is gone again and a suite can quietly re-stage a developer's index (rc=$BATT_RC out=$(printf '%s' "$BATT_OUT" | grep -i 'hermetic\|INDEX\|HEAD\|Results' | tail -5))"

# T11j5 — the guard's FOURTH leg: a mid-run REF move. `git commit` and `git add`
# are not the only members of the "disturbs the repo, moves no byte" family, and
# the guard's own comment used to claim they were (guv eval, 2026-07-27, filed as
# an UNWRITTEN gap — rule 15 tolerates a documented limit and not a silent one).
# `git switch -c` leaves working-tree content identical, leaves `rev-parse HEAD`
# identical (the new branch points at the same commit), and shows nothing in
# `git status --porcelain` — so all three original legs pass it.
#
# The fixture is the sharpest of the four: NOTHING moves except which ref HEAD
# names. A pass here cannot be bought by the content hash, the HEAD check, or the
# porcelain comparison, because none of the three can see a symbolic-ref change.
# What it protects is a developer's checkout: a suite that mis-resolves the repo
# and branches in the live tree leaves them on a branch they never chose.
IFS='|' read -r BP1E BC1E <<<"$(mk_battery_plane)"
plant_suite "$BC1E" "brancher.test.sh" $'#!/bin/bash\nREPO="$(cd "$(dirname "$0")/../.." && pwd)"\ngit -C "$REPO" switch -c lane/hijack 2>/dev/null || git -C "$REPO" checkout -b lane/hijack 2>/dev/null\necho "Results: 1 passed, 0 failed"\nexit 0\n'
( cd "$BC1E" && git init -q . && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm baseline ) >/dev/null 2>&1
run_battery "$BP1E"
[ "$BATT_RC" -ne 0 ] && printf '%s' "$BATT_OUT" | grep -q 'THE CODE REPO MOVED' \
  && printf '%s' "$BATT_OUT" | grep -qi 'checked-out REF moved' \
  && ! printf '%s' "$BATT_OUT" | grep -qi 'HEAD moved' \
  && ! printf '%s' "$BATT_OUT" | grep -qi 'the INDEX moved' \
  && ok "[15.1] fix(b): a suite that SWITCHES BRANCHES in the live repo fails the battery and the breach names the REF — the fourth member of the moves-no-byte family, which the other three legs are all blind to by construction" \
  || no "[15.1] fix(b): a mid-run \`git switch -c\` must breach the guard. Content is identical, HEAD is identical (the new branch is at the same commit) and porcelain is identical, so the symbolic-ref capture is the ONLY leg that can see it — if this went green, a suite can leave a developer on a branch they never chose and the run still passes (rc=$BATT_RC out=$(printf '%s' "$BATT_OUT" | grep -i 'hermetic\|REF\|HEAD\|Results' | tail -5))"

# T11k — NO FALSE RED. The same plane with only hermetic suites must come back
# green with the guard silent. This is the assertion that keeps the guard alive:
# a check that reds a clean battery gets deleted within a day for crying wolf,
# and every suite in the real battery is now expected to pass it on every run.
IFS='|' read -r BP2 BC2 <<<"$(mk_battery_plane)"
plant_suite "$BC2" "alpha.test.sh" $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
plant_suite "$BC2" "beta.test.sh"  $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
( cd "$BC2" && git init -q . && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm baseline ) >/dev/null 2>&1
run_battery "$BP2"
[ "$BATT_RC" -eq 0 ] && ! printf '%s' "$BATT_OUT" | grep -qi 'hermeticity' \
  && ok "[15.1] fix(b): a hermetic battery stays green and the guard stays silent (no false red on the clean path)" \
  || no "[15.1] fix(b): the hermeticity guard must not fire on a clean run — a guard that reds a good battery is removed, not obeyed (rc=$BATT_RC out=$(printf '%s' "$BATT_OUT" | grep -i 'hermetic\|Results' | tail -4))"

# T11l — the ANNOUNCED DEGRADATION (rule 15). Where the code repo is not a git
# repo the fingerprint cannot be taken at all. The battery must still run and
# still be green — but it must SAY that hermeticity went unchecked, because the
# failure mode this prevents is a run that looks identically clean whether the
# property held or was never tested. mk_battery_plane deliberately does not git
# init its fixture code repo, so this is that fixture's default state.
IFS='|' read -r BP3 BC3 <<<"$(mk_battery_plane)"
plant_suite "$BC3" "solo.test.sh" $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
run_battery "$BP3"
[ "$BATT_RC" -eq 0 ] && printf '%s' "$BATT_OUT" | grep -qiE 'hermeticity NOT CHECKED' \
  && ok "[15.1] fix(b): an unfingerprintable code repo degrades to an ANNOUNCED unchecked run, not a silent one that looks verified" \
  || no "[15.1] fix(b): where the guard cannot run it must announce so — an unchecked run that reads as a clean run is the failure this prevents (rc=$BATT_RC out=$(printf '%s' "$BATT_OUT" | grep -i 'hermetic\|Results' | tail -4))"

# T11m — the SERIAL CARVE holds (behavioral). The two named suites must not run
# concurrently with each other or with the pool. Proof by decoy: plant suites named
# exactly plugin.test.sh and ship-suite.test.sh that DETECT concurrency — each marks
# itself live, sleeps so an overlap is observable, then fails if the other was live
# in the same window. Serialized, they never overlap and both pass; thrown into the
# pool, they overlap and at least one fails. A third generic suite stays in the pool
# so the test also proves the carve removes only the named suites, not the pool.
#
# This is the SCHEDULING property, not the hermeticity one — T11j–T11l cover that.
# Kept behavioral rather than structural because the failure being prevented is a
# runner that declares SERIAL_SET but never applies it, which a grep cannot see.
IFS='|' read -r BP4 BC4 <<<"$(mk_battery_plane)"
CONC_BODY='#!/bin/bash
set -u
SHARED="$(cd "$(dirname "$0")/.." && pwd)"
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
plant_suite "$BC4" "plugin.test.sh"     "${CONC_BODY/__TAG__/serialA}"
plant_suite "$BC4" "ship-suite.test.sh" "${CONC_BODY/__TAG__/serialB}"
plant_suite "$BC4" "generic.test.sh" $'#!/bin/bash\necho "Results: 1 passed, 0 failed"\nexit 0\n'
run_battery "$BP4"
# The uncarved suite must still have RUN. Without this leg the non-overlap
# assertion is satisfiable vacuously: a runner that executed the two carved suites
# and then skipped the pool entirely would pass on "nothing overlapped".
POOL_RAN=0
printf '%s' "$BATT_OUT" | grep -q '== generic.test.sh ==' && POOL_RAN=1
if [ "$BATT_RC" -eq 0 ] && [ "$POOL_RAN" -eq 1 ] && ! printf '%s' "$BATT_OUT" | grep -qi 'overlapped'; then
  ok "[15.1] fix(b): the carved suites (plugin.test.sh, ship-suite.test.sh) never overlap each other, and the uncarved suite still runs (the carve removes those two from the pool, not the pool itself)"
else
  no "[15.1] fix(b): the carved suites must run one-at-a-time ahead of a pool that still runs — they overlapped, or the pool was skipped (rc=$BATT_RC pool_ran=$POOL_RAN out=$(printf '%s' "$BATT_OUT" | grep -i 'overlap\|serial\|Results' | tail -4))"
fi

# T11n — the carve is DECLARED in the runner as a readable list (structural). The
# behavioral test above proves it is applied; this proves it is legible at the
# source, so enrolling or retiring a suite is one edit rather than a hunt through
# the launch loop.
#
# ANCHORED TO THE ASSIGNMENT, and that is the whole test. The first version of this
# ran three independent whole-file greps for SERIAL_SET, plugin.test.sh and
# ship-suite.test.sh — which the runner's own COMMENTS satisfy on their own (the
# census table names both suites; two rationale paragraphs name SERIAL_SET). It
# passed with the declaration deleted, i.e. it could not fail (guv eval,
# 2026-07-27). A line starting SERIAL_SET= at column 0 cannot be a comment, so this
# form reds when the declaration goes even if every word of the prose survives.
grep -qE '^SERIAL_SET=.*plugin\.test\.sh.*ship-suite\.test\.sh' "$RUNNER_SRC" \
  && ok "[15.1] fix(b): the runner declares SERIAL_SET naming the carved suites, as an assignment and not merely in prose" \
  || no "[15.1] fix(b): the runner must declare the serial set as a named list assignment (the carve must be readable at the source, not buried in the launch loop — and not merely described in a comment)"
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

# ── T13 — the installed plugin CACHE is refreshed when it drifts from source ──
# [19.5] hands hook registration to the plugin; that makes the plugin's OWN copy of
# core the one every hook actually runs (session-start.sh resolves BASE from its own
# dirname, so a plugin-registered hook executes ${CLAUDE_PLUGIN_ROOT}/scripts/*, never
# the plane's synced .claude/*). So --sync could deliver a fixed script to .claude/
# while every hook kept running the release-frozen cache copy — silently, because the
# cache and source report the SAME plugin version while their content differs. Observed
# live: a budget-gate.sh windowing fix landed in source on 2026-07-21 and the cached
# pre-fix gate still fired a spurious initiative BREACH at every session entry, whose
# own banner invites the operator to raise the budget setpoint — a phantom ~914M-token
# overage presented as a decision. The refresh is the other half of the [19.5] handoff:
# having made the plugin authoritative, --sync must not leave it stale.
# Rule 15 throughout: the DB alone never authorizes the write — a guv entry names a
# path, and the cache's OWN plugin.json must agree it is the artifact this repo builds.
# Every rung that cannot establish that discloses and writes nothing; only "guv is not
# installed here" is silent. GUV_PLUGINS_DB carries installPath, so the whole seam is
# testable without touching the real ~/.claude cache.
# The refresh covers every guv-owned tree WHOLE — one vintage, never a blend. A first cut
# refreshed only the executed trees (scripts/, hooks/, workflows/) and froze skill text at
# the release; that shipped a live fail-open regression, because [24.1] renamed the
# greenfield door and the frozen skill then invoked the refreshed router with a door name
# it no longer knew (exit 2, which that skill reads as "router unavailable — proceed").
# T13g pins both halves of the lesson: a rename lands WHOLE across trees, and the delete
# still never leaves those trees. What protects Claude Code's own cache-root entries is
# the prune being TREE-SCOPED, not the number of trees in scope.
PLUGIN_JSON='{"name":"guv","version":"0.10.0","description":"fixture"}'
seed_cache() {   # $1 = cache dir; a STALE script, the identity manifest, and Claude Code's own
  mkdir -p "$1/scripts" "$1/.claude-plugin" "$1/.in_use"
  printf 'STALE GATE — pre-windowing\n' > "$1/scripts/budget-gate.sh"
  printf '%s\n' "$PLUGIN_JSON" > "$1/.claude-plugin/plugin.json"
  # .in_use is Claude Code's per-session PID-lock directory, planted EMPTY on purpose:
  # empty is its ordinary state between sessions, and an empty directory is exactly what
  # an unscoped `find "$cache" -type d -empty -delete` reaches. It and the root-level
  # file beside it must survive every refresh — see T13g.
  printf 'claude-code owns this\n' > "$1/.last_inuse_sweep"
}
seed_built() {   # $1 = guv home; the built plugin tree --sync refreshes FROM
  mkdir -p "$1/plugin/scripts" "$1/plugin/.claude-plugin" "$1/plugin/rules"
  printf 'CURRENT GATE — windowed\n' > "$1/plugin/scripts/budget-gate.sh"
  printf '%s\n' "$PLUGIN_JSON" > "$1/plugin/.claude-plugin/plugin.json"
  # A FAITHFUL build, not just the one file under test: the refresh now also reports
  # whether plugin/ is itself behind .claude/ (helpers and hooks -> scripts/, guv-*
  # rules), and a fixture whose plugin/ never mirrored its own source would fly that
  # banner in every case — turning a real signal into background noise nobody reads.
  # T13m perturbs this deliberately to prove the banner still fires.
  for f in "$1/.claude/"*.sh "$1/.claude/hooks/"*.sh; do
    [ -e "$f" ] && cp "$f" "$1/plugin/scripts/$(basename "$f")"
  done
  for f in "$1/.claude/rules/"guv-*.md; do
    [ -e "$f" ] && cp "$f" "$1/plugin/rules/$(basename "$f")"
  done
  # …and every other surface the builder copies verbatim, for the same reason: a fixture
  # that mirrors only part of its own source flies the behind-build banner on every case
  # that touches the rest, which is how a real signal becomes noise.
  mkdir -p "$1/plugin/shell/sandbox" "$1/plugin/shell/docs" "$1/plugin/hooks"
  for f in CLAUDE.template.md README.template.md Makefile; do
    [ -e "$1/$f" ] && cp "$1/$f" "$1/plugin/shell/$f"
  done
  [ -e "$1/sandbox/Dockerfile" ] && cp "$1/sandbox/Dockerfile" "$1/plugin/shell/sandbox/Dockerfile"
  for f in REQUIREMENTS ARCHITECTURE PHASE_STATUS; do
    [ -e "$1/docs/$f.md" ] && cp "$1/docs/$f.md" "$1/plugin/shell/docs/$f.md"
  done
  for f in "$1/maintainers/plugin-src/scripts/"*.sh; do
    [ -e "$f" ] && cp "$f" "$1/plugin/scripts/$(basename "$f")"
  done
  for f in "$1/maintainers/plugin-src/skills/"*/SKILL.md; do
    [ -e "$f" ] || continue
    mkdir -p "$1/plugin/skills/$(basename "$(dirname "$f")")"
    cp "$f" "$1/plugin/skills/$(basename "$(dirname "$f")")/SKILL.md"
  done
  ( cd "$1/.claude" 2>/dev/null && find skills -mindepth 3 -type f ! -name '.DS_Store' 2>/dev/null ) \
  | while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      mkdir -p "$1/plugin/$(dirname "$rel")"
      cp "$1/.claude/$rel" "$1/plugin/$rel"
    done
  # The two DERIVED outputs. The real builder rewrites hook command PATHS and injects the
  # plugin-only guard; neither moves the SET OF SCRIPT BASENAMES, which is the only thing
  # the detector compares here — so preserving .hooks verbatim is a faithful stand-in.
  jq 'del(.hooks)'  "$1/.claude/settings.json" > "$1/plugin/shell/settings.json" 2>/dev/null
  jq '{hooks: .hooks}' "$1/.claude/settings.json" > "$1/plugin/hooks/hooks.json" 2>/dev/null
  return 0
}
db_with_path() { # $1 = installPath → a guv-family DB naming it
  printf '{"version":2,"plugins":{"guv@guv":[{"scope":"user","version":"0.10.0","installPath":"%s"}]}}\n' "$1"
}

# Each case CREATES the plane with a neutral DB first (so the create-path refresh does
# not pre-empt what we are pinning) and only then --syncs with the DB under test. An
# earlier draft --synced a directory that had never been created; setup exits early with
# "not an existing control plane", so it never reached the refresh — and three of these
# five assertions passed on that early exit rather than on merit.
NEUTRAL_DB="$WORK/db-neutral.json"
printf '%s\n' '{"version":2,"plugins":{}}' > "$NEUTRAL_DB"

# T13a — drift detected on --sync → the cached script is refreshed to match source.
H=$(make_guv); seed_built "$H"; D="$WORK/cx-refresh"; C="$WORK/cx-refresh-installed"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
seed_cache "$C"                                  # stale only AFTER the create
db_with_path "$C" > "$WORK/db-refresh.json"
OUT13=$( GUV_PLUGINS_DB="$WORK/db-refresh.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync 2>&1 )
if diff -q "$C/scripts/budget-gate.sh" "$H/plugin/scripts/budget-gate.sh" >/dev/null 2>&1; then
  ok "[19.5] --sync refreshes a DRIFTED plugin cache — hook-invoked core stops running release-old code"
else
  no "[19.5] --sync must refresh the drifted plugin cache (hooks run the CACHE copy; a stale gate/meter keeps firing)"
fi

# T13b — the refresh is announced and NAMES what drifted (never silent, Rule 15).
printf '%s' "$OUT13" | grep -q 'drifted:' && printf '%s' "$OUT13" | grep -q 'budget-gate.sh' \
  && ok "[19.5] the refresh names the drifted script(s) — a stale meter and a stale gate are different problems" \
  || no "[19.5] the refresh must name what drifted (an unnamed refresh is indistinguishable from no drift)"

# T13b2 — the result is VERIFIED, not asserted from cp's exit status. cp -R is documented
# to keep copying after an error, so a 0 exit does not mean the tree matches; the report
# has to come from re-reading the cache.
printf '%s' "$OUT13" | grep -q 'verified: hook-invoked core' \
  && ok "[19.5] the refresh re-reads the cache and reports what it FOUND (cp's exit status cannot carry this)" \
  || no "[19.5] parity must be verified after the copy, not claimed from cp's exit status (cp -R continues past errors)"

# T13c — a non-guv plugin entry never authorizes a write into its cache (positive signal
# only — the same asymmetry as T12b: a detection failure must never license a write).
H=$(make_guv); seed_built "$H"; D="$WORK/cx-noplugin"; C="$WORK/cx-noplugin-installed"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
seed_cache "$C"; BEFORE=$(cat "$C/scripts/budget-gate.sh")
printf '%s\n' '{"version":2,"plugins":{"other@mkt":[{"scope":"user","installPath":"'"$C"'"}]}}' > "$WORK/db-other.json"
( GUV_PLUGINS_DB="$WORK/db-other.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync ) >>"$WORK/setup.log" 2>&1
[ "$(cat "$C/scripts/budget-gate.sh")" = "$BEFORE" ] \
  && ok "[19.5] a non-guv plugin entry never authorizes a write into its cache (positive signal only)" \
  || no "[19.5] --sync must not write into a cache it cannot attribute to the guv plugin"

# T13d — installPath recorded but ABSENT on disk → disclose, create nothing. A cache dir
# this run did not find is not one it may invent.
H=$(make_guv); seed_built "$H"; D="$WORK/cx-missing"; C="$WORK/cx-never-existed"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
db_with_path "$C" > "$WORK/db-missing.json"
OUT13D=$( GUV_PLUGINS_DB="$WORK/db-missing.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync 2>&1 )
[ ! -e "$C" ] \
  && ok "[19.5] a recorded-but-absent installPath is never created — --sync verifies, it does not provision a cache" \
  || no "[19.5] --sync must not conjure a plugin cache directory that was not already there"
# Assert a phrase only the disclosure emits: an earlier draft grepped for 'cache', which
# the fixture's own DEST path already supplies via the [setup] synced-core line.
printf '%s' "$OUT13D" | grep -q 'NOT verified' \
  && ok "[19.5] an unresolvable cache is disclosed, not passed over in silence (Rule 15)" \
  || no "[19.5] failing to verify the cache must be announced — silence reads as verified"

# T13e — no drift → idempotent: nothing is claimed refreshed on a cache already current.
H=$(make_guv); seed_built "$H"; D="$WORK/cx-current"; C="$WORK/cx-current-installed"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
# "Current" means current across EVERY refreshed tree, so mirror the built plugin whole
# rather than hand-copying the one file under test — a fixture that copies a single file
# reports drift the moment the built tree grows a second one, which is a fixture defect
# masquerading as a behavior change.
mkdir -p "$C/.claude-plugin"
for t in $(cd "$H/plugin" && for d in */; do d=${d%/}; [ "$d" = ".claude-plugin" ] || printf '%s ' "$d"; done); do
  mkdir -p "$C/$t"; cp -R "$H/plugin/$t/." "$C/$t/"
done
printf '%s\n' "$PLUGIN_JSON" > "$C/.claude-plugin/plugin.json"
db_with_path "$C" > "$WORK/db-current.json"
OUT13E=$( GUV_PLUGINS_DB="$WORK/db-current.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync 2>&1 )
# Anchor on the banner itself: an earlier draft grepped for 'refresh', which two unrelated
# --sync lines ("refreshed .claude/run-core-tests.sh", "refreshed status-render post-commit
# hook") also emit — it passed on fixture luck, not on the property.
printf '%s' "$OUT13E" | grep -q 'PLUGIN CACHE DRIFT' \
  && no "[19.5] a current cache must not report a refresh (crying drift every sync trains the operator to ignore it)" \
  || ok "[19.5] a cache already matching source reports no refresh — the signal stays meaningful"

# T13f — an asset REMOVED upstream is pruned from the cache, not left beside its
# replacement. Overlay alone guarantees only cache ⊇ source, so a landed rename would be
# half-delivered: both the old and the new entry point live at once, and which one runs
# is whichever the caller names. Mirrors copy_core's obsolete-prune for the plane.
H=$(make_guv); seed_built "$H"; D="$WORK/cx-prune"; C="$WORK/cx-prune-installed"
mkdir -p "$H/plugin/scripts/nested"; printf 'new name\n' > "$H/plugin/scripts/resolve-stack.sh"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
seed_cache "$C"
mkdir -p "$C/scripts/nested"; printf 'old name\n' > "$C/scripts/nested/resolve-stacks.sh"
db_with_path "$C" > "$WORK/db-prune.json"
OUT13F=$( GUV_PLUGINS_DB="$WORK/db-prune.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync 2>&1 )
[ ! -e "$C/scripts/nested/resolve-stacks.sh" ] \
  && ok "[19.5] an asset removed upstream is pruned from the cache — a landed rename is not half-delivered" \
  || no "[19.5] the refresh must prune what source dropped (overlay alone leaves the OLD entry point live beside the new one)"
printf '%s' "$OUT13F" | grep -q 'removed upstream: scripts/nested/resolve-stacks.sh' \
  && ok "[19.5] each pruned asset is NAMED (a silent delete from a user-scope cache is the wrong kind of quiet)" \
  || no "[19.5] pruned cache assets must be named in the report, as copy_core names the plane's"
[ -f "$C/scripts/resolve-stack.sh" ] \
  && ok "[19.5] the replacement asset is delivered alongside the prune (rename lands whole)" \
  || no "[19.5] the prune must not race the overlay — the new entry point has to be present"

# T13g — the two properties that a first cut of this fix got wrong, pinned together.
# (1) ONE VINTAGE: a rename lands WHOLE across trees. Refreshing only the executed trees
# and freezing skill text left release skill text calling source scripts — and because a
# skill's command line IS an interface, [24.1]'s door rename turned the [8.1] routing
# guard fail-open on a live machine (the frozen skill invoked the refreshed router with a
# door it no longer knew; exit 2 reads as "router unavailable — proceed").
# (2) THE DELETE STILL STOPS: .in_use/ (Claude Code's per-session PID locks) and every
# other cache-ROOT entry survive. That protection comes from the prune being TREE-SCOPED,
# not from how few trees are in scope — which is exactly why (1) could be fixed without
# weakening (2), and why both belong in one case.
H=$(make_guv); seed_built "$H"; D="$WORK/cx-scope"; C="$WORK/cx-scope-installed"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
seed_cache "$C"
# The [24.1] shape, staged in a read-by-name tree: source ships the new door, the cache
# still carries the old. The names are fabricated because a live surface may not carry a
# retired door name — docs-sweep enforces that repo-wide, and caught it here.
mkdir -p "$H/plugin/skills/newdoor"; printf 'source door\n' > "$H/plugin/skills/newdoor/SKILL.md"
mkdir -p "$C/skills/olddoor"; printf 'release door\n' > "$C/skills/olddoor/SKILL.md"
# A removed-upstream file in a DIFFERENT tree, so the prune demonstrably runs even if the
# skills half regressed: the empty-directory sweep is gated on there being something to
# prune, so without this an unscoped sweep would sail past the .in_use assertion.
printf 'retired\n' > "$C/scripts/retired.sh"
db_with_path "$C" > "$WORK/db-scope.json"
( GUV_PLUGINS_DB="$WORK/db-scope.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync ) >>"$WORK/setup.log" 2>&1
[ ! -e "$C/scripts/retired.sh" ] \
  && ok "[19.5] the prune ran in this fixture — the scope assertions below are live, not vacuous" \
  || no "[19.5] the prune must fire here, or the scope-limit assertions that follow prove nothing"
[ -d "$C/.in_use" ] && [ -f "$C/.last_inuse_sweep" ] \
  && ok "[19.5] the prune never reaches Claude Code's own .in_use/ or the cache root — a TREE-scoped delete cannot see a root sibling" \
  || no "[19.5] the refresh must not delete a cache-root entry Claude Code owns (.in_use is its PID-lock dir, and EMPTY is its ordinary state)"
[ -f "$C/skills/newdoor/SKILL.md" ] && [ ! -e "$C/skills/olddoor/SKILL.md" ] \
  && ok "[19.5] a rename lands WHOLE across trees — the cache carries ONE vintage, never release text over source code" \
  || no "[19.5] freezing a read-by-name tree while refreshing scripts/ ships a vintage that was never built: [24.1] renamed a door and the stale skill drove the fresh router fail-open"

# T13h — a guv entry whose installPath cannot be resolved is the rung where silence is
# most dangerous: the dedup has just announced "the plugin is authoritative", so hearing
# nothing about its cache reads as verified. This is the original defect's exact shape.
H=$(make_guv); seed_built "$H"; D="$WORK/cx-nopath"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
printf '%s\n' '{"version":2,"plugins":{"guv@guv":[{"scope":"user","version":"0.10.0"}]}}' > "$WORK/db-nopath.json"
OUT13H=$( GUV_PLUGINS_DB="$WORK/db-nopath.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync 2>&1 )
printf '%s' "$OUT13H" | grep -q 'records no installPath' \
  && ok "[19.5] a guv entry with no installPath is disclosed — 'present but unlocatable' is not the same as 'not installed'" \
  || no "[19.5] an unresolvable guv cache must be announced; the dedup just handed it authority"

# T13i — no built plugin here → disclose and leave the installed cache alone. The
# maintainer who edited .claude/ but never rebuilt gets told, not silently served.
H=$(make_guv); D="$WORK/cx-nobuilt"; C="$WORK/cx-nobuilt-installed"   # note: NO seed_built
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
seed_cache "$C"; BEFORE=$(cat "$C/scripts/budget-gate.sh")
db_with_path "$C" > "$WORK/db-nobuilt.json"
OUT13I=$( GUV_PLUGINS_DB="$WORK/db-nobuilt.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync 2>&1 )
printf '%s' "$OUT13I" | grep -q 'no built plugin at' && [ "$(cat "$C/scripts/budget-gate.sh")" = "$BEFORE" ] \
  && ok "[19.5] with no built plugin, the cache is disclosed as unverified and left untouched" \
  || no "[19.5] a missing plugin/ build must disclose and write nothing — it is not evidence the cache is current"

# T13j — the DB says guv, the artifact must agree. 'guv@* and the directory exists' is a
# claim by the plugin DB; the cache's own plugin.json is a claim by the artifact. Without
# the second, a maintainer running a FORK at $GUV_DIR silently overwrites — and now
# partly DELETES — the released plugin every guv project on the machine runs.
H=$(make_guv); seed_built "$H"; D="$WORK/cx-foreign"; C="$WORK/cx-foreign-installed"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
seed_cache "$C"; BEFORE=$(cat "$C/scripts/budget-gate.sh")
printf '%s\n' '{"name":"not-guv","version":"9.9.9"}' > "$C/.claude-plugin/plugin.json"
db_with_path "$C" > "$WORK/db-foreign.json"
OUT13J=$( GUV_PLUGINS_DB="$WORK/db-foreign.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync 2>&1 )
printf '%s' "$OUT13J" | grep -q "refusing to overwrite a plugin this repo does not build" \
  && [ "$(cat "$C/scripts/budget-gate.sh")" = "$BEFORE" ] \
  && ok "[19.5] a cache whose manifest names another plugin is refused — the DB names a path, the artifact confirms identity" \
  || no "[19.5] the write must be authorized by the artifact's own manifest, not by the plugin DB alone"

# T13k — every recorded install is refreshed, not just the first. user- and local-scope
# entries coexist under one key, and several guv@<marketplace> keys can coexist too;
# refreshing whichever jq emitted first would declare parity for a cache that is not the
# one running.
H=$(make_guv); seed_built "$H"; D="$WORK/cx-multi"
C1="$WORK/cx-multi-user"; C2="$WORK/cx-multi-local"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
seed_cache "$C1"; seed_cache "$C2"
printf '{"version":2,"plugins":{"guv@guv":[{"scope":"user","installPath":"%s"},{"scope":"local","installPath":"%s"}]}}\n' \
  "$C1" "$C2" > "$WORK/db-multi.json"
( GUV_PLUGINS_DB="$WORK/db-multi.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync ) >>"$WORK/setup.log" 2>&1
diff -q "$C1/scripts/budget-gate.sh" "$H/plugin/scripts/budget-gate.sh" >/dev/null 2>&1 \
  && diff -q "$C2/scripts/budget-gate.sh" "$H/plugin/scripts/budget-gate.sh" >/dev/null 2>&1 \
  && ok "[19.5] every recorded guv install is refreshed — a second cache left stale is a cache still running the defect" \
  || no "[19.5] the refresh must cover all recorded installPaths; picking the first silently leaves the others stale"

# T13m — plugin/ itself behind .claude/. This is the one staleness cache drift is blind
# to: the cache is compared AGAINST plugin/, so when plugin/ is what is behind, drift
# reads zero, the function returns early, and every advisory hanging off the drift banner
# is suppressed — silence in exactly the case that poisons the cache. The check runs
# before any cache is compared and names the files. Proceeding is deliberate: plugin/ is
# still a real build, so the cache lands on ONE coherent vintage, just not the newest.
H=$(make_guv); seed_built "$H"; D="$WORK/cx-behind"; C="$WORK/cx-behind-installed"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
seed_cache "$C"
printf 'edited in source, never rebuilt\n' > "$H/.claude/resolve-ready.sh"   # source moves, plugin/ does not
db_with_path "$C" > "$WORK/db-behind.json"
OUT13M=$( GUV_PLUGINS_DB="$WORK/db-behind.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync 2>&1 )
printf '%s' "$OUT13M" | grep -q 'BUILT PLUGIN IS BEHIND' \
  && printf '%s' "$OUT13M" | grep -q 'not rebuilt since edited: scripts/resolve-ready.sh' \
  && ok "[19.5] a plugin/ behind .claude/ is disclosed and NAMED — the staleness cache drift cannot see" \
  || no "[19.5] editing .claude/ without rebuilding must be announced; drift against plugin/ reads zero and hides it"

# T13m2 — and it stays quiet when the build IS current, so the banner keeps meaning
# something. Same fixture, no source edit.
H=$(make_guv); seed_built "$H"; D="$WORK/cx-current-build"; C="$WORK/cx-current-build-installed"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
seed_cache "$C"
db_with_path "$C" > "$WORK/db-cbuild.json"
OUT13M2=$( GUV_PLUGINS_DB="$WORK/db-cbuild.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync 2>&1 )
printf '%s' "$OUT13M2" | grep -q 'BUILT PLUGIN IS BEHIND' \
  && no "[19.5] the behind-build banner fired on a current build — a warning that always fires is not a warning" \
  || ok "[19.5] no behind-build banner when plugin/ is a current build of .claude/"

# T13n — the provenance marker records the VERIFY outcome, and is written after it. A
# marker asserting a refresh before the check that can contradict it is the same
# claim-don't-verify mistake the verify step exists to prevent.
printf '%s' "$OUT13M2" | grep -q 'verified: hook-invoked core' \
  && grep -q '^verified=yes' "$C/.guv-source-refresh" 2>/dev/null \
  && grep -q '^source_commit=' "$C/.guv-source-refresh" 2>/dev/null \
  && ok "[19.5] the provenance marker carries the verify outcome (verified=yes) and the source commit" \
  || no "[19.5] .guv-source-refresh must record what the verify found, not merely that a copy was attempted"

# T13n2 — every marker flag is spelled out, never left empty for the good state. The file
# is read by catting it; an empty value cannot be told apart from a check that never ran,
# and this is the one reading where "fine" and "unmeasured" must not look alike.
grep -q '^source_plugin_behind_claude=no$' "$C/.guv-source-refresh" 2>/dev/null \
  && ok "[19.5] the marker states the behind-build result explicitly (=no), not as an empty value" \
  || no "[19.5] source_plugin_behind_claude must read yes/no — an empty value reads as 'never checked'"

# T13m3..m6 — the surfaces the FIRST cut of the detector missed while its comment said it
# covered "everything build-plugin.sh copies verbatim". Each case edits one source file,
# leaves plugin/ unrebuilt, and demands the file be NAMED. They are separate cases on
# purpose: they are four different copy rules in the builder, and a single case passing
# would have told us nothing about the other three.
stale_names() {  # $1 = source file to perturb, $2 = tag → the sync output
  local h d c
  h=$(make_guv); seed_built "$h"; d="$WORK/cx-$2"; c="$WORK/cx-$2-installed"
  ( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$h/maintainers/setup-control-plane.sh" "$d" ) >>"$WORK/setup.log" 2>&1
  seed_cache "$c"
  printf 'edited in source, never rebuilt\n' >> "$h/$1"
  db_with_path "$c" > "$WORK/db-$2.json"
  ( GUV_PLUGINS_DB="$WORK/db-$2.json" bash "$h/maintainers/setup-control-plane.sh" "$d" --sync 2>&1 )
}

printf '%s' "$(stale_names CLAUDE.template.md shellv)" \
  | grep -q 'not rebuilt since edited: shell/CLAUDE.template.md' \
  && ok "[19.5] a stale shell/ payload is named — the tree scaffolded into every new project" \
  || no "[19.5] editing CLAUDE.template.md without rebuilding must be named; shell/ ships verbatim into real repos"

printf '%s' "$(stale_names maintainers/plugin-src/scripts/reviewer-readonly.sh psrc)" \
  | grep -q 'not rebuilt since edited: scripts/reviewer-readonly.sh' \
  && ok "[19.5] a stale plugin-only source (maintainers/plugin-src/scripts/) is named" \
  || no "[19.5] plugin-src scripts ship verbatim into scripts/ — a stale one must not be silent"

printf '%s' "$(stale_names .claude/skills/status/assets/legend.txt bundle)" \
  | grep -q 'not rebuilt since edited: skills/status/assets/legend.txt' \
  && ok "[19.5] a stale skill-bundled asset outside scripts/ and not .sh is named (cp -R ships any bundle)" \
  || no "[19.5] the bundle walk must be as wide as the builder's cp -R, not scripts/*.sh only"

# m6 — the [9.2] dead-hook class, which is why hooks.json is worth checking at all: a hook
# wired in settings.json but never rebuilt into the plugin's hooks.json silently does not
# run, and [19.5] made the plugin's copy the authoritative one. Byte-comparing is useless
# here (hooks.json is DERIVED), so the check is a subset test on hook script basenames.
H=$(make_guv); seed_built "$H"; D="$WORK/cx-hookwire"; C="$WORK/cx-hookwire-installed"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
seed_cache "$C"
jq '.hooks.Stop[0].hooks += [{"type":"command","command":"bash .claude/hooks/brand-new-guard.sh"}]' \
   "$H/.claude/settings.json" > "$WORK/st.json" && mv "$WORK/st.json" "$H/.claude/settings.json"
db_with_path "$C" > "$WORK/db-hookwire.json"
OUT13M6=$( GUV_PLUGINS_DB="$WORK/db-hookwire.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync 2>&1 )
printf '%s' "$OUT13M6" | grep -q 'not rebuilt since edited: hooks/hooks.json' \
  && ok "[9.2] a hook wired in settings.json but never rebuilt into hooks.json is named, not silently dead" \
  || no "[9.2] adding a hook without rebuilding leaves it dead in the plugin — the refresh must say so"

# m6b — and the same fixture with NO settings edit stays quiet, so m6 is measuring the
# edit rather than a check that always fires (hooks.json legitimately carries one extra
# entry the builder injects, so an equality test here would red on every clean build).
H=$(make_guv); seed_built "$H"; D="$WORK/cx-hookclean"; C="$WORK/cx-hookclean-installed"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
seed_cache "$C"; db_with_path "$C" > "$WORK/db-hookclean.json"
OUT13M6B=$( GUV_PLUGINS_DB="$WORK/db-hookclean.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync 2>&1 )
# The prefix matters: a freshly seeded cache legitimately lists hooks/hooks.json as
# DRIFTED (it does not have it yet), which is a different banner saying a different thing.
# Matching the bare filename would have passed this case off the wrong line.
printf '%s' "$OUT13M6B" | grep -q 'not rebuilt since edited: hooks/hooks.json' \
  && no "[9.2] the hooks.json check fired on an unedited settings.json — a warning that always fires is not a warning" \
  || ok "[9.2] no hooks.json complaint when settings.json is unchanged"

# T13L — the SCOPE DECLARATION itself, which nothing above constrains. Every T13 case
# plants only scripts/, so narrowing GUV_CACHE_TREES back to "scripts" left all of them
# green — and that variable is exactly what the fail-open regression turned on: a cut
# scope shipped release-frozen skills/ beside source-vintage scripts/, and the greenfield
# door's routing guard degraded to fail-open on a live machine. Two assertions, because
# either alone is vacuous: L1 pins WHICH trees are declared (a derived list would narrow
# silently along with the code), L2 pins that each declared tree is actually copied (a
# declaration nothing acts on is a comment).
#
# L1 — the scope is every top-level tree the BUILT plugin ships, with exactly one
# exception: .claude-plugin/ (the identity manifest, deliberately held back so the cache
# keeps declaring the release it was installed as). Derived from the real plugin/, not a
# hard-coded literal, so adding a tree to the build without adding it to scope reds here
# rather than shipping a half-vintage cache.
#
# What L1 does NOT cover, said plainly because the derivation makes it easy to assume
# otherwise: the reference is the COMMITTED plugin/, not build-plugin.sh. Between a
# builder change that adds a tree and the rebuild that materialises it, both sides still
# agree and this stays green. The behind-build detector is what covers that window.
#
# The enumeration uses find, not a */ glob: bash does not match dotted directories
# without dotglob, so the earlier glob never saw .claude-plugin and the "one deliberate
# exception" filtered nothing. Enumerating it and then excluding it by name is what makes
# the exception real — and makes declaring .claude-plugin in scope red here.
REAL_PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)/plugin"
SHIPPED=""
[ -d "$REAL_PLUGIN" ] && SHIPPED=$(cd "$REAL_PLUGIN" \
              && find . -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
              | sed 's|^\./||' | grep -v '^\.claude-plugin$' \
              | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
if [ -d "$REAL_PLUGIN" ]; then
  DECLARED=$(grep '^GUV_CACHE_TREES=' "$REAL_SCRIPT" | head -1 \
             | sed 's/^GUV_CACHE_TREES=//; s/^"//; s/"$//' \
             | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
  [ -n "$SHIPPED" ] && [ "$DECLARED" = "$SHIPPED" ] \
    && ok "[19.5] refresh scope declares every guv-owned tree the built plugin ships (.claude-plugin held back)" \
    || no "[19.5] refresh scope must cover every shipped tree — declared '$DECLARED' vs shipped '$SHIPPED'; a partial refresh is a vintage that was never built or tested"
else
  no "[19.5] SETUP: no built plugin at $REAL_PLUGIN — cannot pin the refresh scope against what ships"
fi

# L2 — each shipped tree round-trips. One uniquely-named file per tree on the built side;
# every one must arrive in the cache.
#
# The expected set comes from the REAL plugin (SHIPPED), deliberately NOT from the
# script's own GUV_CACHE_TREES. Reading the declaration and then checking the loop that
# iterates that same declaration cannot fail — "declared but not copied" is unreachable
# while both sides read one variable, so that shape asserted nothing while reading like
# coverage. Anchored to what the plugin actually ships, this reds on the real regression:
# narrow GUV_CACHE_TREES back toward "scripts" and every dropped tree's probe goes
# missing here. L1 pins the declaration, L2 pins the delivery, and neither borrows the
# other's reference.
H=$(make_guv); seed_built "$H"; D="$WORK/cx-trees"; C="$WORK/cx-trees-installed"
( GUV_PLUGINS_DB="$NEUTRAL_DB" bash "$H/maintainers/setup-control-plane.sh" "$D" ) >>"$WORK/setup.log" 2>&1
seed_cache "$C"
for t in $SHIPPED; do
  mkdir -p "$H/plugin/$t"
  printf 'tree-probe %s\n' "$t" > "$H/plugin/$t/zz-tree-probe.txt"
done
db_with_path "$C" > "$WORK/db-trees.json"
( GUV_PLUGINS_DB="$WORK/db-trees.json" bash "$H/maintainers/setup-control-plane.sh" "$D" --sync ) >>"$WORK/setup.log" 2>&1
MISSING=""
for t in $SHIPPED; do
  cmp -s "$H/plugin/$t/zz-tree-probe.txt" "$C/$t/zz-tree-probe.txt" 2>/dev/null || MISSING="$MISSING $t"
done
[ -n "$SHIPPED" ] && [ -z "$MISSING" ] \
  && ok "[19.5] every tree the built plugin ships is actually copied into the cache (probe landed in: $SHIPPED)" \
  || no "[19.5] shipped trees that never reached the cache:${MISSING:-<none — no shipped trees enumerated>}"

fi  # SCP_TEST_INNER guard (T12 [19.5] block)

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
