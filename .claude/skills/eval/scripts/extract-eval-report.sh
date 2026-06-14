#!/bin/bash
# extract-eval-report.sh — surface the FULL eval-parallel report
# from its on-disk output ([10.5]; feedback id 447210968).
#
# The eval-parallel workflow returns
#   {summary, evaluatorReport, productReviewerReport}
# but the Task runtime writes its on-disk output as
#   {summary, agentCount, logs, result}
# where `result` is a JSON *STRING* of the workflow's return value. The
# completion notification then truncates the combined report, so surfacing the
# whole thing previously needed a manual json-decode round-trip. The workflow
# script can't change the runtime nesting (workflow scripts have no filesystem
# access), so the fix lives here: decode the nested `result` and print the full
# combined report — summary + both sub-reports, untruncated.
#
# Usage: bash extract-eval-report.sh <path-to-output.json>
#   The path is the Task-runtime output file referenced by the run notification.
# Prints the combined report to stdout. Exit 4 on a missing/unreadable file or
# unparseable JSON; exit 5 if a required report field is absent (fail loud — a
# half review is never surfaced as a partial; rules 10 and 15). `summary` is
# non-essential and tolerated when absent (defaults to ""); the two sub-reports
# are the must-haves — that asymmetry is deliberate.
set -u

FILE="${1:-}"
if [ -z "$FILE" ]; then
  echo "extract-eval-report: usage: bash extract-eval-report.sh <output.json>" >&2
  exit 4
fi
if [ ! -f "$FILE" ] || [ ! -r "$FILE" ]; then
  echo "extract-eval-report: cannot read output file: $FILE" >&2
  exit 4
fi
if ! jq -e . "$FILE" >/dev/null 2>&1; then
  echo "extract-eval-report: $FILE is not valid JSON" >&2
  exit 4
fi

# Normalize both shapes to the workflow's documented return object:
#   - runtime nesting: the reports live inside the `result` JSON STRING;
#   - direct return:   the reports are already at the top level.
# If `.result` is a string, decode it; otherwise read the top level. This is a
# deterministic transform — no model in the loop (rule 12).
REPORT=$(jq -r '
  (if (.result | type) == "string" then (.result | fromjson) else . end)
  | { summary:        (.summary // ""),
      evaluatorReport: .evaluatorReport,
      productReviewerReport: .productReviewerReport }
' "$FILE" 2>/dev/null)
if [ -z "$REPORT" ]; then
  echo "extract-eval-report: could not decode the workflow output in $FILE" >&2
  exit 4
fi

# Fail loud on a half review: both sub-reports must be present and non-null.
# A workflow error object (e.g. {error: …, evaluatorReport: null}) lands here.
MISSING=$(printf '%s' "$REPORT" | jq -r '
  [ if (.evaluatorReport // "") == "" then "evaluatorReport" else empty end,
    if (.productReviewerReport // "") == "" then "productReviewerReport" else empty end
  ] | join(", ")
')
if [ -n "$MISSING" ]; then
  echo "extract-eval-report: incomplete report in $FILE — missing: $MISSING (do not proceed on a half review)" >&2
  exit 5
fi

# Print the full combined report, untruncated.
printf '%s' "$REPORT" | jq -r '
  .summary,
  "",
  "─── Evaluator ───",
  .evaluatorReport,
  "",
  "─── Product Reviewer ───",
  .productReviewerReport
'
