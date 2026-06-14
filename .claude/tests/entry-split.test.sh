#!/bin/bash
# Tests for [7.2] — the entry split: a light daily/mid-phase next door
# (`/next`) carved out of `/phase`, which becomes the phase-boundary
# command. What this suite pins:
#   Part A (ships to every plane — code repo AND control planes per [7.7]):
#     - the next door exists, calls resolve-ready.sh, and presents the
#       frontier (serial pick the headline)
#     - the next door is LIGHT: no spec-alignment step, no reviewer
#       (the defining contrast with the boundary door — acceptance criterion 1)
#     - both doors no-op in task/onboard ceremony (mode signal, not error)
#     - the next door loud-stops on a MALFORMED tracker rather than present
#       a plan off a broken frontier (rule 15; resolver exit 5)
#     - the next door name is ratified: no provisional marker remains
#       ([8.2] chose the verb grammar; [8.3] landed the rename)
#     - /phase is the BOUNDARY door: framed as such, points at the next
#       door for daily resume, and still performs the full sequence (spec
#       alignment + /replan routing survive — acceptance criterion 2)
#     - the session-management skill routes daily/overnight resume to /next
#   Part B (template-repo doc surface only — skips in consumer/plane shape):
#     - README teaches /next (What's Included bullet + File Structure tree)
#     - CLAUDE.template.md process-commands bullet names /next
# The plugin byte-parity of the new command is covered by plugin.test.sh's
# glob-derived T3/T14 — not restated here. Pure bash, no runner required.
# Run: bash .claude/tests/entry-split.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

RESUME="$ROOT/.claude/skills/next/SKILL.md"
SP="$ROOT/.claude/skills/phase/SKILL.md"
SM="$ROOT/.claude/skills/session-management/SKILL.md"

# ── Part A — the next door (ships to every plane) ──────────────────────────
if [ -f "$RESUME" ]; then
  ok "next door exists (.claude/skills/next/SKILL.md)"

  grep -q 'resolve-ready.sh' "$RESUME" \
    && ok "next door calls the resolver (resolve-ready.sh)" \
    || no "next door must call resolve-ready.sh — it presents the frontier, not a hand read"

  grep -qi 'frontier' "$RESUME" && grep -q 'serial' "$RESUME" \
    && ok "next door presents the frontier with the serial pick as the headline" \
    || no "next door must present the frontier (serial pick the headline)"

  grep -qi 'plan' "$RESUME" \
    && ok "next door presents a session plan" \
    || no "next door must present a plan (acceptance: a mid-phase session reaches a presented plan)"

  # The defining contrast: the LIGHT door does not re-run spec alignment.
  if grep -iqE '^#+ .*spec.?alignment' "$RESUME"; then
    no "next door must NOT carry a spec-alignment step (that is the boundary door's ritual)"
  else
    ok "next door carries no spec-alignment step (light door, acceptance criterion 1)"
  fi
  if grep -q 'reviewer' "$RESUME"; then
    no "next door must NOT invoke the reviewer (no spec-alignment pass on the light door)"
  else
    ok "next door does not invoke the reviewer"
  fi

  # No-op in task/onboard ceremony — mode signal, not error.
  grep -q 'ceremony' "$RESUME" && grep -qi 'mode signal' "$RESUME" \
    && ok "next door no-ops in task/onboard ceremony (mode signal, not error)" \
    || no "next door must treat non-phased ceremony as a mode signal, not an error"

  # Loud stop on a malformed tracker — rule 15, never a plan off a broken frontier.
  grep -qiE 'MALFORMED|exit 5' "$RESUME" \
    && ok "next door surfaces a MALFORMED tracker as a loud stop (rule 15)" \
    || no "next door must loud-stop on the resolver's MALFORMED/exit-5 path, not present an empty frontier"

  # Name ratified at [8.2], rename landed at [8.3]: no provisional marker remains.
  if grep -qi 'provisional' "$RESUME"; then
    no "next door must not carry a provisional-name marker — [8.2] ratified the name, [8.3] landed the rename"
  else
    ok "next door name is ratified (no provisional marker; [8.2] decided, [8.3] landed)"
  fi
else
  no "next door missing — .claude/skills/next/SKILL.md must exist"
fi

