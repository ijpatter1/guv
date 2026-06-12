#!/bin/bash
# maintainers/setup-control-plane.sh
# Scaffold (or --sync) a dogfooding CONTROL PLANE that treats THIS harness repo as
# roots.code. The control plane holds every session artifact (rendered CLAUDE.md,
# handoffs, feedback log), so the harness repo stays clean. See maintainers/DOGFOODING.md.
#
# Usage:
#   bash maintainers/setup-control-plane.sh [<control-plane-dir>] [--sync]
#
#   <control-plane-dir> defaults to a sibling of this repo named <repo>-guv —
#   the <project>-guv naming convention (announced when defaulted). The default
#   is a constructed path offered at creation/sync time only: no script ever
#   discovers a control plane by name; the manifest is the sole machine pointer.
#
#   (no flag)  create the control plane if absent; copy the harness core into it; write
#              the dogfooding manifest + CLAUDE.md ONLY if they don't exist yet
#              (so your session artifacts are never clobbered); git init it.
#   --sync     refresh ONLY the copied harness core (commands/skills/agents/hooks/scripts/
#              guv-* rules/workflows/schema/settings) plus the generated test runner —
#              run-harness-tests.sh carries no consumer state, so it is harness-owned and
#              regenerated whenever the generator's copy changes (announced; silent when
#              current). Leaves the control plane's manifest, CLAUDE.md, docs, and
#              feedback untouched. Run this after editing the harness.

set -u

HARNESS_DIR="$(cd "$(dirname "$0")/.." && pwd)"      # the harness repo (= roots.code)
DEST="${1:-}"
MODE_ARG="${2:-}"

# --sync may stand alone; the destination then defaults like the no-arg form.
# Flag-first WITH a directory is refused loud: silently discarding an explicit
# argument and defaulting elsewhere is the improvised path rule 15 prohibits.
if [ "$DEST" = "--sync" ]; then
  if [ -n "$MODE_ARG" ]; then
    echo "error: directory must come first — usage: bash maintainers/setup-control-plane.sh [<control-plane-dir>] [--sync]" >&2
    exit 2
  fi
  MODE_ARG="--sync"
  DEST=""
fi
# Any other flag-shaped first argument is a typo, not a directory — refuse
# loud in EITHER position rather than cascading toward a false success banner.
# The only recognized second argument is the literal --sync (bare sync/create
# aliases are refused too: the guard's allow-list IS the documented grammar).
case "$DEST" in
  -?*)
    echo "error: unknown argument '$DEST' — usage: bash maintainers/setup-control-plane.sh [<control-plane-dir>] [--sync]" >&2
    exit 2
    ;;
esac
if [ -n "$MODE_ARG" ] && [ "$MODE_ARG" != "--sync" ]; then
  echo "error: unknown argument '$MODE_ARG' — usage: bash maintainers/setup-control-plane.sh [<control-plane-dir>] [--sync]" >&2
  exit 2
fi
if [ -z "$DEST" ]; then
  DEST="$HARNESS_DIR/../$(basename "$HARNESS_DIR")-guv"
  echo "No control-plane dir given — defaulting to $DEST (the <project>-guv convention)"
fi
MODE="create"
[ "$MODE_ARG" = "--sync" ] && MODE="sync"
# Sync refreshes an EXISTING plane; against an absent one it would silently
# manufacture an empty half-plane (no manifest, no CLAUDE.md) and report
# success while the real plane stays stale. Refuse loud instead.
if [ "$MODE" = "sync" ] && [ ! -d "$DEST/.claude" ]; then
  echo "error: --sync target $DEST has no .claude/ — not an existing control plane." >&2
  echo "       Create it first (run without --sync), or pass the right directory." >&2
  exit 2
