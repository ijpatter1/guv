#!/bin/bash
# Build the Governor (guv) plugin from the harness sources — Phase 5 D1.
#
# The committed plugin/ directory is GENERATED, never hand-edited. The single
# source of truth stays in .claude/ (commands, skills, agents, hooks, rules,
# helper scripts, the saved workflow); plugin-only files (manifest, hooks.json,
# the reviewer-readonly guard, the zen and evaluate-parallel skills) are
# authored in maintainers/plugin-src/ and copied verbatim. plugin.test.sh's
# drift guard rebuilds into a temp dir and diffs against the committed tree.
#
# Transforms applied to derived files:
#   - commands/<name>.md  -> skills/<name>/SKILL.md, gaining a frontmatter
#     description (the command's first line — every command opens with a
#     one-sentence summary)
#   - skills/<name>/      -> skills/<name>/ unchanged in structure
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

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) echo "usage: bash maintainers/build-plugin.sh [--out <dir>]" >&2; exit 2 ;;
  esac
done

# The helper scripts the path rewrite targets and scripts/ ships.
HELPERS="archive-initiative resolve-stack check-citations update-readme-status"
HOOKS="bash-guard auto-format stop-check"

# Project-relative script references -> plugin-root references. Covers both
# "bash .claude/x.sh" invocations and bare ".claude/x.sh" prose mentions in one
# pass (the "bash " prefix, where present, survives in place).
rewrite_paths() {
  sed -E 's|\.claude/(hooks/)?(archive-initiative\|resolve-stack\|check-citations\|update-readme-status\|bash-guard\|auto-format\|stop-check)\.sh|"${CLAUDE_PLUGIN_ROOT}"/scripts/\2.sh|g'
}

# Cross-references in derived content -> the namespaced forms a plugin consumer
# can actually invoke. Plugin skills and agents resolve ONLY as guv:<name>
# (verified live 2026-06-11), so bare /command mentions and reviewer-spawn
# instructions are dead pointers in a plugin-only project.
#   - slash commands: longest name first so /evaluate-parallel is consumed
#     before /evaluate; the preceding-char guard [^[:alnum:].:-] keeps path
#     segments (docs/manual/task-*.md) and already-namespaced (/guv:task)
#     mentions untouched
#   - agent spawns: the "`<name>` subagent" instruction phrasing and the
#     @-mention form used in agent descriptions
#   - two template-clone topology facts with no plugin counterpart path
namespace_refs() {
  sed -E \
    -e 's|the saved `/evaluate-parallel` workflow|the `/evaluate-parallel` skill|g' \
    -e 's|\(`\.claude/workflows/evaluate-parallel\.js`\)|(launching the plugin-shipped workflow)|g' \
    -e 's|`\.claude/skills/phase-docs/SKILL\.md`|plugin-shipped|g' \
    -e 's|(^\|[^[:alnum:].:-])/evaluate-parallel|\1/guv:evaluate-parallel|g' \
    -e 's|(^\|[^[:alnum:].:-])/plan-initiative|\1/guv:plan-initiative|g' \
    -e 's|(^\|[^[:alnum:].:-])/init-project|\1/guv:init-project|g' \
    -e 's|(^\|[^[:alnum:].:-])/log-feedback|\1/guv:log-feedback|g' \
    -e 's|(^\|[^[:alnum:].:-])/start-phase|\1/guv:start-phase|g' \
    -e 's|(^\|[^[:alnum:].:-])/evaluate|\1/guv:evaluate|g' \
    -e 's|(^\|[^[:alnum:].:-])/onboard|\1/guv:onboard|g' \
    -e 's|(^\|[^[:alnum:].:-])/handoff|\1/guv:handoff|g' \
    -e 's|(^\|[^[:alnum:].:-])/status|\1/guv:status|g' \
    -e 's|(^\|[^[:alnum:].:-])/manual|\1/guv:manual|g' \
    -e 's|(^\|[^[:alnum:].:-])/task|\1/guv:task|g' \
    -e 's|`evaluator` subagent|`guv:evaluator` subagent|g' \
    -e 's|`product-reviewer` subagent|`guv:product-reviewer` subagent|g' \
    -e 's|@evaluator|@guv:evaluator|g' \
    -e 's|@product-reviewer|@guv:product-reviewer|g'
}

