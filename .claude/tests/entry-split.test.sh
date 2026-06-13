#!/bin/bash
# Tests for [7.2] — the entry split: a light name-neutral resume door
# (`/resume`) carved out of `/start-phase`, which becomes the phase-boundary
# command. What this suite pins:
#   Part A (ships to every plane — code repo AND control planes per [7.7]):
#     - the resume door exists, calls resolve-ready.sh, and presents the
#       frontier (serial pick the headline)
#     - the resume door is LIGHT: no spec-alignment step, no product-reviewer
#       (the defining contrast with the boundary door — acceptance criterion 1)
#     - both doors no-op in task/onboard ceremony (mode signal, not error)
#     - the resume door loud-stops on a MALFORMED tracker rather than present
#       a plan off a broken frontier (rule 15; resolver exit 5)
#     - the resume door ships name-neutral: an explicit provisional marker
#       pending [8.2] (the naming discipline — no chosen verb before 8.2)
#     - /start-phase is the BOUNDARY door: framed as such, points at the resume
#       door for daily resume, and still performs the full sequence (spec
#       alignment + /replan routing survive — acceptance criterion 2)
#     - the session-management skill routes daily/overnight resume to /resume
#   Part B (template-repo doc surface only — skips in consumer/plane shape):
#     - README teaches /resume (What's Included bullet + File Structure tree)
#     - CLAUDE.template.md process-commands bullet names /resume
# The plugin byte-parity of the new command is covered by plugin.test.sh's
# glob-derived T3/T14 — not restated here. Pure bash, no runner required.
# Run: bash .claude/tests/entry-split.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

RESUME="$ROOT/.claude/commands/resume.md"
SP="$ROOT/.claude/commands/start-phase.md"
SM="$ROOT/.claude/skills/session-management/SKILL.md"

# ── Part A — the resume door (ships to every plane) ──────────────────────────
if [ -f "$RESUME" ]; then
  ok "resume door exists (.claude/commands/resume.md)"

  grep -q 'resolve-ready.sh' "$RESUME" \
    && ok "resume door calls the resolver (resolve-ready.sh)" \
    || no "resume door must call resolve-ready.sh — it presents the frontier, not a hand read"

  grep -qi 'frontier' "$RESUME" && grep -q 'serial' "$RESUME" \
    && ok "resume door presents the frontier with the serial pick as the headline" \
    || no "resume door must present the frontier (serial pick the headline)"

  grep -qi 'plan' "$RESUME" \
    && ok "resume door presents a session plan" \
    || no "resume door must present a plan (acceptance: a mid-phase session reaches a presented plan)"

  # The defining contrast: the LIGHT door does not re-run spec alignment.
  if grep -iqE '^#+ .*spec.?alignment' "$RESUME"; then
    no "resume door must NOT carry a spec-alignment step (that is the boundary door's ritual)"
  else
    ok "resume door carries no spec-alignment step (light door, acceptance criterion 1)"
  fi
  if grep -q 'product-reviewer' "$RESUME"; then
    no "resume door must NOT invoke the product-reviewer (no spec-alignment pass on the light door)"
  else
    ok "resume door does not invoke the product-reviewer"
  fi

  # No-op in task/onboard ceremony — mode signal, not error.
  grep -q 'ceremony' "$RESUME" && grep -qi 'mode signal' "$RESUME" \
    && ok "resume door no-ops in task/onboard ceremony (mode signal, not error)" \
    || no "resume door must treat non-phased ceremony as a mode signal, not an error"

  # Loud stop on a malformed tracker — rule 15, never a plan off a broken frontier.
  grep -qiE 'MALFORMED|exit 5' "$RESUME" \
    && ok "resume door surfaces a MALFORMED tracker as a loud stop (rule 15)" \
    || no "resume door must loud-stop on the resolver's MALFORMED/exit-5 path, not present an empty frontier"

  # Name-neutral: an explicit provisional marker pending [8.2].
  grep -qi 'provisional' "$RESUME" && grep -q '8.2' "$RESUME" \
    && ok "resume door ships name-neutral (provisional name marker pending [8.2])" \
    || no "resume door must mark its name explicitly provisional pending [8.2] (naming discipline)"
