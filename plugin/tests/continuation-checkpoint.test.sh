#!/bin/bash
# .claude/tests/continuation-checkpoint.test.sh
# [14.3] — the PreCompact continuation-checkpoint hook persists continuation
# state to disk before compaction proceeds. These tests encode the intent
# (Rule 8), not just "runs without crashing":
#   - it captures the FOUR continuation fields a post-compaction resume needs:
#     active deliverable, resolver frontier, git HEAD, and burn/budget;
#   - the active deliverable RECONCILES the in-flight signal with the resolver serial
#     ([14.6]): the latest CODE-repo commit's conventional [N.N] tag wins WHILE that
#     deliverable is still open (committed-but-not-yet-marked-✅ work diverges from the
#     serial — observed 3× in the Phase-14 dogfood), else it falls to the serial;
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
[ "$(jq -r '.code_root' <<<"$J" 2>/dev/null)" = "null" ] && ok "full: code_root null in single-repo (the [14.6] split field stays absent without roots.code)" || no "full: code_root should be null single-repo (got $(jq -r '.code_root' <<<"$J" 2>/dev/null))"

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

# ── Fixture H: in-flight reconcile ([14.6]) — the latest CODE commit's [N.N] tag
# OVERRIDES the resolver serial when that deliverable is still OPEN. The serial (first
# ready) is 6.2, but a commit tagged [6.3] (also open) means 6.3 is the work actually in
# flight (committed-but-not-yet-marked-✅) — the fix for the 3×-observed "the resume named
# the serial pick, not the in-flight deliverable" divergence.
H="$WORK/inflight"; mkdir -p "$H/.claude"
write_tracker "$H"
( cd "$H" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -q -m init \
    && git commit -q --allow-empty -m 'feat([6.3]): wip on the mutation primitive' ) >/dev/null 2>&1
run "$H" "$(payload manual)"
J=$(cat "$H/$CKPT" 2>/dev/null)
[ "$(jq -r '.active_deliverable' <<<"$J" 2>/dev/null)" = "6.3" ] && ok "inflight: active = the in-flight commit tag [6.3], NOT the serial 6.2 (the [14.6] reconcile)" || no "inflight: active_deliverable should be 6.3 (got $(jq -r '.active_deliverable' <<<"$J" 2>/dev/null))"

# ── Fixture I: a tag for a CLOSED (✅) deliverable falls back to the serial — the
# in-flight signal only wins while its deliverable is still open; a tag for a just-
# finished deliverable must NOT resume finished work, so the resolver serial governs.
I="$WORK/closed-tag"; mkdir -p "$I/.claude"
write_tracker "$I"
( cd "$I" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -q -m init \
    && git commit -q --allow-empty -m 'feat([6.1]): grammar amendment landed' ) >/dev/null 2>&1
run "$I" "$(payload manual)"
J=$(cat "$I/$CKPT" 2>/dev/null)
[ "$(jq -r '.active_deliverable' <<<"$J" 2>/dev/null)" = "6.2" ] && ok "closed-tag: a [6.1]✅ tag is ignored → active falls to the serial 6.2 (don't resume finished work)" || no "closed-tag: active_deliverable should be 6.2 (got $(jq -r '.active_deliverable' <<<"$J" 2>/dev/null))"

# ── Fixture H2: an UNTAGGED latest commit (chore/docs) → the serial governs, unchanged.
# Pins that the reconcile only fires on a real deliverable tag, not on every commit.
H2="$WORK/untagged"; mkdir -p "$H2/.claude"
write_tracker "$H2"
( cd "$H2" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -q -m init \
    && git commit -q --allow-empty -m 'chore(render): regenerate status views' ) >/dev/null 2>&1
run "$H2" "$(payload manual)"
J=$(cat "$H2/$CKPT" 2>/dev/null)
[ "$(jq -r '.active_deliverable' <<<"$J" 2>/dev/null)" = "6.2" ] && ok "untagged: an untagged latest commit leaves active = the serial 6.2 (reconcile fires only on a tag)" || no "untagged: active_deliverable should be 6.2 (got $(jq -r '.active_deliverable' <<<"$J" 2>/dev/null))"

