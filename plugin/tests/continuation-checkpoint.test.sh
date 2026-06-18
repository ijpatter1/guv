#!/bin/bash
# .claude/tests/continuation-checkpoint.test.sh
# [14.3] — the PreCompact continuation-checkpoint hook persists continuation
# state to disk before compaction proceeds. These tests encode the intent
# (Rule 8), not just "runs without crashing":
#   - it captures the FOUR continuation fields a post-compaction resume needs:
#     active deliverable, resolver frontier, git HEAD, and burn/budget;
#   - it resolves its base from $CLAUDE_PROJECT_DIR, NEVER the payload `cwd`
#     ([14.1] finding (e): hook commands run in the launch CWD, not payload cwd);
#   - every field degrades INDEPENDENTLY when its source is absent (Rule 15) —
#     a fresh consumer with no metering log / no budget still gets a checkpoint;
#   - it NEVER blocks compaction: even when it cannot write, it is a loud,
#     non-blocking stop (exit 0 + a message), per the spike's designed ladder.
# Pure bash + jq, no test runner. Run: bash .claude/tests/continuation-checkpoint.test.sh
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/continuation-checkpoint.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

CKPT=".claude/continuation-checkpoint.json"   # written under the resolved root

# A PreCompact payload shaped the way Claude Code sends it (spike §payload).
# args: trigger custom_instructions session_id transcript_path cwd
payload() {
  printf '{"hook_event_name":"PreCompact","trigger":"%s","custom_instructions":%s,"session_id":"%s","transcript_path":"%s","cwd":"%s"}' \
    "${1:-manual}" "${2:-null}" "${3:-sess-1}" "${4:-/tmp/t.jsonl}" "${5:-/nowhere}"
}

# Run the hook with CLAUDE_PROJECT_DIR set to a fixture root. stderr is captured
# (not leaked) so a deliberate loud-stop test does not trip the strict-stderr gate.
# args: root payload [extra-env-unset]
run() {
  local root="$1" pl="$2" errf; errf=$(mktemp)
  if [ "${3:-}" = "unset-project-dir" ]; then
    OUT=$( cd "$root" && printf '%s' "$pl" | env -u CLAUDE_PROJECT_DIR bash "$HOOK" 2>"$errf" ); RC=$?
  else
    OUT=$( printf '%s' "$pl" | CLAUDE_PROJECT_DIR="$root" bash "$HOOK" 2>"$errf" ); RC=$?
  fi
  ERR=$(cat "$errf"); rm -f "$errf"
}

# A minimal VALID GRAMMAR tracker — same shape resolve-ready.test.sh uses.
# 6.1 ✅, rest ⬜ → ready=6.2 6.3 7.1, serial=6.2 (first ready, document order).
write_tracker() {
  mkdir -p "$1/docs"
  cat > "$1/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 6 — Plan as Data**

## Phase 6 — Plan as Data

- ✅ **[6.1]** Grammar amendment `[deps: none]` (2026-06-12, session-001)
- ⬜ **[6.2]** Resolver `[deps: 6.1]`
- ⬜ **[6.3]** Mutation primitive `[deps: 6.1]`
MD
}

# ── Fixture A: everything present (git repo + tracker + budgets + metering) ──
A="$WORK/full"; mkdir -p "$A/.claude/metering"
write_tracker "$A"
cat > "$A/.claude/project.json" <<'JSON'
{ "budgets": { "initiative": { "tokens": 800000 }, "session": { "tokens": 120000 } } }
JSON
# A guv.meter.v1 entry the emitter ([9.5]) sums into cost.by_initiative — the
# checkpoint reads burn through the emitter, never this raw log directly.
printf '%s\n' '{"schema":"guv.meter.v1","ts":"2026-06-10T12:00:00Z","session":"session-2026-06-10-001","deliverable_ids":["6.2"],"model":"m","tokens":{"input":10,"output":20,"cache_read":0,"cache_creation":0},"dollars":null}' \
  > "$A/.claude/metering/metering.ndjson"
