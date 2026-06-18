#!/bin/bash
# .claude/tests/continuation-resume.test.sh
# [14.4] — the SessionStart(source=compact) continuation-resume hook reads the
# [14.3] checkpoint and RE-INJECTS continuation state into the rebuilt context so
# the post-compaction model resumes the active deliverable IN PLACE, without a human
# re-priming it (the [14.1] lever-b linchpin). These tests encode the intent (Rule 8):
#   - it fires ONLY on source=compact — startup/resume/clear emit nothing, so a stale
#     checkpoint is never re-injected on a normal session start;
#   - on a compact it re-injects the LOAD-BEARING resume signal: the active
#     deliverable + the git-dirty "N uncommitted paths in flight — read them" pointer
#     + the prior transcript pointer (resume-sufficiency: the continuing model recovers
#     in-flight state from the dirty files itself; the hook hands a MAP, not a chewed
#     plan — distilling a "next step" from a transcript is an LLM judgment call, Rule 12);
#   - it resolves the root from $CLAUDE_PROJECT_DIR, NEVER the payload cwd (finding e);
#   - Rule-15 ladder (the [14.1] lever-b ladder, taken not invented): primary
#     additionalContext → a stdout pointer when jq is absent → (passive) CLAUDE.md-
#     survival floor; a malformed or wrong-SCHEMA checkpoint is a NAMED loud stop,
#     never re-injected as if it were state;
#   - it ALWAYS exits 0 — a SessionStart hook that exits non-zero blocks the session.
# Pure bash + jq, no test runner. Run: bash .claude/tests/continuation-resume.test.sh
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/continuation-resume.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# A SessionStart payload shaped the way Claude Code sends it ([14.1] spike §lever-b):
# hook_event_name, source ∈ {startup,resume,clear,compact}, model, session_id,
# transcript_path, cwd. There is NO `trigger` field (that is PreCompact-only).
# args: source transcript_path cwd
payload() {
  printf '{"hook_event_name":"SessionStart","source":"%s","model":"claude-opus-4-8[1m]","session_id":"sess-1","transcript_path":"%s","cwd":"%s"}' \
    "${1:-compact}" "${2:-/tmp/prior.jsonl}" "${3:-/nowhere}"
}

# Run the hook with CLAUDE_PROJECT_DIR set to a fixture root. stderr is captured (not
# leaked) so a deliberate loud-stop test does not trip the strict-stderr battery gate.
# args: root payload [bindir-for-restricted-PATH]
run() {
  local root="$1" pl="$2" errf; errf=$(mktemp)
  if [ -n "${3:-}" ]; then
    OUT=$( printf '%s' "$pl" | PATH="$3" CLAUDE_PROJECT_DIR="$root" bash "$HOOK" 2>"$errf" ); RC=$?
  else
    OUT=$( printf '%s' "$pl" | CLAUDE_PROJECT_DIR="$root" bash "$HOOK" 2>"$errf" ); RC=$?
  fi
  ERR=$(cat "$errf"); rm -f "$errf"
}

# Write a valid [14.3]-shaped checkpoint under a root's .claude/.
# args: root active_deliverable git_dirty_paths [schema]
write_ckpt() {
  mkdir -p "$1/.claude"
  # default the schema WITHOUT embedding the constructed-name literal the docs-sweep
  # T6 lint bans in shipped scripts (plugin/tests/ ships this file): bash's ${4:-...}
  # default operator abutting the word guv would form it. set -u safe.
  local schema="${4:-}"; [ -n "$schema" ] || schema="guv.continuation-checkpoint/1"
  jq -n \
    --arg active "$2" \
    --argjson dirty "$3" \
    --arg schema "$schema" \
    '{
      schema: $schema,
      checkpoint_at: "2026-06-18T12:00:00Z",
      active_deliverable: (if $active=="" then null else $active end),
      frontier: "mode=GRAMMAR\nphase=14\nready=14.4\nserial=14.4",
      git_head: "abc1234",
      git_dirty_paths: $dirty,
      budget: { initiative: 800000, session: 120000 },
      burn: { source: "emit-metrics.sh", by_initiative: {sessions: 3} },
      transcript_path: "/tmp/prior.jsonl"
    }' > "$1/.claude/continuation-checkpoint.json"
}

# The additionalContext string the hook re-injected (empty if none).
ac() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

