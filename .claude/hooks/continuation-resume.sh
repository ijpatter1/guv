#!/bin/bash
# .claude/hooks/continuation-resume.sh
# SessionStart(source=compact) continuation resume ([14.4]) — the symmetric READER
# for continuation-checkpoint.sh ([14.3]). PreCompact writes the checkpoint; this
# hook re-injects it into the rebuilt context after a compaction via
# hookSpecificOutput.additionalContext, so the continuing model resumes the ACTIVE
# DELIVERABLE in place without a human re-priming it — the [14.1] lever-b linchpin
# (SessionStart source=compact + additionalContext re-injection is CONFIRMED on this
# local 1M session).
#
# SCOPE — fires ONLY on source=compact. session-start.sh already surfaces the LIVE
# dispatch advisory on every source; this hook adds the one thing that hook cannot:
# the PRE-compaction continuation state captured by [14.3] (the active deliverable,
# the in-flight git-dirty signal, the budget posture, the prior transcript pointer).
# On any other source (startup/resume/clear) it emits nothing and exits 0 — re-
# injecting a stale checkpoint on a normal start would be noise, not continuation.
#
# TWO HOOKS ON ONE COMPACT — on a compact both session-start.sh and this hook emit
# hookSpecificOutput.additionalContext. Claude Code's documented "Multiple Hooks &
# Aggregation" contract CONCATENATES every additionalContext value into context, so
# both reach the continuing model (CONFIRMED(docs)). But the docs do NOT guarantee
# the ORDER of the concatenation (hooks run in parallel), so the breadcrumb makes NO
# positional reference to the other hook's output — it points at "a separate session-
# open dispatch advisory", not one "above". The two voices are complementary by
# design: session-start.sh carries the LIVE re-resolved frontier (authoritative for
# the current pick), this carries the PRE-compaction state (where I was + recover my
# work), and the breadcrumb defers to the live frontier rather than competing. The
# specific two-hooks-on-one-compact path rests on CONFIRMED(docs) — flag for empirical
# confirmation when [14.6] dogfoods the end-to-end loop under a real /compact.
#
# RESUME-SUFFICIENCY ([14.4] design decision) — the hook re-injects the structured
# checkpoint as a MAP, not a chewed plan: active deliverable + "you had N uncommitted
# paths in flight, read them" + the transcript pointer. The continuing model recovers
# the in-flight working state by reading those dirty files itself — distilling a
# semantic "next step" from a transcript is an LLM judgment call, not a job for a
# deterministic bash hook (Rule 12). The transcript pointer keeps the deeper rung
# reachable without the hook parsing it. So guv.continuation-checkpoint/1 is consumed
# end-to-end: a deeper transcript-mined state would be a deliberate /2 bump, gated below.
#
# WIRING ([14.1] finding (e)) — resolve the project root from $CLAUDE_PROJECT_DIR,
# never the payload `cwd`. The settings.json command stays relative so build-plugin
# derives the absolute "${CLAUDE_PLUGIN_ROOT}"/scripts/ plugin form.
#
# DEGRADATION (Rule 15 — the [14.1] lever-b ladder, TAKEN not invented):
#   1. PRIMARY — additionalContext re-inject (jq present, checkpoint present + valid).
#   2. If the envelope cannot be built (jq absent) — a terse STDOUT POINTER to the
#      on-disk checkpoint (SessionStart stdout→context is CONFIRMED in [14.1]).
#   3. CLAUDE.md-survival floor — PASSIVE: the checkpoint persists on disk and
#      CLAUDE.md / the latest handoff are re-read every session regardless.
# A malformed or wrong-SCHEMA checkpoint is a NAMED loud stop (Rule 10), never re-
# injected as if it were state. Every rung exits 0: a SessionStart hook that exits
# non-zero BLOCKS the session from starting, and a resume must never deny the start.
set -u

# Resolve the project root: $CLAUDE_PROJECT_DIR (finding e), else the launch CWD
# (which IS the project root for a main-session hook) — never the payload `cwd`.
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
CKPT="$ROOT/.claude/continuation-checkpoint.json"

# Read the SessionStart payload from stdin.
INPUT=$(cat)

