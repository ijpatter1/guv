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
SELF="$ROOT/.claude/tests/$(basename "$0")"   # absolute — $0-relative re-invocation breaks if a cd ever lands in the main shell
PLUGIN="$ROOT/plugin"
SRC="$ROOT/.claude"
MANIFEST="$PLUGIN/.claude-plugin/plugin.json"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
READONLY_SH="$PLUGIN/scripts/reviewer-readonly.sh"
BUILD="${PLUGIN_BUILD_SCRIPT:-$ROOT/maintainers/build-plugin.sh}"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# A template-clone fork may delete the generated plugin/ (and .claude-plugin/)
# per the README's tree note — with no plugin tree there is nothing to guard;
# skip the whole suite cleanly, never as failures. PLUGIN_TEST_TREE is the
# seam for T16b's self-check of this path.
if [ ! -d "${PLUGIN_TEST_TREE:-$PLUGIN}" ]; then
  echo "  - plugin/ absent (template-clone fork) — suite skips"
  echo ""
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}

# The helper/hook script-name alternation, DERIVED by glob ([7.1]) — used by
# T6's body comparison (the build path-rewrites agent bodies) and T12's
# stale-path detector. The hand list this replaces had fallen behind the
# build's; derivation keeps both sides of the guard in lockstep by existing.
SCRIPTS_ALT=$(
  {
    for f in "$SRC"/*.sh; do basename "$f" .sh; done
    for f in "$SRC"/hooks/*.sh; do basename "$f" .sh; done
  } | paste -sd'|' -
)
# the forward rewrite exactly as the build applies it (sed -E, '#' delimiter)
apply_path_rewrite() {
  sed -E 's#\.claude/(hooks/)?('"$SCRIPTS_ALT"')\.sh#"${CLAUDE_PLUGIN_ROOT}"/scripts/\2.sh#g'
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

# T3 — every source skill (incl. the former commands flattened into skills/ at
# [8.3]) carries name + description frontmatter and ships under its own name
# (the folder name becomes /guv:<name>). The flatten gave the former commands
# real frontmatter; this guards that none ships without it.
T3_OK=1
for d in "$SRC"/skills/*/; do
  name="$(basename "$d")"
  src="$d/SKILL.md"
  s="$PLUGIN/skills/$name/SKILL.md"
  if [ ! -f "$src" ]; then no "source skill $name has no SKILL.md"; T3_OK=0; continue; fi
  fm="$(awk '/^---$/{n++} n==1' "$src")"
  echo "$fm" | grep -q '^name:'        || { no "skills/$name/SKILL.md lacks name frontmatter"; T3_OK=0; }
  echo "$fm" | grep -q '^description:' || { no "skills/$name/SKILL.md lacks description frontmatter"; T3_OK=0; }
  [ -f "$s" ] || { no "skill $name not packaged at skills/$name/SKILL.md"; T3_OK=0; }
done
[ "$T3_OK" -eq 1 ] && ok "every source skill (incl. flattened former commands) ships with name + description frontmatter"

# T4 — every core skill ships under the same name (body content preserved:
# the part after the source frontmatter appears verbatim in the plugin copy,
# modulo the script-path rewrite, which T9 checks separately).
T4_OK=1
for d in "$SRC"/skills/*/; do
  name="$(basename "$d")"
  [ -f "$PLUGIN/skills/$name/SKILL.md" ] || { no "skill $name missing from plugin"; T4_OK=0; }
done
[ "$T4_OK" -eq 1 ] && ok "all core skills ship in the plugin under their own names"

# T4b — bundled single-owner scripts ([8.3]) ship byte-identical inside their
# skill's scripts/ (referenced via ${CLAUDE_SKILL_DIR}), and NOT in the shared
# scripts/ tree. Derived from source: any skills/<name>/scripts/*.sh must land at
# plugin/skills/<name>/scripts/<file> identical to source, and must be absent
# from plugin/scripts/ (it is owned, not shared).
T4B_OK=1
T4B_SEEN=0
for sd in "$SRC"/skills/*/scripts/*.sh; do
  [ -e "$sd" ] || continue
  T4B_SEEN=$((T4B_SEEN + 1))
  name="$(basename "$(dirname "$(dirname "$sd")")")"
  base="$(basename "$sd")"
  dest="$PLUGIN/skills/$name/scripts/$base"
  cmp -s "$sd" "$dest" || { no "bundled script $name/$base not shipped byte-identical at skills/$name/scripts/"; T4B_OK=0; }
  [ -e "$PLUGIN/scripts/$base" ] && { no "bundled script $base leaked into shared scripts/ (must be skill-owned only)"; T4B_OK=0; }
done
[ "$T4B_OK" -eq 1 ] && [ "$T4B_SEEN" -gt 0 ] \
  && ok "all $T4B_SEEN bundled single-owner scripts ship under their skill's scripts/ (and not in shared scripts/)" \
  || { [ "$T4B_SEEN" -eq 0 ] && no "T4b found no bundled skill scripts to check (expected the [8.3] single-owners)"; }

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
for a in evaluator reviewer; do
  pa="$PLUGIN/agents/$a.md"
  sa="$SRC/agents/$a.md"
  if [ ! -f "$pa" ]; then no "agent $a missing from plugin"; T6_OK=0; continue; fi
  awk '/^---$/{n++} n==1' "$pa" | grep -q '^hooks:' && { no "agent $a still carries frontmatter hooks (unsupported in plugins)"; T6_OK=0; }
  awk '/^---$/{n++} n==1' "$pa" | grep -q "^name: $a$" || { no "agent $a frontmatter name not preserved"; T6_OK=0; }
  awk '/^---$/{n++} n==1' "$pa" | grep -q '^tools: Read, Glob, Grep, Bash$' || { no "agent $a restricted tool list not preserved"; T6_OK=0; }
  # body (after the closing ---) must be identical to the source body modulo
  # the namespace rewrite (plugin copies reference /guv:* and @guv:* because
  # bare names don't resolve under plugin install) and the script-path rewrite
  # ([7.1]: agent procedures route through .claude/guv-*.sh helpers, which a
  # plugin-only project doesn't have) — forward-rewrite the source side,
  # un-namespace the plugin side, and compare
  diff <(awk '/^---$/{n++; next} n>=2' "$sa" | apply_path_rewrite) \
       <(awk '/^---$/{n++; next} n>=2' "$pa" | sed -E 's|/guv:|/|g; s|@guv:|@|g; s|`guv:(evaluator\|reviewer)` subagent|`\1` subagent|g') >/dev/null 2>&1 \
    || { no "agent $a body differs from source beyond the namespace + path rewrites"; T6_OK=0; }
done
[ "$T6_OK" -eq 1 ] && ok "both agents ship hook-free with name/tools/body preserved"

# T7 — hooks.json wires all three core hooks plus the reviewer read-only
# guard, every command routed through \${CLAUDE_PLUGIN_ROOT}.
if [ -f "$HOOKS_JSON" ] && jq -e . "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks/hooks.json exists and is valid JSON"
  jq -r '.hooks.PreToolUse[]?.hooks[]?.command' "$HOOKS_JSON" | grep -q 'bash-guard.sh' \
    && ok "PreToolUse wires bash-guard" || no "PreToolUse must wire bash-guard.sh"
  jq -r '.hooks.PreToolUse[]?.hooks[]?.command' "$HOOKS_JSON" | grep -q 'reviewer-readonly.sh' \
    && ok "PreToolUse wires the reviewer read-only guard" || no "PreToolUse must wire reviewer-readonly.sh"
  jq -r '.hooks.PreToolUse[]?.hooks[]?.command' "$HOOKS_JSON" | grep -q 'single-writer.sh' \
    && ok "PreToolUse wires the single-writer tracker guard ([7.3])" || no "PreToolUse must wire single-writer.sh"
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
  out=$(printf '%s' '{"agent_type":"reviewer","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' | bash "$READONLY_SH")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q '^Product reviewer is read-only\. Blocked write-pattern command:' \
    && ok "reviewer + write-pattern command -> deny with verbatim message" \
    || no "reviewer write-pattern must be denied with the verbatim message"
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
  out=$(printf '%s' '{"agent_type":"guv:reviewer","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' | bash "$READONLY_SH")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && ok "guv:reviewer (namespaced plugin form) + write-pattern -> deny" \
    || no "guv:reviewer write-pattern must be denied (plugin agents resolve namespaced)"
  # T8b — [20.1] over-block fix (and its re-fix). The evaluator guard must NOT
  # deny a benign read-only probe. Three over-block classes must pass: (1) a
  # write-ish WORD (install/create/write/modify) or substring (tee) riding inside
  # a quoted grep pattern / path / commit-message search — not a command, so
  # read-only; (2) the benign redirects an evaluator actually uses — N>/dev/null,
  # 2>&1, > /dev/null — which write nothing real and are SCRUBBED before matching;
  # (3) a wrapper word inside an argument (grep "sudo rm") — peeling happens only
  # at command position, so the quoted form stays read-only. Symmetrically, the
  # deny cases prove the scrub did not under-block: a real-file redirect, and a
  # write verb behind a command-position wrapper (sudo rm / find | xargs rm /
  # FOO=1 rm) is still denied. The guard anchors detection to command position;
  # a word in an argument is not a command. jq builds the hook JSON so the
  # embedded quotes survive into a valid payload.
  evjson() { jq -cn --arg a "$1" --arg c "$2" '{agent_type:$a,tool_name:"Bash",tool_input:{command:$c}}'; }
  while IFS='|' read -r agent verdict cmd; do
    [ -z "$agent" ] && continue
    out=$(evjson "$agent" "$cmd" | bash "$READONLY_SH"); rc=$?
    denied=no; echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 && denied=yes
    if [ "$verdict" = allow ]; then
      [ $rc -eq 0 ] && [ "$denied" = no ] \
        && ok "evaluator allows benign read-only probe: $cmd" \
        || no "evaluator over-blocks benign read-only probe: $cmd"
    else
      [ "$denied" = yes ] \
        && ok "evaluator still denies write at command position: $cmd" \
        || no "evaluator under-blocks a real write: $cmd"
    fi
  done <<'T8B'
evaluator|allow|grep -rn "install" .
evaluator|allow|git log --grep="createTable"
evaluator|allow|grep -rn "writeFile" src/
evaluator|allow|grep -r "guarantee none" notes.md
guv:evaluator|allow|grep -rn "modifyConfig" .
evaluator|allow|cat foo 2>/dev/null
evaluator|allow|make test 2>&1
evaluator|allow|ls > /dev/null
guv:evaluator|allow|bash run.sh 2>&1 | grep -i fail
evaluator|allow|grep "sudo rm" file
evaluator|deny|ls; rm -rf build
evaluator|deny|cat a | tee out.txt
evaluator|deny|echo hi && mkdir d
evaluator|deny|echo $(touch f)
evaluator|deny|sudo rm -rf build
evaluator|deny|find . | xargs rm
evaluator|deny|FOO=1 rm x
guv:evaluator|deny|cmd > output.txt
evaluator|deny|cp src dst
T8B
else
  no "reviewer-readonly.sh missing: $READONLY_SH"
fi

# T8c — [20.1] dual-surface parity. The project-mode evaluator.md frontmatter
# carries the SAME scrub+grep as the plugin reviewer-readonly.sh, but until now
# nothing asserted they stay equal — T9 byte-checks only the .sh against its
# source; T8b drives only the .sh. A future edit to one surface that missed the
# other would ship a silently-divergent guard (the recurring cross-install-rot
# class). Drive BOTH surfaces with the same probes and assert identical verdicts —
# behavioral parity, robust to the whitespace/escaping a textual diff trips on.
# The frontmatter command is extracted exactly as Claude Code runs it (a
# single-quoted YAML scalar, '' -> ' unescaped) and fed the hook JSON on stdin.
EVAL_MD="$SRC/agents/evaluator.md"
if [ -f "$READONLY_SH" ] && [ -f "$EVAL_MD" ]; then
  raw=$(sed -n "s/^[[:space:]]*command: '\(COMMAND=.*\)'\$/\1/p" "$EVAL_MD" | head -1)
  fmcmd=${raw//\'\'/\'}
  if [ -z "$fmcmd" ]; then
    no "T8c parity: could not extract evaluator.md frontmatter hook command"
  else
    T8C_OK=1
    while IFS='|' read -r want cmd; do
      [ -z "$want" ] && continue
      j=$(jq -cn --arg a evaluator --arg c "$cmd" '{agent_type:$a,tool_name:"Bash",tool_input:{command:$c}}')
      shv=allow; printf '%s' "$j" | bash "$READONLY_SH" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && shv=deny
      mdv=allow; printf '%s' "$j" | bash -c "$fmcmd"     | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && mdv=deny
      [ "$shv" = "$mdv" ] && [ "$shv" = "$want" ] \
        || { no "frontmatter/script parity broke: '$cmd' -> sh=$shv md=$mdv want=$want"; T8C_OK=0; }
    done <<'T8C'
allow|grep -rn "install" .
allow|cat foo 2>/dev/null
allow|grep "sudo rm" file
deny|sudo rm -rf build
deny|find . | xargs rm
deny|cmd > output.txt
deny|echo x > /tmp/f
T8C
    [ "$T8C_OK" -eq 1 ] && ok "evaluator.md frontmatter and reviewer-readonly.sh enforce identically (dual-surface parity)"
  fi
else
  no "T8c parity: missing $READONLY_SH or $EVAL_MD"
fi

# T9 — hook + helper scripts ship byte-identical (cmp) to their .claude/ sources.
# They are invoked with cwd = the project, so project-relative reads like
# .claude/project.json stay correct without rewriting. The set is DERIVED by
# glob ([7.1]) — a new helper joins this parity check by existing, exactly as
# it joins the build's registry.
T9_OK=1
T9_N=0
for src in "$SRC"/hooks/*.sh "$SRC"/*.sh; do
  T9_N=$((T9_N + 1))
  dst="$PLUGIN/scripts/$(basename "$src")"
  cmp -s "$src" "$dst" || { no "scripts/$(basename "$src") not byte-identical to its .claude/ source"; T9_OK=0; }
done
[ "$T9_OK" -eq 1 ] && ok "all $T9_N hook/helper scripts byte-identical to .claude/ sources (set derived by glob)"

# T10 — the guv-* rules (count derived by glob) ship byte-identical as scaffold assets (plugins
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
WF="$PLUGIN/workflows/eval-parallel.js"
if [ -f "$WF" ]; then
  grep -q "agentType: 'guv:evaluator'" "$WF" && grep -q "agentType: 'guv:reviewer'" "$WF" \
    && ! grep -qE "agentType: '(evaluator|reviewer)'" "$WF" \
    && ok "plugin workflow spawns the namespaced reviewers (guv:evaluator, guv:reviewer)" \
    || no "plugin workflow must use guv:-namespaced agentType (bare names don't resolve from the plugin)"
  diff <(sed "s/agentType: 'guv:/agentType: '/g" "$WF") "$SRC/workflows/eval-parallel.js" >/dev/null 2>&1 \
    && ok "workflow asset identical to the saved workflow modulo agentType namespacing" \
    || no "plugin workflow differs from source beyond the agentType rewrite"
else
  no "plugin/workflows/eval-parallel.js missing"
fi
EP="$PLUGIN/skills/eval-parallel/SKILL.md"
if [ -f "$EP" ] && grep -q 'scriptPath' "$EP" && grep -q 'CLAUDE_PLUGIN_ROOT.*workflows/eval-parallel\.js' "$EP"; then
  ok "eval-parallel skill fronts the asset via scriptPath + \${CLAUDE_PLUGIN_ROOT}"
else
  no "skills/eval-parallel/SKILL.md must invoke the Workflow tool with the plugin-root scriptPath"
fi

# T12 — no stale project-relative script invocations survive inside plugin
# skills OR agents: every helper-script reference must have been rewritten to
# the plugin root (references to project files like .claude/project.json are
# legitimate). The detector's name set is DERIVED by glob ([7.1]) — the hand
# list it replaces had silently fallen three helpers behind the build's — and
# agents/ joined the scan after [7.1]'s routing shipped dead .claude/guv-*.sh
# paths there inside a green battery (the skills-only scan was blind to the
# exact surface the routing touched).
STALE=$(grep -rE "\.claude/(hooks/)?($SCRIPTS_ALT)\.sh" "$PLUGIN/skills" "$PLUGIN/agents" | grep -cv 'CLAUDE_PLUGIN_ROOT')
[ "$STALE" -eq 0 ] \
  && ok "no stale .claude/ script paths in plugin skills or agents (all rewritten to plugin root)" \
  || no "$STALE stale .claude/ script reference(s) remain in plugin/skills|agents"

# T12b — cross-references are namespaced: bare /command mentions and bare
# reviewer-spawn instructions are dead pointers for plugin consumers (plugin
# skills/agents resolve only as guv:<name> — verified live 2026-06-11). The
# preceding-char guard skips path segments and already-namespaced forms; the
# trailing guard skips longer names (/task-foo) and the :-suffixed guv forms.
# Derived from the source tree exactly as the build's slash_names() derives
# its rewrite list — a future command/skill/workflow is covered by both or by
# neither, never silently by one. plugin-src skills (zen, scaffold) register
# as /guv:<name> too; the guard tolerates their absence in a consumer fork
# (maintainers/ deleted), where the detector is just slightly narrower.
CMDS=$(
  {
    for d in "$SRC/skills"/*/; do basename "$d"; done
    for f in "$SRC/workflows"/*.js; do basename "$f" .js; done
    for d in "$ROOT/maintainers/plugin-src/skills"/*/; do
      [ -e "$d" ] && basename "$d"
    done
  } | paste -sd'|' -
)
# --exclude-dir=scripts: bundled single-owner scripts ([8.3]) ship byte-identical
# (NOT namespace-rewritten), so a bare /command in them is legitimate when it
# carries a guv: decoder — exactly the shared-scripts regime (plugin/scripts/ is
# not scanned here either). T12e enforces the decoder on those bundled scripts.
# The qualified-mention filter mirrors the build's protect/restore carve
# ([24.1]): "built-in `/cmd`" / "native `/cmd`" / "bare `/cmd`" name a token
# literally and legitimately stay bare — T12f asserts they survive unmangled.
# Token-granular, matching the carve: the sed strips the qualified mention and
# the line's REMAINDER is re-tested, so a line carrying both a qualified
# mention and a bare use still counts as a violation.
BARE=$(grep -rE --exclude-dir=scripts "(^|[^[:alnum:].:-])/($CMDS)($|[^[:alnum:]:_-])" "$PLUGIN/skills" "$PLUGIN/agents" \
  | sed -E 's#(built-in|native|bare) `/[^`]+`##g' \
  | grep -E "(^|[^[:alnum:].:-])/($CMDS)($|[^[:alnum:]:_-])" | wc -l | tr -d ' ')
