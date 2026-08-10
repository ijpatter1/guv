#!/bin/bash
# Plugin-level PreToolUse guard: read-only enforcement for the calibrated
# reviewer agent.
#
# Why this exists: plugin-shipped agents cannot carry frontmatter hooks (the
# plugin docs exclude hooks/mcpServers/permissionMode from plugin agents for
# security), so the per-agent read-only hooks from .claude/agents/*.md ride the
# plugin's hooks.json instead, gated on agent_type — a field present in hook
# input only when the call fires inside a subagent. Main-thread and
# non-reviewer calls pass through untouched (exit 0).
#
# SCOPE — a cooperative-agent hygiene layer, not an adversarial sandbox. It stops
# the common accidental write (redirect to a real file, tee, sed -i, or a write
# verb at command position, incl. behind a direct wrapper like sudo/xargs). It is
# NOT the containment boundary: bash-guard blocks only CATASTROPHIC patterns
# (rm -rf of root/system dirs/~/., mkfs, dd, hard-reset-to-remote, pipe-to-shell)
# plus the agent_type-gated tracker guard — NOT an ordinary `rm build`/`cp`/`> file`;
# the isolation tier (native sandbox) is the real boundary. Residuals — by
# DIRECTION, since they fail opposite ways (both acceptable for a cooperative
# agent): OVER-block — a benign command we tolerate DENYING: a blocked verb at
# pipe position doing read-only work (git checkout -- to inspect, python for
# analysis). UNDER-block — a write that SLIPS, leaving the isolation tier as the
# backstop: shell redirects (> file), tee/sed -i, and wrapped verbs (sudo rm,
# xargs rm) — the pattern matches command position only.
#
# Patterns and deny messages stay verbatim-consistent with the agent frontmatter
# (.claude/agents/reviewer.md). The Phase 4 spike verified the write denials
# live. (The evaluator arm, and the [20.1] SCRUB machinery it carried, retired
# with the evaluator agent at [32.3].) Both bare and
# guv:-prefixed agent_type values are matched: plugin-shipped agents resolve
# namespaced (verified live 2026-06-11 with the then-shipped guv:evaluator, the
# denial fired with the file confirmed absent), while project .claude/agents/
# copies report the bare name; one guard covers both install modes.
set -u
INPUT=$(cat)
AGENT=$(echo "$INPUT" | jq -r '.agent_type // empty')
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

case "$AGENT" in
  reviewer|guv:reviewer)
    if echo "$CMD" | grep -qE '(^|\|)\s*(rm|mv|cp|chmod|chown|git\s+(push|commit|merge|rebase|checkout)|npm\s+(publish|install)|npx|node\s+-e|pip|python)'; then
      jq -n --arg r "Product reviewer is read-only. Blocked write-pattern command: $CMD" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    fi
    ;;
esac
exit 0