( cd "$A" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -q --allow-empty -m init ) >/dev/null 2>&1
A_HEAD=$(git -C "$A" rev-parse --short HEAD 2>/dev/null)

run "$A" "$(payload manual null sess-9 /tmp/x.jsonl /nowhere)"
[ "$RC" -eq 0 ] && ok "full: exit 0 (never blocks compaction)" || no "full: expected exit 0 (rc=$RC, err=$ERR)"
[ -z "$ERR" ] && ok "full: stderr clean on the happy path" || no "full: unexpected stderr: $ERR"
[ -f "$A/$CKPT" ] && ok "full: checkpoint file written" || no "full: no checkpoint at $A/$CKPT"
J=$(cat "$A/$CKPT" 2>/dev/null)
[ "$(jq -r '.git_head' <<<"$J" 2>/dev/null)" = "$A_HEAD" ] && ok "full: git HEAD captured ($A_HEAD)" || no "full: git_head != $A_HEAD (got $(jq -r '.git_head' <<<"$J" 2>/dev/null))"
[ "$(jq -r '.git_dirty_paths' <<<"$J" 2>/dev/null)" = "0" ] && ok "full: git_dirty_paths = 0 on a clean committed tree" || no "full: git_dirty_paths != 0 (got $(jq -r '.git_dirty_paths' <<<"$J" 2>/dev/null))"
[ "$(jq -r '.active_deliverable' <<<"$J" 2>/dev/null)" = "6.2" ] && ok "full: active deliverable = serial pick 6.2" || no "full: active_deliverable != 6.2 (got $(jq -r '.active_deliverable' <<<"$J" 2>/dev/null))"
grep -q 'ready=6.2' <<<"$(jq -r '.frontier' <<<"$J" 2>/dev/null)" && ok "full: resolver frontier captured" || no "full: frontier missing ready=6.2 (got $(jq -r '.frontier' <<<"$J" 2>/dev/null))"
[ "$(jq -r '.budget.initiative' <<<"$J" 2>/dev/null)" = "800000" ] && ok "full: budget setpoint (initiative) captured" || no "full: budget.initiative != 800000 (got $(jq -r '.budget.initiative' <<<"$J" 2>/dev/null))"
[ "$(jq -r '.budget.session' <<<"$J" 2>/dev/null)" = "120000" ] && ok "full: budget setpoint (session) captured" || no "full: budget.session != 120000"
[ "$(jq -r '.burn.source' <<<"$J" 2>/dev/null)" = "emit-metrics.sh" ] && ok "full: burn read through the emitter (one-parser discipline, not the raw log)" || no "full: burn.source != emit-metrics.sh (got $(jq -r '.burn.source' <<<"$J" 2>/dev/null))"
[ "$(jq -r '.burn.by_initiative.tokens.input' <<<"$J" 2>/dev/null)" = "10" ] && ok "full: burn = emitter's slice-aware initiative tokens (input=10)" || no "full: burn.by_initiative.tokens.input != 10 (got $(jq -r '.burn.by_initiative.tokens.input' <<<"$J" 2>/dev/null))"
[ "$(jq -r '.burn.by_initiative.sessions' <<<"$J" 2>/dev/null)" = "1" ] && ok "full: burn = 1 contributing session" || no "full: burn.by_initiative.sessions != 1 (got $(jq -r '.burn.by_initiative.sessions' <<<"$J" 2>/dev/null))"
[ "$(jq -r '.trigger' <<<"$J" 2>/dev/null)" = "manual" ] && ok "full: trigger captured" || no "full: trigger != manual"
[ "$(jq -r '.session_id' <<<"$J" 2>/dev/null)" = "sess-9" ] && ok "full: session_id captured" || no "full: session_id != sess-9"