# Without jq we can neither parse the payload nor build the envelope. But the
# checkpoint may still be on disk — fall to the stdout-pointer rung (Rule 15 rung 2)
# if one exists, else nothing. (We cannot confirm source=compact without jq, so only
# point when a checkpoint is actually present; the pointer is terse + advisory, and a
# checkpoint on disk is a better breadcrumb than silence.)
if ! command -v jq >/dev/null 2>&1; then
  if [ -f "$CKPT" ]; then
    echo "guv continuation: jq unavailable — a continuation checkpoint exists at .claude/continuation-checkpoint.json; read it to resume the active deliverable (Rule 15 stdout-pointer rung)."
  fi
  exit 0
fi

# SCOPE GATE — only a post-compaction start is a resume. Anything else: nothing.
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)
[ "$SOURCE" = "compact" ] || exit 0

# No checkpoint → nothing to re-inject; the CLAUDE.md-survival floor carries the
# session (Rule 15 rung 3), and session-start.sh still surfaces the live frontier.
[ -f "$CKPT" ] || exit 0

# Read + validate. A file that is not JSON is NOT state — NAMED loud stop, exit 0.
CJSON=$(jq -e . "$CKPT" 2>/dev/null) || {
  echo "guv continuation: $CKPT is not valid JSON — NOT re-injected; the CLAUDE.md-survival floor carries the resume (Rule 15 loud stop)." >&2
  exit 0
}

# Version gate — we consume guv.continuation-checkpoint/1 (the [14.3] producer schema).
# An unrecognized schema (a future /2) is NOT re-injected as if it were /1 — NAMED
# loud stop. This gate is what lets /1 graduate from provisional: produced AND consumed.
SCHEMA=$(printf '%s' "$CJSON" | jq -r '.schema // empty' 2>/dev/null)
case "$SCHEMA" in
  guv.continuation-checkpoint/1) : ;;
  *)
    echo "guv continuation: unrecognized checkpoint schema '${SCHEMA:-<none>}' (expected guv.continuation-checkpoint/1) — NOT re-injected; the CLAUDE.md-survival floor carries the resume (Rule 15 loud stop)." >&2
    exit 0 ;;
esac

# Build the human-readable continuation breadcrumb from the checkpoint fields — the
# MAP the continuing model resumes from (see RESUME-SUFFICIENCY above).
CTX=$(printf '%s' "$CJSON" | jq -r '
  "guv continuation — resuming after a compaction; state re-injected from the [14.3] checkpoint" +
    (if .checkpoint_at then " (written " + .checkpoint_at + ")" else "" end) + ":",
  "",
  "You were working on: " + (.active_deliverable // "(none resolved at checkpoint)") + ".",
  (if .git_head == null and .git_dirty_paths == null
     then "Git state: unavailable at checkpoint (non-git or unresolved) — no in-flight-work signal."
     else "Git HEAD at checkpoint: " + (.git_head // "(unknown)") +
       (if (.git_dirty_paths // 0) > 0
          then " — " + (.git_dirty_paths|tostring) + " uncommitted path(s) in flight at checkpoint; read them (git status / git diff) to recover the in-flight working state before continuing."
          else " — working tree was clean at checkpoint (no uncommitted work)." end)
     end),
  (if (.budget.initiative // null) != null or (.budget.session // null) != null
     then "Budget posture at checkpoint: initiative=" + ((.budget.initiative // "unset")|tostring) +
          ", session=" + ((.budget.session // "unset")|tostring) +
          " (burn re-derives live this session via the entry-tension gate)."
     else empty end),
  (if .transcript_path
     then "Prior transcript (for deeper in-flight detail if the dirty files are not enough): " + .transcript_path + "."
     else empty end),
  "",
  "Resume that deliverable in place. A separate session-open dispatch advisory carries the LIVE frontier (re-resolved this session) — re-run the entry-door resolver to confirm the current pick before acting."
' 2>/dev/null)

# Envelope assembly failure → the stdout-pointer rung (rung 2), not silence.
if [ -z "$CTX" ]; then
  echo "guv continuation: could not assemble the re-injection breadcrumb — a continuation checkpoint exists at .claude/continuation-checkpoint.json; read it to resume (Rule 15 stdout-pointer rung)."
  exit 0
fi

# PRIMARY rung — the documented SessionStart context-injection envelope ([14.1] lever-b).
# A final jq failure degrades to the stdout pointer rather than emitting nothing.
jq -n --arg c "$CTX" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' 2>/dev/null \
  || echo "guv continuation: a continuation checkpoint exists at .claude/continuation-checkpoint.json; read it to resume (Rule 15 stdout-pointer rung)."
exit 0
