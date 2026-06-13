#!/bin/bash
# .claude/hooks/single-writer.sh
# PreToolUse hook (Write|Edit|MultiEdit) — the single-writer tracker invariant ([7.3]).
#
# Only the MAIN session writes the plan-of-record trackers
# (docs/PHASE_STATUS.md, docs/REQUIREMENTS.md). A subagent's edit to either is
# denied; the main thread and every other file pass through untouched.
#
# The signal is agent_type — present (non-empty) in PreToolUse input ONLY when
# the call fires inside a subagent; the main thread reports it empty. So any
# non-empty value is denied: both the bare (evaluator) and guv:-prefixed
# (guv:evaluator, verified live 2026-06-11) forms, AND every other subagent
# (Explore, lane workers) — the rule needs no per-agent list. The matcher is
# Write|Edit|MultiEdit (the same file-write set settings.json already routes to
# auto-format), so a subagent can't slip the tracker through MultiEdit; the hook
# keys on the tool_input path, resolving the same field set as auto-format.sh
# (file_path, then path). Bash-driven writes
# (shell redirection) are a different tool surface and out of scope here — the
# spec scopes this hook to Write/Edit; bash-guard owns Bash. Legitimate plan
# mutation runs through /replan (replan.sh) in the MAIN session.
#
# Why a hook and not agent frontmatter: same reason as reviewer-readonly.sh —
# plugin-shipped agents can't carry frontmatter hooks, so enforcement rides
# hooks.json (plugin mode) / settings.json (project mode), gated on agent_type.
# Ships byte-identical in both modes (the T9 parity set, glob-derived).
set -u
INPUT=$(cat)
AGENT=$(echo "$INPUT" | jq -r '.agent_type // empty')

# Main session (no agent_type) is the single writer — never our concern.
[ -z "$AGENT" ] && exit 0

# Extract the target path — different tools use different field names; resolve
# the same field set as auto-format.sh (the other Write|Edit|MultiEdit guard) so
# the two read the path identically.
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')

# The two plan-of-record trackers, anchored to a docs/ segment and the .md tail
# so near-misses (REQUIREMENTS.md.bak, a stray PHASE_STATUS elsewhere) don't match.
if echo "$FILE" | grep -qE '(^|/)docs/(PHASE_STATUS|REQUIREMENTS)\.md$'; then
  jq -n --arg r "Single-writer invariant: only the main session writes the plan-of-record tracker. Subagent (agent_type=$AGENT) denied write to $FILE. Plan mutations go through /replan (/guv:replan under the plugin) in the main session." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
