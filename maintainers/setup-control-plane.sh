#!/bin/bash
# maintainers/setup-control-plane.sh
# Scaffold (or --sync) a dogfooding CONTROL PLANE that treats THIS harness repo as
# roots.code. The control plane holds every session artifact (rendered CLAUDE.md,
# handoffs, feedback log), so the harness repo stays clean. See maintainers/DOGFOODING.md.
#
# Usage:
#   bash maintainers/setup-control-plane.sh <control-plane-dir> [--sync]
#
#   (no flag)  create the control plane if absent; copy the harness core into it; write
#              the dogfooding manifest + CLAUDE.md + helpers ONLY if they don't exist yet
#              (so your session artifacts are never clobbered); git init it.
#   --sync     refresh ONLY the copied harness core (commands/skills/agents/hooks/scripts/
#              guv-* rules/schema/settings). Leaves the control plane's manifest, CLAUDE.md,
#              docs, and feedback untouched. Run this after editing the harness.

set -u

HARNESS_DIR="$(cd "$(dirname "$0")/.." && pwd)"      # the harness repo (= roots.code)
DEST="${1:-}"
MODE="${2:-create}"

if [ -z "$DEST" ]; then
  echo "usage: bash maintainers/setup-control-plane.sh <control-plane-dir> [--sync]" >&2
  exit 2
fi
[ "$MODE" = "--sync" ] && MODE="sync"

mkdir -p "$DEST/.claude"
DEST_ABS="$(cd "$DEST" && pwd)"

# Relative path from the control plane back to the harness (for roots.code).
# Falls back to an absolute path if a relative one can't be computed.
rel_code() {
  python3 -c "import os,sys;print(os.path.relpath(sys.argv[1], sys.argv[2]))" \
    "$HARNESS_DIR" "$DEST_ABS" 2>/dev/null || echo "$HARNESS_DIR"
}
CODE_REL="$(rel_code)"

# ── Copy the behavioral core from the harness (always — this is the syncable part) ──
# Note what is NOT copied: project.json (we write a dogfooding one), docs/, feedback/,
# agent-memory/, CLAUDE.md — those are control-plane-owned session state.
copy_core() {
  for item in commands skills agents hooks project.schema.json \
              resolve-stack.sh check-citations.sh update-readme-status.sh \
              archive-initiative.sh settings.json; do
    if [ -e "$HARNESS_DIR/.claude/$item" ]; then
      rm -rf "$DEST/.claude/$item"
      cp -R "$HARNESS_DIR/.claude/$item" "$DEST/.claude/$item"
      # cp -R copies directories wholesale — scrub Finder droppings
      find "$DEST/.claude/$item" -name '.DS_Store' -delete 2>/dev/null
    fi
  done
  # Rules: ownership is declared by filename — replace harness-owned guv-* only;
  # unprefixed consumer-authored rules are never touched. The superseded single-file
  # RULES.md is removed (leaving it would double-load: once via a consumer CLAUDE.md
  # still carrying the old @import, once natively from .claude/rules/).
  if [ -d "$HARNESS_DIR/.claude/rules" ]; then
    mkdir -p "$DEST/.claude/rules"
    rm -f "$DEST/.claude/rules/guv-"*.md
    cp "$HARNESS_DIR/.claude/rules/guv-"*.md "$DEST/.claude/rules/" 2>/dev/null
    rm -f "$DEST/.claude/RULES.md"
  fi
  echo "[setup] synced harness core → $DEST/.claude/"
}

copy_core

if [ "$MODE" = "sync" ]; then
  echo "[setup] --sync complete. Manifest, CLAUDE.md, docs, and feedback left untouched."
  exit 0
fi

# ── First-time scaffolding (create only what's absent — never clobber session state) ──

# run-harness-tests.sh: commands.test for the control plane runs the harness's bash suites
# (which live in roots.code, not here).
if [ ! -f "$DEST/.claude/run-harness-tests.sh" ]; then
  cat > "$DEST/.claude/run-harness-tests.sh" <<'SH'
#!/bin/bash
# Run the harness's bash test suites from the code repo (roots.code).
set -u
CODE=$(jq -r '.roots.code' .claude/project.json)
fail=0
for t in "$CODE"/.claude/tests/*.test.sh; do
  [ -e "$t" ] || continue
  echo "== $(basename "$t") =="
  bash "$t" || fail=1
done
exit $fail
SH
  chmod +x "$DEST/.claude/run-harness-tests.sh"
fi

# Dogfooding manifest: roots.code points back at the harness; ceremony: task.
if [ ! -f "$DEST/.claude/project.json" ]; then
  jq -n --arg code "$CODE_REL" '{
    "$schema": "./project.schema.json",
    name: "harness-dev",
    language: "node",
    packageManager: null,
    roots: { control: ".", code: $code },
    commands: {
      test: "bash .claude/run-harness-tests.sh",
      build: null, lint: null, format: null, dev: null, install: null
    },
    scaffoldCheck: ("test -d \"" + $code + "/.claude\""),
    readyCheck: null,
    formatExtensions: ["md","json","sh","yml","yaml"],
    guards: [],
    ceremony: "task"
  }' > "$DEST/.claude/project.json"
  echo "[setup] wrote dogfooding manifest (roots.code=$CODE_REL, ceremony=task)"
fi

# Control-plane CLAUDE.md — context for the dogfooding session.
if [ ! -f "$DEST/CLAUDE.md" ]; then
  cat > "$DEST/CLAUDE.md" <<SH
# Harness Dev — Control Plane

This is the **control plane** for improving the Claude Code harness. The harness itself
is the code repo at \`roots.code\` (\`$CODE_REL\`).

- **Behavior & conventions:** \`.claude/rules/\` (\`guv-*.md\` harness-owned; add your own unprefixed rules alongside)
- **Memory authority:** the manifest and the latest session handoff are authoritative;
  treat auto memory as hints and never let it override either.
- **Commands, roots, ceremony:** \`.claude/project.json\`. \`commands.test\` runs the
  harness's bash suites in the code repo.
- **Where edits go:** improve the harness in the **code repo** ($CODE_REL) — that's
  where product commits land. This control plane holds session artifacts only
  (handoffs in \`docs/sessions/\`, harness friction in \`.claude/feedback/\`).
- **After editing the harness**, run \`maintainers/setup-control-plane.sh <here> --sync\`
  from the harness repo to pull your changes in before testing them.

## Project facts

- This is \`ceremony: task\` — scoped changes, no phase docs. Use \`/task\` for work.
- Log harness friction with \`/log-feedback\`; it stays here, never in the template.
SH
  echo "[setup] wrote control-plane CLAUDE.md"
fi

mkdir -p "$DEST/docs/sessions"
[ -f "$DEST/docs/sessions/.gitkeep" ] || : > "$DEST/docs/sessions/.gitkeep"

# Gitignore agent-memory in the control plane (feedback IS committed here — it's the
# dogfooding record).
if [ ! -f "$DEST/.gitignore" ]; then
  printf '.claude/agent-memory/\n.claude/settings.local.json\n.DS_Store\n' > "$DEST/.gitignore"
fi

# Init the control plane's own git (its own commit stream), if not already a repo.
if [ ! -d "$DEST/.git" ]; then
  git -C "$DEST" init -q && echo "[setup] git init'd the control plane"
fi

echo ""
echo "[setup] Control plane ready at: $DEST_ABS"
echo "  roots.code → $CODE_REL (the harness)"
echo "  Next:  cd \"$DEST_ABS\" && claude   then  /status"
echo "  Re-sync after harness edits:  bash maintainers/setup-control-plane.sh \"$DEST\" --sync"
