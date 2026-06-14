#!/bin/bash
# Deploy the guv project shell into the current directory — the
# deterministic half of /guv:scaffold (Phase 5 D2). Replaces the
# template-clone step: everything a project needs on disk that the plugin
# can't provide from its own directory at runtime.
#
# Ownership semantics mirror copy_core:
#   - core-owned, REFRESHED every run: CLAUDE.template.md,
#     README.template.md, .claude/project.schema.json,
#     .claude/settings.sandbox-example.json, .claude/rules/guv-*.md
#     (re-running after a plugin update is the shell's update channel)
#   - consumer-owned after first deploy, NEVER clobbered: .claude/settings.json
#     (permissions only — hooks come from the plugin's hooks.json), .gitignore
#     content (the guv block is appended once, marker-guarded), and the Docker
#     tier (consumers patch init-firewall.sh with their registry domains)
#   - NEVER touched: .claude/project.json, CLAUDE.md, README.md, docs/ contents
#
# The manifest is deliberately NOT written here — proposing and confirming it
# is a judgment call the /guv:scaffold skill handles via resolve-stack.sh.
#
# Usage (cwd = the project root): bash scaffold-shell.sh [--docker]
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHELL_DIR="$PLUGIN_ROOT/shell"
RULES_DIR="$PLUGIN_ROOT/rules"
GI_MARKER="guv-gitignore"

DOCKER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --docker) DOCKER=1; shift ;;
    *) echo "usage: bash scaffold-shell.sh [--docker]" >&2; exit 2 ;;
  esac
done

created=(); refreshed=(); kept=()

# refresh_file <src> <dst> — core-owned: always overwritten
refresh_file() {
  if [ -e "$2" ]; then refreshed+=("$2"); else created+=("$2"); fi
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"
}

# keep_file <src> <dst> — consumer-owned: deployed once, never clobbered
keep_file() {
  if [ -e "$2" ]; then kept+=("$2"); return 0; fi
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"
  created+=("$2")
}

mkdir -p .claude/rules docs/sessions
[ -f docs/sessions/.gitkeep ] || : > docs/sessions/.gitkeep

# ── core-owned: templates, schema, sandbox-settings example, rules ──
refresh_file "$SHELL_DIR/CLAUDE.template.md" "CLAUDE.template.md"
refresh_file "$SHELL_DIR/README.template.md" "README.template.md"
refresh_file "$SHELL_DIR/project.schema.json" ".claude/project.schema.json"
refresh_file "$SHELL_DIR/settings.sandbox-example.json" ".claude/settings.sandbox-example.json"
if ls .claude/rules/guv-*.md >/dev/null 2>&1; then
  refreshed+=(".claude/rules/guv-*.md ($(ls "$RULES_DIR"/guv-*.md | wc -l | tr -d ' ') files)")
else
  created+=(".claude/rules/guv-*.md ($(ls "$RULES_DIR"/guv-*.md | wc -l | tr -d ' ') files)")
fi
rm -f .claude/rules/guv-*.md
for r in "$RULES_DIR"/guv-*.md; do
  cp "$r" ".claude/rules/"
done

# ── consumer-owned: settings (permissions only; the plugin's hooks.json owns
# the hooks — the template's hook commands point at .claude/hooks/ scripts a
# scaffolded project doesn't have) ──
keep_file "$SHELL_DIR/settings.json" ".claude/settings.json"

# ── .gitignore: full template when absent; marker-guarded append when present.
# The appended block is EXTRACTED from the shipped template (between the
# guv-core-start/end markers) — one source for both paths, no hardcoded copy
# to drift. ──
if [ ! -f .gitignore ]; then
  cp "$SHELL_DIR/gitignore" .gitignore
  created+=(".gitignore")
elif ! grep -q "$GI_MARKER" .gitignore; then
  {
    printf '\n# %s — appended by /guv:scaffold\n' "$GI_MARKER"
    awk '/^# guv-core-start/,/^# guv-core-end/' "$SHELL_DIR/gitignore"
  } >> .gitignore
  refreshed+=(".gitignore (guv core block appended)")
else
  kept+=(".gitignore")
fi

# ── docs templates: the three phase-doc skeletons (consumer-owned the moment
# they exist — /guv:init-project and /guv:plan fill them in) ──
for d in REQUIREMENTS.md ARCHITECTURE.md PHASE_STATUS.md; do
  keep_file "$SHELL_DIR/docs/$d" "docs/$d"
done

# ── Docker tier (opt-in): per-file deploy-if-absent ──
if [ "$DOCKER" -eq 1 ]; then
  mkdir -p sandbox
  for f in "$SHELL_DIR/sandbox/"*; do
    keep_file "$f" "sandbox/$(basename "$f")"
  done
  keep_file "$SHELL_DIR/Makefile" "Makefile"
fi

# ── report ──
[ ${#created[@]} -gt 0 ]   && printf '[scaffold] created:   %s\n' "${created[@]}"
[ ${#refreshed[@]} -gt 0 ] && printf '[scaffold] refreshed: %s\n' "${refreshed[@]}"
[ ${#kept[@]} -gt 0 ]      && printf '[scaffold] kept:      %s (existing — not touched)\n' "${kept[@]}"
echo "[scaffold] shell deploy complete. Manifest (.claude/project.json), CLAUDE.md, and docs/ are yours — never written here."
exit 0
