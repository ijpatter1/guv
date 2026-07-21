#!/bin/bash
# Tests for [19.3] — init gains the headless present-and-proceed branch
# its sibling doors already have, so it has a non-interactive path. The cold-path
# gap: init's Step 1 confirmation gate said only "Wait for the user to
# confirm" — an UNCONDITIONAL block. In a headless/autonomous run (no human to
# confirm) that gate dead-ends: unlike /phase (Step 7 carries an explicit
# "In headless/bypass mode: present and proceed" branch), the greenfield door had
# no sanctioned non-interactive path. The fix adds the two-mode structure /phase
# uses — interactive waits for confirmation; headless presents the summary and
# proceeds, treating a spec named in the prompt as pre-approved scope (the spec
# path IS the confirmation) — without dropping the interactive wait.
#
# What this suite pins (asserting the CORE skill's prose — the source of truth;
# the plugin mirror's byte-parity is covered by plugin.test.sh's drift guard):
#   - init names a headless / non-interactive mode at all (the gap: it
#     had none) — the actual fix
#   - in that mode it PRESENTS-AND-PROCEEDS (a real non-interactive path, not just
#     a mention) — proceed, not block
#   - a spec named in the prompt is pre-approved scope (so headless has something
#     to proceed on — the spec path is the confirmation)
#   - headless+NO-spec takes a designed loud stop (Rule 15), not a fall-through to
#     the Input "ask for the file path" gate (the dead-end this branch removes)
#   - it PRESERVES the interactive confirmation gate (still waits for a human when
#     one is present — the nuanced fix, not "headless always")
# Pure bash, no test runner. Run: bash .claude/tests/init-headless.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IP="${IP:-$ROOT/.claude/skills/init/SKILL.md}"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$IP" ]; then
  no "init skill missing — .claude/skills/init/SKILL.md must exist"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
ok "init skill exists (.claude/skills/init/SKILL.md)"

# The fix: name a headless / bypass / non-interactive mode (init had none;
# every sibling that offers a non-interactive path names the mode explicitly).
grep -qiE 'headless|bypass|non-interactive' "$IP" \
  && ok "init names a headless/non-interactive mode" \
  || no "init must name a headless/bypass/non-interactive mode (it had no non-interactive path)"

# Slice the headless branch — from the headless-mode line up to the next blank
# line / heading — and assert it PRESENTS-AND-PROCEEDS (a real path, not a bare
# mention that still blocks). Mirrors /phase Step 7's "present, then proceed".
HEADLESS=$(awk 'tolower($0) ~ /headless|bypass|non-interactive/{f=1} f&&/^## /{exit} f&&/^$/{n++; if(n>=2) exit} f{print}' "$IP")
if [ -z "$HEADLESS" ]; then
  no "could not locate a headless-mode branch in init"
else
  echo "$HEADLESS" | grep -qi 'proceed' \
    && ok "headless branch presents-and-proceeds (a non-interactive path, not a block)" \
    || no "headless branch must PROCEED (present then generate), not just mention the mode"

  # The no-spec case: headless pre-approval rests on a NAMED spec (the spec path
  # is the confirmation), so headless+no-spec has nothing to build from. It must
  # take the designed loud stop (Rule 15) — NOT scaffold from auto-discovered
  # guesses, NOT fall through to the Input "ask for the file path" gate (no human
  # to answer; the dead-end this branch removes). "loud stop"/"halt" appears only
  # here within the sliced branch, so it pins the no-spec degradation specifically.
  echo "$HEADLESS" | grep -qiE 'loud stop|halt' \
    && ok "headless+no-spec takes a designed loud stop (Rule 15), not a fall-through dead-end" \
    || no "headless branch must name a loud stop for headless+no-spec (no fall-through to the human-ask gate)"
fi

# Headless needs something to proceed ON without a human: a spec named in the
# prompt is pre-approved scope (the spec path is the confirmation).
grep -qiE 'pre-approved' "$IP" \
  && ok "a prompt-named spec is pre-approved scope (the headless confirmation)" \
  || no "init must treat a prompt-named spec as pre-approved scope for the headless path"

# The nuance: the interactive confirmation gate survives — headless is an added
# branch, not a replacement that proceeds unconditionally (would scaffold a whole
# project with no human ever in the loop).
grep -qiE 'in interactive mode|wait for the user to confirm' "$IP" \
  && ok "preserves the interactive confirmation gate (still waits when a human is present)" \
  || no "init must keep waiting for confirmation in interactive mode (don't drop the human gate)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
