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

  # T8d — parity guard: the skill must DOCUMENT the provenance-APPENDING form
  # (status flip + note -> detail), not a status-only flip. Since [15.4] moved the
  # jq into feedback.sh, the skill carries the form as documentation of what the
  # helper does (the "under the hood" note); T8f below anchors the live form to the
  # helper SOURCE so the guard catches a real doc->tool regression, not only prose.
  grep -qF '.detail=(.detail + " | " + $note)' "$copy" \
    && ok "triage command documents the provenance-appending (detail) form in $label" \
    || no "$label triage command must append the note to detail (the form /handoff's drain needs), not flip status alone"
done

# T8f — the live parity guard: feedback.sh itself must carry the provenance-
# appending form for both triage-graduate and graduate (status flip + note ->
# detail), never a status-only jq. T16/T8d run against the helper and the doc; this
# grep on the helper SOURCE catches a regression to a status-only rewrite that
# would silently drop provenance — the home of the form is now code, so the parity
# guard lives where the logic does. The (.detail // "") guard tolerates a null detail.
HELPER="$ROOT/.claude/skills/feedback/scripts/feedback.sh"   # the [15.4] mutation helper
grep -qF '.detail=((.detail // "") + " | " + $note)' "$HELPER" \
  && ok "feedback.sh carries the provenance-appending form (status flip + note -> detail)" \
  || no "feedback.sh must append the note to detail on graduate/triage, not flip status alone"

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

# ── feedback.sh mutation-helper guards ([15.4]) ──────────────────────────────
# The triage operations the skill documents as hand-rolled jq are now mechanized
# in .claude/skills/feedback/scripts/feedback.sh (new|list|triage|graduate|note),
# schema-validated, mirroring estimate.sh/replan.sh. These tests exercise the
# helper directly (Rule 8 — verify intent: the schema rejects, the round-trip is
# byte-stable, the provenance note is required on a graduate). The skill's inline
# jq must POINT at this helper (T8e), so a deterministic transform is code, not a
# pasted command (Rule 12). $HELPER is defined at T8f above.
[ -x "$HELPER" ] && ok "feedback.sh helper exists and is executable" || no "feedback.sh helper missing or not executable: $HELPER"

# A fresh log for the helper tests, isolated from the documented-jq fixtures above.
HF="$WORK/helper.ndjson"
rm -f "$HF"

# T11 — `new` appends a schema-valid entry (status open) and creates the file.
bash "$HELPER" new --log "$HF" \
  --category broken-command --artifact "/phase" \
  --summary "helper new appends one entry" --detail "ctx" \
  --severity major --routing upstream >/dev/null 2>&1 \
  && ok "new exits 0 on a well-formed entry" || no "new should accept a well-formed entry"
[ -f "$HF" ] && ok "new creates the log file" || no "new did not create the log"
[ "$(wc -l < "$HF" | tr -d ' ')" = 1 ] && ok "new writes exactly one NDJSON line" || no "new should write one line"
NEW_ENTRY=$(tail -1 "$HF")
echo "$NEW_ENTRY" | jq -e . >/dev/null 2>&1 && ok "new line is valid JSON" || no "new line is not valid JSON"
for k in id ts session category artifact summary detail severity routing status; do
  echo "$NEW_ENTRY" | jq -e --arg k "$k" 'has($k)' >/dev/null || no "new entry missing required field: $k"
done
echo "$NEW_ENTRY" | jq -e '.status=="open"' >/dev/null && ok "new entry defaults status to open" || no "new entry status should be open"

# T12 — `new` REJECTS an out-of-set category/severity/routing (schema validation,
# not just shape). A bad enum value must be refused, not silently written.
LINES_BEFORE=$(wc -l < "$HF" | tr -d ' ')
bash "$HELPER" new --log "$HF" --category bogus-cat \
  --summary "bad category" --severity major --routing upstream >/dev/null 2>&1 \
  && no "new should REJECT an unknown category" || ok "new rejects an unknown category"
bash "$HELPER" new --log "$HF" --category friction \
  --summary "bad severity" --severity catastrophic --routing upstream >/dev/null 2>&1 \
  && no "new should REJECT an unknown severity" || ok "new rejects an unknown severity"
