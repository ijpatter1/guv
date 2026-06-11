#!/bin/bash
# Tests for the Governor (guv) plugin package — Phase 5 D1.
# The plugin/ directory is GENERATED: maintainers/build-plugin.sh derives it from
# the .claude/ sources (single source of truth) plus authored plugin-only files in
# maintainers/plugin-src/. These tests guard the packaging invariants:
#   - manifest shape (name=guv, semver version, only plugin.json in .claude-plugin/)
#   - every command and skill ships as skills/<name>/SKILL.md (-> /guv:<name>)
#   - /guv:zen is user-only and carries all five design principles
#   - plugin agents carry NO frontmatter hooks (unsupported for plugin agents);
#     the read-only enforcement lives in hooks/hooks.json gated on agent_type
#   - hook/helper scripts, rules, and the workflow asset are byte-identical to
#     their .claude/ sources (cmp)
#   - skills reference plugin scripts via ${CLAUDE_PLUGIN_ROOT}, never .claude/
#   - no install-time tooling (spec constraint, Phase 5 scoped)
#   - drift guard: rebuilding into a temp dir reproduces the committed plugin/
# Live behaviors (skill resolution under /guv:, hook firing under plugin install)
# need a real session: covered by dogfood runs and the Phase 5 UAT, not here.
# Pure bash + jq, no test runner required.
# Run: bash .claude/tests/plugin.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN="$ROOT/plugin"
SRC="$ROOT/.claude"
MANIFEST="$PLUGIN/.claude-plugin/plugin.json"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
READONLY_SH="$PLUGIN/scripts/reviewer-readonly.sh"
BUILD="$ROOT/maintainers/build-plugin.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}

# T1 — manifest exists, parses, and carries the identity fields. name must be
# "guv" (it IS the namespace: /guv:status), version must be semver (D3's release
# flow pins updates to version bumps).
if [ -f "$MANIFEST" ] && jq -e . "$MANIFEST" >/dev/null 2>&1; then
  ok "plugin.json exists and is valid JSON"
else
  no "plugin manifest missing or invalid: $MANIFEST"
  finish; exit 1
fi
[ "$(jq -r '.name' "$MANIFEST")" = "guv" ] \
  && ok "manifest name is guv (the skill namespace)" \
  || no "manifest name must be exactly \"guv\", got: $(jq -r '.name' "$MANIFEST")"
jq -r '.version // empty' "$MANIFEST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
  && ok "manifest version is semver ($(jq -r '.version' "$MANIFEST"))" \
  || no "manifest version must be MAJOR.MINOR.PATCH semver"
[ -n "$(jq -r '.description // empty' "$MANIFEST")" ] \
  && ok "manifest carries a description" \
  || no "manifest description missing"

# T2 — structure: only plugin.json lives inside .claude-plugin/; component dirs
# sit at the plugin root (the documented common mistake is nesting them).
[ "$(ls "$PLUGIN/.claude-plugin" | tr '\n' ' ')" = "plugin.json " ] \
  && ok ".claude-plugin/ contains only plugin.json" \
  || no ".claude-plugin/ must contain only plugin.json, got: $(ls "$PLUGIN/.claude-plugin" | tr '\n' ' ')"
MISPLACED=0
for d in skills agents hooks scripts rules workflows; do
  [ -e "$PLUGIN/.claude-plugin/$d" ] && MISPLACED=1
done
[ "$MISPLACED" -eq 0 ] \
  && ok "component dirs are at the plugin root, not inside .claude-plugin/" \
  || no "component dirs found inside .claude-plugin/"

# T3 — every harness command ships as a namespaced skill: skills/<name>/SKILL.md
# with a description in frontmatter (the folder name becomes /guv:<name>).
T3_OK=1
for c in "$SRC"/commands/*.md; do
  name="$(basename "$c" .md)"
  s="$PLUGIN/skills/$name/SKILL.md"
  if [ ! -f "$s" ]; then no "command $name not packaged as skills/$name/SKILL.md"; T3_OK=0; continue; fi
  awk '/^---$/{n++} n==1' "$s" | grep -q '^description:' || { no "skills/$name/SKILL.md lacks description frontmatter"; T3_OK=0; }
done
[ "$T3_OK" -eq 1 ] && ok "all commands ship as skills/<name>/SKILL.md with description frontmatter"

# T4 — every harness skill ships under the same name (body content preserved:
# the part after the source frontmatter appears verbatim in the plugin copy,
# modulo the script-path rewrite, which T9 checks separately).
T4_OK=1
for d in "$SRC"/skills/*/; do
  name="$(basename "$d")"
  [ -f "$PLUGIN/skills/$name/SKILL.md" ] || { no "skill $name missing from plugin"; T4_OK=0; }
