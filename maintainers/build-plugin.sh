#!/bin/bash
# Build the Governor (guv) plugin from source — Phase 5 D1.
#
# The committed plugin/ directory is GENERATED, never hand-edited. The single
# source of truth stays in .claude/ (skills, agents, hooks, rules,
# helper scripts, the saved workflow); plugin-only files (manifest, the
# reviewer-readonly guard, the zen and eval-parallel skills) are authored in
# maintainers/plugin-src/ and copied verbatim. The plugin hooks.json is DERIVED
# from .claude/settings.json (one source — a hook wired in project mode can't
# silently miss plugin mode; the [9.2] dead-hook class), not authored: see the
# derivation below. plugin.test.sh's drift guard rebuilds into a temp dir and
# diffs against the committed tree.
#
# Transforms applied to derived files:
#   - skills/<name>/      -> skills/<name>/ unchanged in structure (the former
#     commands/ were flattened into skills/ at [8.3]; the build no longer
#     derives skills from a commands/ dir)
#   - both of the above get the script-path rewrite: project-relative helper
#     invocations (bash .claude/<script>.sh and bare .claude/<script>.sh
#     mentions) become "${CLAUDE_PLUGIN_ROOT}"/scripts/<script>.sh
#   - agents/*.md         -> agents/*.md with the frontmatter hooks: block
#     STRIPPED (plugin agents don't support frontmatter hooks; the enforcement
#     moves to hooks/hooks.json + scripts/reviewer-readonly.sh)
#   - hook + helper scripts, rules, workflow script: byte-identical copies
#     (scripts run with cwd = the project, so .claude/project.json reads stay
#     correct; rules/ and workflows/ are assets the scaffold skill deploys)
#
# Usage: bash maintainers/build-plugin.sh [--out <dir>]   (default: <repo>/plugin)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/.claude"
PSRC="$ROOT/maintainers/plugin-src"
OUT="$ROOT/plugin"
# The single source for the plugin hook wiring; PLUGIN_SETTINGS overrides it so
# plugin.test.sh can prove the settings→plugin derivation end-to-end (T17b).
SETTINGS="${PLUGIN_SETTINGS:-$SRC/settings.json}"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) echo "usage: bash maintainers/build-plugin.sh [--out <dir>]" >&2; exit 2 ;;
  esac
done

# The helper scripts the path rewrite targets and scripts/ ships — DERIVED by
# glob from the source tree ([7.1]: a hand-maintained copy of this list is
# exactly the drift this build exists to prevent; plugin.test.sh derives its
# T9 parity set and T12 stale-detector the same way).
HELPERS=""
for f in "$SRC"/*.sh; do HELPERS="$HELPERS $(basename "$f" .sh)"; done
HOOKS=""
for f in "$SRC/hooks"/*.sh; do HOOKS="$HOOKS $(basename "$f" .sh)"; done
SCRIPT_ALT=$(for n in $HELPERS $HOOKS; do echo "$n"; done | paste -sd'|' -)

# Project-relative script references -> plugin-root references. Covers both
# "bash .claude/x.sh" invocations and bare ".claude/x.sh" prose mentions in one
# pass (the "bash " prefix, where present, survives in place).
rewrite_paths() {
  # '#' delimiter: the derived alternation carries raw '|' (regex), and the
  # pattern itself needs '/'
  sed -E 's#\.claude/(hooks/)?('"$SCRIPT_ALT"')\.sh#"${CLAUDE_PLUGIN_ROOT}"/scripts/\2.sh#g'
}

# Cross-references in derived content -> the namespaced forms a plugin consumer
# can actually invoke. Plugin skills and agents resolve ONLY as guv:<name>
# (verified live 2026-06-11), so bare /command mentions and reviewer-spawn
# instructions are dead pointers in a plugin-only project.
#   - slash commands: longest name first so /eval-parallel is consumed
#     before /eval; the preceding-char guard [^[:alnum:].:-] keeps path
#     segments (docs/manual/task-*.md) and already-namespaced (/guv:task)
#     mentions untouched
#   - agent spawns: the "`<name>` subagent" instruction phrasing and the
#     @-mention form used in agent descriptions
#   - two template-clone topology facts with no plugin counterpart path
# Every name that registers as /<name> for consumers — commands, skills, and
# saved workflows — DERIVED from the source tree (a hand-maintained copy of
# this list is exactly the drift this build exists to prevent; plugin.test.sh
# derives its detector the same way). Longest first so /eval-parallel is
# consumed before /eval.
slash_names() {
  {
    for d in "$SRC/skills"/*/; do basename "$d"; done
    for f in "$SRC/workflows"/*.js; do basename "$f" .js; done
    # plugin-only skills (zen, scaffold, …) register as /guv:<name> too
    for d in "$PSRC/skills"/*/; do basename "$d"; done
  } | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-
}