bash "$HELPER" new --log "$HF" --category friction \
  --summary "bad routing" --severity minor --routing sideways >/dev/null 2>&1 \
  && no "new should REJECT an unknown routing" || ok "new rejects an unknown routing"
[ "$(wc -l < "$HF" | tr -d ' ')" = "$LINES_BEFORE" ] \
  && ok "rejected new writes nothing (log line count unchanged)" || no "a rejected new must not append"

# T13 — `list` surfaces open entries (id present); a triaged entry leaves the list.
bash "$HELPER" list --log "$HF" 2>/dev/null | grep -qF "$(echo "$NEW_ENTRY" | jq -r .id)" \
  && ok "list shows the open entry by id" || no "list should show the open entry"

# T14 — `triage ID STATUS` flips ONE entry by unique id and keeps NDJSON valid.
TID=$(echo "$NEW_ENTRY" | jq -r .id)
bash "$HELPER" triage "$TID" resolved --log "$HF" >/dev/null 2>&1 \
  && ok "triage exits 0 on a known id + allowed status" || no "triage should accept a known id + allowed status"
ENT=$(jq -c --arg id "$TID" 'select(.id==$id)' "$HF")
[ "$(echo "$ENT" | jq -r .status)" = "resolved" ] && ok "triage sets the terminal status" || no "triage should set status=resolved"
bash "$HELPER" list --log "$HF" 2>/dev/null | grep -qF "$TID" \
  && no "triaged entry must drop out of the open list" || ok "triaged entry leaves the open list"

# T15 — `triage` REFUSES an unknown status (the allowed set is open/resolved/wontfix/graduated).
bash "$HELPER" triage "$TID" deleted --log "$HF" >/dev/null 2>&1 \
  && no "triage should REJECT an unknown status" || ok "triage rejects an unknown status"

# T16 — `graduate` flips status to graduated AND appends the provenance note to detail.
bash "$HELPER" new --log "$HF" --category friction \
  --summary "to graduate" --detail "orig-detail" --severity minor --routing upstream >/dev/null 2>&1
GID=$(tail -1 "$HF" | jq -r .id)
GNOTE="GRADUATED 2026-06-19 (session-x): resolved by deliverable [15.4]"
bash "$HELPER" graduate "$GID" "$GNOTE" --log "$HF" >/dev/null 2>&1 \
  && ok "graduate exits 0 with a provenance note" || no "graduate should accept a note"
GENT=$(jq -c --arg id "$GID" 'select(.id==$id)' "$HF")
[ "$(echo "$GENT" | jq -r .status)" = "graduated" ] && ok "graduate sets status=graduated" || no "graduate must set status=graduated"
echo "$GENT" | jq -r .detail | grep -qF "$GNOTE" \
  && ok "graduate appends the provenance note to detail" || no "graduate must append the note to detail"
echo "$GENT" | jq -r .detail | grep -qF "orig-detail" \
  && ok "graduate preserves the original detail (appends, not replaces)" || no "graduate must preserve original detail"

# T17 — `graduate` REFUSES without a provenance note (the acceptance bar: a
# graduate CARRIES provenance — an empty/missing note is a loud refusal).
bash "$HELPER" new --log "$HF" --category friction \
  --summary "graduate sans note" --severity minor --routing upstream >/dev/null 2>&1
NGID=$(tail -1 "$HF" | jq -r .id)
bash "$HELPER" graduate "$NGID" --log "$HF" >/dev/null 2>&1 \
  && no "graduate must REFUSE without a provenance note" || ok "graduate refuses without a provenance note"
bash "$HELPER" graduate "$NGID" "" --log "$HF" >/dev/null 2>&1 \
  && no "graduate must REFUSE an empty provenance note" || ok "graduate refuses an empty provenance note"
[ "$(jq -c --arg id "$NGID" 'select(.id==$id)' "$HF" | jq -r .status)" = "open" ] \
  && ok "a refused graduate leaves the entry untouched (still open)" || no "a refused graduate must not mutate the entry"

# T18 — `note` appends a provenance note to detail WITHOUT changing status.
bash "$HELPER" note "$NGID" "investigating | extra context" --log "$HF" >/dev/null 2>&1 \
  && ok "note exits 0" || no "note should accept an id + text"
