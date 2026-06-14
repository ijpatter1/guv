#!/bin/bash
# Tests for .claude/extract-eval-report.sh and the /task chore classification
# ([10.5] tooling ergonomics — feedback id 447210968).
#
# The bug ([10.5], feedback 447210968): the evaluate-parallel workflow returns
# {summary, evaluatorReport, productReviewerReport}, but the Task runtime writes
# its on-disk output as {summary, agentCount, logs, result} where `result` is a
# JSON *STRING* of the workflow's return value. The completion notification then
# truncates the combined report, and surfacing the full report needed a manual
# json-decode round-trip (a python one-liner workaround). The workflow script
# can't change the runtime nesting (no filesystem access), so the fix is an
# extraction helper that decodes the nested `result` and surfaces the FULL
# combined report — both sub-reports present and untruncated.
#
# This suite defends the heart-of-the-deliverable invariants:
#   1. extraction decodes the nested-`result` on-disk shape and surfaces BOTH
#      sub-reports untruncated (the bug — asserted against a fixture output);
#   2. a long report is surfaced whole, not truncated (the truncation is what
#      the deliverable names);
#   3. a missing report fails LOUD (rule 10/15 — never a half review silently);
#   4. /task Step 1 gains a Chore/Maintenance class routing to approve-then-write
#      with NO TDD-test demand, and the three product classes are unchanged.
#
# Pure bash + jq, no test runner. Run: bash .claude/tests/extract-eval-report.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"          # .claude/
ROOT="$(cd "$SRC/.." && pwd)"
SCRIPT="$SRC/extract-eval-report.sh"
SKILL="$SRC/skills/task/SKILL.md"
EVAL_SKILL="$SRC/skills/evaluate/SKILL.md"       # the parallel-variant operator note
HANDOFF="$SRC/commands/handoff.md"               # the /handoff parallel-pass note
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── Fixture: the on-disk output the Task runtime writes for an
# evaluate-parallel run — top-level {summary, agentCount, logs, result} where
# `result` is a JSON STRING of {summary, evaluatorReport, productReviewerReport}.
# The reports are deliberately long so a truncation regression is visible.
EVAL_REPORT="EVALUATOR REPORT
Functionality: PASS. Test Quality: the suite encodes intent.
$(for i in $(seq 1 40); do echo "  finding line $i — detail detail detail detail"; done)
Weighted score: 4.6/5 — PASS WITH ISSUES.
EVAL-REPORT-TAIL-MARKER"
PROD_REPORT="PRODUCT-REVIEWER REPORT
Vision Alignment: on-spec. User Experience: coherent.
$(for i in $(seq 1 40); do echo "  ux note $i — detail detail detail detail"; done)
Weighted score: 4.2/5 — PASS.
PROD-REPORT-TAIL-MARKER"

INNER=$(jq -n --arg s "═══ Evaluation Summary (parallel) ═══ ... Action: proceed ✓" \
              --arg e "$EVAL_REPORT" --arg p "$PROD_REPORT" \
              '{summary:$s, evaluatorReport:$e, productReviewerReport:$p}')
# `result` is the inner object as a JSON STRING (the runtime nesting that broke).
jq -n --arg r "$INNER" \
      '{summary:"truncated preview…", agentCount:3, logs:["scope","review"], result:$r}' \
      > "$WORK/output.json"

# T1 — the helper exists and is the surface under test. Bail loudly if absent.
if [ -f "$SCRIPT" ]; then
  ok "extract-eval-report.sh exists in .claude/"
else
  no "extraction helper missing: $SCRIPT"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# T2 — extraction decodes the nested-`result` shape and surfaces BOTH sub-reports
# (the bug: the reports lived only inside the JSON-string `result` field).
OUT=$(bash "$SCRIPT" "$WORK/output.json" 2>"$WORK/err"); RC=$?
[ $RC -eq 0 ] \
  && ok "extraction exits 0 on a valid nested output" \
  || no "extraction failed (rc=$RC): $(cat "$WORK/err")"
echo "$OUT" | grep -q "EVALUATOR REPORT" \
  && ok "surfaces the evaluator sub-report from the nested result" \
  || no "evaluator sub-report not surfaced from nested result"
echo "$OUT" | grep -q "PRODUCT-REVIEWER REPORT" \
  && ok "surfaces the product-reviewer sub-report from the nested result" \
  || no "product-reviewer sub-report not surfaced from nested result"

# T3 — UNTRUNCATED: the tail markers of BOTH long reports survive. This is the
# bug the deliverable names — a preview/notification cuts mid-report.
echo "$OUT" | grep -q "EVAL-REPORT-TAIL-MARKER" \
  && ok "evaluator report surfaced whole (tail marker present — untruncated)" \
  || no "evaluator report truncated — tail marker missing"
echo "$OUT" | grep -q "PROD-REPORT-TAIL-MARKER" \
  && ok "product report surfaced whole (tail marker present — untruncated)" \
  || no "product report truncated — tail marker missing"
# And the helper does NOT surface the runtime's truncated `summary` preview as
# the report body — the truncated string is what we are escaping.
echo "$OUT" | grep -q "truncated preview…" \
  && no "extraction echoed the runtime's truncated preview — defeats the fix" \
  || ok "extraction does not surface the truncated runtime preview"

# T4 — stderr is clean on the happy path (the empty-stderr gate).
[ -s "$WORK/err" ] \
  && no "stderr not clean on happy path: $(cat "$WORK/err")" \
  || ok "stderr clean on the happy path"

