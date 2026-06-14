#!/bin/bash
# Tests for .claude/hooks/single-writer.sh — the single-writer tracker hook ([7.3]).
#
# Invariant: only the MAIN session writes the plan-of-record trackers
# (docs/PHASE_STATUS.md, docs/REQUIREMENTS.md). A subagent's Write/Edit/MultiEdit
# to either is denied; the main thread and every other file pass through. The
# signal is agent_type — present (non-empty) in PreToolUse input ONLY inside a
# subagent; the main thread reports it empty. Both bare (evaluator) and
# guv:-prefixed (guv:evaluator) forms are subagents, so any non-empty value
# denies — no per-agent list. Synthetic hook JSON on stdin, exactly as Claude
# Code delivers it.
#
# This suite owns the behavior matrix + the PROJECT-mode wiring (settings.json).
# The PLUGIN-mode wiring (hooks.json) is asserted in plugin.test.sh T7, and the
# byte-identical plugin copy by plugin.test.sh T9 (glob-derived — single-writer.sh
# joins that parity set by existing). Those two are the "both install modes" and
# "byte-identical plugin copy per the T9 pattern" halves of the acceptance.
# Pure bash + jq, no test runner required.
# Run: bash .claude/tests/single-writer.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/.claude/hooks/single-writer.sh"
SETTINGS="$ROOT/.claude/settings.json"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# feed <json> -> hook stdout. stderr is suppressed only as belt-and-suspenders
# for the run-harness-tests gate: the hook is stderr-clean for the well-formed
# JSON the runtime always delivers (non-JSON stdin would make jq complain and
# the hook would fail-open with exit 0 — but Claude Code never feeds that).
feed() { printf '%s' "$1" | bash "$HOOK" 2>/dev/null; }

# A denied call: structural decision == deny AND the reason names the invariant
# (Rule 8 — the assertion encodes WHY the write is refused, not just that it is).
is_deny() {
  echo "$1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && echo "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null | grep -qi 'single-writer'
}

mk() { # mk <agent_type|""> <tool_name> <file_path>
  if [ -z "$1" ]; then
    jq -nc --arg t "$2" --arg f "$3" '{tool_name:$t,tool_input:{file_path:$f}}'
  else
    jq -nc --arg a "$1" --arg t "$2" --arg f "$3" '{agent_type:$a,tool_name:$t,tool_input:{file_path:$f}}'
  fi
}

# ── DENY: a subagent writing either tracker, by any edit tool, any agent form ──

# T1 — subagent (bare) Write to PHASE_STATUS.md (absolute path) -> deny
out=$(feed "$(mk evaluator Write /home/proj/docs/PHASE_STATUS.md)")
is_deny "$out" \
  && ok "subagent Write docs/PHASE_STATUS.md -> deny (names the single-writer invariant)" \
  || no "a subagent Write to docs/PHASE_STATUS.md must be denied"

# T1b — the deny reason names the offending agent_type AND the target file, so a
# regression that dropped or hard-coded the interpolation fails (the "name the
# offender" bar the resolver/grammar suites set), and the message can guide.
out=$(feed "$(mk guv:reviewer Write /home/proj/docs/REQUIREMENTS.md)")
reason=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)
echo "$reason" | grep -qF 'guv:reviewer' && echo "$reason" | grep -qF '/home/proj/docs/REQUIREMENTS.md' \
  && ok "deny reason interpolates the offending agent_type and file (message names the offender)" \
  || no "deny reason must name the agent_type and the file_path"

# T2 — subagent (bare) Edit to REQUIREMENTS.md -> deny (the Edit tool + 2nd file)
out=$(feed "$(mk reviewer Edit /home/proj/docs/REQUIREMENTS.md)")
is_deny "$out" \
  && ok "subagent Edit docs/REQUIREMENTS.md -> deny (Edit tool, second tracker)" \
  || no "a subagent Edit to docs/REQUIREMENTS.md must be denied"

