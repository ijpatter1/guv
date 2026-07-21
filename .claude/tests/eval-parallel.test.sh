#!/bin/bash
# Tests for .claude/workflows/eval-parallel.js — the saved dual-QA workflow
# (Phase 4 D2: both calibrated reviewers concurrently over a commit-range scope).
# Guards the invariants the workflow promises:
#   - the script exists in .claude/workflows/ with a literal meta block whose
#     name matches the filename (that name IS the /eval-parallel command)
#   - the review stage invokes BOTH calibrated reviewers by name via agentType,
#     and no other agentType appears (rule 14: ad-hoc reviewers prohibited)
#   - the combined summary (the /eval skill's Step 4 block) is produced
#   - the fix loop is explicitly excluded (Step 5 stays conversational —
#     workflow subagents run in acceptEdits mode, which conflicts with it)
#   - the script parses as JavaScript (node --check; skipped cleanly when node
#     is absent — the guv's own runtime deps stay bash + jq + git)
# Pure bash, no test runner required.
# Run: bash .claude/tests/eval-parallel.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$ROOT/.claude/workflows/eval-parallel.js"
SELF="$ROOT/.claude/tests/$(basename "$0")"   # absolute — for seamed self-checks
RMD="${EP_TEST_README:-$ROOT/README.md}"      # self-check seam for the README gate
DOCROOT="${EP_TEST_DOCROOT:-$ROOT}"           # seam for the plane-shape doc skips (T8c)
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# T1 — workflow script exists. Everything else reads it, so bail loudly if absent.
if [ -f "$WF" ]; then
  ok "eval-parallel.js exists in .claude/workflows/"
else
  no "workflow script missing: $WF"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# T2 — meta block: literal export with name matching the filename (the saved
# name is what registers the /eval-parallel command).
grep -q "^export const meta" "$WF" \
  && ok "meta block exported at top level" \
  || no "script must open with: export const meta = { ... }"
grep -q "name: 'eval-parallel'" "$WF" \
  && ok "meta.name matches the filename (registers /eval-parallel)" \
  || no "meta.name must be 'eval-parallel'"

# T3 — both calibrated reviewers invoked BY NAME via agentType (rule 14).
grep -q "agentType: 'evaluator'" "$WF" \
  && ok "review stage spawns the evaluator by name (agentType)" \
  || no "must spawn agentType: 'evaluator'"
grep -q "agentType: 'reviewer'" "$WF" \
  && ok "review stage spawns the reviewer by name (agentType)" \
  || no "must spawn agentType: 'reviewer'"

# T4 — no ad-hoc reviewer sneaks in: every agentType in the script (either
# quote style) is one of the two calibrated agents (the scope-gathering stage
# uses the default worker, which carries no agentType at all).
ROGUE=$(grep -oE "agentType: ['\"][^'\"]*['\"]" "$WF" | grep -vE "['\"](evaluator|reviewer)['\"]" || true)
[ -z "$ROGUE" ] \
  && ok "no ad-hoc reviewer agentType present (rule 14)" \
  || no "unexpected agentType in workflow: $ROGUE"

# T5 — the combined summary block (skill Step 4) is produced by the script.
grep -q "Evaluation Summary" "$WF" \
  && ok "combined summary block present (mirrors /eval Step 4)" \
  || no "script must produce the combined Evaluation Summary"

# T6 — the fix loop is excluded and the exclusion is stated, not silent:
# Step 5 stays conversational, outside the workflow.
grep -qi "fix loop" "$WF" && grep -qi "conversational" "$WF" \
  && ok "fix-loop exclusion stated (Step 5 stays conversational)" \
  || no "script must state that the fix loop stays conversational, outside the workflow"

# T7 — the script parses as JavaScript. The workflow runtime strips the meta
# export and runs the body inside an async function (that's what legalizes
# top-level await/return), so the check emulates that wrapping — which also
# keeps it CommonJS-parsed and independent of node's ESM-detection version
# threshold. node is not a guv runtime dep: skip cleanly (loudly) if absent.
if command -v node >/dev/null 2>&1; then
  { printf 'async function __wf(){\n'; sed 's/^export //' "$WF"; printf '\n}\n'; } \
    | node --check >/dev/null 2>&1 \
    && ok "script parses as JavaScript (node --check, runtime-wrapped)" \
    || no "node --check failed — syntax error in $WF"
else
  echo "  - node not installed — skipping syntax check"
fi