else
  no "resume door missing — .claude/commands/resume.md must exist"
fi

# ── Part A — the boundary door (/start-phase) ────────────────────────────────
if [ -f "$SP" ]; then
  grep -qi 'boundary' "$SP" \
    && ok "start-phase is framed as the phase-boundary command" \
    || no "start-phase.md must frame itself as the boundary command (the entry split)"

  grep -q '/resume' "$SP" \
    && ok "start-phase points at /resume for daily/mid-phase resume" \
    || no "start-phase.md must point daily resume at the /resume door"

  # The full sequence survives: spec alignment + /replan routing stay.
  grep -iqE '^#+ .*spec.?alignment' "$SP" && grep -q 'product-reviewer' "$SP" \
    && ok "start-phase still performs spec alignment (full sequence intact)" \
    || no "start-phase.md must keep the spec-alignment step (acceptance criterion 2)"
  grep -q '/replan' "$SP" \
    && ok "start-phase still routes spec-alignment findings through /replan" \
    || no "start-phase.md must keep routing through /replan"
else
  no "start-phase.md missing"
fi

# ── Part A — session-management routes daily resume to /resume ───────────────
if [ -f "$SM" ]; then
  grep -q '/resume' "$SM" \
    && ok "session-management routes daily/overnight resume to /resume" \
    || no "session-management SKILL.md must point daily/overnight resume at /resume"
else
  no "session-management SKILL.md missing"
fi

# ── Part B — template-repo doc surface (skips in consumer/plane shape) ────────
# A rendered consumer project replaces README.md and may delete maintainers/;
# a control plane carries the commands but not the harness's README/template.
# ES_TEST_README seams the marker probe for the self-check below.
README_PROBE="${ES_TEST_README:-$ROOT/README.md}"
if grep -q 'guv-template-readme' "$README_PROBE" 2>/dev/null && [ -d "$ROOT/maintainers" ]; then
  README="$ROOT/README.md"; CT="$ROOT/CLAUDE.template.md"

  grep -qE '^- `/resume' "$README" \
    && ok "README What's Included carries a /resume bullet" \
    || no "README What's Included must carry a /resume bullet"
  grep -q 'resume\.md' "$README" \
    && ok "README File Structure tree lists resume.md" \
    || no "README File Structure tree must list resume.md"

  if grep '^\- \*\*Process commands:\*\*' "$CT" | grep -q '/resume'; then
    ok "CLAUDE.template.md process-commands bullet names /resume"
  else
    no "CLAUDE.template.md process-commands bullet must name /resume"
  fi
else
  echo "  - template-repo doc surface not present — skipping (consumer/plane shape)"
fi

# ── Seamed self-check: the Part B skip must fire visibly (exit 0) when the
# README lacks the template marker — this file ships to every consumer fork and
# control plane, and a maintainer assertion redding out those repos is this
# project's one prior Critical class ([7.7]/docs-sweep precedent).
if [ -z "${ES_TEST_INNER:-}" ]; then
  FAKE_README=$(mktemp)
  echo "# a rendered consumer project readme" > "$FAKE_README"
  INNER=$(ES_TEST_INNER=1 ES_TEST_README="$FAKE_README" bash "$SELF" 2>&1)
  RC=$?
  rm -f "$FAKE_README"
  if [ "$RC" -eq 0 ] && echo "$INNER" | grep -q "skipping (consumer/plane shape)"; then
    ok "Part B doc-surface skip fires visibly with exit 0 (seamed self-check)"
  else
    no "a marker-less README must skip Part B visibly with exit 0, got rc=$RC"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
