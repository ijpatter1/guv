#!/bin/bash
# Tests for the feedback skill's data contract: the NDJSON append, the open-count
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
SELF="$ROOT/.claude/tests/$(basename "$0")"   # absolute — the suite cd's away from $0's base
SKILL_SRC="$ROOT/.claude/skills/feedback/SKILL.md"
SKILL_PLUGIN="$ROOT/plugin/skills/feedback/SKILL.md"

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
    --arg artifact ".claude/skills/handoff/SKILL.md:7" \
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

# T4b — the GRADUATION triage form (the one /handoff's drain step uses) flips
# status AND appends a provenance note to detail. The bare status-only form can't
# do the second half, so /handoff's "name what resolved it" instruction needs
# this exact documented command — exercised verbatim here so the doc can't drift
# back to a status-only command that silently drops provenance.
append "friction" "stale once its fix shipped" "minor" "upstream" "g"
GID=$(tail -1 "$F" | jq -r .id)
BEFORE=$(tail -1 "$F" | jq -r .detail)
NOTE="GRADUATED 2026-06-13 (session-x): resolved by deliverable [9.9]"
tmp=$(mktemp) && jq -c --arg id "$GID" --arg s "graduated" --arg note "$NOTE" \
  'if .id==$id then .status=$s | (if $note=="" then . else .detail=(.detail + " | " + $note) end) else . end' \
  "$F" > "$tmp" && mv "$tmp" "$F"
ENT=$(jq -c --arg id "$GID" 'select(.id==$id)' "$F")
[ "$(echo "$ENT" | jq -r .status)" = "graduated" ] \
  && ok "graduate triage flips status to graduated" || no "graduate triage must set status=graduated"
echo "$ENT" | jq -r .detail | grep -qF "$NOTE" \
  && ok "graduate triage appends the provenance note to detail (what /handoff Step 10 instructs)" \
  || no "graduate triage must append the provenance note to detail, not just flip status"
echo "$ENT" | jq -r .detail | grep -qF "$BEFORE" \
  && ok "graduate triage appends (preserves original detail), does not replace" \
  || no "graduate triage must preserve the original detail context"
while IFS= read -r line; do echo "$line" | jq -e . >/dev/null 2>&1 || no "post-graduate line not valid JSON"; done < "$F"
ok "every line still valid JSON after the graduate triage"

# T5 — open-count is 0 (not an error) when the log doesn't exist yet
rm -f "$F"
[ "$(open_count)" = 0 ] && ok "missing log: open-count is 0, no error" || no "missing log should yield 0"

# ── Skill-text guards (Phase 5 D3): the drain is live, the Half-B deferral is gone ──
# The deferral-language class, as a function so T9's positive control can prove
# the detector fires (standing rule: detector-style guards ship a positive control).
# Flattened first: 'not built yet' wrapping across lines must not hide a
# deferral from this ABSENCE detector (the wrap class, swept in Phase 5 D4).
# 'half[ -]b\b' is boundary-anchored so flattening doesn't make innocent
# cross-line prose ("...the second half\nbecause...") read as a deferral.
has_deferral() { tr '\n' ' ' < "$1" | tr -s ' ' | grep -qiE 'half[ -]b\b|DISTRIBUTION_OPTIONS|not built yet'; }

# The plugin copy exists only where plugin/ does — a template-clone fork may
# delete the generated tree (README's note), and that must skip, not fail.
# In the canonical repo (or any tree keeping plugin/) a missing copy IS a
# failure: the skill ships in both install modes. Array, not word-split — the
# checkout path may contain spaces. FEEDBACK_PLUGIN_TREE is the T10 seam.
COPIES=("$SKILL_SRC")
if [ -d "${FEEDBACK_PLUGIN_TREE:-$ROOT/plugin}" ]; then
  COPIES+=("$SKILL_PLUGIN")
else
  echo "  - plugin/ absent (template-clone fork) — plugin-copy guards skip"
fi

# T6 — no Half-B deferral language survives in any shipped copy
for copy in "${COPIES[@]}"; do
  if [ -f "$copy" ]; then
    has_deferral "$copy" \
      && no "Half-B deferral language still in ${copy#"$ROOT"/}" \
      || ok "no Half-B deferral language in ${copy#"$ROOT"/}"
  else
    no "skill copy missing: $copy"
  fi
done

