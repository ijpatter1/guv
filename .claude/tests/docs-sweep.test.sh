#!/bin/bash
# Tests for the [6.4] docs sweep — the new-grammar doc surface, asserted.
# What this suite pins:
#   - /replan is taught where commands are taught (README tree + What's Included,
#     CLAUDE.template.md process-commands bullet)
#   - both generators route doc generation through the phase-docs skill, whose
#     templates emit ID'd, token'd deliverables (the "generators emit the new
#     format" chain — the skill is the single grammar definition, per [6.1])
#   - rule 15 exists in the rules family with its load-bearing qualifiers
#     (numbering uniqueness and plugin byte-parity are the standing guards in
#     workflows-rule.test.sh and plugin.test.sh — not restated here)
#   - the <project>-guv convention is taught in the topology docs, and no script
#     discovers a control plane by name (the setup script's creation DEFAULT is
#     the one sanctioned -guv construction; globbing for *-guv is banned outright)
#   - README.template.md carries no Philosophy section (the harness README only)
# Deliberately ABSENT: a standing byte-diff of the README Philosophy section
# against spec Appendix A — considered and rejected per the spec's Pre-Resolved
# Decisions (one-time placement check; a later hand edit is a person revising
# their philosophy, which machinery must not block). Do not add it back.
# Pure bash, no test runner required.
# Run: bash .claude/tests/docs-sweep.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# Consumer-shape skip: a rendered project replaces README.md and may delete
# maintainers/ — this suite asserts the TEMPLATE repo's doc surface only.
# DS_TEST_README seams the marker probe for the self-check below.
README_PROBE="${DS_TEST_README:-$ROOT/README.md}"
if ! grep -q 'guv-template-readme' "$README_PROBE" 2>/dev/null || [ ! -d "$ROOT/maintainers" ]; then
  echo "  - template-repo doc surface not present — skipping (consumer repo)"
  echo ""
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

# T1 — README teaches /replan: a What's Included workflow bullet and the
# File Structure tree (replan.md among the commands).
if grep -q '^- `/replan' "$ROOT/README.md"; then
  ok "README What's Included carries a /replan bullet"
else
  no "README What's Included must carry a /replan bullet"
fi
if grep -qE '├── replan/' "$ROOT/README.md"; then
  ok "README File Structure tree lists the replan skill"
else
  no "README File Structure tree must list the replan skill (skills/replan/)"
fi

# T2 — CLAUDE.template.md process-commands bullet names /replan (the bullet
# is the one starting '- **Process commands:**').
if grep '^\- \*\*Process commands:\*\*' "$ROOT/CLAUDE.template.md" | grep -q '/replan'; then
  ok "CLAUDE.template.md process-commands bullet names /replan"
else
  no "CLAUDE.template.md process-commands bullet must name /replan"
fi

# T3 — the generator chain: both generators defer to the phase-docs skill,
# and the skill's templates emit ID'd, token'd deliverables. Together these
# are "both generators emit the new format" without a second grammar copy.
for cmd in plan init-project; do
  if grep -q 'phase-docs' "$ROOT/.claude/skills/$cmd/SKILL.md"; then
    ok "$cmd.md routes doc generation through the phase-docs skill"
  else
    no "$cmd.md must route doc generation through the phase-docs skill"
  fi
done
SKILL="$ROOT/.claude/skills/phase-docs/SKILL.md"
if grep -q '\*\*\[N\.1\]\*\*' "$SKILL" && grep -q '\[deps: none\]' "$SKILL"; then
  ok "phase-docs templates emit ID'd, token'd deliverables"
else
  no "phase-docs templates must emit ID'd, token'd deliverables"
fi

# T4 — rule 15 in the rules family: the heading, the slogan, and the two
# qualifiers that give it teeth (written-down-and-predates; loud stop default).
R15=$(grep -l '^## 15 —' "$ROOT/.claude/rules"/guv-*.md 2>/dev/null | head -1)
if [ -n "$R15" ]; then
  ok "a guv-* rules file carries rule 15"
  grep -qi 'selects a path' "$R15" \
    && ok "rule 15 states the slogan (failure selects a path)" \
    || no "rule 15 must state the slogan"
  grep -q 'predates the failure' "$R15" \
    && ok "rule 15 carries the written-down-and-predates qualifier" \
    || no "rule 15 must require the path to be written down before the failure"
  grep -qi 'loud stop' "$R15" \
    && ok "rule 15 names the loud stop as the default rung" \
    || no "rule 15 must name the loud stop as the default"
