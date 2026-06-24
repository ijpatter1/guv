#!/bin/bash
# Plugin-level PreToolUse guard: read-only enforcement for the two calibrated
# reviewer agents (evaluator, reviewer).
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
# agent): OVER-block — a benign read we tolerate DENYING: a quoted > read as a
# redirect (awk '$1 > 5', grep ">"). UNDER-block — a write that SLIPS, leaving
# the isolation tier as the backstop: interposed-arg wrappers (timeout N cmd,
# sudo -u U cmd), a doubled direct wrapper (sudo sudo rm — one peel pass leaves
# the verb off-anchor), exotic wrappers (stdbuf), and backtick (not $()) substitution.
#
# Patterns and deny messages stay verbatim-consistent with the agent frontmatter
# (.claude/agents/{evaluator,reviewer}.md). The Phase 4 spike verified the write
# denials live; [20.1] stopped the evaluator branch over-blocking benign probes:
# detection is anchored to command position (a write WORD in an argument — grep
# "install", the "tee" in "guarantee" — passes), and a SCRUB drops the benign
# redirects an evaluator uses (N>/dev/null, 2>&1, >&2) and peels command-position
# wrappers before matching, so a write behind one (sudo rm, find | xargs rm) is
# still denied. Both bare and
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
    # SCRUB then match (see SCOPE above): drop benign redirects (N>/dev/null, fd
    # dups) and peel command-position wrappers/env-assignments so the real verb
    # sits at an anchor — a write WORD inside an argument never reaches the verb test.
    SCRUBBED=$(printf '%s' "$CMD" | sed -E 's#[0-9]*>>?[[:space:]]*/dev/null##g;s#[0-9]*>&[0-9-]+##g;s#(^|[|&;(])[[:space:]]*(sudo|time|nohup|env|xargs|nice|ionice)[[:space:]]+#\1 #g;s#(^|[|&;(])[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+#\1 #g')
    if printf '%s' "$SCRUBBED" | grep -qE '(>>?|sed[[:space:]]+-i|(^|[|&;(])[[:space:]]*(tee|mv|cp|rm|mkdir|touch|chmod|npm[[:space:]]+(i|install|ci)|pip[[:space:]]+install))'; then
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
