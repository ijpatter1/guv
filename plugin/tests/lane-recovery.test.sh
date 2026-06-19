#!/bin/bash
# .claude/tests/lane-recovery.test.sh
# [14.5] — lane / subagent recovery. A fan-out lane is a Task subagent: it runs in
# its own context window, gets NO SessionStart re-injection ([14.1] lever-d), and so
# the [14.4] seamless-continuation path does NOT reach it. Recovery for a lane is
# re-spawn-from-disk, parent-driven. This script is the deterministic core of that
# ladder; these tests encode the intent (Rule 8), not "runs without crashing":
#   - detect: a lane/child context is env-detectable (CLAUDE_CODE_CHILD_SESSION=1),
#     because recovery code must KNOW it has no re-injection rung — a main session
#     does (the [14.4] hook), a child does not;
#   - checkpoint: the lane persists a recovery checkpoint to its worktree disk (the
#     proven rung, [14.1]) carrying what a fresh re-spawned subagent needs to resume
#     — including the git_dirty_paths "read the in-flight work" signal ([14.3]);
#   - assess: the PARENT's re-spawn decision is a deterministic transform on the
#     lane's returned state (Rule 12: routing is code, not model judgment) — a
#     finished lane LANDS, a self-checkpointed lane RE-SPAWNS, a silent/failed lane
#     is a loud STOP (Rule 10/15), never a silent skip;
#   - every field degrades INDEPENDENTLY (Rule 15) and a write/parse failure is a
#     loud NAMED stop, never a guessed verdict.
# Pure bash + jq, no test runner. Run: bash .claude/tests/lane-recovery.test.sh
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/lane-recovery.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# Run the script capturing stdout/stderr/rc separately. stderr is captured (not
# leaked) so a deliberate loud-stop test does not trip the strict-stderr battery gate.
# Everything before `--` is handed to env(1) verbatim (so a case can set VAR=val or
# `-u VAR` to unset); pass nothing before `--` for a plain run.
# args: [env-args...] -- argv...
run() {
  local errf; errf=$(mktemp)
  local env_kv=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do env_kv+=("$1"); shift; done
  shift  # drop the --
  OUT=$( env ${env_kv[@]+"${env_kv[@]}"} bash "$SCRIPT" "$@" 2>"$errf" ); RC=$?
  ERR=$(cat "$errf"); rm -f "$errf"
}

# A git worktree fixture standing in for a lane worktree. $1 dir; remaining args:
# "dirty" leaves an uncommitted file. Returns the short HEAD on stdout.
make_lane() {
  local d="$1"; shift
  mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  case "${1:-}" in dirty) ( cd "$d" && printf 'wip\n' > inflight.txt ) ;; esac
  git -C "$d" rev-parse --short HEAD 2>/dev/null
}

write_output() {  # write_output <dir> <status>
  printf '{"id":"14.5","status":"%s","docFragments":[],"notes":"x"}\n' "$2" > "$1/.lane-output.json"
}

echo "== lane-recovery: detect (the child-session discriminator) =="
# A lane/subagent IS a child context — CLAUDE_CODE_CHILD_SESSION=1 — and gets no
# SessionStart re-injection, so recovery code must detect it from the env.
run CLAUDE_CODE_CHILD_SESSION=1 -- detect
[ "$RC" -eq 0 ] && ok "detect: exit 0 in a child session" || no "detect: expected exit 0 (rc=$RC, err=$ERR)"
printf '%s' "$OUT" | grep -q 'child=1' && ok "detect: child=1 when CLAUDE_CODE_CHILD_SESSION=1 (a lane — no re-injection rung)" || no "detect: expected child=1 (got: $OUT)"
[ -z "$ERR" ] && ok "detect: stderr clean" || no "detect: unexpected stderr: $ERR"
# A main session is NOT a child — it HAS the [14.4] re-injection path.
run -u CLAUDE_CODE_CHILD_SESSION -- detect   # hermetic: ensure it is unset
printf '%s' "$OUT" | grep -q 'child=0' && ok "detect: child=0 when unset (main session — re-injection available)" || no "detect: expected child=0 when unset (got: $OUT)"

