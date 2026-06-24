#!/bin/bash
# Plugin-level PreToolUse guard: read-only enforcement for the two calibrated
# reviewer agents (evaluator, reviewer).
#
# Why this exists: plugin-shipped agents cannot carry frontmatter hooks (the
# plugin docs exclude hooks/mcpServers/permissionMode from plugin agents for
# security), so the per-agent read-only hooks from .claude/agents/*.md ride the
# plugin's hooks.json instead, gated on agent_type — a field present in hook
# input only when the call fires inside a subagent. Main-thread and
# non-reviewer calls pass through untouched (exit 0); bash-guard still owns
# destructive-pattern blocking for everyone.
#
# Patterns and deny messages stay verbatim-consistent with the agent frontmatter
# (.claude/agents/{evaluator,reviewer}.md). The Phase 4 spike verified the write
# denials live; [20.1] anchored the evaluator pattern to command position so a
# benign read-only probe whose text merely contains a write-ish word
# (install/create/write/modify) or substring (tee) is no longer denied. Both bare and
# guv:-prefixed agent_type values are matched: plugin-shipped agents resolve
# namespaced (guv:evaluator — verified live 2026-06-11, the denial fired with
# the file confirmed absent), while project .claude/agents/ copies report the
# bare name; one guard covers both install modes.
set -u
INPUT=$(cat)
AGENT=$(echo "$INPUT" | jq -r '.agent_type // empty')
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

case "$AGENT" in
  evaluator|guv:evaluator)
    if echo "$CMD" | grep -qE '(>>?|sed[[:space:]]+-i|(^|[|&;(])[[:space:]]*(tee|mv|cp|rm|mkdir|touch|chmod|npm[[:space:]]+(i|install|ci)|pip[[:space:]]+install))'; then
      jq -n --arg r "Evaluator is read-only. Blocked write-pattern command: $CMD" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    fi
    ;;
  reviewer|guv:reviewer)
    if echo "$CMD" | grep -qE '(^|\|)\s*(rm|mv|cp|chmod|chown|git\s+(push|commit|merge|rebase|checkout)|npm\s+(publish|install)|npx|node\s+-e|pip|python)'; then
      jq -n --arg r "Product reviewer is read-only. Blocked write-pattern command: $CMD" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    fi
    ;;
esac
exit 0