# ── Fixture H3: a deliverable tag UNDER an untagged chore commit ([14.6]) — the REAL guv
# topology: a post-commit `chore(render)` lands ON TOP of the deliverable commit, so the
# in-flight tag is NOT at HEAD. The reconcile scans recent commits (not just HEAD) and picks
# the most-recent DELIVERABLE tag, seeing through the chore. Pins the head-1-over-N ordering:
# a regression that only read HEAD (or reversed the order) would miss the in-flight deliverable.
H3="$WORK/tag-under-chore"; mkdir -p "$H3/.claude"
write_tracker "$H3"
( cd "$H3" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -q -m init \
    && git commit -q --allow-empty -m 'feat([6.3]): wip on the mutation primitive' \
    && git commit -q --allow-empty -m 'chore(render): regenerate status views' ) >/dev/null 2>&1
run "$H3" "$(payload manual)"
J=$(cat "$H3/$CKPT" 2>/dev/null)
[ "$(jq -r '.active_deliverable' <<<"$J" 2>/dev/null)" = "6.3" ] && ok "tag-under-chore: reconcile sees through an untagged chore on top to the in-flight [6.3] (the real post-commit-hook topology, not just HEAD)" || no "tag-under-chore: active_deliverable should be 6.3 (got $(jq -r '.active_deliverable' <<<"$J" 2>/dev/null))"

# ── Fixture J: SPLIT topology ([14.6]) — git state is measured against roots.code (the
# DELIVERABLE repo), NOT the control-plane root the hook runs in. The control plane is CLEAN;
# the code repo has in-flight work. Pre-fix the hook measured ROOT (the clean control plane)
# and reported git_dirty_paths=0 — so the resume said "clean tree" while a deliverable was
# mid-flight in roots.code (the dogfooded dirty-tree resume crux). The checkpoint must report
# the CODE repo's HEAD + dirty count and carry code_root so the resume can target the right repo.
SPLIT="$WORK/split-cp"; mkdir -p "$SPLIT/.claude"
write_tracker "$SPLIT"
CODEREPO="$WORK/split-code"; mkdir -p "$CODEREPO"
( cd "$CODEREPO" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'src\n' > src.txt && git add -A && git commit -q -m init \
    && printf 'wip\n' > inflight.txt ) >/dev/null 2>&1   # inflight.txt uncommitted → dirty
CODEREPO_HEAD=$(git -C "$CODEREPO" rev-parse --short HEAD 2>/dev/null)
printf '%s\n' "{\"roots\":{\"code\":\"$CODEREPO\"}}" > "$SPLIT/.claude/project.json"
# the control plane is itself a CLEAN git repo (0 dirty) — proving the count came from the
# code repo and not the root the hook runs in.
( cd "$SPLIT" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -q -m 'control-plane init' ) >/dev/null 2>&1
run "$SPLIT" "$(payload manual)"
J=$(cat "$SPLIT/$CKPT" 2>/dev/null)
[ "$(jq -r '.git_dirty_paths' <<<"$J" 2>/dev/null)" -ge 1 ] 2>/dev/null && ok "split: git_dirty_paths counts the CODE repo's in-flight work, not the clean control plane (the [14.6] dirty-tree fix)" || no "split: git_dirty_paths should be >= 1 from roots.code (got $(jq -r '.git_dirty_paths' <<<"$J" 2>/dev/null))"
[ "$(jq -r '.git_head' <<<"$J" 2>/dev/null)" = "$CODEREPO_HEAD" ] && ok "split: git_head is the CODE repo's HEAD ($CODEREPO_HEAD), not the control plane's" || no "split: git_head should be the code repo HEAD $CODEREPO_HEAD (got $(jq -r '.git_head' <<<"$J" 2>/dev/null))"
[ "$(jq -r '.code_root' <<<"$J" 2>/dev/null)" = "$CODEREPO" ] && ok "split: code_root carries roots.code so the resume can target git -C <code_root>" || no "split: code_root should be $CODEREPO (got $(jq -r '.code_root' <<<"$J" 2>/dev/null))"

