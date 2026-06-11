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

rm -rf "$OUT"
mkdir -p "$OUT/.claude-plugin" "$OUT/skills" "$OUT/agents" "$OUT/hooks" \
  "$OUT/scripts" "$OUT/rules" "$OUT/workflows"

# ── authored plugin-only sources, verbatim ──
cp "$PSRC/plugin.json" "$OUT/.claude-plugin/plugin.json"
cp "$PSRC/hooks/hooks.json" "$OUT/hooks/hooks.json"
cp "$PSRC/scripts/reviewer-readonly.sh" "$OUT/scripts/reviewer-readonly.sh"
for d in "$PSRC/skills"/*/; do
  name="$(basename "$d")"
  mkdir -p "$OUT/skills/$name"
  cp "$d"SKILL.md "$OUT/skills/$name/SKILL.md"
done

# ── commands -> namespaced skills ──
for c in "$SRC/commands"/*.md; do
  name="$(basename "$c" .md)"
  mkdir -p "$OUT/skills/$name"
  desc="$(head -1 "$c" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  {
    printf -- '---\ndescription: "%s"\n---\n\n' "$desc"
    tail -n +2 "$c" | rewrite_paths
  } > "$OUT/skills/$name/SKILL.md"
done

# ── harness skills, path-rewritten ──
for d in "$SRC/skills"/*/; do
  name="$(basename "$d")"
  mkdir -p "$OUT/skills/$name"
  for f in "$d"*; do
    rewrite_paths < "$f" > "$OUT/skills/$name/$(basename "$f")"
  done
done

# ── agents, frontmatter hooks: block stripped ──
# hooks: is dropped from the line "hooks:" through the last indented line of
# its block; every other frontmatter key and the body pass through untouched.
for a in "$SRC/agents"/*.md; do
  awk '
    /^---$/ { fm++; inhooks=0; print; next }
    fm==1 && /^hooks:/ { inhooks=1; next }
    fm==1 && inhooks && /^[^ ]/ { inhooks=0 }
    inhooks { next }
    { print }
  ' "$a" > "$OUT/agents/$(basename "$a")"
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

# ── rules + workflow assets, byte-identical ──
cp "$SRC/rules"/guv-*.md "$OUT/rules/"
cp "$SRC/workflows/evaluate-parallel.js" "$OUT/workflows/evaluate-parallel.js"

echo "Built plugin at $OUT"