done
[ "$T4_OK" -eq 1 ] && ok "all harness skills ship in the plugin under their own names"

# T5 — /guv:zen: user-only (disable-model-invocation: true, so it never costs
# context) and prints ALL FIVE design principles from the spec.
ZEN="$PLUGIN/skills/zen/SKILL.md"
if [ -f "$ZEN" ]; then
  ok "zen skill exists (skills/zen/SKILL.md)"
  awk '/^---$/{n++} n==1' "$ZEN" | grep -q '^disable-model-invocation: true' \
    && ok "zen is user-only (disable-model-invocation: true)" \
    || no "zen must set disable-model-invocation: true in frontmatter"
  Z_OK=1
  while IFS= read -r p; do
    grep -qi "$p" "$ZEN" || { no "zen missing principle: $p"; Z_OK=0; }
  done <<'EOF'
explicit manifest over implicit defaults
null-means-skip over guessing
fail loud over fail silent
one active initiative over many
namespaces are a honking good idea
EOF
  [ "$Z_OK" -eq 1 ] && ok "zen names all five design principles"
else
  no "zen skill missing: $ZEN"
fi

# T6 — both reviewer agents ship, with the frontmatter hooks: block STRIPPED
# (plugin agents do not support frontmatter hooks — security restriction in the
# plugin docs) and everything else preserved: name, tools, memory, and the body.
T6_OK=1
for a in evaluator product-reviewer; do
  pa="$PLUGIN/agents/$a.md"
  sa="$SRC/agents/$a.md"
  if [ ! -f "$pa" ]; then no "agent $a missing from plugin"; T6_OK=0; continue; fi
  awk '/^---$/{n++} n==1' "$pa" | grep -q '^hooks:' && { no "agent $a still carries frontmatter hooks (unsupported in plugins)"; T6_OK=0; }
  awk '/^---$/{n++} n==1' "$pa" | grep -q "^name: $a$" || { no "agent $a frontmatter name not preserved"; T6_OK=0; }
  awk '/^---$/{n++} n==1' "$pa" | grep -q '^tools: Read, Glob, Grep, Bash$' || { no "agent $a restricted tool list not preserved"; T6_OK=0; }
  # body (after the closing ---) must be identical to the source body
  diff <(awk '/^---$/{n++; next} n>=2' "$sa") <(awk '/^---$/{n++; next} n>=2' "$pa") >/dev/null 2>&1 \
    || { no "agent $a body differs from source"; T6_OK=0; }
done
[ "$T6_OK" -eq 1 ] && ok "both agents ship hook-free with name/tools/body preserved"

# T7 — hooks.json wires all three harness hooks plus the reviewer read-only
# guard, every command routed through \${CLAUDE_PLUGIN_ROOT}.
if [ -f "$HOOKS_JSON" ] && jq -e . "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks/hooks.json exists and is valid JSON"
  jq -r '.hooks.PreToolUse[]?.hooks[]?.command' "$HOOKS_JSON" | grep -q 'bash-guard.sh' \
    && ok "PreToolUse wires bash-guard" || no "PreToolUse must wire bash-guard.sh"
  jq -r '.hooks.PreToolUse[]?.hooks[]?.command' "$HOOKS_JSON" | grep -q 'reviewer-readonly.sh' \
    && ok "PreToolUse wires the reviewer read-only guard" || no "PreToolUse must wire reviewer-readonly.sh"
  jq -r '.hooks.PostToolUse[]?.hooks[]?.command' "$HOOKS_JSON" | grep -q 'auto-format.sh' \
    && ok "PostToolUse wires auto-format" || no "PostToolUse must wire auto-format.sh"
  jq -r '.hooks.Stop[]?.hooks[]?.command' "$HOOKS_JSON" | grep -q 'stop-check.sh' \
    && ok "Stop wires stop-check" || no "Stop must wire stop-check.sh"
  STRAY=$(jq -r '.hooks[][]?.hooks[]?.command' "$HOOKS_JSON" | grep -cv 'CLAUDE_PLUGIN_ROOT')
  [ "$STRAY" -eq 0 ] \
    && ok "every hook command resolves via \${CLAUDE_PLUGIN_ROOT}" \
    || no "$STRAY hook command(s) do not use \${CLAUDE_PLUGIN_ROOT}"