echo "== lane-recovery: checkpoint (the disk-write rung the re-spawn seeds from) =="
L="$WORK/lane-dirty"; LH=$(make_lane "$L" dirty)
run -- checkpoint 14.5 --dir "$L" --note "red tests written; green impl of assess pending"
[ "$RC" -eq 0 ] && ok "checkpoint: exit 0 on success" || no "checkpoint: expected exit 0 (rc=$RC, err=$ERR)"
[ -z "$ERR" ] && ok "checkpoint: stderr clean on the happy path" || no "checkpoint: unexpected stderr: $ERR"
CK="$L/.lane-checkpoint.json"
[ -f "$CK" ] && ok "checkpoint: .lane-checkpoint.json written at the worktree root" || no "checkpoint: no checkpoint at $CK"
J=$(cat "$CK" 2>/dev/null)
[ "$(jq -r '.schema' <<<"$J" 2>/dev/null)" = "guv.lane-recovery/1" ] && ok "checkpoint: schema = guv.lane-recovery/1 (versioned, consumable)" || no "checkpoint: schema != guv.lane-recovery/1 (got $(jq -r '.schema' <<<"$J" 2>/dev/null))"
[ "$(jq -r '.deliverable' <<<"$J" 2>/dev/null)" = "14.5" ] && ok "checkpoint: deliverable id captured" || no "checkpoint: deliverable != 14.5"
[ "$(jq -r '.git_head' <<<"$J" 2>/dev/null)" = "$LH" ] && ok "checkpoint: git HEAD captured ($LH)" || no "checkpoint: git_head != $LH (got $(jq -r '.git_head' <<<"$J" 2>/dev/null))"
[ "$(jq -r '.git_dirty_paths' <<<"$J" 2>/dev/null)" -ge 1 ] 2>/dev/null && ok "checkpoint: git_dirty_paths >= 1 — the in-flight work the re-spawn must read ([14.3] resume-sufficiency)" || no "checkpoint: git_dirty_paths should be >= 1 (got $(jq -r '.git_dirty_paths' <<<"$J" 2>/dev/null))"
[ "$(jq -r '.note' <<<"$J" 2>/dev/null)" = "red tests written; green impl of assess pending" ] && ok "checkpoint: note (the re-spawn seed) captured verbatim" || no "checkpoint: note not captured (got $(jq -r '.note' <<<"$J" 2>/dev/null))"
[ "$(jq -r '.checkpoint_at' <<<"$J" 2>/dev/null)" != "null" ] && ok "checkpoint: checkpoint_at timestamp present" || no "checkpoint: checkpoint_at should be set"

# Clean tree → git_dirty_paths = 0 (distinguish clean from non-git null).
LC="$WORK/lane-clean"; make_lane "$LC" >/dev/null
run -- checkpoint 14.5 --dir "$LC"
[ "$(jq -r '.git_dirty_paths' "$LC/.lane-checkpoint.json" 2>/dev/null)" = "0" ] && ok "checkpoint: clean tree → git_dirty_paths = 0 (not null)" || no "checkpoint: clean tree should be 0"
[ "$(jq -r '.note' "$LC/.lane-checkpoint.json" 2>/dev/null)" = "null" ] && ok "checkpoint: absent note → null (not fabricated)" || no "checkpoint: absent note should be null"

# Rule 15 — a non-git dir: git fields degrade to null, checkpoint still written.
LN="$WORK/lane-nongit"; mkdir -p "$LN"
run -- checkpoint 14.5 --dir "$LN"
[ "$RC" -eq 0 ] && ok "non-git: exit 0 (other fields survive)" || no "non-git: expected exit 0 (rc=$RC, err=$ERR)"
[ -f "$LN/.lane-checkpoint.json" ] && ok "non-git: checkpoint still written" || no "non-git: checkpoint should still be written"
[ "$(jq -r '.git_head' "$LN/.lane-checkpoint.json" 2>/dev/null)" = "null" ] && ok "non-git: git_head degrades to null (not fabricated)" || no "non-git: git_head should be null"
[ "$(jq -r '.git_dirty_paths' "$LN/.lane-checkpoint.json" 2>/dev/null)" = "null" ] && ok "non-git: git_dirty_paths null (a non-repo, not a clean 0)" || no "non-git: git_dirty_paths should be null"