else
  no "a .claude/rules/guv-*.md file must carry '## 15 —'"
  no "rule 15 must state the slogan"
  no "rule 15 must require the path to be written down before the failure"
  no "rule 15 must name the loud stop as the default"
fi

# T5 — the topology docs teach the <project>-guv convention, including the
# no-discovery boundary.
TOPO="$ROOT/maintainers/DOGFOODING.md"
if grep -q '<project>-guv' "$TOPO"; then
  ok "DOGFOODING.md teaches the <project>-guv convention"
else
  no "DOGFOODING.md must teach the <project>-guv convention"
fi
if grep -qi 'ever discovers a control plane by name\|no name-based discovery' "$TOPO"; then
  ok "topology docs state the no-name-based-discovery boundary"
else
  no "topology docs must state that no script discovers a control plane by name"
fi
if grep -q '<product>-guv' "$ROOT/README.md" && ! grep -q '<product>-control' "$ROOT/README.md"; then
  ok "README topology block teaches <product>-guv (old -control convention retired)"
else
  no "README topology block must teach <product>-guv and drop <product>-control"
fi
# The retirement holds across the topology-doc CLASS, not just where the fix
# first landed: no doc that teaches control-plane topology may still carry the
# old -control convention (as a templated name or the historical literal).
RETIRE_HITS=$(grep -l '<product>-control\|sandbox-control' "$ROOT/README.md" "$ROOT/CLAUDE.template.md" "$TOPO" 2>/dev/null || true)
if [ -z "$RETIRE_HITS" ]; then
  ok "old -control convention retired across all topology docs"
else
  no "old -control convention survives in: $(echo "$RETIRE_HITS" | tr '\n' ' ')"
fi

# T5b — the LEGACY position-encodes-sequence statements stay qualified: any doc
# line stating that document order/position carries dependency order must sit
# under a LEGACY / token-free qualification (same line or the two lines above).
POS_VIOL=""
while IFS=: read -r f ln _; do
  start=$(( ln > 2 ? ln - 2 : 1 ))
  sed -n "${start},${ln}p" "$f" | grep -qi 'LEGACY\|token-free' || POS_VIOL="$POS_VIOL $f:$ln"
done < <(grep -rn 'encodes dependency order\|reflects dependency order\|position encodes' \
  "$ROOT/README.md" "$ROOT/README.template.md" "$ROOT/CLAUDE.template.md" \
  "$ROOT/.claude/commands" "$ROOT/.claude/skills" "$ROOT/.claude/rules" \
  "$ROOT/docs" "$ROOT/maintainers" 2>/dev/null)
if [ -z "$POS_VIOL" ]; then
  ok "position-encodes-sequence stated only under LEGACY qualification"
else
  no "unqualified position-encodes-sequence statement at:$POS_VIOL"
fi

# T6 — no script resolves a control plane by name. Two layers:
#   (a) no '*-guv' glob in any shipped script, anywhere;
#   (b) '-guv' as a constructed name appears in scripts ONLY in
#       maintainers/setup-control-plane.sh (the sanctioned creation default).
# Test fixtures (.claude/tests/) are excluded — they build -guv-named dirs to
# test the default itself.
SCRIPT_DIRS=$(find "$ROOT/.claude" "$ROOT/maintainers" "$ROOT/plugin" "$ROOT/sandbox" \( -name '*.sh' -o -name '*.js' \) -not -path "$ROOT/.claude/tests/*" 2>/dev/null; ls "$ROOT/Makefile" "$ROOT/plugin/shell/Makefile" 2>/dev/null)
GLOB_HITS=$(echo "$SCRIPT_DIRS" | xargs grep -l '\*-guv' 2>/dev/null || true)
if [ -z "$GLOB_HITS" ]; then
  ok "no shipped script globs for *-guv (no name-based discovery)"
