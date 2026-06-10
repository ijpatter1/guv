#!/bin/bash
# Tests for the log-feedback skill's data contract: the NDJSON append, the open-count
# query, and the triage rewrite all behave and stay valid. Exercises the exact commands
# the skill documents (no test runner needed). Run: bash .claude/tests/feedback-log.test.sh
set -u

PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p docs/sessions
echo "# s" > docs/sessions/session-2026-06-10-001.md

F=.claude/feedback/feedback.ndjson

# Documented append (Mode 1), parameterized so the test can vary fields.
append() { # $1 category  $2 summary  $3 severity  $4 routing  [$5 id-suffix]
  mkdir -p .claude/feedback
  SESSION=$(ls -t docs/sessions/session-*.md 2>/dev/null | head -1 | xargs -r basename | sed 's/\.md$//')
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -cn \
    --arg id "${TS}-${5:-$RANDOM$RANDOM}" \
    --arg ts "$TS" \
    --arg session "${SESSION:-n/a}" \
    --arg category "$1" \
    --arg artifact ".claude/commands/handoff.md:7" \
    --arg summary "$2" \
    --arg detail "context" \
    --arg severity "$3" \
    --arg routing "$4" \
    '{id:$id, ts:$ts, session:$session, category:$category, artifact:$artifact,
      summary:$summary, detail:$detail, severity:$severity, routing:$routing, status:"open"}' \
    >> "$F"
}

# Guarded count — a missing slurp file makes jq -s both print 0 AND exit non-zero,
# so an `|| echo 0` fallback would double-count. Guard existence instead.
open_count() { [ -f "$F" ] && jq -s '[.[] | select(.status=="open")] | length' "$F" || echo 0; }

# T1 — append creates the dir/file and writes one valid NDJSON line
append "broken-command" "handoff git -C fails pre-scaffold" "major" "upstream" "a"
[ -f "$F" ] && ok "append creates the log file" || no "log file not created"
[ "$(wc -l < "$F" | tr -d ' ')" = 1 ] && ok "one line after one append" || no "expected 1 line"
jq -e . "$F" >/dev/null 2>&1 && ok "line is valid JSON" || no "line is not valid JSON"

# T2 — required fields present and constrained to allowed sets
E=$(tail -1 "$F")
for k in id ts session category artifact summary detail severity routing status; do
  echo "$E" | jq -e --arg k "$k" 'has($k)' >/dev/null || no "missing field: $k"
done
echo "$E" | jq -e '.status=="open"' >/dev/null && ok "status defaults to open" || no "status should be open"
echo "$E" | jq -e '.category|IN("broken-command","inapplicable-setting","doc-drift","manifest-gap","hook-misfire","friction","other")' >/dev/null && ok "category in allowed set" || no "category out of set"
echo "$E" | jq -e '.severity|IN("blocker","major","minor")' >/dev/null && ok "severity in allowed set" || no "severity out of set"
echo "$E" | jq -e '.routing|IN("upstream","local","unsure")' >/dev/null && ok "routing in allowed set" || no "routing out of set"
echo "$E" | jq -e '.session=="session-2026-06-10-001"' >/dev/null && ok "session auto-derived from docs/sessions" || no "session not derived"

# T3 — appends accumulate; open-count query works
append "doc-drift" "README file tree stale" "minor" "local" "b"
[ "$(wc -l < "$F" | tr -d ' ')" = 2 ] && ok "two lines after two appends" || no "expected 2 lines"
[ "$(open_count)" = 2 ] && ok "open-count query returns 2" || no "open-count should be 2 (got $(open_count))"

# T4 — triage rewrite flips ONE entry's status (matched by unique id) and keeps NDJSON valid.
# (ts alone would collide: both appends can land in the same second — the bug `id` fixes.)
ID=$(tail -1 "$F" | jq -r .id)
tmp=$(mktemp) && jq -c --arg id "$ID" --arg s "resolved" 'if .id==$id then .status=$s else . end' "$F" > "$tmp" && mv "$tmp" "$F"
[ "$(open_count)" = 1 ] && ok "triage by id drops open-count to exactly 1" || no "open-count should be 1 after triage (got $(open_count))"
while IFS= read -r line; do echo "$line" | jq -e . >/dev/null 2>&1 || no "post-triage line not valid JSON"; done < "$F"
ok "every line still valid JSON after triage"
[ "$(wc -l < "$F" | tr -d ' ')" = 2 ] && ok "triage preserves entry count (no deletion)" || no "triage should not delete entries"

# T5 — open-count is 0 (not an error) when the log doesn't exist yet
rm -f "$F"
[ "$(open_count)" = 0 ] && ok "missing log: open-count is 0, no error" || no "missing log should yield 0"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