NENT=$(jq -c --arg id "$NGID" 'select(.id==$id)' "$HF")
echo "$NENT" | jq -r .detail | grep -qF "investigating" && ok "note appends to detail" || no "note must append to detail"
[ "$(echo "$NENT" | jq -r .status)" = "open" ] && ok "note leaves status unchanged" || no "note must not change status"

# T19 — unknown id is a loud refusal, not a silent no-op, for triage/graduate/note.
bash "$HELPER" triage "no-such-id" resolved --log "$HF" >/dev/null 2>&1 \
  && no "triage must REFUSE an unknown id" || ok "triage refuses an unknown id"
bash "$HELPER" graduate "no-such-id" "note" --log "$HF" >/dev/null 2>&1 \
  && no "graduate must REFUSE an unknown id" || ok "graduate refuses an unknown id"
bash "$HELPER" note "no-such-id" "note" --log "$HF" >/dev/null 2>&1 \
  && no "note must REFUSE an unknown id" || ok "note refuses an unknown id"

# T20 — BYTE-STABLE round-trip: a no-op rewrite changes NOTHING. The helper
# rewrites the whole file on every mutation; a triage to the SAME status the entry
# already holds must leave the file byte-identical (append-only / no-churn
# guarantee — the acceptance bar: existing entries round-trip byte-stable).
RT="$WORK/roundtrip.ndjson"
rm -f "$RT"
bash "$HELPER" new --log "$RT" --category doc-drift --artifact "README.md" \
  --summary "round-trip a" --detail "d1" --severity minor --routing local >/dev/null 2>&1
bash "$HELPER" new --log "$RT" --category friction \
  --summary "round-trip b" --detail "d2" --severity major --routing unsure >/dev/null 2>&1
# Resolve the first entry, capture the bytes, then re-triage it to the SAME status.
FIRST_ID=$(head -1 "$RT" | jq -r .id)
bash "$HELPER" triage "$FIRST_ID" wontfix --log "$RT" >/dev/null 2>&1
SUM_BEFORE=$(cksum < "$RT")
bash "$HELPER" triage "$FIRST_ID" wontfix --log "$RT" >/dev/null 2>&1
SUM_AFTER=$(cksum < "$RT")
[ "$SUM_BEFORE" = "$SUM_AFTER" ] \
  && ok "no-op triage is byte-stable (round-trip changes nothing)" || no "a no-op rewrite must leave the file byte-identical"

# T8e — the skill SOURCE documents the helper, not hand-rolled jq, for the
# mutation operations (Rule 12 — a deterministic transform is code, not a pasted
# command). Scoped to SKILL_SRC: the plugin/ mirror is a DERIVED tree rebuilt at
# the build-fanout join, so it carries this repoint only after the join syncs it —
# asserting the mirror in-lane would test JOIN-owned state. The general plugin-vs-
# source parity is guarded by plugin.test.sh, which the join re-greens.
grep -q 'scripts/feedback.sh' "$SKILL_SRC" \
  && ok "skill source references the feedback.sh helper (${SKILL_SRC#"$ROOT"/})" \
  || no "${SKILL_SRC#"$ROOT"/} must point its triage/new/list ops at scripts/feedback.sh, not inline jq (Rule 12)"

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

  # T21 — stderr-clean guard (the empty-stderr gate): the project runner
  # .claude/run-core-tests.sh FAILS any suite that writes to stderr, yet this
  # suite self-reports green (the ok/no condition evaluates first). A leak —
  # e.g. an unescaped backtick in a double-quoted assertion string running a
  # word as a command — would therefore slip a green summary but FAIL the
  # battery at the join. Re-run the suite (FEEDBACK_TEST_INNER guards recursion,
  # as T10 above) capturing stderr ALONE and assert it is empty, so a future
  # leak fails LOUDLY here instead of silently downstream. (Sibling: T7 in
  # feedback-submit.test.sh, "happy-path run keeps stderr clean".)
  FEEDBACK_TEST_INNER=1 bash "$SELF" >/dev/null 2>"$WORK/t21.err"
  [ ! -s "$WORK/t21.err" ] \
    && ok "suite run keeps stderr clean (empty-stderr gate)" \
    || no "suite wrote to stderr (will fail the battery at the join): $(cat "$WORK/t21.err")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