[ "$BARE" -eq 0 ] \
  && ok "no bare /command references in plugin skills or agents (all /guv:-namespaced)" \
  || no "$BARE bare /command reference(s) remain in plugin skills/agents"
SPAWN=$(grep -rE '`(evaluator|reviewer)` subagent|@(evaluator|reviewer)([^-]|$)' "$PLUGIN/skills" "$PLUGIN/agents" | wc -l | tr -d ' ')
[ "$SPAWN" -eq 0 ] \
  && ok "no bare reviewer-spawn references in plugin skills or agents" \
  || no "$SPAWN bare reviewer-spawn reference(s) remain"

# T12f — qualified mentions survive the namespace rewrite ([24.1]). A slash
# token qualified as "built-in `/cmd`", "native `/cmd`", or "bare `/cmd`"
# NAMES the token (Claude Code's built-in /init, the source-clone bare
# surface) — mention, not invocation — and the build's protect/restore carve
# must ship it literal. The garble signature is a qualified mention wearing
# the namespace: renaming the door onto the built-in's token turned every
# built-in mention into the namespaced form, and the plugin told consumers
# not to run the canonical door (the [24.1] review's critical finding).
# Case-insensitive: the build's protect matches only lowercase qualifiers, so a
# sentence-initial "Bare `/init`" garbles to "Bare `/guv:init`" — this scan must
# catch that slip loudly rather than let the case gap evade it (pass-3 finding).
GARBLED=$(grep -riE '(built-in|native|bare) `/guv:' "$PLUGIN/skills" "$PLUGIN/agents" | wc -l | tr -d ' ')
[ "$GARBLED" -eq 0 ] \
  && ok "T12f: no qualified mention wears the namespace (mention/use carve holds)" \
  || no "T12f: $GARBLED qualified mention(s) namespaced: $(grep -riEl '(built-in|native|bare) `/guv:' "$PLUGIN/skills" "$PLUGIN/agents" | tr '\n' ' ')"
