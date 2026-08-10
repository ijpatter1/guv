#!/bin/bash
# Tests for .claude/qa-stamp.sh — the QA verdict STAMP writer ([18.2], Phase 18;
# design of record docs/spikes/18-1-generated-artifact-qa.md).
#
# [18.2] routes every generated UAT (handoff Step 8) and manual card (/manual)
# through a calibrated single-reviewer vet at its generation point, then RECORDS
# and STAMPS the verdict. This script is the MECHANICAL half (Rule 12): the verdict
# is the calibrated reviewer's judgment (passed in); the helper only composes the
# canonical `QA:` stamp line and places it idempotently — one source of the stamp
# format so both generation points stamp identically and a re-run never double-stamps.
#
# The heart-of-the-deliverable invariants this suite defends (the two clauses the
# mechanical half owns — the prose half is pinned by qa-vet-prose.test.sh):
#   - clause 3: the artifact CARRIES a `QA:` status stamp (script and card forms);
#   - clause 4: UNVETTED is a distinct, loud verdict — never textually a pass, so a
#     review that could not run is VISIBLY unvetted, never silently presented as passed;
#   - the stamp NAMES the calibrated reviewer (the by-name vet is what gives the
#     verdict meaning — Rule 14);
#   - idempotent: a second stamp REPLACES the first in place, never appends a duplicate
#     (re-running a handoff over the same artifact must not pile stamps);
#   - the rewrite preserves the artifact's mode (a UAT script is chmod +x'd before it
#     is vetted — the stamp must not silently drop the executable bit);
#   - loud failure (Rule 15): a missing artifact or an unknown verdict exits non-zero
#     and writes nothing, never a silent no-op pass.
#
# This suite tests a CONSUMER helper (no skills/<x>/SKILL.md reference), so it SHIPS
# by build-plugin.sh's partition — ship-suite.test.sh asserts that classification.
# Pure bash + grep, no test runner. Run: bash .claude/tests/qa-stamp.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"          # .claude/
SCRIPT="$SRC/qa-stamp.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# Precondition: the helper exists (a missing script is a loud failure, not a silent
# skip — Rule 15).
[ -f "$SCRIPT" ] || { no "expected helper missing: $SCRIPT"; echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1; }

# A generated UAT/manual SCRIPT fixture: shebang + header block + a body sentinel we
# assert survives the rewrite.
mk_sh() { # $1=path
  cat > "$1" <<'EOF'
#!/bin/bash
# ═══════════════════════════════════════════════════════
# Phase 18 UAT
# Created: 2026-06-28, session-2026-06-28-003
# ═══════════════════════════════════════════════════════
set -euo pipefail
echo "BODY_SENTINEL_KEEP"
EOF
}

# A manual/UAT CARD fixture: H1 + metadata + a body sentinel.
mk_md() { # $1=path
  cat > "$1" <<'EOF'
# Manual Task — Example

**Created:** 2026-06-28, session-2026-06-28-003
**Status:** pending

## Context
BODY_SENTINEL_KEEP
EOF
}