# ── Auto trigger produces a COMPLETE checkpoint (not just trigger fidelity) ──
# Acceptance names manual AND auto; assert the auto path yields the full envelope,
# not only the trigger/custom_instructions fields.
run "$A" "$(payload auto '"focus the resolver"' sess-9 /tmp/x.jsonl /nowhere)"
J=$(cat "$A/$CKPT" 2>/dev/null)
[ "$(jq -r '.trigger' <<<"$J" 2>/dev/null)" = "auto" ] && ok "auto: trigger=auto captured (matcher fires on both)" || no "auto: trigger != auto"
[ "$(jq -r '.custom_instructions' <<<"$J" 2>/dev/null)" = "focus the resolver" ] && ok "auto: custom_instructions captured" || no "auto: custom_instructions not captured"
[ "$(jq -r '.git_head' <<<"$J" 2>/dev/null)" = "$A_HEAD" ] && ok "auto: full envelope — git HEAD present" || no "auto: git_head missing under auto"
grep -q 'ready=6.2' <<<"$(jq -r '.frontier' <<<"$J" 2>/dev/null)" && ok "auto: full envelope — frontier present" || no "auto: frontier missing under auto"
[ "$(jq -r '.budget.initiative' <<<"$J" 2>/dev/null)" = "800000" ] && ok "auto: full envelope — budget present" || no "auto: budget missing under auto"

# ── Fixture B: no tracker → frontier degrades, rest still captured (Rule 15) ──
B="$WORK/no-tracker"; mkdir -p "$B/.claude"
( cd "$B" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) >/dev/null 2>&1
run "$B" "$(payload manual)"
[ "$RC" -eq 0 ] && ok "no-tracker: exit 0" || no "no-tracker: expected exit 0 (rc=$RC)"
[ -f "$B/$CKPT" ] && ok "no-tracker: checkpoint still written" || no "no-tracker: no checkpoint written"
J=$(cat "$B/$CKPT" 2>/dev/null)
[ -n "$(jq -r '.git_head' <<<"$J" 2>/dev/null)" ] && [ "$(jq -r '.git_head' <<<"$J" 2>/dev/null)" != "null" ] && ok "no-tracker: git HEAD still captured" || no "no-tracker: git_head should survive a missing tracker"
[ "$(jq -r '.frontier' <<<"$J" 2>/dev/null)" = "null" ] && ok "no-tracker: frontier degrades to null (not fabricated)" || no "no-tracker: frontier should be null (got $(jq -r '.frontier' <<<"$J" 2>/dev/null))"

# ── Fixture C: no metering log + no budgets (the fresh-consumer reality) ──
C="$WORK/bare"; mkdir -p "$C/.claude"
write_tracker "$C"
printf '{}\n' > "$C/.claude/project.json"
( cd "$C" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) >/dev/null 2>&1
run "$C" "$(payload manual)"
[ "$RC" -eq 0 ] && ok "bare: exit 0" || no "bare: expected exit 0 (rc=$RC)"
J=$(cat "$C/$CKPT" 2>/dev/null)
[ "$(jq -r '.budget.initiative' <<<"$J" 2>/dev/null)" = "null" ] && ok "bare: absent budget → null (absent means unlimited)" || no "bare: budget.initiative should be null"
[ "$(jq -r '.burn.by_initiative.sessions' <<<"$J" 2>/dev/null)" = "0" ] && ok "bare: absent meter → emitter's zeroed rollup (0 sessions, no fabricated burn)" || no "bare: burn.by_initiative.sessions != 0 (got $(jq -r '.burn.by_initiative.sessions' <<<"$J" 2>/dev/null))"
grep -q 'ready=6.2' <<<"$(jq -r '.frontier' <<<"$J" 2>/dev/null)" && ok "bare: frontier still captured" || no "bare: frontier missing"