# Rule 10/15 — an unwritable worktree dir is a LOUD NAMED stop, non-zero, nothing written.
touch "$WORK/notadir"
run -- checkpoint 14.5 --dir "$WORK/notadir"
[ "$RC" -ne 0 ] && ok "unwritable: non-zero exit (the lane learns its checkpoint did NOT persist)" || no "unwritable: expected non-zero exit (rc=$RC)"
printf '%s' "$ERR" | grep -qi "checkpoint" && ok "unwritable: loud stop names the failure (Rule 10/15)" || no "unwritable: stderr should name the failure (got: $ERR)"

echo "== lane-recovery: assess (the parent's deterministic re-spawn decision, Rule 12) =="
# A finished lane LANDS — proceed to the gate, no re-spawn.
LL="$WORK/assess-ok"; make_lane "$LL" >/dev/null; write_output "$LL" ok
run -- assess 14.5 --dir "$LL"
[ "$RC" -eq 0 ] && ok "land: exit 0" || no "land: expected exit 0 (rc=$RC, err=$ERR)"
printf '%s' "$OUT" | grep -q 'recovery=land' && ok "land: status=ok → recovery=land (a finished lane proceeds to the gate)" || no "land: expected recovery=land (got: $OUT)"

# A self-checkpointed lane (hit its window) RE-SPAWNS, seeded from the checkpoint.
LR="$WORK/assess-respawn"; make_lane "$LR" dirty >/dev/null
run -- checkpoint 14.5 --dir "$LR" --note "phase 2 of 3 done; resume at the assess branch"
run -- assess 14.5 --dir "$LR"
[ "$RC" -eq 0 ] && ok "respawn: exit 0" || no "respawn: expected exit 0 (rc=$RC, err=$ERR)"
printf '%s' "$OUT" | grep -q 'recovery=respawn' && ok "respawn: checkpoint present + not done → recovery=respawn (re-spawn, NOT in-place continue)" || no "respawn: expected recovery=respawn (got: $OUT)"
printf '%s' "$OUT" | grep -q 'resume at the assess branch' && ok "respawn: the note (re-spawn seed) is surfaced to the parent" || no "respawn: note should be surfaced (got: $OUT)"

# A finished lane LANDS even if a stale checkpoint is also present — ok wins.
LB="$WORK/assess-both"; make_lane "$LB" >/dev/null
run -- checkpoint 14.5 --dir "$LB"
write_output "$LB" ok
run -- assess 14.5 --dir "$LB"
printf '%s' "$OUT" | grep -q 'recovery=land' && ok "precedence: status=ok beats a leftover checkpoint → recovery=land" || no "precedence: ok should win (got: $OUT)"

# A failed lane is a LOUD STOP (designed path, Rule 15), not a re-spawn.
LF="$WORK/assess-failed"; make_lane "$LF" >/dev/null; write_output "$LF" failed
run -- assess 14.5 --dir "$LF"
printf '%s' "$OUT" | grep -q 'recovery=fail' && ok "fail: status=failed (no checkpoint) → recovery=fail (loud stop, not re-spawn)" || no "fail: expected recovery=fail (got: $OUT)"
[ "$RC" -ne 0 ] && ok "fail: non-zero exit so the parent loud-stops (designed path, Rule 15)" || no "fail: expected non-zero exit (rc=$RC)"

# A SILENT lane (no sidecar at all) is a loud stop, never a silent skip (Rule 10).
LE="$WORK/assess-empty"; make_lane "$LE" >/dev/null
run -- assess 14.5 --dir "$LE"
printf '%s' "$OUT" | grep -q 'recovery=fail' && ok "no-output: a lane that returned nothing → recovery=fail (Rule 10, never a silent skip)" || no "no-output: expected recovery=fail (got: $OUT)"
[ "$RC" -ne 0 ] && ok "no-output: non-zero exit" || no "no-output: expected non-zero exit (rc=$RC)"