_namespace_pass() {
  local args=(-E
    -e 's|the saved `/eval-parallel` workflow|the `/eval-parallel` skill|g'
    -e 's|\(`\.claude/workflows/eval-parallel\.js`\)|(launching the plugin-shipped workflow)|g'
    -e 's|`\.claude/skills/phase-docs/SKILL\.md`|plugin-shipped|g'
    -e 's|\(`\.claude/skills/eval/SKILL\.md`\)|(plugin-shipped)|g')
  local n
  while IFS= read -r n; do
    # '#' delimiter: the pattern itself needs both '/' and the ERE '|'
    args+=(-e "s#(^|[^[:alnum:].:-])/$n(\$|[^[:alnum:]:_-])#\\1/guv:$n\\2#g")
  done < <(slash_names)
  args+=(-e 's|`evaluator` subagent|`guv:evaluator` subagent|g'
    -e 's|`reviewer` subagent|`guv:reviewer` subagent|g'
    -e 's|@evaluator|@guv:evaluator|g'
    -e 's|@reviewer|@guv:reviewer|g')
  sed "${args[@]}"
}

# The trailing-boundary guard (same class as T12b's detector — /task must not
# eat /task-tier or /evaluated) consumes the boundary character, so two
# adjacent mentions ("/task /handoff") leave the second unmatched on a single
# pass. All rewrites are idempotent, so run the pass twice.
namespace_refs() {
  _namespace_pass | _namespace_pass
}

rm -rf "$OUT"
mkdir -p "$OUT/.claude-plugin" "$OUT/skills" "$OUT/agents" "$OUT/hooks" \
  "$OUT/scripts" "$OUT/rules" "$OUT/workflows"

# ── plugin hooks.json: DERIVED from settings.json (one source) ──
# Every hook is wired once, in .claude/settings.json; the build rewrites each
# command's project path (.claude/hooks/X.sh) to the plugin-root path, then
# injects the reviewer-readonly guard into the Bash PreToolUse matcher. That
# guard is the ONE plugin-only hook: plugin agents can't carry the frontmatter
# hooks: block that enforces reviewer read-only in project mode (stripped from
# the agents below), so it rides hooks.json instead, gated on agent_type. No
# hand-maintained second copy means a settings hook can never silently miss the
# plugin (the [9.2] dead-hook class); T17/T17b guard the derivation.
jq '{
  hooks: (
    .hooks
    | walk(if type == "object" and has("command")
           then .command |= gsub("\\.claude/hooks/"; "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/")
           else . end)
    | .PreToolUse |= map(
        if (.matcher // "" | test("Bash"))
        then .hooks += [{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}\"/scripts/reviewer-readonly.sh"}]
        else . end)
  )
}' "$SETTINGS" > "$OUT/hooks/hooks.json"