rm -rf "$OUT"
mkdir -p "$OUT/.claude-plugin" "$OUT/skills" "$OUT/agents" "$OUT/hooks" \
  "$OUT/scripts" "$OUT/rules" "$OUT/workflows"

# ── authored plugin-only sources, verbatim ──
cp "$PSRC/plugin.json" "$OUT/.claude-plugin/plugin.json"
cp "$PSRC/hooks/hooks.json" "$OUT/hooks/hooks.json"
cp "$PSRC/scripts/"*.sh "$OUT/scripts/"
for d in "$PSRC/skills"/*/; do
  name="$(basename "$d")"
  mkdir -p "$OUT/skills/$name"
  cp "$d"SKILL.md "$OUT/skills/$name/SKILL.md"
done

# ── commands -> namespaced skills ──
# Authored plugin-src skills were copied first; a derived name colliding with
# one would silently clobber it — fail loud instead.
for c in "$SRC/commands"/*.md; do
  name="$(basename "$c" .md)"
  if [ -e "$OUT/skills/$name/SKILL.md" ]; then
    echo "build-plugin: derived command '$name' collides with an authored plugin-src skill" >&2
    exit 1
  fi
  mkdir -p "$OUT/skills/$name"
  desc="$(head -1 "$c" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  {
    printf -- '---\ndescription: "%s"\n---\n\n' "$desc"
    tail -n +2 "$c" | rewrite_paths | namespace_refs
  } > "$OUT/skills/$name/SKILL.md"
done

# ── harness skills, path- and namespace-rewritten ──
for d in "$SRC/skills"/*/; do
  name="$(basename "$d")"
  if [ -e "$OUT/skills/$name/SKILL.md" ]; then
    echo "build-plugin: derived skill '$name' collides with an existing plugin skill" >&2
    exit 1
  fi
  mkdir -p "$OUT/skills/$name"
  for f in "$d"*; do
    rewrite_paths < "$f" | namespace_refs > "$OUT/skills/$name/$(basename "$f")"
  done
done

# ── agents, frontmatter hooks: block stripped, references namespaced ──
# hooks: is dropped from the line "hooks:" through the last indented line of
# its block; every other frontmatter key and the body pass through with the
# namespace rewrite (descriptions and bodies mention /evaluate, /handoff,
# @evaluator — dead pointers in their bare forms under plugin install).
for a in "$SRC/agents"/*.md; do
  awk '
    /^---$/ { fm++; inhooks=0; print; next }
    fm==1 && /^hooks:/ { inhooks=1; next }
    fm==1 && inhooks && /^[^ ]/ { inhooks=0 }
    inhooks { next }
    { print }
  ' "$a" | namespace_refs > "$OUT/agents/$(basename "$a")"
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
jq 'del(.hooks)' "$SRC/settings.json" > "$OUT/shell/settings.json"
mkdir -p "$OUT/shell/sandbox" "$OUT/shell/docs"
cp "$ROOT/sandbox/"* "$OUT/shell/sandbox/"
# the three phase-doc skeletons template-clone consumers get from docs/
cp "$ROOT/docs/REQUIREMENTS.md" "$ROOT/docs/ARCHITECTURE.md" "$ROOT/docs/PHASE_STATUS.md" "$OUT/shell/docs/"

# ── workflow asset: reviewers namespaced ──
# Plugin agents resolve only as guv:<name> (verified live 2026-06-11), so the
# plugin copy of the workflow spawns guv:evaluator / guv:product-reviewer;
# the project copy keeps bare names for .claude/agents/ consumers.
sed "s/agentType: 'evaluator'/agentType: 'guv:evaluator'/; s/agentType: 'product-reviewer'/agentType: 'guv:product-reviewer'/" \
  "$SRC/workflows/evaluate-parallel.js" > "$OUT/workflows/evaluate-parallel.js"

echo "Built plugin at $OUT"