# A lane that DECLARED FAILURE is a loud stop even if a stray checkpoint is also
# present — a declared failure (hit a wall) must never be silently re-spawned. The
# loud stop OUTRANKS the recovery rung (Rule 15: failure selects the safe designed
# path). [14.5] dual-review — the evaluator's assess-precedence finding: the lane-
# builder contract says a real failure writes status=failed and NO checkpoint, so
# this combination is a contract violation, and the code must resolve it to the stop.
LFC="$WORK/assess-failed-and-ckpt"; make_lane "$LFC" dirty >/dev/null
run -- checkpoint 14.5 --dir "$LFC" --note "stray checkpoint beside a failure"
write_output "$LFC" failed
run -- assess 14.5 --dir "$LFC"
printf '%s' "$OUT" | grep -q 'recovery=fail' && ok "precedence: status=failed beats a stray checkpoint → recovery=fail (a declared failure is never silently re-spawned)" || no "precedence: failed must outrank a checkpoint (got: $OUT)"
[ "$RC" -ne 0 ] && ok "precedence: failed+checkpoint exits non-zero (loud stop, not a re-spawn)" || no "precedence: expected non-zero exit (rc=$RC)"

# A lane that returned output with an UNRECOGNISED status (neither ok nor failed) and
# no checkpoint is a loud stop too — but the reason must NAME the offending status,
# not misreport it as "the lane returned nothing" (it DID return output). [14.5]
# dual-review — the evaluator's diagnostic-honesty finding (Rule 10: an accurate loud
# stop the parent/loop can act on, not a misleading one).
LUS="$WORK/assess-unknown-status"; make_lane "$LUS" >/dev/null; write_output "$LUS" complete
run -- assess 14.5 --dir "$LUS"
printf '%s' "$OUT" | grep -q 'recovery=fail' && ok "unknown-status: an unrecognised status → recovery=fail (loud stop)" || no "unknown-status: expected recovery=fail (got: $OUT)"
{ printf '%s' "$OUT" | grep -qi "unrecognized status" && printf '%s' "$OUT" | grep -q "complete"; } && ok "unknown-status: the reason NAMES the status ('complete'), not 'returned nothing' (Rule 10 honesty)" || no "unknown-status: the reason should name the status 'complete', not misreport no output (got: $OUT)"
[ "$RC" -ne 0 ] && ok "unknown-status: non-zero exit (loud stop)" || no "unknown-status: expected non-zero exit (rc=$RC)"

# A MALFORMED checkpoint (and no ok output) is a loud NAMED stop, never a guessed verdict (Rule 15).
LM="$WORK/assess-malformed"; make_lane "$LM" >/dev/null
printf 'not json{{{\n' > "$LM/.lane-checkpoint.json"
run -- assess 14.5 --dir "$LM"
[ "$RC" -ne 0 ] && ok "malformed: non-zero exit (cannot assess)" || no "malformed: expected non-zero exit (rc=$RC)"
printf '%s' "$ERR" | grep -qi "checkpoint" && ok "malformed: loud stop names the bad checkpoint (Rule 15 — no guessed verdict)" || no "malformed: stderr should name the malformed checkpoint (got: $ERR)"

# A WRONG-SCHEMA checkpoint (valid JSON, future/foreign version) is a loud stop too —
# the version gate mirrors the [14.4] resume hook: never consume an unrecognised shape.
LW="$WORK/assess-wrongschema"; make_lane "$LW" >/dev/null
printf '{"schema":"guv.lane-recovery/2","deliverable":"14.5"}\n' > "$LW/.lane-checkpoint.json"
run -- assess 14.5 --dir "$LW"
[ "$RC" -ne 0 ] && ok "wrong-schema: non-zero exit (version skew — cannot assess)" || no "wrong-schema: expected non-zero exit (rc=$RC)"
printf '%s' "$ERR" | grep -qi "schema" && ok "wrong-schema: loud stop names the schema mismatch (Rule 15)" || no "wrong-schema: stderr should name the schema mismatch (got: $ERR)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