# ── A: source=compact + valid checkpoint → additionalContext re-injected (primary) ──
A="$WORK/compact"; write_ckpt "$A" "14.4" 2
run "$A" "$(payload compact /tmp/prior.jsonl /nowhere)"
[ "$RC" -eq 0 ] && ok "compact: exit 0 (a SessionStart hook must never block the session)" || no "compact: expected exit 0 (rc=$RC, err=$ERR)"
[ -z "$ERR" ] && ok "compact: stderr clean on the happy path" || no "compact: unexpected stderr: $ERR"
[ -n "$(ac)" ] && ok "compact: additionalContext envelope emitted (primary rung)" || no "compact: no additionalContext (out=$OUT)"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null 2>&1 && ok "compact: envelope names hookEventName=SessionStart" || no "compact: envelope hookEventName wrong"
ac | grep -q "14.4" && ok "compact: active deliverable (14.4) re-injected — the resume target" || no "compact: active deliverable 14.4 missing from context (ctx=$(ac))"
# the git-dirty signal is the resume-sufficiency crux: it points the model at the files
ac | grep -qi "uncommitted" && ac | grep -q "read them" && ok "compact: re-injects the 'uncommitted … read them' signal (resume-sufficiency: model recovers in-flight state from the files)" || no "compact: missing the uncommitted/read-them signal (ctx=$(ac))"
ac | grep -q "2 uncommitted" && ok "compact: the actual dirty count (2) is surfaced" || no "compact: dirty count 2 not surfaced (ctx=$(ac))"
ac | grep -q "/tmp/prior.jsonl" && ok "compact: prior transcript pointer re-injected (deeper recovery rung)" || no "compact: transcript pointer missing (ctx=$(ac))"
ac | grep -q "initiative=800000" && ok "compact: budget posture re-injected" || no "compact: budget posture missing (ctx=$(ac))"

# ── B: clean tree → states clean, no FALSE in-flight-work signal ──
B="$WORK/clean"; write_ckpt "$B" "14.4" 0
run "$B" "$(payload compact)"
ac | grep -qi "working tree was clean" && ok "clean: states the working tree was clean at checkpoint" || no "clean: clean-tree case not stated (ctx=$(ac))"
ac | grep -q "read them" && no "clean: must NOT tell the model to read uncommitted files on a clean tree" || ok "clean: no spurious 'read them' on a clean tree"

# ── C: scope gate — startup/resume/clear emit NOTHING even with a checkpoint present ──
# Otherwise the hook would re-inject a stale checkpoint on every normal session start.
for src in startup resume clear; do
  run "$A" "$(payload $src)"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && ok "scope: source=$src emits nothing (only a compact is a resume)" || no "scope: source=$src should emit nothing (rc=$RC, out=$OUT, err=$ERR)"
done

# ── D: source=compact but NO checkpoint → emit nothing, exit 0 (floor carries it) ──
D="$WORK/no-ckpt"; mkdir -p "$D/.claude"
run "$D" "$(payload compact)"
[ "$RC" -eq 0 ] && ok "no-ckpt: exit 0" || no "no-ckpt: expected exit 0 (rc=$RC)"
[ -z "$OUT" ] && ok "no-ckpt: nothing re-injected — the CLAUDE.md-survival floor carries the resume (Rule 15 rung 3)" || no "no-ckpt: should emit nothing (out=$OUT)"

# ── E: malformed checkpoint (not JSON) → NAMED loud stop to stderr, exit 0, no inject ──
E="$WORK/malformed"; mkdir -p "$E/.claude"; printf 'not json{' > "$E/.claude/continuation-checkpoint.json"
run "$E" "$(payload compact)"
[ "$RC" -eq 0 ] && ok "malformed: still exit 0 (never blocks the session)" || no "malformed: expected exit 0 (rc=$RC)"
[ -z "$(ac)" ] && ok "malformed: nothing re-injected (a broken checkpoint is not state)" || no "malformed: must not re-inject a malformed checkpoint (ctx=$(ac))"
printf '%s' "$ERR" | grep -q "NOT re-injected" && ok "malformed: loud stop NAMES the failure — 'NOT re-injected' (Rule 10/15)" || no "malformed: stderr should name the failure (got: $ERR)"

# ── F: unrecognized schema → NAMED loud stop, exit 0 (version gate; lets /1 be settled) ──
F="$WORK/wrong-schema"; write_ckpt "$F" "14.4" 1 "guv.continuation-checkpoint/2"
run "$F" "$(payload compact)"
[ "$RC" -eq 0 ] && ok "wrong-schema: exit 0" || no "wrong-schema: expected exit 0 (rc=$RC)"
[ -z "$(ac)" ] && ok "wrong-schema: an incompatible /2 checkpoint is NOT consumed as if it were /1" || no "wrong-schema: must not consume an unknown schema (ctx=$(ac))"
printf '%s' "$ERR" | grep -q "schema" && ok "wrong-schema: loud stop names the schema mismatch" || no "wrong-schema: stderr should name the schema mismatch (got: $ERR)"

# ── G: finding (e) — root resolves from $CLAUDE_PROJECT_DIR, NOT the payload cwd ──
# The checkpoint lives only under the resolved root; the payload cwd points at /nowhere.
# A re-injected context proves the hook read from $CLAUDE_PROJECT_DIR, not payload cwd.
G="$WORK/finding-e"; write_ckpt "$G" "14.4" 0
run "$G" "$(payload compact /tmp/prior.jsonl /nowhere)"
[ -n "$(ac)" ] && ok "finding-e: read the checkpoint from \$CLAUDE_PROJECT_DIR, ignoring payload cwd=/nowhere" || no "finding-e: should have resolved root from CLAUDE_PROJECT_DIR (ctx=$(ac))"

