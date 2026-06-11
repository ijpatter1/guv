#!/bin/bash
# Plugin-level PreToolUse guard: read-only enforcement for the two calibrated
# reviewer agents (evaluator, product-reviewer).
#
# Why this exists: plugin-shipped agents cannot carry frontmatter hooks (the
# plugin docs exclude hooks/mcpServers/permissionMode from plugin agents for
# security), so the per-agent read-only hooks from .claude/agents/*.md ride the
# plugin's hooks.json instead, gated on agent_type — a field present in hook
# input only when the call fires inside a subagent. Main-thread and
# non-reviewer calls pass through untouched (exit 0); bash-guard still owns
# destructive-pattern blocking for everyone.
#
# Patterns and deny messages are verbatim from the original agent frontmatter —
# the Phase 4 spike verified those exact denials live. Both bare and
# guv:-prefixed agent_type values are matched: the docs say agent_type carries
# the frontmatter name, but whether plugin agents report it namespaced is
# undocumented — match both so enforcement holds either way (pin down at UAT).
set -u
INPUT=$(cat)
AGENT=$(echo "$INPUT" | jq -r '.agent_type // empty')
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

case "$AGENT" in
  evaluator|guv:evaluator)
    if echo "$CMD" | grep -qEi '(>|>>|tee |mv |cp |rm |mkdir |touch |chmod |sed -i|write|create|modify|install|npm (i|install|ci)|pip install)'; then
      jq -n --arg r "Evaluator is read-only. Blocked write-pattern command: $CMD" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    fi
    ;;
  product-reviewer|guv:product-reviewer)
    if echo "$CMD" | grep -qE '(^|\|)\s*(rm|mv|cp|chmod|chown|git\s+(push|commit|merge|rebase|checkout)|npm\s+(publish|install)|npx|node\s+-e|pip|python)'; then
      jq -n --arg r "Product reviewer is read-only. Blocked write-pattern command: $CMD" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    fi
    ;;
esac
exit 0
