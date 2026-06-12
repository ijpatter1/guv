#!/bin/bash
# Tests for maintainers/setup-control-plane.sh — focused on the copy_core sync
# (what lands in the control plane's .claude/, and what must not).
# Pure bash + git, no test runner required (this template repo ships no JS suite).
# Run: bash .claude/tests/setup-control-plane.test.sh
set -u

REAL_SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/maintainers/setup-control-plane.sh"
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
  echo "resolver" > "$h/.claude/resolve-ready.sh"
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
  && [ -f "$D/.claude/archive-initiative.sh" ] && [ -f "$D/.claude/resolve-ready.sh" ] \
  && ok "create: core copied (skills, guv rules, archive + resolver scripts present)" \
  || no "create: core should be copied (archive + resolver helpers asserted here; copy_core's hand-enumerated list means an unlisted helper is unreachable by sync — the class is retired by [7.1]'s glob-derived registry)"
[ -f "$D/.claude/workflows/evaluate-parallel.js" ] \
  && ok "create: workflows dir copied (saved workflows are core)" \
  || no "create: .claude/workflows/ should be copied to the control plane"

# T2 — ...but no .DS_Store comes along, at any depth.
FOUND=$(find "$D/.claude" -name '.DS_Store' 2>/dev/null)
[ -z "$FOUND" ] && ok "create: no .DS_Store copied into the control plane" \
  || no "create: .DS_Store leaked into the control plane: $FOUND"
grep -q '^\.DS_Store$' "$D/.gitignore" && ok "create: generated .gitignore covers .DS_Store" \
  || no "generated .gitignore should ignore .DS_Store (Finder recreates them at the root)"
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
# Fresh create is where chmod is load-bearing: cp from mktemp yields a
# non-executable mode, so this fails if the chmod line is dropped.
[ -x "$D/.claude/run-harness-tests.sh" ] \
  && ok "create: freshly generated runner is executable" \
  || no "create: freshly generated runner must be executable (cp from mktemp is not)"
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

# T8b — refresh-only on --sync: the runner is dogfooding tooling, but --sync is
# ALSO the template-clone consumer update path, and a consumer project never had
# the runner. Syncing into a dest without one must not plant it.
H=$(make_harness)
D="$WORK/consumer-clone"
mkdir -p "$D/.claude"
run_setup "$H" "$D" --sync
[ ! -e "$D/.claude/run-harness-tests.sh" ] \
  && ok "sync: no runner planted where none existed (consumer-project shape)" \
  || no "sync must not inject the dogfooding runner into a consumer project"

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
    && ok "DOGFOODING: RELEASING.md in the what-lives-in-the-harness-repo list" \
    || no "DOGFOODING must list RELEASING.md among durable maintainer tooling"
  grep -q 'unreleased' "$DOG" \
    && ok "DOGFOODING: maintainer disposition — --sync kept for unreleased changes" \
    || no "DOGFOODING must state why --sync survives the plugin (unreleased changes)"
  grep -q 'plan-initiative' "$DOG" \
    && ok "DOGFOODING: ceremony flip acknowledged (seeded task, initiative flips it)" \
    || no "DOGFOODING must reflect that /plan-initiative can flip the control plane to phased"
  flat "$DOG" | grep -qi 'replaces harness-owned surfaces[^.]*wholesale' \
    && ok "DOGFOODING: fallback bullet carries the wholesale-replacement caveat" \
    || no "DOGFOODING must warn that --sync replaces harness-owned surfaces wholesale (the fact, not the word, same-sentence)"
  if flat "$DOG" | grep -q 'pinned to the template repo'; then
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
  # evaluate-parallel.test.sh's README gate — keep the two in step.)
  if flat "$RM" | grep -qi 'replaces harness-owned surfaces'; then
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
  # replaces harness-owned surfaces wholesale, which reverts exactly the edits
  # the fallback audience is invited to make.
  flat "$RM" | grep -qi 'replaces harness-owned surfaces[^.]*wholesale' \
    && ok "README: customized forks warned that --sync replaces harness-owned surfaces wholesale" \
    || no "README must warn customized forks that --sync reverts harness-owned edits"
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
  printf '# readme\n--sync replaces harness-owned surfaces wholesale.\n' > "$FAKE4"
  INNER4=$(SCP_TEST_INNER=1 SCP_TEST_README="$FAKE4" bash "$SELF" 2>&1)
  if [ $? -ne 0 ] && echo "$INNER4" | grep -q "marker/detector drift"; then
    ok "marker-less template content fails loud (drift-probe self-check)"
  else
    no "a marker-less README with template content must fail loud, not skip"
  fi
fi

# ── the <project>-guv default destination ([6.4]) ──────────────────────────
# No-arg create defaults to a SIBLING of the harness named <repo>-guv. This is
# a constructed default, announced loudly — never discovery (no glob; the
# docs-sweep suite pins that boundary repo-wide).
H=$(make_harness)
DH="$WORK/widget"; rm -rf "$DH" "$WORK/widget-guv"; mv "$H" "$DH"
OUT_DEF=$( cd "$WORK" && bash "$DH/maintainers/setup-control-plane.sh" 2>&1 )
if [ -d "$WORK/widget-guv/.claude/commands" ]; then
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
echo "# cmd v2" > "$DH/.claude/commands/status.md"
( cd "$WORK" && bash "$DH/maintainers/setup-control-plane.sh" --sync ) >> "$WORK/setup.log" 2>&1
if grep -q "cmd v2" "$WORK/widget-guv/.claude/commands/status.md" 2>/dev/null; then
  ok "sole-arg --sync syncs the defaulted <project>-guv plane"
else
  no "--sync without a dir must sync the default <project>-guv plane"
fi
# Sync against an ABSENT destination refuses — it must never manufacture an
# empty half-plane and report success while the real plane stays stale.
H=$(make_harness)
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
# source. The fixture harness gets the REAL resolver + its REAL suite so
# the divergence proof below is genuine, plus the REAL copy of this very
# suite to prove the maintainers-shape skip in the plane. Outer-run only
# (the T10b seamed self-invocations re-run this whole file; real-suite
# executions in every inner run would multiply runtime and couple T10b's
# exit-code assertions to this block's state).
if [ -z "${SCP_TEST_INNER:-}" ]; then
REALROOT="$(cd "$(dirname "$REAL_SCRIPT")/.." && pwd)"
H77=$(make_harness)
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
  && ok "[7.7] sync: a drifted plane suite is refreshed (harness-owned, like the core)" \
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