# T8 — ultracode-guidance touchpoints (Phase 4 D3): the README and
# CLAUDE.template.md carry the planning-/execution-layer guidance, and the
# /eval skill + /handoff command cross-reference the workflow variant.
for doc in README.md CLAUDE.template.md \
           .claude/skills/eval/SKILL.md .claude/skills/handoff/SKILL.md; do
  target="$DOCROOT/$doc"
  # /init replaces README.md with a rendered project README, and a
  # fork may delete it — both are consumer shapes that skip this one guard
  # rather than failing (matching setup-control-plane.test.sh T10's gates).
  # Detector = the explicit guv-template-readme marker, reword-proof; the
  # README path rides the EP_TEST_README seam so T8b can prove both branches.
  # A control plane carries the suites ([7.7]) but not the source repo's doc
  # surfaces — an absent non-README doc skips visibly ONLY in plane/fork
  # shape (no maintainers/); in source shape (maintainers/ present) an
  # absent doc is drift and fails loud, mirroring sandbox-example's
  # both-absent-vs-one-absent discrimination. Rides EP_TEST_DOCROOT (T8c).
  if [ "$doc" != "README.md" ] && [ ! -f "$target" ]; then
    if [ -d "$DOCROOT/maintainers" ]; then
      no "$doc absent in source shape — drift, not topology"
    else
      echo "  - $doc absent (control plane / stripped fork) — cross-reference check skips"
    fi
    continue
  fi
  if [ "$doc" = "README.md" ]; then
    target="$RMD"
    if [ ! -f "$target" ]; then
      echo "  - README.md absent (fork) — cross-reference guard skips"
      continue
    fi
    if ! grep -q 'guv-template-readme' "$target"; then
      # Detector-drift probe (mirrors setup-control-plane T10; the probe
      # literal lives in both suites — keep them in step): template-only
      # content without the marker means drift, not a rendered README.
      if tr '\n' ' ' < "$target" | tr -s ' ' | grep -qi 'replaces core-owned surfaces'; then
        no "README carries template content but no guv-template-readme marker — marker/detector drift"
      else
        echo "  - README.md is a rendered project README, not the template's — cross-reference guard skips"
      fi
      continue
    fi
  fi
  grep -q "eval-parallel" "$target" 2>/dev/null \
    && ok "$doc cross-references /eval-parallel" \
    || no "$doc must cross-reference /eval-parallel"
done

# T8b — seamed self-checks for the README gate, both directions (the b0310b2
# convention; the rendered/absent skips must fire visibly, and a marker-bearing
# README must make the guard RUN — a typo'd detector otherwise disables the
# guard silently while the suite stays green).
if [ -z "${EP_TEST_INNER:-}" ]; then
  EPWORK=$(mktemp -d)
  echo "# my-rendered-project" > "$EPWORK/rendered.md"
  INNER=$(EP_TEST_INNER=1 EP_TEST_README="$EPWORK/rendered.md" bash "$SELF" 2>&1)
  if [ $? -eq 0 ] && echo "$INNER" | grep -q "rendered project README"; then
    ok "rendered-README shape visibly skips the cross-reference guard (seamed self-check)"
  else
    no "a rendered README must skip the cross-reference guard visibly"
  fi
  INNER=$(EP_TEST_INNER=1 EP_TEST_README="$EPWORK/absent.md" bash "$SELF" 2>&1)
  if [ $? -eq 0 ] && echo "$INNER" | grep -q "README.md absent"; then
    ok "absent-README shape visibly skips the cross-reference guard (seamed self-check)"
  else
    no "an absent README must skip the cross-reference guard visibly"
  fi
  printf '# some readme\n<!-- guv-template-readme -->\n' > "$EPWORK/marker-only.md"
  INNER=$(EP_TEST_INNER=1 EP_TEST_README="$EPWORK/marker-only.md" bash "$SELF" 2>&1)
  if [ $? -ne 0 ] && echo "$INNER" | grep -q "README.md must cross-reference"; then
    ok "marker-bearing README runs the cross-reference guard (template-shape positive control)"
  else
    no "with the marker present the cross-reference guard must RUN (and fail on empty content)"
  fi
  # Scope: probe↔plant consistency only (catches a typo'd probe). Accepted
  # residual: if the README phrase is reworded, the sibling suite's running
  # wholesale guard reds loudly and forces the update THERE, but this suite's
  # probe+fixture can stay coherently stale — its drift probe then degrades to
  # the plain visible skip, not silence. Keep the literals in step with
  # setup-control-plane.test.sh.
  printf '# readme\n--sync replaces core-owned surfaces wholesale.\n' > "$EPWORK/drifted.md"
  INNER=$(EP_TEST_INNER=1 EP_TEST_README="$EPWORK/drifted.md" bash "$SELF" 2>&1)
  if [ $? -ne 0 ] && echo "$INNER" | grep -q "marker/detector drift"; then
    ok "marker-less template content fails loud (drift-probe self-check)"
  else
    no "a marker-less README with template content must fail loud, not skip"
  fi
  rm -rf "$EPWORK"