fi

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
              resolve-stack.sh resolve-ready.sh render-status.sh replan.sh check-citations.sh \
              update-readme-status.sh archive-initiative.sh settings.json; do
    if [ -e "$HARNESS_DIR/.claude/$item" ]; then
      rm -rf "$DEST/.claude/$item"
      cp -R "$HARNESS_DIR/.claude/$item" "$DEST/.claude/$item"
      # cp -R copies directories wholesale — scrub Finder droppings
      find "$DEST/.claude/$item" -name '.DS_Store' -delete 2>/dev/null
    fi
  done
  # Workflows: never clobber the directory wholesale — the native feature saves
  # USER-authored workflows into .claude/workflows/, so only the entries the
  # harness itself ships are refreshed (ownership by filename, like rules);
  # consumer-saved workflows are never touched. Two accepted edges until the
  # plugin namespace (Phase 5) gives harness workflows a real prefix: a workflow
  # removed upstream lingers until deleted by hand, and a consumer file whose
  # name collides with a future harness-shipped one is overwritten on sync.
  if [ -d "$HARNESS_DIR/.claude/workflows" ]; then
    mkdir -p "$DEST/.claude/workflows"
    for f in "$HARNESS_DIR/.claude/workflows/"*; do
      [ -e "$f" ] || continue
      rm -rf "$DEST/.claude/workflows/$(basename "$f")"
      cp -R "$f" "$DEST/.claude/workflows/"
    done
    find "$DEST/.claude/workflows" -name '.DS_Store' -delete 2>/dev/null
  fi
  # Rules: ownership is declared by filename — replace harness-owned guv-* only;
  # unprefixed consumer-authored rules are never touched. The superseded single-file
  # RULES.md is removed (leaving it would double-load: once via a consumer CLAUDE.md
  # still carrying the old @import, once natively from .claude/rules/).
  if [ -d "$HARNESS_DIR/.claude/rules" ]; then
    mkdir -p "$DEST/.claude/rules"
    rm -f "$DEST/.claude/rules/guv-"*.md
    for f in "$HARNESS_DIR/.claude/rules/guv-"*.md; do
      [ -e "$f" ] && cp "$f" "$DEST/.claude/rules/"
    done
    if [ -f "$DEST/.claude/RULES.md" ]; then
      rm -f "$DEST/.claude/RULES.md"
      echo "[setup] removed superseded .claude/RULES.md — rules now live in .claude/rules/"
      echo "        (your customizations belong in unprefixed files there; if your CLAUDE.md"
      echo "        still carries an '@.claude/RULES.md' import line, delete that line)"
    fi
  fi
  echo "[setup] synced harness core → $DEST/.claude/"
}

copy_core

# run-harness-tests.sh: commands.test for the control plane runs the harness's bash
# suites (which live in roots.code, not here). Generated, but NOT create-only: the
# runner carries no consumer state, so like guv-* rules it is harness-owned and
# refreshed in BOTH modes whenever it drifts from the generator (entry
# 2026-06-11T23:17:51Z-15612590 — create-only meant the D3 stderr-gate fix never
# reached existing control planes). Announced on change, silent when current.
# Refresh-only on --sync: the runner is dogfooding tooling, and --sync is also the
# template-clone consumer update path — a project that never had the runner must
# not be handed one. Creation stays a create-mode act.
write_runner() {
  local target="$DEST/.claude/run-harness-tests.sh" tmp
  if [ ! -f "$target" ] && [ "$MODE" = "sync" ]; then
    return 0
  fi
  tmp=$(mktemp)
  cat > "$tmp" <<'SH'
#!/bin/bash
# Run the harness's bash test suites from the code repo (roots.code).
# stderr is captured per suite and ANY output there fails the run: a green
# summary above a parse error is how a vacuous guard slipped two review gates
# (session-2026-06-11-003) — the empty-stderr gate is enforced here, not by
# reading discipline.
# Harness-owned: regenerated by setup-control-plane.sh (create and --sync) —
# local edits will be overwritten; improve the generator instead.
set -u
CODE=$(jq -r '.roots.code' .claude/project.json)
fail=0
for t in "$CODE"/.claude/tests/*.test.sh; do
  [ -e "$t" ] || continue
  echo "== $(basename "$t") =="
  err=$(mktemp)
  bash "$t" 2>"$err" || fail=1
  if [ -s "$err" ]; then
    echo "[stderr] $(basename "$t") wrote to stderr — failing the run:"
    cat "$err"
    fail=1
  fi
  rm -f "$err"
done
exit $fail
SH
  if [ ! -f "$target" ]; then
    cp "$tmp" "$target"
  elif ! cmp -s "$tmp" "$target"; then
    cp "$tmp" "$target"
    echo "[setup] refreshed .claude/run-harness-tests.sh (harness-owned — drifted from the generator)"
  fi
  chmod +x "$target"
  rm -f "$tmp"
}
write_runner

if [ "$MODE" = "sync" ]; then
  echo "[setup] --sync complete. Manifest, CLAUDE.md, docs, and feedback left untouched."
  exit 0
fi

# ── First-time scaffolding (create only what's absent — never clobber session state) ──

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
- **Execution at scale:** saved workflows in \`.claude/workflows/\` (e.g.
  \`/evaluate-parallel\`) — fan-out execution only; QA stages use the calibrated
  reviewers by name (\`.claude/rules/guv-workflows.md\`).
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