# ── authored plugin-only sources, verbatim ──
cp "$PSRC/plugin.json" "$OUT/.claude-plugin/plugin.json"
cp "$PSRC/scripts/"*.sh "$OUT/scripts/"
for d in "$PSRC/skills"/*/; do
  name="$(basename "$d")"
  mkdir -p "$OUT/skills/$name"
  cp "$d"SKILL.md "$OUT/skills/$name/SKILL.md"
done

# ── core skills, path- and namespace-rewritten ──
# Includes the flattened former commands (next, phase, plan, handoff, …): at
# [8.3] commands/ was flattened into skills/, so they ship through this one loop
# like any other skill. Authored plugin-src skills were copied first; the
# collision check below fails loud if a core skill name shadows one.
for d in "$SRC/skills"/*/; do
  name="$(basename "$d")"
  if [ -e "$OUT/skills/$name/SKILL.md" ]; then
    echo "build-plugin: derived skill '$name' collides with an existing plugin skill" >&2
    exit 1
  fi
  mkdir -p "$OUT/skills/$name"
  for f in "$d"*; do
    if [ -d "$f" ]; then
      # A bundled subdir (e.g. scripts/, [8.3] single-owner bundle) — copied
      # byte-identical. The skill body references it via ${CLAUDE_SKILL_DIR}/…,
      # which resolves in every install mode, so it gets NO path/namespace
      # rewrite (unlike shared helpers, which become ${CLAUDE_PLUGIN_ROOT}).
      cp -R "$f" "$OUT/skills/$name/"
    else
      rewrite_paths < "$f" | namespace_refs > "$OUT/skills/$name/$(basename "$f")"
    fi
  done
  # bundled scripts ship executable (the top plugin pitfall; cp preserves source
  # mode, but be explicit as the shared-scripts copy is). Per-file so an empty
  # scripts/ never leaves an unexpanded glob for chmod to choke on (stderr-gate).
  for bs in "$OUT/skills/$name/scripts"/*.sh; do [ -e "$bs" ] && chmod +x "$bs"; done
done

# ── agents, frontmatter hooks: block stripped, references namespaced AND
# path-rewritten ──
# hooks: is dropped from the line "hooks:" through the last indented line of
# its block; every other frontmatter key and the body pass through with the
# namespace rewrite (descriptions and bodies mention /eval, /handoff,
# @evaluator — dead pointers in their bare forms under plugin install) and
# the script-path rewrite ([7.1] routed agent procedures through the
# .claude/guv-*.sh helpers — dead paths in a plugin-only project without it).
for a in "$SRC/agents"/*.md; do
  awk '
    /^---$/ { fm++; inhooks=0; print; next }
    fm==1 && /^hooks:/ { inhooks=1; next }
    fm==1 && inhooks && /^[^ ]/ { inhooks=0 }
    inhooks { next }
    { print }
  ' "$a" | rewrite_paths | namespace_refs > "$OUT/agents/$(basename "$a")"
done

# ── hook + helper scripts, byte-identical ──
for h in $HOOKS; do
  cp "$SRC/hooks/$h.sh" "$OUT/scripts/$h.sh"
done
for s in $HELPERS; do
  cp "$SRC/$s.sh" "$OUT/scripts/$s.sh"
done

# all shipped scripts executable — non-executable hook scripts are the
# documented top plugin pitfall, and cp preserves uneven source modes
chmod +x "$OUT/scripts"/*.sh

# ── rules, byte-identical ──
cp "$SRC/rules"/guv-*.md "$OUT/rules/"

# ── consumer-meaningful test suites + the layout-reconstructing runner ([10.3]) ──
# Ship the glob-derived suite set MINUS the maintainer-only suites. "Maintainer-
# only" is the deliverable's three named reference patterns (maintainers/,
# plugin-src/, .claude/settings.json) COMPLETED with the source-tree surfaces a
# plugin install does not reproduce: source command/skill files, project.schema.
# json, and the top-level .claude/ shape docs (estimate.shape.md, metering*.md).
# A suite that asserts any of those is a source-shape check, not consumer script
# behavior — it cannot run green in plugin layout no matter how the tree is
# reconstructed, so it is maintainer-only in the same spirit as the named three.
# The directory-grep forms a green consumer suite uses
# (grep -r … .claude/commands .claude/skills 2>/dev/null) do NOT match — the
# patterns require a trailing /<file>.md or /SKILL.md. ship-suite.test.sh derives
# the SAME partition and asserts it both directions, so this rule lives once.
MAINTAINER_ONLY='maintainers/|plugin-src/|\.claude/settings\.json|commands/[a-z][a-z-]*\.md|skills/[a-z][a-z-]*/SKILL\.md|project\.schema\.json|estimate\.shape\.md|/metering[a-z-]*\.md'
mkdir -p "$OUT/tests"
for t in "$SRC/tests"/*.test.sh; do
  b="$(basename "$t")"
  # the ship-suite self-test IS the shipping machinery's own guard — it builds
  # the plugin and asserts the partition, so it never ships into the plugin
  case "$b" in ship-suite.test.sh) continue ;; esac
  grep -qE "$MAINTAINER_ONLY" "$t" && continue
  cp "$t" "$OUT/tests/$b"
done

# The runner rebuilds a temp .claude/-shaped tree from the FLATTENED plugin
# scripts/ so the location-relative suites ($(dirname "$0")/.. -> .claude/) run
# unmodified: scripts at the .claude/ top level, hooks in .claude/hooks/ recovered
# from which scripts hooks.json references, rules in .claude/rules/, the shipped
# suites in .claude/tests/. Authored here as a heredoc (no .claude/ source — it is
# plugin-runtime-only, like the manifest), self-locating from plugin/tests/.
cat > "$OUT/tests/run-plugin-tests.sh" <<'RUNNER'
#!/bin/bash
# Layout-reconstructing runner for the shipped guv test suites ([10.3]).
# The plugin ships scripts FLATTENED into scripts/; the consumer suites self-
# locate via $(dirname "$0")/.. expecting a .claude/-shaped tree (scripts at the
# top level, hooks in hooks/, tests in tests/). This runner rebuilds that shape in
# a temp dir and runs every shipped suite against it, so the location-relative
# suites verify the plugin's INSTALLED script copies unmodified.
#
# Hooks are recovered deterministically: a script is a hook iff hooks.json
# references it (the build flattens both into scripts/; hooks.json is the only
# record of which were hooks). Everything else in scripts/ is a top-level helper.
#
# Pure bash + jq. Run: bash <plugin>/tests/run-plugin-tests.sh
set -u

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$PLUGIN/scripts"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
TESTS="$PLUGIN/tests"
RULES="$PLUGIN/rules"

if [ ! -d "$SCRIPTS" ] || [ ! -f "$HOOKS_JSON" ]; then
  echo "run-plugin-tests: not a plugin tree (missing scripts/ or hooks/hooks.json): $PLUGIN" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REC="$WORK/.claude"
mkdir -p "$REC/hooks" "$REC/tests" "$REC/rules"

# the hook basenames hooks.json references — these scripts were .claude/hooks/X.sh
HOOK_NAMES="$(jq -r '.hooks[][]?.hooks[]?.command' "$HOOKS_JSON" 2>/dev/null \
  | grep -oE '[A-Za-z0-9_-]+\.sh' | sort -u)"
is_hook() { printf '%s\n' "$HOOK_NAMES" | grep -qx "$1"; }

for s in "$SCRIPTS"/*.sh; do
  [ -e "$s" ] || continue
  b="$(basename "$s")"
  if is_hook "$b"; then cp "$s" "$REC/hooks/$b"; else cp "$s" "$REC/$b"; fi
done
chmod +x "$REC"/*.sh "$REC/hooks"/*.sh 2>/dev/null || true

# bundled single-owner scripts ([8.3]) live under skills/<name>/scripts/ in the
# plugin (resolved via ${CLAUDE_SKILL_DIR}); reconstruct them at the same path so
# a shipped suite testing a bundled script resolves it from the rebuilt .claude/.
for sd in "$PLUGIN"/skills/*/scripts/*.sh; do
  [ -e "$sd" ] || continue
  sn="$(basename "$(dirname "$(dirname "$sd")")")"
  mkdir -p "$REC/skills/$sn/scripts"
  cp "$sd" "$REC/skills/$sn/scripts/$(basename "$sd")"
  chmod +x "$REC/skills/$sn/scripts/$(basename "$sd")"
done

# rules ship as plugin assets; some location-relative suites read .claude/rules/
[ -d "$RULES" ] && cp "$RULES"/*.md "$REC/rules/" 2>/dev/null || true

# the suites themselves, into the reconstructed tests/ so $(dirname "$0")/.. lands
# on the reconstructed .claude/
SHIPPED=0
for t in "$TESTS"/*.test.sh; do
  [ -e "$t" ] || continue
  b="$(basename "$t")"
  case "$b" in run-plugin-tests.sh) continue ;; esac
  cp "$t" "$REC/tests/$b"
  SHIPPED=$((SHIPPED + 1))
done

if [ "$SHIPPED" -eq 0 ]; then
  echo "run-plugin-tests: no shipped suites found in $TESTS" >&2
  exit 2
fi

PASS_SUITES=0; FAIL_SUITES=0; FAILED_NAMES=""
for t in "$REC/tests"/*.test.sh; do
  b="$(basename "$t")"
  echo "── $b ──"
  if bash "$t"; then
    PASS_SUITES=$((PASS_SUITES + 1))
  else
    FAIL_SUITES=$((FAIL_SUITES + 1))
    FAILED_NAMES="$FAILED_NAMES $b"
  fi
  echo ""
done

echo "════════════════════════════════════════"
if [ "$FAIL_SUITES" -eq 0 ]; then
  echo "All $PASS_SUITES shipped suites passed in plugin layout (suites: 0 failed)"
else
  echo "Plugin-layout suites: $PASS_SUITES passed, $FAIL_SUITES failed —$FAILED_NAMES"
fi
[ "$FAIL_SUITES" -eq 0 ]
RUNNER
chmod +x "$OUT/tests/run-plugin-tests.sh"

# ── project-shell assets for /guv:scaffold ──
# Everything the template-clone step used to provide that must live in the
# PROJECT (the plugin can't supply these from its own directory at runtime).
# settings.json ships minus the hooks block: the plugin's hooks.json owns the
# hooks, and the template's hook commands point at .claude/hooks/ scripts a
# scaffolded project doesn't have.
mkdir -p "$OUT/shell"
cp "$ROOT/CLAUDE.template.md" "$OUT/shell/CLAUDE.template.md"
cp "$ROOT/README.template.md" "$OUT/shell/README.template.md"
cp "$ROOT/.gitignore" "$OUT/shell/gitignore"
cp "$ROOT/Makefile" "$OUT/shell/Makefile"
cp "$SRC/project.schema.json" "$OUT/shell/project.schema.json"
cp "$SRC/settings.sandbox-example.json" "$OUT/shell/settings.sandbox-example.json"
jq 'del(.hooks)' "$SETTINGS" > "$OUT/shell/settings.json"
mkdir -p "$OUT/shell/sandbox" "$OUT/shell/docs"
cp "$ROOT/sandbox/"* "$OUT/shell/sandbox/"
# the three phase-doc skeletons template-clone consumers get from docs/
cp "$ROOT/docs/REQUIREMENTS.md" "$ROOT/docs/ARCHITECTURE.md" "$ROOT/docs/PHASE_STATUS.md" "$OUT/shell/docs/"

# ── workflow asset: reviewers namespaced ──
# Plugin agents resolve only as guv:<name> (verified live 2026-06-11), so the
# plugin copy of the workflow spawns guv:evaluator / guv:reviewer;
# the project copy keeps bare names for .claude/agents/ consumers.
sed "s/agentType: 'evaluator'/agentType: 'guv:evaluator'/; s/agentType: 'reviewer'/agentType: 'guv:reviewer'/" \
  "$SRC/workflows/eval-parallel.js" > "$OUT/workflows/eval-parallel.js"

echo "Built plugin at $OUT"