else
  no "scripts must never glob for *-guv — offenders: $(echo "$GLOB_HITS" | tr '\n' ' ')"
fi
NAME_HITS=$(echo "$SCRIPT_DIRS" | xargs grep -l '\-guv' 2>/dev/null | grep -v 'maintainers/setup-control-plane\.sh' || true)
if [ -z "$NAME_HITS" ]; then
  ok "-guv name construction confined to the setup script's creation default"
else
  no "-guv in scripts outside the sanctioned default — offenders: $(echo "$NAME_HITS" | tr '\n' ' ')"
fi

# T7 — README.template.md (the consumer project's README source) never carries
# the Philosophy section; it describes the consumer's project, not guv.
if ! grep -q '^## Philosophy' "$ROOT/README.template.md"; then
  ok "README.template.md carries no Philosophy section"
else
  no "README.template.md must not carry the Philosophy section"
fi

# T8 — seamed self-check: the consumer-shape skip must actually fire (visible
# message, exit 0) when the README lacks the template marker — this file ships
# to every consumer fork, and a maintainer assertion redding out consumer repos
# is this project's one prior Critical class.
if [ -z "${DS_TEST_INNER:-}" ]; then
  FAKE_README=$(mktemp)
  echo "# a rendered consumer project readme" > "$FAKE_README"
  INNER=$(DS_TEST_INNER=1 DS_TEST_README="$FAKE_README" bash "$SELF" 2>&1)
  RC=$?
  rm -f "$FAKE_README"
  if [ "$RC" -eq 0 ] && echo "$INNER" | grep -q "skipping (consumer repo)"; then
    ok "consumer-shape skip fires visibly with exit 0 (seamed self-check)"
  else
    no "a marker-less README must skip visibly with exit 0, got rc=$RC"
  fi
fi

# T9 — vocabulary retirement guard ([8.3] stage 5). On the surfaces the sweep has
# reached, the retired noun "harness" is gone — every sense: the installed
# machinery → core, the product → guv, and the evidence-deriving runtime sense
# (meter.sh / metering-log.md "harness-derived/-measured/-written") → guv, since
# guv's machinery (not the agent) derives it. "control plane" gets no grep-guard:
# its product-category sense is load-bearing and kept (pinned in release.test.sh),
# so retiring only the docs-directory sense is judgment-verified per file, not
# assertable by a blanket grep. The list grows as the sweep lands.
#
# Backward-compat exception ([8.3] stage 6): the migration shims that update
# already-deployed consumers must NAME the pre-retirement markers they migrate
# FROM. Those are fixed legacy-token identifiers carried in consumer artifacts,
# not prose uses of the retired noun — a line referencing one is an allowed
# backward-compat citation, matched as the exact hyphenated token so a bare
# "harness" still fails. Closed set, grown as each shim lands:
#   Harness-owned          — pre-[8.3] post-commit-hook ownership marker (setup-control-plane.sh)
#   guv-harness-gitignore  — pre-[8.3] gitignore append marker (scaffold-shell.sh, shipped in plugin/)
LEGACY_MARKER_RE='Harness-owned|guv-harness-gitignore'
SWEPT_HARNESS_FREE="
.claude/rules/guv-codebase-respect.md
.claude/rules/guv-context-and-llm-use.md
.claude/rules/guv-failure-paths.md
.claude/rules/guv-thinking-and-scope.md
.claude/rules/guv-verification.md
.claude/guv-git.sh
.claude/estimate.sh
.claude/estimate.shape.md
.claude/skills/replan/SKILL.md
maintainers/render-smoke.js
.claude/skills/feedback/SKILL.md
.claude/skills/handoff/SKILL.md
.claude/skills/init-project/SKILL.md
.claude/skills/onboard/SKILL.md
.claude/skills/plan/SKILL.md
.claude/skills/status/SKILL.md
maintainers/plugin-src/skills/eval-parallel/SKILL.md
maintainers/plugin-src/skills/scaffold/SKILL.md
maintainers/plugin-src/skills/zen/SKILL.md
maintainers/setup-control-plane.sh
maintainers/plugin-src/scripts/scaffold-shell.sh
maintainers/build-plugin.sh
maintainers/check-template-clean.sh
maintainers/DOGFOODING.md
.claude/skills/feedback/scripts/feedback-submit.sh
.claude/tests/setup-control-plane.test.sh
.claude/tests/scaffold.test.sh
.claude/tests/render-hook.test.sh
.claude/tests/plugin.test.sh
.claude/tests/eval-parallel.test.sh
.claude/tests/estimate.test.sh
.claude/tests/check-template-clean.test.sh
.claude/tests/single-writer.test.sh
.claude/tests/render-status.test.sh
.claude/tests/guv-lane.test.sh
.claude/tests/feedback-log.test.sh
.claude/tests/entry-split.test.sh
.claude/meter.sh
.claude/metering-log.md
.claude/hooks/stop-check.sh
.claude/tests/meter.test.sh
.claude/tests/stop-check.test.sh
README.template.md
CLAUDE.template.md
.claude/project.schema.json
.gitignore
.github/workflows/template-clean.yml
maintainers/plugin-src/plugin.json
"
for rel in $SWEPT_HARNESS_FREE; do
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then
    no "vocab guard: listed surface missing: $rel"
  elif grep -niw 'harness' "$f" 2>/dev/null | grep -qvE "$LEGACY_MARKER_RE"; then
    no "retired noun 'harness' survives in $rel ($(grep -niw harness "$f" | grep -cvE "$LEGACY_MARKER_RE") hit) — first: $(grep -niw harness "$f" | grep -vE "$LEGACY_MARKER_RE" | head -1 | cut -c1-72)"
  else
    ok "vocabulary: $rel free of 'harness'"
  fi