# ── H: jq absent → stdout-pointer rung (Rule 15 rung 2), exit 0 ──
# Restrict PATH to a bin with `cat` only (the one external before the jq check), so
# `command -v jq` fails. A checkpoint is present, so the terse pointer must be emitted.
H="$WORK/no-jq"; write_ckpt "$H" "14.4" 1
BIN="$WORK/bin"; mkdir -p "$BIN"
ln -s "$(command -v cat)" "$BIN/cat"; ln -s "$(command -v bash)" "$BIN/bash"
run "$H" "$(payload compact)" "$BIN"
[ "$RC" -eq 0 ] && ok "no-jq: exit 0" || no "no-jq: expected exit 0 (rc=$RC, err=$ERR)"
printf '%s' "$OUT" | grep -q "continuation-checkpoint.json" && ok "no-jq: emits a stdout pointer to the on-disk checkpoint (Rule 15 rung 2; SessionStart stdout→context is CONFIRMED in [14.1])" || no "no-jq: should emit a stdout pointer (out=$OUT)"

# ── I: active_deliverable null in the checkpoint → graceful, still re-injects ──
I="$WORK/null-active"; write_ckpt "$I" "" 0
run "$I" "$(payload compact)"
[ -n "$(ac)" ] && ac | grep -qi "none resolved" && ok "null-active: degrades to '(none resolved)' rather than a broken envelope" || no "null-active: should re-inject with a graceful placeholder (ctx=$(ac))"

# ── J: fresh / non-git consumer — the producer's all-null shapes (Rule 8/15) ──
# continuation-checkpoint.sh legitimately writes null git_head/git_dirty_paths (a
# non-git consumer), null budget (no manifest), null checkpoint_at (no `date`), and
# null active_deliverable/frontier/transcript_path (no tracker). The consumer must
# still emit a COHERENT breadcrumb — and must NOT claim a "clean tree" when there is
# no git at all (the git-state-unavailable branch).
J="$WORK/fresh"; mkdir -p "$J/.claude"
cat > "$J/.claude/continuation-checkpoint.json" <<'JSON'
{
  "schema": "guv.continuation-checkpoint/1",
  "checkpoint_at": null,
  "active_deliverable": null,
  "frontier": null,
  "git_head": null,
  "git_dirty_paths": null,
  "budget": { "initiative": null, "session": null },
  "burn": null,
  "transcript_path": null
}
JSON
run "$J" "$(payload compact)"
[ "$RC" -eq 0 ] && ok "fresh: exit 0" || no "fresh: expected exit 0 (rc=$RC, err=$ERR)"
[ -n "$(ac)" ] && ok "fresh: still re-injects a breadcrumb from an all-null checkpoint (envelope not collapsed)" || no "fresh: should still re-inject (ctx=$(ac))"
ac | grep -qi "git state: unavailable" && ok "fresh: non-git → 'git state unavailable', NOT a false 'clean tree' claim" || no "fresh: should not claim a clean tree on a non-git checkpoint (ctx=$(ac))"
ac | grep -q "read them" && no "fresh: must not tell the model to read files when git state is unavailable" || ok "fresh: no spurious 'read them' when git state is unavailable"
ac | grep -qi "Budget posture" && no "fresh: must suppress the budget line when both setpoints are null" || ok "fresh: budget line suppressed (both setpoints null)"
ac | grep -qi "Prior transcript" && no "fresh: must suppress the transcript line when absent" || ok "fresh: transcript line suppressed (absent)"
ac | grep -qi "none resolved" && ok "fresh: active deliverable degrades to '(none resolved)'" || no "fresh: active-deliverable placeholder missing (ctx=$(ac))"

# ── K: jq absent + a NON-compact source → still emits the pointer (documented tradeoff) ──
# Without jq the hook cannot parse `source` to gate on compact, so when a checkpoint
# is on disk it emits the terse pointer regardless of source. This is the documented
# tradeoff (a one-line advisory in an already jq-less, degraded environment is lower-
# risk than hand-parsing source). Pin it so it stays intentional, not accidental.
# Reuses fixture H's checkpoint + the cat/bash-only $BIN.
run "$H" "$(payload startup)" "$BIN"
[ "$RC" -eq 0 ] && ok "no-jq/startup: exit 0" || no "no-jq/startup: expected exit 0 (rc=$RC)"
printf '%s' "$OUT" | grep -q "continuation-checkpoint.json" && ok "no-jq/startup: emits the pointer even on a non-compact source (jq absent → cannot gate on source; documented tradeoff)" || no "no-jq/startup: expected the pointer (out=$OUT)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