# T5 — already-flat shape (a direct return, no runtime nesting) also works:
# the helper must surface the reports whether `result` is nested or absent.
jq -n --arg e "$EVAL_REPORT" --arg p "$PROD_REPORT" \
      '{summary:"s", evaluatorReport:$e, productReviewerReport:$p}' > "$WORK/flat.json"
OUT2=$(bash "$SCRIPT" "$WORK/flat.json" 2>/dev/null); RC=$?
{ [ $RC -eq 0 ] && echo "$OUT2" | grep -q "EVAL-REPORT-TAIL-MARKER" \
    && echo "$OUT2" | grep -q "PROD-REPORT-TAIL-MARKER"; } \
  && ok "flat (un-nested) output also surfaces both reports whole" \
  || no "flat output shape not handled (rc=$RC)"

# T6 — fail LOUD on a half review: a missing report exits non-zero with a
# message on stderr, never a silent partial (rule 10/15).
jq -n --arg r "$(jq -n --arg e "$EVAL_REPORT" '{summary:"s", evaluatorReport:$e}')" \
      '{summary:"x", result:$r}' > "$WORK/half.json"
OUT3=$(bash "$SCRIPT" "$WORK/half.json" 2>"$WORK/err3"); RC=$?
{ [ $RC -ne 0 ] && [ -s "$WORK/err3" ]; } \
  && ok "missing report fails loud (non-zero, stderr message)" \
  || no "a half review must fail loud, not surface a partial (rc=$RC)"

# T7 — a missing/unreadable file argument fails loud rather than silently
# emitting nothing.
bash "$SCRIPT" "$WORK/does-not-exist.json" >/dev/null 2>"$WORK/err7"; RC=$?
{ [ $RC -ne 0 ] && [ -s "$WORK/err7" ]; } \
  && ok "missing output file fails loud" \
  || no "a missing output file must fail loud (rc=$RC)"

# T7b — summary-absence is TOLERATED (asymmetric with the sub-reports): the
# helper defaults `.summary // ""` and must NOT fail when summary is absent,
# while it fails loud on a missing sub-report (T6). A nested output with both
# reports but no `summary` surfaces both reports at exit 0.
jq -n --arg r "$(jq -n --arg e "$EVAL_REPORT" --arg p "$PROD_REPORT" \
                   '{evaluatorReport:$e, productReviewerReport:$p}')" \
      '{agentCount:3, result:$r}' > "$WORK/nosummary.json"
OUT7b=$(bash "$SCRIPT" "$WORK/nosummary.json" 2>"$WORK/err7b"); RC=$?
{ [ $RC -eq 0 ] && [ ! -s "$WORK/err7b" ] \
    && echo "$OUT7b" | grep -q "EVAL-REPORT-TAIL-MARKER" \
    && echo "$OUT7b" | grep -q "PROD-REPORT-TAIL-MARKER"; } \
  && ok "absent summary is tolerated (both reports still surface, exit 0)" \
  || no "summary-absence must be tolerated, not fail (rc=$RC): $(cat "$WORK/err7b")"

# T7c — the operator's documented path is WIRED to the helper (the deliverable's
# first clause: extract from the on-disk output "rather than the truncated
# completion notification"). The parallel-variant note an operator reads after an
# evaluate-parallel run must name extract-eval-report.sh, else the tool is an
# orphan and the operator hand-decodes the nesting the deliverable set out to
# retire. (Source uses the `.claude/` path; the plugin build path-rewrites it.)
grep -q 'extract-eval-report\.sh' "$EVAL_SKILL" \
  && ok "evaluate SKILL parallel-variant note points at the extraction helper" \
  || no "the parallel-variant note must name extract-eval-report.sh (orphan tool)"
grep -q 'extract-eval-report\.sh' "$HANDOFF" \
  && ok "/handoff parallel-pass note points at the extraction helper" \
  || no "the /handoff parallel-pass note must name extract-eval-report.sh"

# ── /task Step 1 chore classification ──

# T8 — Step 1 gains a Chore/Maintenance classification.
grep -qiE 'chore|maintenance' "$SKILL" \
  && ok "/task Step 1 names a chore/maintenance classification" \
  || no "SKILL.md must add a chore/maintenance classification"

# T9 — it routes to approve-then-write, not TDD. The skill must state the
# no-TDD-test routing for the chore class (this is the deliverable's bar:
# "no TDD-test demand", "approve-then-write").
SKILL_FLAT=$(tr '\n' ' ' < "$SKILL" | tr -s ' ')
echo "$SKILL_FLAT" | grep -qi 'approve-then-write' \
  && ok "chore class routes to approve-then-write" \
  || no "SKILL.md must route chore/maintenance to approve-then-write"

# T10 — the chore class is explicitly for control-plane doc-format / migration
# changes that map to no product deliverable and carry no TDD test.
echo "$SKILL_FLAT" | grep -qiE 'no (TDD|test)' \
  && ok "chore class states no TDD test is required" \
  || no "SKILL.md must state the chore class carries no TDD test"

# T11 — the three PRODUCT classifications are unchanged (their headings persist).
for cls in "Bug Fix" "Quality Improvement" "New Capability"; do
  grep -q "### $cls" "$SKILL" \
    && ok "product classification heading preserved: $cls" \
    || no "product classification heading missing: $cls"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