# T7 — the live drain is documented in every shipped copy (the drain phrases
# carry no slash-commands, so the plugin namespace rewrite leaves them intact):
# upstream entry → issue/PR → graduated on the release that ships the fix;
# resolved kept distinct (fixed before any release)
for copy in "${COPIES[@]}"; do
  label="${copy#"$ROOT"/}"
  # Multi-word phrase guards grep a whitespace-flattened copy — an innocent
  # reflow must not break them (the class swept in Phase 5 D4).
  COPY_FLAT=$(tr '\n' ' ' < "$copy" 2>/dev/null | tr -s ' ')
  echo "$COPY_FLAT" | grep -q 'issue or PR against the guv repo' \
    && ok "drain step 1 (issues/PRs) in $label" \
    || no "$label must document: upstream entries become an issue or PR against the guv repo"
  echo "$COPY_FLAT" | grep -q 'on the release that ships the fix' \
    && ok "drain step 2 (graduated on release) in $label" \
    || no "$label must document: graduated flips on the release that ships the fix"
  echo "$COPY_FLAT" | grep -q 'fixed before any release' \
    && ok "graduated vs resolved distinction in $label" \
    || no "$label must distinguish resolved (fixed before any release) from graduated"

  # T8 — routing:local entries have an explicit live statement in Closing the loop
  awk '/^## Closing the loop/,0' "$copy" | grep -q '`local`' \
    && ok "Closing the loop states what local entries do now in $label" \
    || no "Closing the loop in $label must state what routing:local entries do now"

  # T8b — the sync/dogfooding close path: a dogfooding control plane consumes
  # guv via --sync (not releases), so an upstream entry graduates when
  # its fix lands in source and reaches the plane via sync — the close trigger
  # the release-keyed drain alone left missing. Scoped to Closing the loop, and
  # the anchors carry no slash-commands so the plugin rewrite leaves them intact.
  CL=$(awk '/^## Closing the loop/,0' "$copy" | tr '\n' ' ' | tr -s ' ')
  echo "$CL" | grep -q 'dogfooding control plane' && echo "$CL" | grep -q -- '--sync' \
    && ok "Closing the loop documents the --sync/dogfooding graduation path in $label" \
    || no "Closing the loop in $label must document the --sync/dogfooding close path (fix lands in source -> graduates)"

  # T8d — parity guard: the DOCUMENTED triage command must carry the provenance-
  # APPENDING form (status flip + note -> detail), not a status-only jq. T4b runs
  # its own copy of this jq, so it stays green if the skill reverts to status-only;
  # only this grep on the skill text catches that doc->tool regression (the
  # hand-duplicated-literal-with-no-parity-guard class).
  grep -qF '.detail=(.detail + " | " + $note)' "$copy" \
    && ok "triage command documents the provenance-appending (detail) form in $label" \
    || no "$label triage command must append the note to detail (the form /handoff's drain needs), not flip status alone"
done

# T8c — /handoff Step 10 DRAINS, not just counts: it must propose graduating the
# entries this session resolved and frame that as closing the loop — the
# agent-executable close trigger for the sync model. Both the command source and
# its plugin-skill copy; anchors are slash-command-free (rewrite-stable).
HANDOFF_SRC="$ROOT/.claude/skills/handoff/SKILL.md"
HANDOFF_COPIES=("$HANDOFF_SRC")
if [ -d "${FEEDBACK_PLUGIN_TREE:-$ROOT/plugin}" ]; then
  HANDOFF_COPIES+=("$ROOT/plugin/skills/handoff/SKILL.md")
fi
for copy in "${HANDOFF_COPIES[@]}"; do
  label="${copy#"$ROOT"/}"
  if [ ! -f "$copy" ]; then no "handoff copy missing: $copy"; continue; fi
  HFLAT=$(tr '\n' ' ' < "$copy" | tr -s ' ')
  echo "$HFLAT" | grep -q 'propose graduating' \
    && ok "handoff Step 10 proposes graduations (drains the loop) in $label" \
    || no "$label Step 10 must propose graduating the entries this session resolved, not only count them"
  echo "$HFLAT" | grep -q 'close the loop' \
    && ok "handoff Step 10 frames the drain as closing the loop in $label" \
    || no "$label Step 10 must frame the triage as closing the loop, not only surfacing a count"
done

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

# T10 — fork self-check: with the plugin tree absent the plugin-copy guards
# visibly skip and the suite still exits 0 (output-grepped — exit 0 alone
# would pass in the canonical repo even with the skip branch deleted)
if [ -z "${FEEDBACK_TEST_INNER:-}" ]; then
  INNER=$(FEEDBACK_TEST_INNER=1 FEEDBACK_PLUGIN_TREE="$ROOT/nonexistent-plugin" bash "$SELF" 2>&1)
  if [ $? -eq 0 ] && echo "$INNER" | grep -q "plugin-copy guards skip"; then
    ok "plugin-copy guards visibly skip in a fork that deleted plugin/"
  else
    no "suite must exit 0 and visibly skip plugin-copy guards when plugin/ is absent"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