# ── Fixture D: $CLAUDE_PROJECT_DIR unset → falls back to launch CWD, NOT payload cwd ──
# The payload's cwd points at /nowhere; the hook must ignore it (finding e) and
# resolve against the process CWD instead.
D="$WORK/cwd-fallback"; mkdir -p "$D/.claude"
write_tracker "$D"
( cd "$D" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) >/dev/null 2>&1
run "$D" "$(payload manual null s /tmp/t.jsonl /nowhere)" unset-project-dir
[ "$RC" -eq 0 ] && ok "cwd-fallback: exit 0" || no "cwd-fallback: expected exit 0 (rc=$RC)"
[ -f "$D/$CKPT" ] && ok "cwd-fallback: resolved base from launch CWD, not payload cwd=/nowhere" || no "cwd-fallback: checkpoint not written under launch CWD"

# ── Fixture E: unwritable root → LOUD, NON-BLOCKING stop (exit 0 + message) ──
# Point the root at a regular file so .claude/ cannot be created underneath it.
touch "$WORK/notadir"
run "$WORK/notadir" "$(payload manual)"
[ "$RC" -eq 0 ] && ok "unwritable: still exit 0 (a checkpoint failure never blocks compaction)" || no "unwritable: expected exit 0 (rc=$RC)"
# The loud stop must NAME the failure (not just print something) and write nothing.
printf '%s' "$ERR" | grep -q "checkpoint NOT written" && ok "unwritable: loud stop names the failure — 'checkpoint NOT written' (Rule 10/15)" || no "unwritable: stderr should name the checkpoint-write failure (got: $ERR)"
[ ! -f "$WORK/notadir/.claude/continuation-checkpoint.json" ] && ok "unwritable: nothing written on the failure path" || no "unwritable: should not have written a checkpoint"

# ── Fixture F: a dirty working tree → git_dirty_paths reflects uncommitted work ──
# git HEAD alone is the last commit; the dirty count tells a resuming model there
# is in-flight work. A clean tree is 0 (fixture A); this pins the non-zero case.
F="$WORK/dirty"; mkdir -p "$F/.claude"
write_tracker "$F"
( cd "$F" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -q -m init && printf 'wip\n' > inflight.txt ) >/dev/null 2>&1
run "$F" "$(payload manual)"
J=$(cat "$F/$CKPT" 2>/dev/null)
[ "$(jq -r '.git_dirty_paths' <<<"$J" 2>/dev/null)" -ge 1 ] 2>/dev/null && ok "dirty: git_dirty_paths >= 1 captures uncommitted work (resume-sufficiency)" || no "dirty: git_dirty_paths should be >= 1 (got $(jq -r '.git_dirty_paths' <<<"$J" 2>/dev/null))"

# ── Fixture G: a non-numeric budget setpoint degrades ONLY that field ──────────
# A hand-broken manifest (the schema would reject a string `tokens`) must not
# collapse the whole envelope: budget goes null, but frontier/HEAD survive — the
# independent-degradation contract (Rule 15).
G="$WORK/bad-budget"; mkdir -p "$G/.claude"
write_tracker "$G"
printf '%s\n' '{"budgets":{"initiative":{"tokens":"800k"}}}' > "$G/.claude/project.json"
( cd "$G" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) >/dev/null 2>&1
run "$G" "$(payload manual)"
[ "$RC" -eq 0 ] && ok "bad-budget: exit 0" || no "bad-budget: expected exit 0 (rc=$RC, err=$ERR)"
[ -f "$G/$CKPT" ] && ok "bad-budget: checkpoint still written (envelope not collapsed)" || no "bad-budget: no checkpoint — a bad budget collapsed the envelope"
J=$(cat "$G/$CKPT" 2>/dev/null)
[ "$(jq -r '.budget.initiative' <<<"$J" 2>/dev/null)" = "null" ] && ok "bad-budget: non-numeric setpoint degrades to null (not crash)" || no "bad-budget: budget.initiative should be null (got $(jq -r '.budget.initiative' <<<"$J" 2>/dev/null))"
grep -q 'ready=6.2' <<<"$(jq -r '.frontier' <<<"$J" 2>/dev/null)" && ok "bad-budget: other fields survive (frontier still captured — independent degradation)" || no "bad-budget: frontier lost — degradation was not independent"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
