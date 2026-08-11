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
#
# EVERY check here runs against a tree this suite BUILDS, never against the
# committed plugin/ ([32.5]). plugin/ is the release artifact — frozen between
# releases, so source legitimately runs ahead of it and a battery that diffed
# the two would red on the model working as designed. "Does the committed tree
# match source" moved to the release gate (build-plugin.sh --check, pinned by
# release.test.sh); what stays here is what the BUILD must be true of, which is
# what these invariants were always really about.
# Live behaviors (skill resolution under /guv:, hook firing under plugin install)
# need a real session: covered by dogfood runs and the Phase 5 UAT, not here.
# Pure bash + jq, no test runner required.
# Run: bash .claude/tests/plugin.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SELF="$ROOT/.claude/tests/$(basename "$0")"   # absolute — $0-relative re-invocation breaks if a cd ever lands in the main shell
SRC="$ROOT/.claude"
BUILD="${PLUGIN_BUILD_SCRIPT:-$ROOT/maintainers/build-plugin.sh}"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# A consumer fork that dropped maintainers/ has no build to verify — skip the
# whole suite cleanly, never as failures. (Before [32.5] this gate was on
# plugin/ instead; the suite read the committed tree, so its absence was what
# left nothing to check. Now the build script is the dependency and plugin/ is
# never read here at all.)
if [ ! -f "$BUILD" ]; then
  echo "  - maintainers/build-plugin.sh absent (consumer fork) — suite skips"
  echo ""
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

# The tree under test: built here, from today's source. The battery's runner
# exports GUV_BUILT_PLUGIN so one build serves every suite that needs one (a
# build is ~9s); a standalone run builds its own and gets the identical tree.
PLUGIN_BUILD_TMP=""
if [ -n "${GUV_BUILT_PLUGIN:-}" ] && [ -d "${GUV_BUILT_PLUGIN:-}" ]; then
  PLUGIN="$GUV_BUILT_PLUGIN"
else
  PLUGIN_BUILD_TMP=$(mktemp -d)
  PLUGIN="$PLUGIN_BUILD_TMP/plugin"
  if ! bash "$BUILD" --out "$PLUGIN" >/dev/null 2>&1; then
    echo "  ✗ build-plugin.sh failed — nothing to verify" >&2
    rm -rf "$PLUGIN_BUILD_TMP"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
  fi
fi
MANIFEST="$PLUGIN/.claude-plugin/plugin.json"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
READONLY_SH="$PLUGIN/scripts/reviewer-readonly.sh"

finish() {
  [ -n "$PLUGIN_BUILD_TMP" ] && rm -rf "$PLUGIN_BUILD_TMP"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}