# ── SEAM ([14.6] end-to-end): the resume hook ([14.4]) consumes THIS producer-written
# checkpoint. The two unit suites each hand-write their own JSON, so only this run exercises
# both halves of the loop against the SAME on-disk checkpoint — pinning the code_root field
# name across the producer→consumer seam. The resume breadcrumb must name the code repo and
# target git -C <code_root>, proving a split-topology deliverable resumes at the repo holding
# the in-flight work (the dogfooded crux, fixed at both ends).
RESUME_HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/continuation-resume.sh"
RPL='{"hook_event_name":"SessionStart","source":"compact","model":"claude-opus-4-8[1m]","session_id":"s","transcript_path":"/tmp/p.jsonl","cwd":"/nowhere"}'
RAC=$(printf '%s' "$RPL" | CLAUDE_PROJECT_DIR="$SPLIT" bash "$RESUME_HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
printf '%s' "$RAC" | grep -qi "code repo" && ok "seam: the resume hook consumes the producer's code_root → breadcrumb names the code repo ([14.6] end-to-end)" || no "seam: resume breadcrumb should name the code repo from the real checkpoint (ctx=$RAC)"
printf '%s' "$RAC" | grep -q "git -C $CODEREPO" && ok "seam: the resume targets git -C <code_root> = the real roots.code path" || no "seam: resume should target git -C $CODEREPO (ctx=$RAC)"

# ── Fixture K: NAMED-MAP topology ([11.2]/[14.6]) — roots.code as a named MAP, not a string.
# The shape the string-roots Fixture J could not exercise: a bare `jq -r .roots.code` read
# returns the serialized map OBJECT, which fails path resolution and silently falls back to the
# control plane — so git_head/dirty would measure the clean plane and code_root would be null,
# the exact [14.6] regression for map planes. The fix routes through the roots.sh resolver,
# which knows the map shape and returns codePrimary's path. These assertions FAIL on the bare
# read and pass only when the deliverable repo is resolved through the resolver.
MAPCP="$WORK/map-cp"; mkdir -p "$MAPCP/.claude"
write_tracker "$MAPCP"
MAPCODE="$WORK/map-code"; mkdir -p "$MAPCODE"
( cd "$MAPCODE" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'src\n' > src.txt && git add -A && git commit -q -m init \
    && printf 'wip\n' > inflight.txt ) >/dev/null 2>&1   # inflight.txt uncommitted → dirty
MAPCODE_HEAD=$(git -C "$MAPCODE" rev-parse --short HEAD 2>/dev/null)
# roots.code as a named MAP keyed by repo name; codePrimary names the default. The path is
# absolute so the resolver returns it verbatim (the /* normalization branch).
printf '%s\n' "{\"roots\":{\"code\":{\"primary\":{\"path\":\"$MAPCODE\"}},\"codePrimary\":\"primary\"}}" > "$MAPCP/.claude/project.json"
# clean control plane, as in J — proving the count came from the code repo, not the root.
( cd "$MAPCP" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -q -m 'control-plane init' ) >/dev/null 2>&1
run "$MAPCP" "$(payload manual)"
K=$(cat "$MAPCP/$CKPT" 2>/dev/null)
[ "$(jq -r '.git_dirty_paths' <<<"$K" 2>/dev/null)" -ge 1 ] 2>/dev/null && ok "named-map: git_dirty_paths counts the resolved primary code repo, not the clean control plane (resolver knows the map shape)" || no "named-map: git_dirty_paths should be >= 1 from the resolved roots.code primary (got $(jq -r '.git_dirty_paths' <<<"$K" 2>/dev/null))"
[ "$(jq -r '.git_head' <<<"$K" 2>/dev/null)" = "$MAPCODE_HEAD" ] && ok "named-map: git_head is the resolved primary code repo's HEAD ($MAPCODE_HEAD), not the control plane's (a bare jq .roots.code read would serialize the map and fall back to ROOT)" || no "named-map: git_head should be the code repo HEAD $MAPCODE_HEAD (got $(jq -r '.git_head' <<<"$K" 2>/dev/null))"
[ "$(jq -r '.code_root' <<<"$K" 2>/dev/null)" = "$MAPCODE" ] && ok "named-map: code_root carries the resolved primary path so the resume targets git -C <code_root>" || no "named-map: code_root should be $MAPCODE (got $(jq -r '.code_root' <<<"$K" 2>/dev/null))"

# ── Fixture L: MALFORMED named-map manifest ([14.6] degradation path, Rule 15). The resolver
# LOUD-STOPS (a named map WITHOUT codePrimary — "which repo is the default?" is unanswerable),
# so the hook must NOT silently fall back to the control plane and then report a confident
# "clean tree" measured against the WRONG repo (the silent-wrong-repo class [14.6] exists to
# kill, here on the ERROR path). It must surface the failure LOUD and leave the git signal NULL
# so the resume reads "unavailable", never a fabricated clean tree. These assertions go RED on a
# hook that degrades-to-ROOT (git_head = the control-plane HEAD, git_dirty_paths = 0/"clean").
BADCP="$WORK/badmap-cp"; mkdir -p "$BADCP/.claude"
write_tracker "$BADCP"
BADCODE="$WORK/badmap-code"; mkdir -p "$BADCODE"
( cd "$BADCODE" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'src\n' > src.txt && git add -A && git commit -q -m init \
    && printf 'wip\n' > inflight.txt ) >/dev/null 2>&1
# named MAP but NO codePrimary → roots.sh exits non-zero (the default repo is undetermined).
printf '%s\n' "{\"roots\":{\"code\":{\"primary\":{\"path\":\"$BADCODE\"}}}}" > "$BADCP/.claude/project.json"
# clean control plane — pre-fix the hook would have measured THIS (its HEAD + 0 dirty) and,
# via the resume, told the model the working tree was clean.
( cd "$BADCP" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -q -m 'control-plane init' ) >/dev/null 2>&1
run "$BADCP" "$(payload manual)"
L=$(cat "$BADCP/$CKPT" 2>/dev/null)
[ "$RC" = 0 ] && ok "malformed-map: the hook stays non-blocking (exit 0) — a checkpoint failure never blocks compaction (Rule 15)" || no "malformed-map: hook should exit 0 (got $RC)"
[ "$(jq -r '.git_head' <<<"$L" 2>/dev/null)" = "null" ] && ok "malformed-map: git_head is NULL, not the control-plane HEAD (no silent wrong-repo measurement)" || no "malformed-map: git_head should be null (got $(jq -r '.git_head' <<<"$L" 2>/dev/null))"
[ "$(jq -r '.git_dirty_paths' <<<"$L" 2>/dev/null)" = "null" ] && ok "malformed-map: git_dirty_paths is NULL, not a fabricated 0/clean reading (the [14.6] degradation-path fix)" || no "malformed-map: git_dirty_paths should be null (got $(jq -r '.git_dirty_paths' <<<"$L" 2>/dev/null))"
printf '%s' "$ERR" | grep -q "did not resolve" && ok "malformed-map: the resolution failure is surfaced LOUD on stderr (Rule 15), like the jq-absent rung" || no "malformed-map: expected a loud stderr message naming the resolution failure (got: $ERR)"
# end-to-end seam: the resume breadcrumb must report git state UNAVAILABLE, NEVER 'clean tree'.
RAC2=$(printf '%s' "$RPL" | CLAUDE_PROJECT_DIR="$BADCP" bash "$RESUME_HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
printf '%s' "$RAC2" | grep -qi "unavailable" && ok "malformed-map seam: resume breadcrumb reports git state UNAVAILABLE (not a confident clean tree)" || no "malformed-map seam: resume should say git state unavailable (ctx=$RAC2)"
printf '%s' "$RAC2" | grep -qi "working tree was clean" && no "malformed-map seam: resume must NOT claim 'working tree was clean' on an unresolved manifest" || ok "malformed-map seam: resume does NOT fabricate a clean-tree claim on the degradation path"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