done

# T10 — whole-tree backstop ([8.3] stage 5; legacy-marker exception added stage 6).
# "harness" is retired everywhere; the only permitted occurrences are this guard
# itself (the grep pattern above), CHANGELOG.md (release history), the README's two
# Anthropic-citation lines (an external article title + URL), and the named legacy
# markers the stage-6 migration shims grep for (LEGACY_MARKER_RE, filtered below).
# Anything else is a sweep miss or a regression.
BACKSTOP=$(cd "$ROOT" && git grep -In -i harness -- ':!plugin/' ':!.claude/tests/docs-sweep.test.sh' ':!CHANGELOG.md' ':!README.md' 2>/dev/null | grep -vE "$LEGACY_MARKER_RE")
if [ -z "$BACKSTOP" ]; then
  ok "whole-tree backstop: no retired 'harness' outside the allowlist"
else
  no "retired 'harness' survives in: $(echo "$BACKSTOP" | tr '\n' ' ')"
fi
# README.md: 'harness' permitted ONLY on the Anthropic-citation lines.
README_BAD=$(grep -in harness "$ROOT/README.md" 2>/dev/null | grep -vi anthropic)
if [ -z "$README_BAD" ]; then
  ok "README 'harness' confined to the Anthropic citations"
else
  no "non-citation 'harness' in README.md: $README_BAD"
fi
# plugin/ is generated from swept source, so it must be harness-free apart from
# the named legacy markers a shipped migration shim greps for (scaffold-shell.sh's
# guv-harness-gitignore) — same narrow LEGACY_MARKER_RE exception, bare "harness"
# in plugin/ still fails.
PLUGIN_BAD=$(cd "$ROOT" && git grep -In -i harness -- 'plugin/' 2>/dev/null | grep -vE "$LEGACY_MARKER_RE")
if [ -z "$PLUGIN_BAD" ]; then
  ok "plugin/ harness-free (apart from named legacy markers)"
else
  no "harness shipped in plugin/: $(echo "$PLUGIN_BAD" | tr '\n' ' ')"
fi
# Appendix B (the ratified §1 Vocabulary) is placed verbatim in the README.
if grep -q '^## Vocabulary' "$ROOT/README.md" \
   && grep -q 'guv is a control plane for Claude Code' "$ROOT/README.md" \
   && grep -q 'Sync replaces the core' "$ROOT/README.md"; then
  ok "README carries the ratified Vocabulary block (Appendix B placed)"
else
  no "README must carry the ## Vocabulary block (Appendix B)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