else
  no "hooks/hooks.json missing or invalid"
fi

# T8 — reviewer-readonly.sh behavior (the agent_type gate). Synthetic hook JSON
# on stdin, exactly as Claude Code delivers it. Deny messages must keep the
# verbatim prefixes the Phase 4 spike verified live.
if [ -f "$READONLY_SH" ]; then
  out=$(printf '%s' '{"agent_type":"evaluator","tool_name":"Bash","tool_input":{"command":"echo x > /tmp/f"}}' | bash "$READONLY_SH")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q '^Evaluator is read-only\. Blocked write-pattern command:' \
    && ok "evaluator + write-pattern command -> deny with verbatim message" \
    || no "evaluator write-pattern must be denied with the verbatim message"
  out=$(printf '%s' '{"agent_type":"evaluator","tool_name":"Bash","tool_input":{"command":"ls /tmp | head -3"}}' | bash "$READONLY_SH"); rc=$?
  [ $rc -eq 0 ] && ! echo "$out" | grep -q 'deny' \
    && ok "evaluator + read-only command -> allowed" \
    || no "evaluator read-only command must pass"
  out=$(printf '%s' '{"agent_type":"product-reviewer","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' | bash "$READONLY_SH")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q '^Product reviewer is read-only\. Blocked write-pattern command:' \
    && ok "product-reviewer + write-pattern command -> deny with verbatim message" \
    || no "product-reviewer write-pattern must be denied with the verbatim message"
  out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo x > /tmp/f"}}' | bash "$READONLY_SH"); rc=$?
  [ $rc -eq 0 ] && ! echo "$out" | grep -q 'deny' \
    && ok "main thread (no agent_type) -> guard stands aside (bash-guard owns it)" \
    || no "main-thread calls must not be blocked by the reviewer guard"
  out=$(printf '%s' '{"agent_type":"Explore","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' | bash "$READONLY_SH"); rc=$?
  [ $rc -eq 0 ] && ! echo "$out" | grep -q 'deny' \
    && ok "other subagents -> guard stands aside" \
    || no "non-reviewer subagents must not be blocked by the reviewer guard"
  # plugin agents resolve NAMESPACED (guv:evaluator) — verified live 2026-06-11:
  # agent_type arrives prefixed, so the guard must match that form too
  out=$(printf '%s' '{"agent_type":"guv:evaluator","tool_name":"Bash","tool_input":{"command":"echo x > /tmp/f"}}' | bash "$READONLY_SH")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && ok "guv:evaluator (namespaced plugin form) + write-pattern -> deny" \
    || no "guv:evaluator write-pattern must be denied (plugin agents resolve namespaced)"
  out=$(printf '%s' '{"agent_type":"guv:product-reviewer","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' | bash "$READONLY_SH")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && ok "guv:product-reviewer (namespaced plugin form) + write-pattern -> deny" \
    || no "guv:product-reviewer write-pattern must be denied (plugin agents resolve namespaced)"
else
  no "reviewer-readonly.sh missing: $READONLY_SH"
fi

# T9 — hook + helper scripts ship byte-identical (cmp) to their .claude/ sources.
# They are invoked with cwd = the project, so project-relative reads like
# .claude/project.json stay correct without rewriting.
T9_OK=1
for pair in \
  "hooks/bash-guard.sh:scripts/bash-guard.sh" \
  "hooks/auto-format.sh:scripts/auto-format.sh" \
  "hooks/stop-check.sh:scripts/stop-check.sh" \
  "resolve-stack.sh:scripts/resolve-stack.sh" \
  "check-citations.sh:scripts/check-citations.sh" \
  "update-readme-status.sh:scripts/update-readme-status.sh" \
  "archive-initiative.sh:scripts/archive-initiative.sh"; do
  src="$SRC/${pair%%:*}"; dst="$PLUGIN/${pair##*:}"
  cmp -s "$src" "$dst" || { no "${pair##*:} not byte-identical to ${pair%%:*}"; T9_OK=0; }
done
[ "$T9_OK" -eq 1 ] && ok "all 7 hook/helper scripts byte-identical to .claude/ sources"

