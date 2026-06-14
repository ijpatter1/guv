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
# reached, the retired noun "harness" (every guv sense: core / guv / the product
# category / record) is gone. Runtime-sense files — meter.sh, metering-log.md,
# stop-check.sh, where "harness" means the Claude Code platform itself — are
# deliberately NOT listed here; that sense is kept. "control plane" gets no
# grep-guard: its product-category sense is load-bearing and kept (pinned in
# release.test.sh), so retiring only the docs-directory sense is judgment-verified
# per file, not assertable by a blanket grep. The list grows as the sweep lands.
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
"
for rel in $SWEPT_HARNESS_FREE; do
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then
    no "vocab guard: listed surface missing: $rel"
  elif grep -niw 'harness' "$f" >/dev/null 2>&1; then
    no "retired noun 'harness' survives in $rel ($(grep -ciw harness "$f") hit) — first: $(grep -niw harness "$f" | head -1 | cut -c1-72)"
  else
    ok "vocabulary: $rel free of 'harness'"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