# ── hermetic source root (spike Prong B) ─────────────────────────────────────
# The build sub-tests below PLANT fixtures and then build. Planting them into the
# LIVE source tree is what makes this suite unsafe to run beside anything that
# reads that tree — another copy of itself, ship-suite.test.sh's build, or an
# agent reading git state mid-run. It is the shared root cause of four friction
# entries: 2026-06-29T18:50:15Z-1575732184 (a leftover fixture from a crashed run
# reds the next battery), 2026-07-18T17:33:15Z-149671608 (the tree goes
# transiently phantom-dirty), 2026-07-21T17:00:10Z-1640628803 (concurrent QA
# agents false-red each other), 2026-07-18T05:23:41Z-7113820 (whole-live-tree
# diff picks up junk).
#
# So plant into a COPY. No builder flag is needed and none was added:
# build-plugin.sh derives its ROOT from its own location, so a copied tree's
# builder builds that copy — verified byte-identical to a live-tree build. .git
# and plugin/ are excluded because the builder reads neither, and .git is 26M of
# the repo's 30M; what remains is ~2.8M and copies in well under a second.
mk_source_copy() {   # echoes a scratch root holding a buildable copy of $ROOT
  local d err; d=$(mktemp -d); err="$d.tar-err"
  ( cd "$ROOT" && tar -cf - --exclude=.git --exclude=plugin . ) 2>"$err" \
    | ( cd "$d" && tar -xf - ) 2>>"$err"
  # Fail loud, and in the right place. Both tars used to send stderr to
  # /dev/null: a copy that died half-way (a vanishing file, a permission, a
  # full disk) returned a partial tree, and the first thing to notice was T14
  # reporting "rebuild needed?" — a drift verdict against a source tree that
  # was never complete. Structural check only, so tar's benign
  # "file changed as we read it" warnings stay quiet; when the copy really is
  # short, tar's own message is what gets printed.
  #
  # Sentinel on the BUILDER, not on `.claude/`. Every caller below dereferences
  # $d/maintainers/build-plugin.sh, and tar writes `.claude/` among the first
  # entries and `maintainers/` much later — so a `.claude/` check passes on exactly
  # the truncation shape that matters (a copy that died part-way) and the misleading
  # drift verdict comes back anyway. Check the artifact the callers actually need.
  if [ ! -f "$d/maintainers/build-plugin.sh" ]; then
    printf '  ! mk_source_copy: the scratch copy of %s is INCOMPLETE (no maintainers/build-plugin.sh at %s).\n' "$ROOT" "$d" >&2
    printf '    Every check built on this copy below is unreliable — this is NOT plugin drift.\n' >&2
    [ -s "$err" ] && sed 's/^/    tar: /' "$err" >&2
  fi
  rm -f "$err"
  printf '%s' "$d"
}
# The copy's own builder, at the same repo-relative path as $BUILD, so a
# PLUGIN_BUILD_SCRIPT override pointing inside the repo is still honored. An
# override pointing elsewhere is used as-is (only the enclosing `[ -f "$BUILD" ]`
# gate cares about it, and that gate has already decided a build exists).
copy_build() {  # <scratch-root> → the build script to invoke inside it
  case "$BUILD" in
    "$ROOT"/*) printf '%s' "$1/${BUILD#"$ROOT"/}" ;;
    *)         printf '%s' "$BUILD" ;;
  esac
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
for d in skills agents hooks scripts rules; do
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

# T6 — the reviewer agent ships, with the frontmatter hooks: block STRIPPED
# (plugin agents do not support frontmatter hooks — security restriction in the
# plugin docs) and everything else preserved: name, tools, memory, and the body.
T6_OK=1
for a in reviewer; do
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
       <(awk '/^---$/{n++; next} n>=2' "$pa" | sed -E 's|/guv:|/|g; s|@guv:|@|g; s|`guv:(reviewer)` subagent|`\1` subagent|g') >/dev/null 2>&1 \
    || { no "agent $a body differs from source beyond the namespace + path rewrites"; T6_OK=0; }
done
[ "$T6_OK" -eq 1 ] && ok "the reviewer ships hook-free with name/tools/body preserved"

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
  out=$(printf '%s' '{"agent_type":"reviewer","tool_name":"Bash","tool_input":{"command":"ls /tmp | head -3"}}' | bash "$READONLY_SH"); rc=$?
  [ $rc -eq 0 ] && ! echo "$out" | grep -q 'deny' \
    && ok "reviewer + read-only command -> allowed" \
    || no "reviewer read-only command must pass"
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
  # plugin agents resolve NAMESPACED (verified live 2026-06-11 with the
  # then-shipped guv:evaluator): agent_type arrives prefixed, so the guard must
  # match that form too
  out=$(printf '%s' '{"agent_type":"guv:reviewer","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' | bash "$READONLY_SH")
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && ok "guv:reviewer (namespaced plugin form) + write-pattern -> deny" \
    || no "guv:reviewer write-pattern must be denied (plugin agents resolve namespaced)"
  # T8b — [32.3] posture probes for the surviving reviewer arm. (The [20.1]
  # SCRUB machinery and its over/under-block table lived in the evaluator arm
  # and retired with the evaluator agent at [32.3]; these probes pin what the
  # reviewer arm actually is — a command-position write-verb match, with
  # redirects an accepted UNDER-block whose backstop is the isolation tier.)
  evjson() { jq -cn --arg a "$1" --arg c "$2" '{agent_type:$a,tool_name:"Bash",tool_input:{command:$c}}'; }
  while IFS='|' read -r agent verdict cmd; do
    [ -z "$agent" ] && continue
    out=$(evjson "$agent" "$cmd" | bash "$READONLY_SH"); rc=$?
    denied=no; echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 && denied=yes
    if [ "$verdict" = allow ]; then
      [ $rc -eq 0 ] && [ "$denied" = no ] \
        && ok "reviewer allows: $cmd" \
        || no "reviewer over-blocks: $cmd"
    else
      [ "$denied" = yes ] \
        && ok "reviewer denies write verb at command position: $cmd" \
        || no "reviewer under-blocks a real write: $cmd"
    fi
  done <<'T8B'
reviewer|allow|grep -rn "install" .
reviewer|allow|grep "rm -rf" notes.md
reviewer|allow|make test 2>&1
reviewer|allow|echo done > /tmp/log
guv:reviewer|allow|cat docs/REQUIREMENTS.md
reviewer|deny|rm -rf build
reviewer|deny|git push origin main
guv:reviewer|deny|python -c "print()"
T8B
else
  no "reviewer-readonly.sh missing: $READONLY_SH"
fi

# T8c — dual-surface parity, retargeted to the reviewer at [32.3] (the
# evaluator surface retired with the agent). The project-mode reviewer.md
# frontmatter carries the SAME write-verb pattern as the plugin
# reviewer-readonly.sh's reviewer arm, but nothing else asserts they stay
# equal — T9 byte-checks only the .sh against its source. A future edit to one
# surface that missed the other would ship a silently-divergent guard (the
# recurring cross-install-rot class). Drive BOTH surfaces with the same probes
# and assert identical VERDICTS — behavioral parity, robust to the
# whitespace/escaping a textual diff trips on. (Deny MESSAGES differ by
# design: the frontmatter says "Reviewer", the plugin arm "Product reviewer".)
# The frontmatter command is a YAML block scalar — extracted as the lines
# under `command: |`, de-indented, and fed the hook JSON on stdin.
REV_MD_SRC="$SRC/agents/reviewer.md"
if [ -f "$READONLY_SH" ] && [ -f "$REV_MD_SRC" ]; then
  fmcmd=$(awk '/^[[:space:]]*command: \|/{f=1; next} f && /^---$/{exit} f{sub(/^[[:space:]]{12}/,""); print}' "$REV_MD_SRC")
  if [ -z "$fmcmd" ]; then
    no "T8c parity: could not extract reviewer.md frontmatter hook command"
  else
    T8C_OK=1
    while IFS='|' read -r want cmd; do
      [ -z "$want" ] && continue
      j=$(evjson reviewer "$cmd")
      shv=allow; printf '%s' "$j" | bash "$READONLY_SH" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && shv=deny
      mdv=allow; printf '%s' "$j" | bash -c "$fmcmd"     | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && mdv=deny
      [ "$shv" = "$mdv" ] && [ "$shv" = "$want" ] \
        || { no "frontmatter/script parity broke: '$cmd' -> sh=$shv md=$mdv want=$want"; T8C_OK=0; }
    done <<'T8C'
allow|grep -rn "install" .
allow|grep "rm -rf" notes.md
allow|echo done > /tmp/log
deny|rm -rf build
deny|git push origin main
deny|python -c "print()"
T8C
    [ "$T8C_OK" -eq 1 ] && ok "reviewer.md frontmatter and reviewer-readonly.sh enforce identically (dual-surface parity)"
  fi
else
  no "T8c parity: missing $READONLY_SH or $REV_MD_SRC"
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

# T11 — retired at [32.1] (spec-2026-07-31): the eval-parallel workflow and its
# fronting skill left the plugin — the review gate is /code-review plus the
# reviewer agent (skills/eval). The eval-parallel-specific assertions died with
# their subject. This tombstone keeps the T-numbering stable for the suites
# that cite it.
if [ ! -f "$PLUGIN/workflows/eval-parallel.js" ] && [ ! -d "$PLUGIN/skills/eval-parallel" ]; then
  ok "eval-parallel workflow and skill are retired from the plugin ([32.1])"
else
  no "eval-parallel must not ship: retired at [32.1] (stale plugin artifact — rebuild)"
fi

# T11b — retired at [32.3] (spec-2026-07-31): the lane cluster left with the
# build-fanout skill/workflow and the evaluator agent — no workflows ship at
# all now, so the plugin has no workflows/ dir. Same tombstone idiom as T11:
# a stale rebuild is the failure this catches.
if [ ! -d "$PLUGIN/workflows" ] && [ ! -d "$PLUGIN/skills/build-fanout" ] && [ ! -f "$PLUGIN/agents/evaluator.md" ] \
   && [ ! -f "$PLUGIN/agents/lane-builder.md" ] && [ ! -f "$PLUGIN/scripts/guv-lane.sh" ] && [ ! -f "$PLUGIN/scripts/fanout-offer.sh" ]; then
  ok "the lane cluster and the evaluator are retired from the plugin ([32.3])"
else
  no "lane-cluster artifacts must not ship: retired at [32.3] (stale plugin artifact — rebuild)"
fi

# T12 — no stale project-relative script invocations survive inside plugin
# skills OR agents: every helper-script reference must have been rewritten to
# the plugin root (references to project files like .claude/project.json are
# legitimate). The detector's name set is DERIVED by glob ([7.1]) — the hand
# list it replaces had silently fallen three helpers behind the build's — and
# agents/ joined the scan after [7.1]'s routing shipped dead .claude/guv-*.sh
# paths there inside a green battery (the skills-only scan was blind to the
# exact surface the routing touched).
# Shape-doc references are STRIPPED before the test rather than excluded by
# line: the builder deliberately leaves `.claude/<name>.shape.md` alone (it is a
# project path the scaffold deploys, like metering-log.md) and
# `.claude/estimate.sh` is a substring of it. Stripping then re-testing keeps a
# line carrying BOTH a shape-doc mention and a genuinely stale script path
# visible, which a line-level exclusion would hide.
STALE=$(grep -rE "\.claude/(hooks/)?($SCRIPTS_ALT)\.sh" "$PLUGIN/skills" "$PLUGIN/agents" \
  | sed -E 's#\.claude/[a-z][a-z-]*\.shape\.md##g' \
  | grep -E "\.claude/(hooks/)?($SCRIPTS_ALT)\.sh" \
  | grep -cv 'CLAUDE_PLUGIN_ROOT')
[ "$STALE" -eq 0 ] \
  && ok "no stale .claude/ script paths in plugin skills or agents (all rewritten to plugin root)" \
  || no "$STALE stale .claude/ script reference(s) remain in plugin/skills|agents"

# T12b — cross-references are namespaced: bare /command mentions and bare
# reviewer-spawn instructions are dead pointers for plugin consumers (plugin
# skills/agents resolve only as guv:<name> — verified live 2026-06-11). The
# preceding-char guard skips path segments and already-namespaced forms; the
# trailing guard skips longer names (/task-foo) and the :-suffixed guv forms.
# Derived from the source tree exactly as the build's slash_names() derives
# its rewrite list — a future command/skill is covered by both or by
# neither, never silently by one. plugin-src skills (zen, scaffold) register
# as /guv:<name> too; the guard tolerates their absence in a consumer fork
# (maintainers/ deleted), where the detector is just slightly narrower.
CMDS=$(
  {
    for d in "$SRC/skills"/*/; do basename "$d"; done
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

# T12e — SOURCE-side decoder lint: the shift-left of T12d. T12d scans the
# BUILT plugin/, so a new script's bare /command with no guv: decoder slips
# every rebuild-free check and surfaces only at the full battery — exactly how
# [9.6]'s estimate.sh missed its /plan + /replan decoders. This lint applies
# the SAME decoder rule to the source that reaches plugin consumers verbatim for
# slash-command purposes — the FULL byte-identical-shipping surface, both halves:
#   - .claude helper + hook scripts        -> scripts/ (byte-identical)
#   - .claude/skills/*/scripts/*.sh        -> skills/<name>/scripts/ (byte-identical;
#                                             [8.3] single-owner bundle, referenced
#                                             via ${CLAUDE_SKILL_DIR}, NOT rewritten)
#   - maintainers/plugin-src/scripts/*.sh  -> scripts/ (byte-identical; authored
#                                             plugin-only)
#   - .claude/rules/guv-*.md               -> rules/   (byte-identical)
# No plugin/ rebuild needed, so it fires the moment any context runs the suite,
# naming the SOURCE file. SKILL.md/agent prose is excluded — the build
# namespace-rewrites those in transit, so bare mentions there are fixed on the
# way in (T12b owns that surface); bundled skill scripts/ are NOT rewritten, so
# they ARE scanned here. Reuses $CMDS and $GENERIC_DECODER from
# T12b/T12d. Runs unconditionally (no plugin/ dependency; tolerates an absent
# maintainers/).
# Both take an optional ROOT so the positive control below can scan a scratch
# copy instead of planting its fixture in the live tree (spike Prong B). The real
# lint still runs against $ROOT — it exists to catch violations in the real source.
t12e_sources() {  # [<root>]
  local r="${1:-$ROOT}" x
  for x in "$r"/.claude/*.sh "$r"/.claude/hooks/*.sh "$r"/.claude/skills/*/scripts/*.sh \
           "$r"/maintainers/plugin-src/scripts/*.sh \
           "$r"/.claude/rules/guv-*.md; do
    [ -e "$x" ] && echo "$x"
  done
}
t12e_violations() {  # [<root>]
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
  done < <(t12e_sources "${1:-$ROOT}")
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
# positive control — plant a source script with a bare mention and no decoder,
# in a scratch COPY of the tree (spike Prong B). This fixture is the one named in
# friction 2026-06-29T18:50:15Z-1575732184: left behind by a crashed run, it reds
# the NEXT battery through T9's byte-identical-shipping check, because a stray
# .claude/*.sh is indistinguishable from a real helper that failed to ship. The
# cleanup line and EXIT trap that guarded that hazard are gone with the live-tree
# plant — a crashed run now leaks a mktemp directory instead.
T12E_COPY=$(mk_source_copy)
T12E_FIX="$T12E_COPY/.claude/zz-t12e-fixture.sh"
printf '#!/bin/bash\n# Planted violation: mentions /handoff with no guv: decoder.\n' > "$T12E_FIX"
[ ! -e "$SRC/zz-t12e-fixture.sh" ] \
  && ok "the decoder-lint fixture is planted outside the live source tree (no concurrent reader can see it)" \
  || no "fixtures must not be planted in the live source tree — a concurrent build or git read sees them ($SRC/zz-t12e-fixture.sh exists mid-run)"
T12E_OUT2=$(t12e_violations "$T12E_COPY")
if printf '%s\n' "$T12E_OUT2" | grep -q 'zz-t12e-fixture.sh:handoff'; then
  ok "positive control: the source lint flags a planted bare mention without a decoder"
else
  no "T12e positive control failed — the source scan did not flag the planted violation"
fi
rm -rf "$T12E_COPY"

# T13 — no install-time tooling (spec constraint, Phase 5 scoped): the plugin
# may use the native manifest format but ships no postinstall machinery.
T13_OK=1
[ -e "$PLUGIN/package.json" ] && { no "package.json found in plugin (install-time tooling)"; T13_OK=0; }
jq -e '.scripts // .install // .postinstall' "$MANIFEST" >/dev/null 2>&1 && { no "manifest carries install-time keys"; T13_OK=0; }
[ "$T13_OK" -eq 1 ] && ok "no install-time tooling (native manifest only)"

# T15 — the build fails loud on an authored/derived skill-name collision
# instead of silently clobbering the authored copy. Fixture: a plugin-src skill
# named like an existing command, planted in a scratch copy of the source tree.
# The stale-fixture cleanup and the EXIT trap this block used to carry are gone
# with the live-tree plant they existed for: a crashed run now leaves a mktemp
# directory behind, not a fixture that reds the next battery.
SCOPY=$(mk_source_copy)
FIXTURE="$SCOPY/maintainers/plugin-src/skills/status"
mkdir -p "$FIXTURE"
printf -- '---\ndescription: "collision fixture"\n---\nx\n' > "$FIXTURE/SKILL.md"
# HERMETICITY (Prong B) — asserted while the fixture EXISTS, so it observes the
# live tree rather than linting this file. Red before the scratch-root rewrite,
# when this exact path was the plant target and any concurrent reader (another
# build, a git status, a second copy of this suite) could see it.
[ ! -e "$ROOT/maintainers/plugin-src/skills/status" ] \
  && ok "the collision fixture is planted outside the live source tree (no concurrent reader can see it)" \
  || no "fixtures must not be planted in the live source tree — a concurrent build or git read sees them ($ROOT/maintainers/plugin-src/skills/status exists mid-run)"
TMP2=$(mktemp -d)
if bash "$(copy_build "$SCOPY")" --out "$TMP2/plugin" >/dev/null 2>&1; then
  no "build must fail when a derived command collides with an authored skill"
else
  ok "build fails loud on authored/derived skill-name collision"
fi
rm -rf "$TMP2" "$SCOPY"

# T15b — adjacent-mention rewrite: the boundary guard consumes the char
# between two adjacent /commands, so a single sed pass misses the second —
# the double-pass exists for exactly this. Fixture command exercises it
# end-to-end through a real build.
SCOPY=$(mk_source_copy)
FIX2DIR="$SCOPY/.claude/skills/zzadjacency-fixture"
FIX2="$FIX2DIR/SKILL.md"
mkdir -p "$FIX2DIR"
printf 'Adjacency fixture for the namespace rewrite.\n\nRun /task /handoff together, then /status /eval too.\n' > "$FIX2"
[ ! -e "$SRC/skills/zzadjacency-fixture" ] \
  && ok "the adjacency fixture is planted outside the live source tree (no concurrent reader can see it)" \
  || no "fixtures must not be planted in the live source tree — a concurrent build or git read sees them ($SRC/skills/zzadjacency-fixture exists mid-run)"
TMP3=$(mktemp -d)
if bash "$(copy_build "$SCOPY")" --out "$TMP3/plugin" >/dev/null 2>&1 \
   && grep -q '/guv:task /guv:handoff' "$TMP3/plugin/skills/zzadjacency-fixture/SKILL.md" \
   && grep -q '/guv:status /guv:eval' "$TMP3/plugin/skills/zzadjacency-fixture/SKILL.md"; then
  ok "adjacent /command mentions both rewritten (double-pass verified end-to-end)"
else
  no "adjacent /command mentions must both be namespaced by the double-pass"
fi
rm -rf "$TMP3" "$SCOPY"

# T15c — glob-derived helper registry ([7.1]): a helper dropped into
# .claude/ ships and gets path-rewritten with ZERO enumeration-list edits.
# Fixture: a throwaway helper plus a skill mentioning it; rebuild; the
# helper must land in scripts/ byte-identical AND the mention must be
# rewritten to ${CLAUDE_PLUGIN_ROOT}. Red until the HELPERS list and
# rewrite_paths derive from the source tree.
SCOPY=$(mk_source_copy)
FIX3="$SCOPY/.claude/zzregistry-fixture.sh"
FIX3DIR="$SCOPY/.claude/skills/zzregistry-fixture-cmd"
FIX3CMD="$FIX3DIR/SKILL.md"
printf '#!/bin/bash\necho zzregistry-fixture\n' > "$FIX3"
mkdir -p "$FIX3DIR"
printf 'Registry fixture.\n\nRun `bash .claude/zzregistry-fixture.sh` to exercise the registry.\n' > "$FIX3CMD"
{ [ ! -e "$SRC/zzregistry-fixture.sh" ] && [ ! -e "$SRC/skills/zzregistry-fixture-cmd" ]; } \
  && ok "the registry fixtures are planted outside the live source tree (no concurrent reader can see them)" \
  || no "fixtures must not be planted in the live source tree — a concurrent build or git read sees them ($SRC/zzregistry-fixture.sh or $SRC/skills/zzregistry-fixture-cmd exists mid-run)"
TMP4=$(mktemp -d)
if bash "$(copy_build "$SCOPY")" --out "$TMP4/plugin" >/dev/null 2>&1 \
   && cmp -s "$FIX3" "$TMP4/plugin/scripts/zzregistry-fixture.sh" \
   && grep -q 'CLAUDE_PLUGIN_ROOT.*scripts/zzregistry-fixture\.sh' "$TMP4/plugin/skills/zzregistry-fixture-cmd/SKILL.md"; then
  ok "fixture helper ships and rewrites with zero enumeration-list edits (registry is glob-derived)"
else
  no "a dropped-in helper must ship in scripts/ and be path-rewritten without touching any list"
fi
rm -rf "$TMP4" "$SCOPY"

# T16 — consumer-fork resilience: with the build script absent there is nothing
# to build and nothing to verify, so the whole suite must exit 0 with the skip
# VISIBLE — exit 0 alone would also pass if the skip block were deleted (the
# suite passes whole in the canonical repo), making the self-check vacuous.
# PLUGIN_TEST_INNER guards the recursion.
#
# One self-check, not three, since [32.5]: the plugin-deleted probe (T16b) tested
# a PLUGIN_TEST_TREE seam that no longer exists — the suite reads its own build,
# never the committed tree — and the reconstruction-skip probe (T16c) tested a
# PLUGIN_TEST_INNER gate inside T18 that is now unreachable, because an inner
# run exits here at the top and never reaches T18 at all. Both guarded shapes
# are gone rather than merely untested.
if [ -z "${PLUGIN_TEST_INNER:-}" ]; then
  INNER=$(PLUGIN_TEST_INNER=1 PLUGIN_BUILD_SCRIPT="$ROOT/nonexistent-build.sh" bash "$SELF" 2>&1)
  if [ $? -eq 0 ] && echo "$INNER" | grep -q "suite skips"; then
    ok "suite exits 0 and visibly skips in a consumer fork (no build script)"
  else
    no "suite must exit 0 AND visibly skip when maintainers/build-plugin.sh is absent"
  fi
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
# build ships the consumer-meaningful suites into tests/ (the glob set minus the
# maintainer-only suites) with run-plugin-tests.sh, which rebuilds a temp
# .claude/-shaped tree from the FLATTENED scripts/ so the location-relative
# suites run unmodified. This is the drift assertion: a shipped suite that can no
# longer resolve its scripts in plugin layout turns the runner red here. The full
# partition + positive-control drift guard live in ship-suite.test.sh.
#
# Runs against the built tree like every other check here, which collapsed three
# branches into one ([32.5]): a build always ships tests/, so the "committed tree
# is stale, rebuild instead" branch and the "no tests and no build" skip were both
# unreachable once the committed tree stopped being read.
if [ -d "$PLUGIN/tests" ]; then
  ok "the build ships tests/ with the consumer suites"
  # maintainer-only suites must not reach a consumer install
  T18_LEAK=0
  for b in plugin.test.sh setup-control-plane.test.sh single-writer.test.sh release.test.sh door-vocabulary.test.sh; do
    [ -e "$PLUGIN/tests/$b" ] && { no "maintainer-only suite leaked into the shipped tests/: $b"; T18_LEAK=1; }
  done
  [ "$T18_LEAK" -eq 0 ] && ok "no named maintainer-only suite in the shipped tests/"
  RUNNER="$PLUGIN/tests/run-plugin-tests.sh"
  if [ -x "$RUNNER" ]; then
    # stderr captured to a temp file (mktemp, never $ROOT) — writing into the
    # git-tracked repo root would dirty the working tree on a crash between the
    # run and the cleanup.
    T18_ERR=$(mktemp)
    if bash "$RUNNER" >/dev/null 2>"$T18_ERR"; then
      ok "run-plugin-tests.sh runs the shipped suite green in plugin layout"
    else
      no "the shipped suite must run green via run-plugin-tests.sh (a suite can't resolve its scripts in plugin layout?)"
    fi
    [ -s "$T18_ERR" ] \
      && no "run-plugin-tests.sh emitted to stderr: $(head -c 200 "$T18_ERR")" \
      || ok "run-plugin-tests.sh reconstruction is stderr-clean"
    rm -f "$T18_ERR"
  else
    no "tests/run-plugin-tests.sh must ship executable"
  fi
else
  no "the build must ship tests/ with the consumer suites"
fi

finish