# T10 — the five guv-* rules ship byte-identical as scaffold assets (plugins
# cannot load rules natively; the D2 scaffold deploys these into projects).
T10_OK=1
RULE_COUNT=0
for r in "$SRC"/rules/guv-*.md; do
  RULE_COUNT=$((RULE_COUNT + 1))
  cmp -s "$r" "$PLUGIN/rules/$(basename "$r")" || { no "rule $(basename "$r") missing or differs in plugin/rules/"; T10_OK=0; }
done
[ "$T10_OK" -eq 1 ] && ok "all $RULE_COUNT guv-* rules ship byte-identical in plugin/rules/"

# T11 — the workflow ships as a skill-fronted asset under workflows/, fronted
# by a skill that launches it via scriptPath + \${CLAUDE_PLUGIN_ROOT} (plugins
# cannot ship .claude/workflows/ natively). The plugin copy must spawn the
# NAMESPACED reviewers — plugin agents resolve only as guv:<name> (verified
# live 2026-06-11); bare names would fail for plugin-only consumers. Apart from
# that rewrite the script is byte-identical to the saved workflow.
WF="$PLUGIN/workflows/evaluate-parallel.js"
if [ -f "$WF" ]; then
  grep -q "agentType: 'guv:evaluator'" "$WF" && grep -q "agentType: 'guv:product-reviewer'" "$WF" \
    && ! grep -qE "agentType: '(evaluator|product-reviewer)'" "$WF" \
    && ok "plugin workflow spawns the namespaced reviewers (guv:evaluator, guv:product-reviewer)" \
    || no "plugin workflow must use guv:-namespaced agentType (bare names don't resolve from the plugin)"
  diff <(sed "s/agentType: 'guv:/agentType: '/g" "$WF") "$SRC/workflows/evaluate-parallel.js" >/dev/null 2>&1 \
    && ok "workflow asset identical to the saved workflow modulo agentType namespacing" \
    || no "plugin workflow differs from source beyond the agentType rewrite"
else
  no "plugin/workflows/evaluate-parallel.js missing"
fi
EP="$PLUGIN/skills/evaluate-parallel/SKILL.md"
if [ -f "$EP" ] && grep -q 'scriptPath' "$EP" && grep -q 'CLAUDE_PLUGIN_ROOT.*workflows/evaluate-parallel\.js' "$EP"; then
  ok "evaluate-parallel skill fronts the asset via scriptPath + \${CLAUDE_PLUGIN_ROOT}"
else
  no "skills/evaluate-parallel/SKILL.md must invoke the Workflow tool with the plugin-root scriptPath"
fi

# T12 — no stale project-relative script invocations survive inside plugin
# skills: every helper-script reference must have been rewritten to the plugin
# root (references to project files like .claude/project.json are legitimate).
STALE=$(grep -rE '\.claude/(hooks/)?(archive-initiative|resolve-stack|check-citations|update-readme-status|bash-guard|auto-format|stop-check)\.sh' "$PLUGIN/skills" | grep -cv 'CLAUDE_PLUGIN_ROOT')
[ "$STALE" -eq 0 ] \
  && ok "no stale .claude/ script paths in plugin skills (all rewritten to plugin root)" \
  || no "$STALE stale .claude/ script reference(s) remain in plugin/skills"

# T13 — no install-time tooling (spec constraint, Phase 5 scoped): the plugin
# may use the native manifest format but ships no postinstall machinery.
T13_OK=1
[ -e "$PLUGIN/package.json" ] && { no "package.json found in plugin (install-time tooling)"; T13_OK=0; }
jq -e '.scripts // .install // .postinstall' "$MANIFEST" >/dev/null 2>&1 && { no "manifest carries install-time keys"; T13_OK=0; }
[ "$T13_OK" -eq 1 ] && ok "no install-time tooling (native manifest only)"

# T14 — drift guard: the committed plugin/ is exactly what build-plugin.sh
# produces from today's sources. A diff here means someone edited plugin/ by
# hand or changed .claude/ without rebuilding.
if [ -x "$BUILD" ] || [ -f "$BUILD" ]; then
  TMP=$(mktemp -d)
  if bash "$BUILD" --out "$TMP/plugin" >/dev/null 2>&1 && diff -r "$TMP/plugin" "$PLUGIN" >/dev/null 2>&1; then
    ok "rebuild reproduces the committed plugin/ byte-for-byte (no drift)"
  else
    no "build-plugin.sh --out output differs from committed plugin/ (rebuild needed?)"
  fi
  rm -rf "$TMP"
else
  no "maintainers/build-plugin.sh missing"
fi

finish
