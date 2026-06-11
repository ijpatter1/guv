#!/bin/bash
# Tests for the log-feedback skill's data contract: the NDJSON append, the open-count
# query, and the triage rewrite all behave and stay valid. Exercises the exact commands
# the skill documents (no test runner needed). T6–T9 guard the skill TEXT: as of
# Phase 5 D3 the feedback drain is live, so the Half-B deferral language must be
# gone from both shipped copies and the live process documented.
# Run: bash .claude/tests/feedback-log.test.sh
set -u

PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_SRC="$ROOT/.claude/skills/log-feedback/SKILL.md"
SKILL_PLUGIN="$ROOT/plugin/skills/log-feedback/SKILL.md"

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

# ── Skill-text guards (Phase 5 D3): the drain is live, the Half-B deferral is gone ──
# The deferral-language class, as a function so T9's positive control can prove
# the detector fires (standing rule: detector-style guards ship a positive control).
has_deferral() { grep -qiE 'half[ -]b|DISTRIBUTION_OPTIONS|not built yet' "$1"; }

# T6 — no Half-B deferral language survives in either shipped copy
for copy in "$SKILL_SRC" "$SKILL_PLUGIN"; do
  if [ -f "$copy" ]; then
    has_deferral "$copy" \
      && no "Half-B deferral language still in ${copy#"$ROOT"/}" \
      || ok "no Half-B deferral language in ${copy#"$ROOT"/}"
  else
    no "skill copy missing: $copy"
  fi
done

# T7 — the live drain is documented: upstream entry → issue/PR → graduated on the
# release that ships the fix; resolved kept distinct (fixed before any release)
grep -q 'issue or PR against the harness repo' "$SKILL_SRC" \
  && ok "drain step 1: upstream entries become issues/PRs" \
  || no "skill must document: upstream entries become an issue or PR against the harness repo"
grep -q 'on the release that ships the fix' "$SKILL_SRC" \
  && ok "drain step 2: graduated flips on the shipping release" \
  || no "skill must document: graduated flips on the release that ships the fix"
grep -q 'fixed before any release' "$SKILL_SRC" \
  && ok "graduated vs resolved distinction present" \
  || no "skill must distinguish resolved (fixed before any release) from graduated"

# T8 — routing:local entries have an explicit live statement in Closing the loop
awk '/^## Closing the loop/,0' "$SKILL_SRC" | grep -q '`local`' \
  && ok "Closing the loop states what local entries do now" \
  || no "Closing the loop must state explicitly what routing:local entries do now"

# T9 — positive control: the deferral detector fires on planted deferral text
# and stays quiet on clean text (proves T6 isn't passing vacuously)
printf 'a local overlay adaptation — _deferred "Half B" work_\n' > planted.md
printf 'entries drain through the live triage flow\n' > clean.md
has_deferral planted.md \
  && ok "positive control: detector fires on planted deferral text" \
  || no "positive control failed: detector missed planted 'Half B'"
has_deferral clean.md \
  && no "positive control failed: detector fired on clean text" \
  || ok "positive control: detector quiet on clean text"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