grep -q 'built-in `/init`' "$PLUGIN/skills/onboard/SKILL.md" \
  && ok "T12f: onboard's callout keeps the literal built-in /init token" \
  || no "T12f: onboard's callout lost the literal built-in /init mention"
grep -q 'built-in `/init`' "$PLUGIN/skills/init/SKILL.md" \
  && ok "T12f: the init canonicality note keeps the literal built-in /init token" \
  || no "T12f: the init canonicality note lost the literal built-in /init mention"

# T12c — no template-clone topology paths survive in plugin skills or agents:
# a plugin consumer has no .claude/skills/, .claude/workflows/, or
# .claude/commands/ (skills, the workflow, and commands all ship inside the
# plugin — commands as plugin skills, so a commands/ path is dead in BOTH
# directions). plugin/shell/ is excluded deliberately: its templates deploy
# into template-clone projects where those paths are real.
DEAD=$(grep -rE '\.claude/(skills|workflows|commands)/' "$PLUGIN/skills" "$PLUGIN/agents" | wc -l | tr -d ' ')
[ "$DEAD" -eq 0 ] \
  && ok "no dead .claude/skills|workflows|commands paths in plugin skills/agents" \
  || no "$DEAD dead template-topology path(s) remain in plugin/skills|agents"

# T12d — files that deploy byte-identical into BOTH install modes (rules,
# shell templates and gitignore) or whose runtime output reaches plugin
# consumers verbatim (shipped scripts, the workflow) may keep bare /command
# mentions — but each bare-mentioned NAME needs its own guv:<name> decoder in
# the same file. The scan is the whole tree inverted (everything outside the
# T12b-covered skills/ and agents/, plus the shipped tests/ — see below), so a
# new file type can never sit outside the guard the way an enumerated surface
# list could.
# plugin/tests/ is excluded: the shipped consumer suites are TEST content, not
# command documentation — they reference command names in assertions/fixtures
# (e.g. grepping for a /replan amendment record), which is not a dead pointer a
# consumer would try to invoke. A decoder comment has no place in a test suite;
# the suites ship byte-identical to their .claude/tests/ sources (ship-suite
# guard), so spraying decoders there would also break that byte-identity.
# NOTE bash 3.2 (macOS /bin/bash) cannot parse comments containing
# apostrophes inside a <(...) substitution — pass 5 found this guard
# erroring and passing vacuously for exactly that reason. Keep substitutions
# comment-free, and keep the SCANNED count + positive control below: they
# make a silent zero-iteration loop impossible to miss again.
# A decoder is either name-specific (guv:<name>) or an explicit all-names
# statement — the standardized generic forms the shipped files use ("…
# guv:-namespaced …", "every name carries the namespace", "namespaced
# /guv:<name>"). An incidental guv:<other-name> mention decodes nothing.
GENERIC_DECODER='guv:`?-namespaced|carries the namespace|/guv:<name>'
t12d_violations() {
  local f n scanned=0
  while IFS= read -r f; do
    scanned=$((scanned + 1))
    grep -qE "(^|[^[:alnum:].:-])/($CMDS)($|[^[:alnum:]:_-])" "$f" 2>/dev/null || continue
    grep -qE "$GENERIC_DECODER" "$f" && continue
    for n in $(printf '%s' "$CMDS" | tr '|' ' '); do
      if grep -qE '(^|[^[:alnum:].:-])/'"$n"'($|[^[:alnum:]:_-])' "$f" 2>/dev/null \
         && ! grep -qE "guv:$n($|[^[:alnum:]_-])" "$f"; then
        printf '%s:%s\n' "$f" "$n"
      fi
    done
  done < <(find "$PLUGIN" -type f -not -path "$PLUGIN/skills/*" -not -path "$PLUGIN/agents/*" -not -path "$PLUGIN/tests/*")
  printf 'SCANNED:%s\n' "$scanned"
}
T12D_OUT=$(t12d_violations)
T12D_SCANNED=$(printf '%s\n' "$T12D_OUT" | grep '^SCANNED:' | cut -d: -f2)
T12D_VIOL=$(printf '%s\n' "$T12D_OUT" | grep -v '^SCANNED:' | grep -c . )
if [ "${T12D_SCANNED:-0}" -gt 0 ] && [ "$T12D_VIOL" -eq 0 ]; then
  ok "full-tree scan ($T12D_SCANNED files): every bare-mentioned /command has its guv: decoder"