# ════ T1 — stamp PASS into a SCRIPT: the artifact carries a `# QA:` stamp (clause 3) ════
F="$WORK/uat.sh"; mk_sh "$F"
OUT=$(bash "$SCRIPT" "$F" pass guv:reviewer "0 findings" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && grep -qE '^# QA: PASS' "$F" \
  && ok "script: pass → carries a '# QA: PASS' stamp (clause 3)" \
  || no "script pass should write a '# QA: PASS' stamp, exit 0 (rc=$RC)"
grep -q 'guv:reviewer' "$F" \
  && ok "script: the stamp NAMES the calibrated reviewer (guv:reviewer)" \
  || no "stamp must name the reviewer (guv:reviewer missing)"
grep -q 'BODY_SENTINEL_KEEP' "$F" \
  && ok "script: the artifact body is preserved across the stamp rewrite" \
  || no "stamp rewrite dropped the artifact body"
printf '%s' "$OUT" | grep -q 'QA: PASS' \
  && ok "script: the written stamp is echoed to stdout" \
  || no "stamp should be echoed to stdout for the caller"

# ════ T2 — stamp PASS into a CARD: markdown `**QA:**` field form (clause 3) ════
G="$WORK/card.md"; mk_md "$G"
bash "$SCRIPT" "$G" pass guv:reviewer >/dev/null 2>&1
grep -qE '^\*\*QA:\*\* PASS' "$G" \
  && ok "card: pass → carries a '**QA:** PASS' field stamp (clause 3)" \
  || no "card pass should write a '**QA:** PASS' field"
grep -q 'guv:reviewer' "$G" \
  && ok "card: the stamp names the calibrated reviewer (guv:reviewer)" \
  || no "card stamp must name the reviewer (guv:reviewer)"
grep -q 'BODY_SENTINEL_KEEP' "$G" \
  && ok "card: the artifact body is preserved across the rewrite" \
  || no "card stamp rewrite dropped the body"

# ════ T3 — NEEDS WORK is a distinct verdict label ════
F3="$WORK/nw.sh"; mk_sh "$F3"
bash "$SCRIPT" "$F3" needs-work guv:reviewer "3 findings" >/dev/null 2>&1
grep -qE '^# QA: NEEDS WORK' "$F3" \
  && ok "needs-work → '# QA: NEEDS WORK' (distinct verdict label)" \
  || no "needs-work should write 'NEEDS WORK'"
grep -q '3 findings' "$F3" \
  && ok "needs-work: the note tail (findings count) is carried in the stamp" \
  || no "the note tail should appear in the stamp"

# ════ T4 — UNVETTED is loud and NEVER textually a pass (clause 4) ════
F4="$WORK/unvetted.sh"; mk_sh "$F4"
bash "$SCRIPT" "$F4" unvetted guv:reviewer "reviewer unavailable" >/dev/null 2>&1
S=$(grep -E '^# QA:' "$F4")
printf '%s' "$S" | grep -q 'UNVETTED' \
  && ok "review-unavailable → '# QA: UNVETTED' (clause 4: loud, recorded)" \
  || no "unvetted should write 'UNVETTED'"
printf '%s' "$S" | grep -qiv 'pass' \
  && ok "clause 4: the UNVETTED stamp is NOT textually a pass (never a silent pass)" \
  || no "UNVETTED stamp must not read as a pass"

# ════ T5 — idempotent: re-stamping REPLACES, never appends a duplicate ════
F5="$WORK/idem.sh"; mk_sh "$F5"
bash "$SCRIPT" "$F5" pass guv:reviewer >/dev/null 2>&1
bash "$SCRIPT" "$F5" needs-work guv:reviewer "1 finding" >/dev/null 2>&1
N=$(grep -cE '^# QA:' "$F5")
[ "$N" -eq 1 ] \
  && ok "idempotent: exactly ONE QA stamp after two stamps (replaced, not appended)" \
  || no "re-stamp must leave exactly one QA line (found $N)"
grep -qE '^# QA: NEEDS WORK' "$F5" \
  && ok "idempotent: the surviving stamp is the LATEST verdict (NEEDS WORK)" \
  || no "the re-stamp should reflect the latest verdict"

# ════ T5b — find-and-replace relocates: a pre-existing stamp anywhere is replaced ════
# The manual templates ship a default UNVETTED stamp INSIDE the header block; the vet
# must update THAT line in place, not insert a second near the top.
F5b="$WORK/template.sh"
cat > "$F5b" <<'EOF'
#!/bin/bash
# ═══════════════════════════════════════════════════════
# Phase 18 UAT
# QA: UNVETTED — not yet vetted
# ═══════════════════════════════════════════════════════
set -euo pipefail
EOF
bash "$SCRIPT" "$F5b" pass guv:reviewer >/dev/null 2>&1
N5b=$(grep -cE '^# QA:' "$F5b")
[ "$N5b" -eq 1 ] && grep -qE '^# QA: PASS' "$F5b" \
  && ok "template default: the in-header UNVETTED default is updated in place to PASS (one stamp)" \
  || no "an existing in-header stamp must be replaced in place (found $N5b QA lines)"

# ════ T6 — insert-when-absent keeps the shebang first (a script must still run) ════
F6="$WORK/noslot.sh"; mk_sh "$F6"
# (mk_sh has no QA line) — stamping inserts one; the shebang must remain line 1.
bash "$SCRIPT" "$F6" pass guv:reviewer >/dev/null 2>&1
[ "$(head -1 "$F6")" = "#!/bin/bash" ] \
  && ok "insert: the shebang remains line 1 (the stamped script still executes)" \
  || no "stamping must not displace the shebang"

# ════ T7 — mode preserved: a chmod +x UAT script stays executable after stamping ════
F7="$WORK/exec.sh"; mk_sh "$F7"; chmod +x "$F7"
bash "$SCRIPT" "$F7" pass guv:reviewer >/dev/null 2>&1
[ -x "$F7" ] \
  && ok "the executable bit survives the stamp rewrite (chmod +x before vet is safe)" \
  || no "stamping a +x script dropped the executable bit"

# ════ T8 — loud failure (Rule 15): missing artifact exits non-zero, writes nothing ════
OUT8=$(bash "$SCRIPT" "$WORK/does-not-exist.sh" pass guv:reviewer 2>/dev/null); RC8=$?
[ "$RC8" -ne 0 ] \
  && ok "missing artifact → non-zero exit (loud, Rule 15)" \
  || no "a missing artifact must fail loudly (rc=$RC8)"
[ ! -f "$WORK/does-not-exist.sh" ] \
  && ok "missing artifact: nothing is created (no silent no-op)" \
  || no "a missing artifact must not be created"

# ════ T9 — unknown verdict exits non-zero and leaves the artifact untouched ════
F9="$WORK/badverdict.sh"; mk_sh "$F9"
BEFORE=$(cat "$F9")
bash "$SCRIPT" "$F9" maybe guv:reviewer >/dev/null 2>&1; RC9=$?
[ "$RC9" -ne 0 ] \
  && ok "unknown verdict → non-zero exit (only pass|needs-work|unvetted are valid)" \
  || no "an unknown verdict must fail loudly (rc=$RC9)"
[ "$(cat "$F9")" = "$BEFORE" ] \
  && ok "unknown verdict: the artifact is left untouched (no partial stamp)" \
  || no "a rejected verdict must not mutate the artifact"

# ════ T10 — stderr is clean on the success path (the battery's empty-stderr gate) ════
F10="$WORK/quiet.sh"; mk_sh "$F10"
ERR=$(bash "$SCRIPT" "$F10" pass guv:reviewer 2>&1 >/dev/null)
[ -z "$ERR" ] \
  && ok "success path emits nothing to stderr (battery empty-stderr gate)" \
  || no "success path leaked to stderr: $ERR"

# ════ T11 — a marker SUBSTRING off line-start does NOT fool detection (silent-no-op regression) ════
# A UAT that tests this very feature echoes/greps the stamp text, so '# QA:' appears
# MID-LINE with NO real line-start stamp. A substring-scoped detector takes the replace
# branch, the line-anchored rewrite matches nothing, the file is written back verbatim —
# yet the stamp is echoed and the run exits 0: a silent no-op reported as success (the
# exact anti-pattern [18.2] kills). Detection must use the SAME line-start predicate as
# the rewrite, so this case INSERTS a real stamp instead of no-op'ing.
F11="$WORK/echoes-marker.sh"
cat > "$F11" <<'EOF'
#!/bin/bash
set -euo pipefail
# This UAT verifies the stamp writer:
echo "expected a '# QA: PASS' line in the header"
grep -qE '^# QA:' "$out" && echo "stamped"
EOF
N11_before=$(grep -cE '^# QA:' "$F11")          # 0 — only off-line-start substrings exist
OUT11=$(bash "$SCRIPT" "$F11" pass guv:reviewer "0 findings" 2>/dev/null); RC11=$?
N11_after=$(grep -cE '^# QA: PASS' "$F11")
[ "$RC11" -eq 0 ] && [ "$N11_before" -eq 0 ] && [ "$N11_after" -eq 1 ] \
  && ok "off-line-start marker doesn't fool detection: a real stamp is INSERTED, not a silent no-op" \
  || no "an off-line-start '# QA:' substring must not block insertion (before=$N11_before after=$N11_after rc=$RC11)"
grep -q "expected a '# QA: PASS' line in the header" "$F11" \
  && ok "the marker-substring body lines survive (only a real stamp line is added)" \
  || no "stamping must not rewrite a marker-substring body line"

# ════ T12 — pass/needs-work MUST name a reviewer; unvetted may omit it (Rule 14) ════
# The by-name vet is what gives a PASS/NEEDS WORK its meaning — an unattributed verdict
# is the unaccountable stamp [18.2] exists to prevent, so it is a loud stop, not a
# "vetted by review" default. unvetted attributes to no one ("review did not run").
F12="$WORK/noreviewer.sh"; mk_sh "$F12"; B12=$(cat "$F12")
bash "$SCRIPT" "$F12" pass >/dev/null 2>&1; RC12=$?
[ "$RC12" -ne 0 ] && [ "$(cat "$F12")" = "$B12" ] \
  && ok "pass without a reviewer → loud fail, artifact untouched (a pass must be attributable)" \
  || no "a pass with no reviewer must fail loudly and not mutate (rc=$RC12)"
bash "$SCRIPT" "$F12" needs-work >/dev/null 2>&1; RC12b=$?
[ "$RC12b" -ne 0 ] \
  && ok "needs-work without a reviewer → loud fail (an unattributed NEEDS WORK is rejected too)" \
  || no "needs-work with no reviewer must fail loudly (rc=$RC12b)"
F12c="$WORK/unvetted-noreviewer.sh"; mk_sh "$F12c"
bash "$SCRIPT" "$F12c" unvetted >/dev/null 2>&1; RC12c=$?
[ "$RC12c" -eq 0 ] && grep -qE '^# QA: UNVETTED' "$F12c" \
  && ok "unvetted without a reviewer → succeeds (it names no one, by design)" \
  || no "unvetted should not require a reviewer (rc=$RC12c)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