# ── Part A — the boundary door (/phase) ────────────────────────────────
if [ -f "$SP" ]; then
  grep -qi 'boundary' "$SP" \
    && ok "phase is framed as the phase-boundary command" \
    || no "phase.md must frame itself as the boundary command (the entry split)"

  grep -q '/next' "$SP" \
    && ok "phase points at /next for daily/mid-phase resume" \
    || no "phase.md must point daily resume at the /next door"

  # The full sequence survives: spec alignment + /replan routing stay.
  grep -iqE '^#+ .*spec.?alignment' "$SP" && grep -q 'reviewer' "$SP" \
    && ok "phase still performs spec alignment (full sequence intact)" \
    || no "phase.md must keep the spec-alignment step (acceptance criterion 2)"
  grep -q '/replan' "$SP" \
    && ok "phase still routes spec-alignment findings through /replan" \
    || no "phase.md must keep routing through /replan"
else
  no "phase.md missing"
fi

# ── Part A — session-management routes daily resume to /next ───────────────
if [ -f "$SM" ]; then
  grep -q '/next' "$SM" \
    && ok "session-management routes daily/overnight resume to /next" \
    || no "session-management SKILL.md must point daily/overnight resume at /next"
else
  no "session-management SKILL.md missing"
fi

# ── Part B — template-repo doc surface (skips in consumer/plane shape) ────────
# A rendered consumer project replaces README.md and may delete maintainers/;
# a control plane carries the commands but not the harness's README/template.
# ES_TEST_README seams the marker probe for the self-check below.
README_PROBE="${ES_TEST_README:-$ROOT/README.md}"
MAINT_PROBE="${ES_TEST_MAINTAINERS:-$ROOT/maintainers}"
if grep -q 'guv-template-readme' "$README_PROBE" 2>/dev/null && [ -d "$MAINT_PROBE" ]; then
  README="$ROOT/README.md"; CT="$ROOT/CLAUDE.template.md"

  grep -qE '^- `/next' "$README" \
    && ok "README What's Included carries a /next bullet" \
    || no "README What's Included must carry a /next bullet"
  grep -qE '├── next/' "$README" \
    && ok "README File Structure tree lists the next skill" \
    || no "README File Structure tree must list the next skill (skills/next/)"

  if grep '^\- \*\*Process commands:\*\*' "$CT" | grep -q '/next'; then
    ok "CLAUDE.template.md process-commands bullet names /next"
  else
    no "CLAUDE.template.md process-commands bullet must name /next"
  fi
else
  echo "  - template-repo doc surface not present — skipping (consumer/plane shape)"
fi

# ── Seamed self-check: the Part B skip must fire visibly (exit 0) for BOTH
# shapes that lack the template-doc surface — a rendered consumer fork (no README
# marker) and a control plane (no maintainers/). This file ships to every such
# repo, and a maintainer assertion redding them out is this project's one prior
# Critical class ([7.7]/docs-sweep precedent), so each operand of the Part B
# guard is seamed independently (the bidirectional-skip-proof convention).
if [ -z "${ES_TEST_INNER:-}" ]; then
  # Seam A — marker-absent README (consumer-fork shape) skips Part B.
  FAKE_README=$(mktemp)
  echo "# a rendered consumer project readme" > "$FAKE_README"
  A_OUT=$(ES_TEST_INNER=1 ES_TEST_README="$FAKE_README" bash "$SELF" 2>&1)
  A_RC=$?
  rm -f "$FAKE_README"
  if [ "$A_RC" -eq 0 ] && echo "$A_OUT" | grep -q "skipping (consumer/plane shape)"; then
    ok "Part B skips visibly on a marker-absent README (seam A — consumer fork)"
  else
    no "a marker-less README must skip Part B visibly with exit 0, got rc=$A_RC"
  fi
  # Seam B — maintainers-absent (control-plane shape) skips Part B. The README
  # marker is present here, so the maintainers operand is the one under test.
  B_OUT=$(ES_TEST_INNER=1 ES_TEST_MAINTAINERS="$ROOT/.es-no-maintainers-$$" bash "$SELF" 2>&1)
  B_RC=$?
  if [ "$B_RC" -eq 0 ] && echo "$B_OUT" | grep -q "skipping (consumer/plane shape)"; then
    ok "Part B skips visibly on absent maintainers/ (seam B — control plane)"
  else
    no "an absent maintainers/ must skip Part B visibly with exit 0, got rc=$B_RC"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