else
  no "T12d: scanned=$T12D_SCANNED, violations: $(printf '%s\n' "$T12D_OUT" | grep -v '^SCANNED:' | tr '\n' ' ')"
fi
# positive control — the same plumbing must FLAG a planted violation; a guard
# that can only ever report success is not a guard (the pass-5 lesson)
T12D_FIX="$PLUGIN/zz-t12d-fixture.md"
# Leftover from a crashed run → clean and proceed (throwaway path), never
# hard-fail the battery (feedback 2026-06-12T04:35:14Z-143815213).
[ -e "$T12D_FIX" ] && { echo "  - cleaning a stale T12d fixture (prior crashed run): $T12D_FIX"; rm -f "$T12D_FIX"; }
trap 'rm -f "$T12D_FIX"' EXIT
printf 'Planted violation: run /handoff now, with no decoder in this file.\n' > "$T12D_FIX"
T12D_OUT2=$(t12d_violations)
if printf '%s\n' "$T12D_OUT2" | grep -q 'zz-t12d-fixture.md:handoff'; then
  ok "positive control: the scan flags a planted bare mention without a decoder"
else
  no "T12d positive control failed — the scan did not flag the planted violation"
fi
rm -f "$T12D_FIX"
trap - EXIT

# T12e — SOURCE-side decoder lint: the in-lane shift-left of T12d. T12d scans the
# BUILT plugin/, which a source-only fan-out lane never rebuilds (the join owns
# the rebuild; lane-dispatch confine even refuses a lane that touches plugin/).
# So a new script's bare /command with no guv: decoder slips every rebuild-free
# in-lane check and surfaces only at the join battery — exactly how [9.6]'s
# estimate.sh missed its /plan + /replan decoders. This lint applies
# the SAME decoder rule to the source that reaches plugin consumers verbatim for
# slash-command purposes — the FULL byte-identical-shipping surface, both halves:
#   - .claude helper + hook scripts        -> scripts/ (byte-identical)
#   - .claude/skills/*/scripts/*.sh        -> skills/<name>/scripts/ (byte-identical;
#                                             [8.3] single-owner bundle, referenced
#                                             via ${CLAUDE_SKILL_DIR}, NOT rewritten)
#   - maintainers/plugin-src/scripts/*.sh  -> scripts/ (byte-identical; authored
#                                             plugin-only, but lane-editable
#                                             source — confine T3c permits it)
#   - .claude/rules/guv-*.md               -> rules/   (byte-identical)
#   - .claude/workflows/*.js               -> workflows/ (rewritten ONLY at its
#                                             agentType lines, never at /command
#                                             mentions — so the decoder rule holds)
# No plugin/ rebuild needed, so it fires the moment any context runs the suite,
# naming the SOURCE file. SKILL.md/agent prose is excluded — the build
# namespace-rewrites those in transit, so bare mentions there are fixed on the
# way in (T12b owns that surface); bundled skill scripts/ are NOT rewritten, so
# they ARE scanned here. Reuses $CMDS and $GENERIC_DECODER from
# T12b/T12d. Runs unconditionally (no plugin/ dependency; tolerates an absent
# maintainers/), so it is the one plugin-transform check a lane can run.
t12e_sources() {
  local x
  for x in "$SRC"/*.sh "$SRC"/hooks/*.sh "$SRC"/skills/*/scripts/*.sh \
           "$ROOT"/maintainers/plugin-src/scripts/*.sh \
           "$SRC"/rules/guv-*.md "$SRC"/workflows/*.js; do
    [ -e "$x" ] && echo "$x"
  done
}
t12e_violations() {
  local f n scanned=0
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    scanned=$((scanned + 1))
    grep -qE "(^|[^[:alnum:].:-])/($CMDS)($|[^[:alnum:]:_-])" "$f" 2>/dev/null || continue
    grep -qE "$GENERIC_DECODER" "$f" && continue
    for n in $(printf '%s' "$CMDS" | tr '|' ' '); do
      if grep -qE '(^|[^[:alnum:].:-])/'"$n"'($|[^[:alnum:]:_-])' "$f" 2>/dev/null \
         && ! grep -qE "guv:$n($|[^[:alnum:]_-])" "$f"; then
        printf '%s:%s\n' "$(basename "$f")" "$n"
      fi
    done
  done < <(t12e_sources)
  printf 'SCANNED:%s\n' "$scanned"
}
T12E_OUT=$(t12e_violations)
T12E_SCANNED=$(printf '%s\n' "$T12E_OUT" | grep '^SCANNED:' | cut -d: -f2)
T12E_VIOL=$(printf '%s\n' "$T12E_OUT" | grep -v '^SCANNED:' | grep -c . )
if [ "${T12E_SCANNED:-0}" -gt 0 ] && [ "$T12E_VIOL" -eq 0 ]; then
  ok "source decoder lint ($T12E_SCANNED files): every bare /command in a byte-identical-shipping source carries its guv: decoder"
else
  no "T12e: scanned=$T12E_SCANNED, source violations: $(printf '%s\n' "$T12E_OUT" | grep -v '^SCANNED:' | tr '\n' ' ')"
fi
# positive control — plant a source script with a bare mention and no decoder
T12E_FIX="$SRC/zz-t12e-fixture.sh"
# Leftover from a crashed run → clean and proceed (throwaway path), never
# hard-fail the battery (feedback 2026-06-12T04:35:14Z-143815213).
[ -e "$T12E_FIX" ] && { echo "  - cleaning a stale T12e fixture (prior crashed run): $T12E_FIX"; rm -f "$T12E_FIX"; }
trap 'rm -f "$T12E_FIX"' EXIT
printf '#!/bin/bash\n# Planted violation: mentions /handoff with no guv: decoder.\n' > "$T12E_FIX"
T12E_OUT2=$(t12e_violations)
if printf '%s\n' "$T12E_OUT2" | grep -q 'zz-t12e-fixture.sh:handoff'; then
  ok "positive control: the source lint flags a planted bare mention without a decoder"
else
  no "T12e positive control failed — the source scan did not flag the planted violation"
fi
rm -f "$T12E_FIX"
trap - EXIT

# T13 — no install-time tooling (spec constraint, Phase 5 scoped): the plugin
# may use the native manifest format but ships no postinstall machinery.
T13_OK=1
[ -e "$PLUGIN/package.json" ] && { no "package.json found in plugin (install-time tooling)"; T13_OK=0; }
jq -e '.scripts // .install // .postinstall' "$MANIFEST" >/dev/null 2>&1 && { no "manifest carries install-time keys"; T13_OK=0; }
[ "$T13_OK" -eq 1 ] && ok "no install-time tooling (native manifest only)"

# T14 — drift guard: the committed plugin/ is exactly what build-plugin.sh
# produces from today's sources. A diff here means someone edited plugin/ by
# hand or changed .claude/ without rebuilding. A template-clone consumer fork
# that dropped maintainers/ has no build to drift from — skip cleanly with a
# message (same pattern as sandbox-example's removed-Docker-tier skip), never
# silently and never as a failure.
if [ -f "$BUILD" ]; then
  TMP=$(mktemp -d)
  if bash "$BUILD" --out "$TMP/plugin" >/dev/null 2>&1 && diff -r "$TMP/plugin" "$PLUGIN" >/dev/null 2>&1; then
    ok "rebuild reproduces the committed plugin/ byte-for-byte (no drift)"
  else
    no "build-plugin.sh --out output differs from committed plugin/ (rebuild needed?)"
  fi
  rm -rf "$TMP"

  # T15 — the build fails loud on an authored/derived skill-name collision
  # instead of silently clobbering the authored copy. Fixture: a plugin-src
  # skill named like an existing command; cleaned up by trap even on failure.
  FIXTURE="$ROOT/maintainers/plugin-src/skills/status"
  # Leftover from a crashed run → clean and proceed (throwaway path), never
  # hard-fail the battery (feedback 2026-06-12T04:35:14Z-143815213).
  [ -e "$FIXTURE" ] && { echo "  - cleaning a stale collision fixture (prior crashed run): $FIXTURE"; rm -rf "$FIXTURE"; }
  trap 'rm -rf "$FIXTURE"' EXIT
  mkdir -p "$FIXTURE"
  printf -- '---\ndescription: "collision fixture"\n---\nx\n' > "$FIXTURE/SKILL.md"
  TMP2=$(mktemp -d)
  if bash "$BUILD" --out "$TMP2/plugin" >/dev/null 2>&1; then
    no "build must fail when a derived command collides with an authored skill"
  else
    ok "build fails loud on authored/derived skill-name collision"
  fi
  rm -rf "$TMP2" "$FIXTURE"
  trap - EXIT

  # T15b — adjacent-mention rewrite: the boundary guard consumes the char
  # between two adjacent /commands, so a single sed pass misses the second —
  # the double-pass exists for exactly this. Fixture command exercises it
  # end-to-end through a real build.
  FIX2DIR="$SRC/skills/zzadjacency-fixture"
  FIX2="$FIX2DIR/SKILL.md"
  # A pre-existing fixture is a leftover from a crashed run (the path is a known
  # zz-throwaway, never a real skill) — clean it and proceed, never hard-fail
  # the battery. Hard-failing here is what let one crashed run poison the next
  # and false-fail overlapping runs (feedback 2026-06-12T04:35:14Z-143815213).
  [ -e "$FIX2DIR" ] && { echo "  - cleaning a stale adjacency fixture (prior crashed run): $FIX2DIR"; rm -rf "$FIX2DIR"; }
  trap 'rm -rf "$FIX2DIR"' EXIT
  mkdir -p "$FIX2DIR"
  printf 'Adjacency fixture for the namespace rewrite.\n\nRun /task /handoff together, then /status /eval too.\n' > "$FIX2"
  TMP3=$(mktemp -d)
  if bash "$BUILD" --out "$TMP3/plugin" >/dev/null 2>&1 \
     && grep -q '/guv:task /guv:handoff' "$TMP3/plugin/skills/zzadjacency-fixture/SKILL.md" \
     && grep -q '/guv:status /guv:eval' "$TMP3/plugin/skills/zzadjacency-fixture/SKILL.md"; then
    ok "adjacent /command mentions both rewritten (double-pass verified end-to-end)"
  else
    no "adjacent /command mentions must both be namespaced by the double-pass"
  fi
  rm -rf "$TMP3" "$FIX2DIR"
  trap - EXIT

  # T15c — glob-derived helper registry ([7.1]): a helper dropped into
  # .claude/ ships and gets path-rewritten with ZERO enumeration-list edits.
  # Fixture: a throwaway helper plus a skill mentioning it; rebuild; the
  # helper must land in scripts/ byte-identical AND the mention must be
  # rewritten to ${CLAUDE_PLUGIN_ROOT}. Red until the HELPERS list and
  # rewrite_paths derive from the source tree.
  FIX3="$SRC/zzregistry-fixture.sh"
  FIX3DIR="$SRC/skills/zzregistry-fixture-cmd"
  FIX3CMD="$FIX3DIR/SKILL.md"
  # Leftovers from a crashed run → clean and proceed (throwaway paths), never
  # hard-fail the battery (feedback 2026-06-12T04:35:14Z-143815213).
  { [ -e "$FIX3" ] || [ -e "$FIX3DIR" ]; } && { echo "  - cleaning stale registry fixtures (prior crashed run)"; rm -rf "$FIX3" "$FIX3DIR"; }
  trap 'rm -rf "$FIX3" "$FIX3DIR"' EXIT
  printf '#!/bin/bash\necho zzregistry-fixture\n' > "$FIX3"
  mkdir -p "$FIX3DIR"
  printf 'Registry fixture.\n\nRun `bash .claude/zzregistry-fixture.sh` to exercise the registry.\n' > "$FIX3CMD"
  TMP4=$(mktemp -d)
  if bash "$BUILD" --out "$TMP4/plugin" >/dev/null 2>&1 \
     && cmp -s "$FIX3" "$TMP4/plugin/scripts/zzregistry-fixture.sh" \
     && grep -q 'CLAUDE_PLUGIN_ROOT.*scripts/zzregistry-fixture\.sh' "$TMP4/plugin/skills/zzregistry-fixture-cmd/SKILL.md"; then
    ok "fixture helper ships and rewrites with zero enumeration-list edits (registry is glob-derived)"
  else
    no "a dropped-in helper must ship in scripts/ and be path-rewritten without touching any list"
  fi
  rm -rf "$TMP4" "$FIX3" "$FIX3DIR"
  trap - EXIT

  # T16 — consumer-fork resilience: with the build script absent, the whole
  # suite must still exit 0 (the drift guard skips; nothing else needs
  # maintainers/). The inner output must SHOW the skip fired — exit 0 alone
  # would also pass if the skip block were deleted (the suite passes whole in
  # the canonical repo), making the self-check vacuous. Guarded against
  # recursion via PLUGIN_TEST_INNER.
  if [ -z "${PLUGIN_TEST_INNER:-}" ]; then
    INNER=$(PLUGIN_TEST_INNER=1 PLUGIN_BUILD_SCRIPT="$ROOT/nonexistent-build.sh" bash "$SELF" 2>&1)
    if [ $? -eq 0 ] && echo "$INNER" | grep -q "skipping drift guard"; then
      ok "suite passes in a consumer fork (build script absent -> drift guard skips)"
    else
      no "suite must exit 0 AND visibly skip when maintainers/build-plugin.sh is absent"
    fi
    # T16c — the inner self-invocation must SKIP the run-plugin-tests reconstruction
    # (T18): it is build-independent, the outer run covers it, and re-running it in
    # every self-invocation tripled the battery's heaviest op. The positive grep
    # (skip marker present) is load-bearing; the negative grep guards against the
    # gate silently falling through and ALSO running the reconstruction. It targets
    # the outer T18 success line's UNIQUE "in plugin layout" phrasing — the elif
    # rebuild branch's "...runs the shipped suite green ([10.3])" omits it — so the
    # negative half can't false-pass on a future branch-structure change.
    if echo "$INNER" | grep -q "skipping run-plugin-tests.sh reconstruction" \
       && ! echo "$INNER" | grep -q "runs the shipped suite green in plugin layout"; then
      ok "inner self-invocation skips the redundant run-plugin-tests reconstruction (battery cost)"
    else
      no "inner self-invocation must skip the run-plugin-tests reconstruction (build-independent; outer covers it)"
    fi
    # T16b — same proof for the plugin-deleted fork (README's deletion note)
    INNER=$(PLUGIN_TEST_INNER=1 PLUGIN_TEST_TREE="$ROOT/nonexistent-plugin" bash "$SELF" 2>&1)
    if [ $? -eq 0 ] && echo "$INNER" | grep -q "suite skips"; then
      ok "suite skips wholesale in a fork that deleted plugin/"
    else
      no "suite must exit 0 and visibly skip when plugin/ is absent"
    fi
  fi
else
  echo "  - maintainers/build-plugin.sh absent (consumer fork) — skipping drift guard"
fi

# T17 — settings↔plugin hook parity. The plugin hooks.json is now DERIVED from
# .claude/settings.json (build-plugin), so parity holds by construction — this
# guard is the backstop on the COMMITTED plugin tree: it fails on a hand-edit to
# plugin/hooks.json or a derivation regression. The [9.2] occupancy meter
# shipped dead to plugin consumers precisely because the two surfaces were
# hand-wired independently; derivation removes the second copy and this guard
# proves the shipped artifact still carries every settings hook. Every
# event-hook script registered in .claude/settings.json MUST have a matching
# command registration in the committed plugin hooks.json for the SAME event,
# matched by script basename (the surfaces differ only in path prefix:
# .claude/hooks/X.sh vs ${CLAUDE_PLUGIN_ROOT}/scripts/X.sh). DIRECTIONAL by
# design: settings ⊆ plugin — hooks.json legitimately carries the one
# plugin-only entry (reviewer-readonly.sh, whose project-mode equivalent rides
# the reviewer agents' frontmatter hooks: block, asserted by T7). T17b proves
# the derivation propagates a NEW settings hook; this proves the committed
# artifact matches today's settings. (Past the suite's plugin/-present skip,
# the committed hooks.json is always there; the guard still tolerates absence.)
PLUGIN_HOOKS="$HOOKS_JSON"
if [ ! -f "$SRC/settings.json" ] || [ ! -f "$PLUGIN_HOOKS" ]; then
  echo "  - settings.json or plugin hooks.json absent — skipping settings↔plugin parity guard"
elif ! jq -e . "$PLUGIN_HOOKS" >/dev/null 2>&1; then
  no "plugin hooks.json is not valid JSON: $PLUGIN_HOOKS"
else
  # basenames of the hook scripts registered for an event on a given surface
  event_scripts() { jq -r --arg e "$1" '.hooks[$e][]?.hooks[]?.command' "$2" 2>/dev/null | grep -oE '[A-Za-z0-9_-]+\.sh' | sort -u; }
  PARITY_MISSING=""
  for ev in PreToolUse PostToolUse Stop; do
    plugin_set=$(event_scripts "$ev" "$PLUGIN_HOOKS")
    while IFS= read -r script; do
      [ -z "$script" ] && continue
      printf '%s\n' "$plugin_set" | grep -qx "$script" \
        || PARITY_MISSING="$PARITY_MISSING [$ev:$script]"
    done <<EOF
$(event_scripts "$ev" "$SRC/settings.json")
EOF
  done
  [ -z "$PARITY_MISSING" ] \
    && ok "every settings.json hook is registered in the plugin hooks.json for the same event (settings↔plugin parity)" \
    || no "settings.json hooks missing from plugin hooks.json (plugin consumers get dead hooks):$PARITY_MISSING"

  # positive control — a guard that can only report success is not a guard
  # (the pass-5 lesson, T12d). Plant a settings.json that wires a hook absent
  # from the committed plugin hooks.json and confirm the parity check FLAGS it.
  PC_SETTINGS=$(mktemp)
  jq '.hooks.Stop[0].hooks += [{"type":"command","command":"bash .claude/hooks/zz-parity-fixture.sh"}]' "$SRC/settings.json" > "$PC_SETTINGS"
  PC_MISSING=""
  for ev in PreToolUse PostToolUse Stop; do
    plugin_set=$(event_scripts "$ev" "$PLUGIN_HOOKS")
    while IFS= read -r script; do
      [ -z "$script" ] && continue
      printf '%s\n' "$plugin_set" | grep -qx "$script" \
        || PC_MISSING="$PC_MISSING [$ev:$script]"
    done <<EOF
$(event_scripts "$ev" "$PC_SETTINGS")
EOF
  done
  case "$PC_MISSING" in
    *zz-parity-fixture.sh*) ok "positive control: the parity check flags a planted settings-only hook" ;;
    *) no "parity positive control failed — a planted settings-only hook was not flagged" ;;
  esac
  rm -f "$PC_SETTINGS"
fi

# T17b — the plugin hooks.json is DERIVED from settings.json, not a
# hand-maintained second copy (the [9.2] dead-hook root: two-place wiring with
# nothing enforcing parity). A hook wired into settings.json must reach plugin
# consumers WITHOUT a second edit. Proof end-to-end: build with a settings.json
# carrying a synthetic Stop hook (the PLUGIN_SETTINGS seam) and confirm the
# derived plugin hooks.json carries it under the SAME event with the path
# rewritten to the plugin root. Red against a verbatim-copy build (which ignores
# settings.json for hooks entirely). The reviewer-readonly guard — the one
# plugin-only hook, compensating for the agent frontmatter hooks: block the
# build strips — is asserted separately by T7; here we prove the settings→plugin
# flow that makes a silent miss impossible.
if [ -f "$BUILD" ] && [ -f "$SRC/settings.json" ]; then
  T17B_SET=$(mktemp)
  jq '.hooks.Stop[0].hooks += [{"type":"command","command":"bash .claude/hooks/zz-derive-fixture.sh"}]' "$SRC/settings.json" > "$T17B_SET"
  T17B_TMP=$(mktemp -d)
  if PLUGIN_SETTINGS="$T17B_SET" bash "$BUILD" --out "$T17B_TMP/plugin" >/dev/null 2>&1 \
     && jq -e '[.hooks.Stop[]?.hooks[]?.command] | any(. == "bash \"${CLAUDE_PLUGIN_ROOT}\"/scripts/zz-derive-fixture.sh")' \
          "$T17B_TMP/plugin/hooks/hooks.json" >/dev/null 2>&1; then
    ok "plugin hooks.json is derived from settings.json (a new settings hook reaches the plugin, path-rewritten)"
  else
    no "a hook added to settings.json must appear in the derived plugin hooks.json (settings→plugin derivation)"
  fi
  rm -rf "$T17B_TMP" "$T17B_SET"
fi

# T18 — shipped test suites + the layout-reconstructing runner ([10.3]). The
# build ships the consumer-meaningful suites into plugin/tests/ (the glob set
# minus the maintainer-only suites) with run-plugin-tests.sh, which rebuilds a
# temp .claude/-shaped tree from the FLATTENED scripts/ so the location-relative
# suites run unmodified. This is the drift assertion: a shipped suite that can no
# longer resolve its scripts in plugin layout turns the runner red here. The full
# partition + positive-control drift guard live in ship-suite.test.sh; this is the
# committed-tree backstop, paralleling T14's drift guard for the plugin proper.
# Skipped in a fork that dropped maintainers/ (no build to exercise — same guard
# as T14). The committed plugin/ is also checked directly (no rebuild) so the
# guard catches a hand-deleted plugin/tests/.
if [ -d "$PLUGIN/tests" ]; then
  ok "committed plugin/tests/ ships the consumer suites"
  # named maintainer-only suites must be absent from the committed tree
  T18_LEAK=0
  for b in plugin.test.sh setup-control-plane.test.sh single-writer.test.sh release.test.sh; do
    [ -e "$PLUGIN/tests/$b" ] && { no "maintainer-only suite leaked into committed plugin/tests/: $b"; T18_LEAK=1; }
  done
  [ "$T18_LEAK" -eq 0 ] && ok "no named maintainer-only suite in committed plugin/tests/"
  RUNNER="$PLUGIN/tests/run-plugin-tests.sh"
  if [ -x "$RUNNER" ]; then
    if [ -n "${PLUGIN_TEST_INNER:-}" ]; then
      # Inner self-invocation (the T16/T16b consumer-fork probes): SKIP the
      # reconstruction. run-plugin-tests.sh is BUILD-INDEPENDENT — it runs the
      # committed plugin/ regardless of the consumer-fork condition being probed —
      # so the outer run already covers it. Re-running it inside every self-
      # invocation only re-paid the battery's single heaviest op (a full shipped-
      # suite reconstruction) for zero added coverage; the inner runs exist to
      # prove the suite still exits 0 + skips, not to re-exercise the runner.
      echo "  - PLUGIN_TEST_INNER: skipping run-plugin-tests.sh reconstruction (build-independent; covered by the outer run)"
    else
      # stderr captured to a temp file (mktemp, never $ROOT) — writing into the
      # git-tracked repo root would dirty the working tree on a crash between the
      # run and the cleanup. Matches the elif mktemp branch and the runner heredoc.
      T18_ERR=$(mktemp)
      if bash "$RUNNER" >/dev/null 2>"$T18_ERR"; then
        ok "run-plugin-tests.sh runs the shipped suite green in plugin layout (committed tree)"
      else
        no "the shipped suite must run green via run-plugin-tests.sh (a suite can't resolve its scripts in plugin layout?)"
      fi
      [ -s "$T18_ERR" ] \
        && no "run-plugin-tests.sh emitted to stderr: $(head -c 200 "$T18_ERR")" \
        || ok "run-plugin-tests.sh reconstruction is stderr-clean (committed tree)"
      rm -f "$T18_ERR"
    fi
  else
    no "plugin/tests/run-plugin-tests.sh must ship executable"
  fi
elif [ -f "$BUILD" ]; then
  # plugin/tests absent but a build exists -> stale committed tree; rebuild and
  # prove the runner green against the fresh build so the guard still fires
  T18_TMP=$(mktemp -d)
  if bash "$BUILD" --out "$T18_TMP/plugin" >/dev/null 2>&1 \
     && [ -x "$T18_TMP/plugin/tests/run-plugin-tests.sh" ] \
     && bash "$T18_TMP/plugin/tests/run-plugin-tests.sh" >/dev/null 2>&1; then
    ok "rebuild ships plugin/tests/ and the runner runs the shipped suite green ([10.3])"
  else
    no "build must ship plugin/tests/ with a runner that runs the shipped suite green"
  fi
  rm -rf "$T18_TMP"
else
  echo "  - plugin/tests absent and no build (consumer fork) — skipping shipped-suite drift guard"
fi

finish