# T3 — guv:-prefixed agent_type (plugin agents resolve namespaced, verified live
# 2026-06-11) is still a subagent -> deny
out=$(feed "$(mk guv:evaluator Write /home/proj/docs/PHASE_STATUS.md)")
is_deny "$out" \
  && ok "guv:evaluator (namespaced plugin form) Write tracker -> deny" \
  || no "a guv:-prefixed subagent must be denied (non-empty agent_type is a subagent)"

# T4 — MultiEdit is the third file-write tool the settings matcher carries
# (Write|Edit|MultiEdit, matching the auto-format matcher); a subagent must not
# slip the tracker through it -> deny
out=$(feed "$(mk Explore MultiEdit /home/proj/docs/REQUIREMENTS.md)")
is_deny "$out" \
  && ok "any subagent MultiEdit tracker -> deny (matcher includes MultiEdit)" \
  || no "a subagent MultiEdit to a tracker must be denied"

# T5 — relative path form (docs/… with no leading slash) still matches the anchor
out=$(feed "$(mk evaluator Write docs/PHASE_STATUS.md)")
is_deny "$out" \
  && ok "relative docs/PHASE_STATUS.md path -> deny (anchor matches ^docs/ too)" \
  || no "the path anchor must match the leading-segment relative form"

# T5b — the target path is resolved from tool_input.path too, matching
# auto-format.sh's field set (the other Write|Edit|MultiEdit guard). A tool that
# delivered the tracker under .path instead of .file_path must not slip through.
out=$(feed "$(jq -nc --arg a evaluator --arg f /home/proj/docs/PHASE_STATUS.md '{agent_type:$a,tool_name:"Edit",tool_input:{path:$f}}')")
is_deny "$out" \
  && ok "tracker path under tool_input.path -> deny (field parity with auto-format.sh)" \
  || no "the hook must read tool_input.path as a fallback, like auto-format.sh"

# ── ALLOW: the main session, and every non-tracker file ──

# T6 — MAIN session (no agent_type) writing the tracker is the whole point:
# the single writer is allowed -> silent exit 0
out=$(feed "$(mk "" Write /home/proj/docs/PHASE_STATUS.md)"); rc=$?
[ $rc -eq 0 ] && ! echo "$out" | grep -q 'deny' \
  && ok "main session (no agent_type) Write tracker -> allowed (it IS the writer)" \
  || no "the main session must be allowed to write the tracker"

# T7 — a subagent writing some OTHER file is none of this hook's business
out=$(feed "$(mk evaluator Write /home/proj/src/app.ts)"); rc=$?
[ $rc -eq 0 ] && ! echo "$out" | grep -q 'deny' \
  && ok "subagent Write a non-tracker file -> allowed" \
  || no "non-tracker writes must pass through for subagents"

# T8 — scope precision: a sibling doc (ARCHITECTURE.md) is NOT a single-writer
# file — the spec names only PHASE_STATUS.md and REQUIREMENTS.md, and lane work
# legitimately edits ARCHITECTURE.md -> allowed
out=$(feed "$(mk reviewer Edit /home/proj/docs/ARCHITECTURE.md)"); rc=$?
[ $rc -eq 0 ] && ! echo "$out" | grep -q 'deny' \
  && ok "subagent Edit docs/ARCHITECTURE.md -> allowed (only the two trackers are guarded)" \
  || no "the hook must not over-block sibling docs; only the two named trackers"

# ── PROJECT-mode wiring: settings.json registers the hook on the edit tools ──

# T9 — .claude/settings.json wires single-writer.sh under a PreToolUse matcher
# that covers the edit tools (project/template-clone install mode).
SW_MATCHER=$(jq -r '.hooks.PreToolUse[]? | select(any(.hooks[]?.command; test("single-writer\\.sh"))) | .matcher' "$SETTINGS" 2>/dev/null)
if [ -n "$SW_MATCHER" ] && echo "$SW_MATCHER" | grep -q 'Write' && echo "$SW_MATCHER" | grep -q 'Edit'; then
  ok "settings.json wires single-writer.sh on a PreToolUse Write|Edit matcher (project mode)"
else
  no "settings.json PreToolUse must wire single-writer.sh on a Write|Edit matcher"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