fi
if [ -f "$DOCROOT/CLAUDE.template.md" ]; then
  tr '\n' ' ' < "$DOCROOT/CLAUDE.template.md" | tr -s ' ' | grep -q "planning layer" \
    && ok "CLAUDE.template.md states the planning/execution layering" \
    || no "CLAUDE.template.md must state planning layer vs execution layer"
elif [ -d "$DOCROOT/maintainers" ]; then
  no "CLAUDE.template.md absent in source shape — drift, not topology"
else
  echo "  - CLAUDE.template.md absent (control plane / stripped fork) — layering check skips"
fi

# T8c — seamed self-checks for the plane-shape doc skips, both directions
# (the T8b convention applied to [7.7]'s skip branches: a skip is trusted
# only when a re-invocation proves it fires, and the drift direction is
# trusted only when a re-invocation proves the guard fails loud in source
# shape).
if [ -z "${EP_TEST_INNER:-}" ]; then
  EPC=$(mktemp -d)
  mkdir -p "$EPC/plane"                       # no docs, no maintainers/ = plane shape
  INNER=$(EP_TEST_INNER=1 EP_TEST_DOCROOT="$EPC/plane" bash "$SELF" 2>&1)
  # Per-branch precision: all four skip sites (three loop docs + the
  # layering check) must print — one silent regression cannot hide behind
  # a printing sibling.
  if [ $? -eq 0 ] && [ "$(echo "$INNER" | grep -c "absent (control plane")" -eq 4 ]; then
    ok "all four plane-shape doc skips fire visibly, suite stays green (seamed self-check)"
  else
    no "absent docs in plane shape must skip visibly at every site with exit 0 (got $(echo "$INNER" | grep -c 'absent (control plane')/4)"
  fi
  mkdir -p "$EPC/source/maintainers"          # maintainers/ present = source shape
  INNER=$(EP_TEST_INNER=1 EP_TEST_DOCROOT="$EPC/source" bash "$SELF" 2>&1)
  if [ $? -ne 0 ] && [ "$(echo "$INNER" | grep -c "drift, not topology")" -eq 4 ]; then
    ok "all four sites fail loud in source shape (drift direction, seamed self-check)"
  else
    no "an absent doc with maintainers/ present must fail loud at every site (got $(echo "$INNER" | grep -c 'drift, not topology')/4)"
  fi
  rm -rf "$EPC"
fi

# T9 — the phase-label guard BEHAVES correctly (node-gated like T7): the
# extracted const lines are executed against the deviations the guard exists
# for — "Phase Phase" duplication, empty phase, and the non-phased sentinels.
# Two fix-pass behavior changes landed here untested; this closes that gap.
if command -v node >/dev/null 2>&1; then
  SNIPPET=$(grep -E '^const (phaseLabel|phased|fromPhase) ' "$WF")
  if [ "$(echo "$SNIPPET" | wc -l)" -eq 3 ]; then
    run_guard() {
      printf 'const scope={phase:process.argv[2] ?? ""};\n%s\nconsole.log(JSON.stringify([phaseLabel,phased,fromPhase]));\n' "$SNIPPET" \
        | node - "$1" 2>/dev/null
    }
    G_OK=1
    [ "$(run_guard '  Phase 4 — X')" = '["4 — X",true," from Phase 4 — X"]' ] || G_OK=0
    [ "$(run_guard '')" = '["",false,""]' ] || G_OK=0
    [ "$(run_guard 'unknown')" = '["unknown",false,""]' ] || G_OK=0
    [ "$(run_guard 'N/A')" = '["N/A",false,""]' ] || G_OK=0
    [ "$(run_guard '4')" = '["4",true," from Phase 4"]' ] || G_OK=0
    [ "$G_OK" -eq 1 ] \
      && ok "phase-label guard behaves: prefix-strip, empty, sentinels (executed)" \
      || no "phase-label guard misbehaves for a deviation case"
  else
    no "could not extract the three guard const lines from $WF (test setup)"
  fi
else
  echo "  - node not installed — skipping phase-label guard behavior check"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
