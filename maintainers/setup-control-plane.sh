#!/bin/bash
# maintainers/setup-control-plane.sh
# Scaffold (or --sync) a dogfooding CONTROL PLANE that treats THIS guv repo as
# roots.code. The control plane holds every session artifact (rendered CLAUDE.md,
# handoffs, feedback log), so the guv repo stays clean. See maintainers/DOGFOODING.md.
#
# Usage:
#   bash maintainers/setup-control-plane.sh [<control-plane-dir>] [--sync]
#
#   <control-plane-dir> defaults to a sibling of this repo named <repo>-guv —
#   the <project>-guv naming convention (announced when defaulted). The default
#   is a constructed path offered at creation/sync time only: no script ever
#   discovers a control plane by name; the manifest is the sole machine pointer.
#
#   (no flag)  create the control plane if absent; copy the core into it; write
#              the dogfooding manifest + CLAUDE.md ONLY if they don't exist yet
#              (so your session artifacts are never clobbered); git init it.
#   --sync     refresh ONLY the copied core (commands/skills/agents/hooks/scripts/
#              guv-* rules/workflows/schema/settings) plus the generated test runner —
#              run-core-tests.sh carries no consumer state, so it is core-owned and
#              regenerated whenever the generator's copy changes (announced; silent when
#              current). Leaves the control plane's manifest, CLAUDE.md, docs, and
#              feedback untouched. Run this after editing guv.

set -u

GUV_DIR="$(cd "$(dirname "$0")/.." && pwd)"      # the guv repo (= roots.code)
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
  DEST="$GUV_DIR/../$(basename "$GUV_DIR")-guv"
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

# Relative path from the control plane back to guv (for roots.code).
# Falls back to an absolute path if a relative one can't be computed.
rel_code() {
  python3 -c "import os,sys;print(os.path.relpath(sys.argv[1], sys.argv[2]))" \
    "$GUV_DIR" "$DEST_ABS" 2>/dev/null || echo "$GUV_DIR"
}
CODE_REL="$(rel_code)"

# ── Copy the behavioral core from guv (always — this is the syncable part) ──
# Note what is NOT copied: project.json (we write a dogfooding one), docs/, feedback/,
# agent-memory/, CLAUDE.md — those are control-plane-owned session state.
copy_core() {
  # The helper-script set is DERIVED by glob ([7.1]: this was the fourth
  # hand-enumerated registry, found during 6.2 — a new .claude/*.sh helper now
  # reaches every plane on create and --sync by existing).
  for item in commands skills agents hooks tests project.schema.json settings.json \
              $(cd "$GUV_DIR/.claude" && ls *.sh 2>/dev/null); do
    if [ -e "$GUV_DIR/.claude/$item" ]; then
      rm -rf "$DEST/.claude/$item"
      cp -R "$GUV_DIR/.claude/$item" "$DEST/.claude/$item"
      # cp -R copies directories wholesale — scrub Finder droppings
      find "$DEST/.claude/$item" -name '.DS_Store' -delete 2>/dev/null
    fi
  done
  # Workflows: never clobber the directory wholesale — the native feature saves
  # USER-authored workflows into .claude/workflows/, so only the entries the
  # guv itself ships are refreshed (ownership by filename, like rules);
  # consumer-saved workflows are never touched. Two accepted edges until the
  # plugin namespace (Phase 5) gives guv workflows a real prefix: a workflow
  # removed upstream lingers until deleted by hand, and a consumer file whose
  # name collides with a future guv-shipped one is overwritten on sync.
  if [ -d "$GUV_DIR/.claude/workflows" ]; then
    mkdir -p "$DEST/.claude/workflows"
    for f in "$GUV_DIR/.claude/workflows/"*; do
      [ -e "$f" ] || continue
      rm -rf "$DEST/.claude/workflows/$(basename "$f")"
      cp -R "$f" "$DEST/.claude/workflows/"
    done
    find "$DEST/.claude/workflows" -name '.DS_Store' -delete 2>/dev/null
  fi
  # Rules: ownership is declared by filename — replace core-owned guv-* only;
  # unprefixed consumer-authored rules are never touched. The superseded single-file
  # RULES.md is removed (leaving it would double-load: once via a consumer CLAUDE.md
  # still carrying the old @import, once natively from .claude/rules/).
  if [ -d "$GUV_DIR/.claude/rules" ]; then
    mkdir -p "$DEST/.claude/rules"
    rm -f "$DEST/.claude/rules/guv-"*.md
    for f in "$GUV_DIR/.claude/rules/guv-"*.md; do
      [ -e "$f" ] && cp "$f" "$DEST/.claude/rules/"
    done
    if [ -f "$DEST/.claude/RULES.md" ]; then
      rm -f "$DEST/.claude/RULES.md"
      echo "[setup] removed superseded .claude/RULES.md — rules now live in .claude/rules/"
      echo "        (your customizations belong in unprefixed files there; if your CLAUDE.md"
      echo "        still carries an '@.claude/RULES.md' import line, delete that line)"
    fi
  fi
  echo "[setup] synced core → $DEST/.claude/"
}

copy_core

# run-core-tests.sh: commands.test for the control plane runs the core's bash
# suites (which live in roots.code, not here). Generated, but NOT create-only: the
# runner carries no consumer state, so like guv-* rules it is core-owned and
# refreshed in BOTH modes whenever it drifts from the generator (entry
# 2026-06-11T23:17:51Z-15612590 — create-only meant the D3 stderr-gate fix never
# reached existing control planes). Announced on change, silent when current.
# Refresh-only on --sync: the runner is dogfooding tooling, and --sync is also the
# template-clone consumer update path — a project that never had the runner must
# not be handed one. Creation stays a create-mode act.
write_runner() {
  local target="$DEST/.claude/run-core-tests.sh" tmp
  if [ ! -f "$target" ] && [ "$MODE" = "sync" ]; then
    return 0
  fi
  tmp=$(mktemp)
  cat > "$tmp" <<'SH'
#!/bin/bash
# Run the core's bash test suites from the code repo (roots.code).
# stderr is captured per suite and ANY output there fails the run: a green
# summary above a parse error is how a vacuous guard slipped two review gates
# (session-2026-06-11-003) — the empty-stderr gate is enforced here, not by
# reading discipline.
# Core-owned: regenerated by setup-control-plane.sh (create and --sync) —
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
    echo "[setup] refreshed .claude/run-core-tests.sh (core-owned — drifted from the generator)"
  fi
  chmod +x "$target"
  rm -f "$tmp"
}
write_runner

# Status-render post-commit hook ([6.7]): a tracker-touching commit regenerates
# status.html through the sanctioned chain and commits it as a derived artifact.
# Same ownership semantics as the runner — created in create mode, refreshed in
# both modes while present and core-owned, never created fresh on --sync
# (--sync doubles as the template-clone consumer update path, and a project
# that never had a git hook must not be handed one). A post-commit hook that
# is NOT core-owned is never touched: announce and step aside.
write_render_hook() {
  local target="$DEST/.git/hooks/post-commit" tmp
  if [ ! -d "$DEST/.git" ]; then
    # A linked worktree has a .git FILE; hooks live with the main repo, and
    # writing here would be wrong. Either way, announce the skip instead of
    # vanishing (create mode git-inits before this runs, so no-.git-at-all is
    # a --sync-against-non-repo shape).
    if [ -e "$DEST/.git" ]; then
      echo "[setup] $DEST/.git is not a directory (worktree?) — render hook not installed"
    else
      echo "[setup] $DEST is not a git repo — render hook not installed"
    fi
    return 0
  fi
  if [ ! -f "$target" ] && [ "$MODE" = "sync" ]; then
    # Silent BY DESIGN, not an unannounced skip: --sync doubles as the
    # template-clone consumer update path, and a project that never had a
    # git hook must not be handed one (T8 pins the no-creation contract).
    return 0
  fi
  # Recognize the pre-[8.3] `Harness-owned` marker too: the noun retirement
  # renamed it to `Core-owned`, and an already-synced consumer carries the old
  # stamp on a hook this generator wrote. Accepting either keeps --sync able to
  # update those consumers (the refresh below rewrites it with the new marker);
  # matching only the new name would orphan every plane synced before [8.3].
  if [ -f "$target" ] && ! grep -qE 'Core-owned|Harness-owned' "$target"; then
    echo "[setup] .git/hooks/post-commit exists and is not core-owned — left untouched (the render hook was not installed)"
    return 0
  fi
  mkdir -p "$DEST/.git/hooks"
  tmp=$(mktemp)
  cat > "$tmp" <<'SH'
#!/bin/bash
# .git/hooks/post-commit — status-view regeneration ([6.7]; README status block
# added at [8.3] §3.3). When a commit touches docs/PHASE_STATUS.md — the views are
# a pure function of the tracker, so other docs cannot change them — regenerate the
# derived status views through the sanctioned chain and commit them: status.html
# (resolve-ready.sh --json -> render-status.sh) and the README status block
# (status-line.sh -> update-readme-status.sh, when present; a no-op without the
# markers). The follow-up render commit touches status.html + README.md, neither
# of which is the tracker, so the trigger check below is still the recursion break.
# Convenience, NEVER a dependency: every failure rung degrades to a loud notice and
# a clean exit, and the manual render always works without this hook:
#   bash .claude/resolve-ready.sh docs/PHASE_STATUS.md --json > status.json
#   bash .claude/render-status.sh status.json > status.html
#   bash .claude/status-line.sh status.json | bash .claude/update-readme-status.sh README.md
# Core-owned: written by setup-control-plane.sh (create; refreshed on
# --sync while present) — local edits will be overwritten; improve the
# generator instead.
set -u
# --root: a repo's very first commit must trigger too (diff-tree is empty
# on a root commit without it).
git diff-tree --root --no-commit-id --name-only -r HEAD 2>/dev/null \
  | grep -qx 'docs/PHASE_STATUS.md' || exit 0
# Detached HEAD (rebase, bisect): never auto-commit there.
git symbolic-ref -q HEAD >/dev/null || exit 0
if ! command -v jq >/dev/null 2>&1; then
  echo "[render-hook] jq not found — status.html NOT regenerated (render manually once jq is available)"
  exit 0
fi
if [ ! -f .claude/resolve-ready.sh ] || [ ! -f .claude/render-status.sh ]; then
  echo "[render-hook] render chain absent (.claude/resolve-ready.sh + render-status.sh) — status.html NOT regenerated"
  exit 0
fi
TMP_JSON=$(mktemp) && TMP_HTML=$(mktemp) && ERR=$(mktemp) \
  || { echo "[render-hook] mktemp failed — status.html NOT regenerated"; exit 0; }
if bash .claude/resolve-ready.sh docs/PHASE_STATUS.md --json > "$TMP_JSON" 2>"$ERR" \
   && bash .claude/render-status.sh "$TMP_JSON" > "$TMP_HTML" 2>>"$ERR"; then
  # The recording rung is guarded too: an ignored target, an index lock, or
  # a failed commit must never hide behind a success banner.
  if mv "$TMP_HTML" status.html 2>>"$ERR" && chmod 644 status.html 2>>"$ERR"; then
    # README status block — secondary to status.html and best-effort: refresh it
    # from the SAME resolver JSON when the composer + updater + a README exist
    # (a no-op without the STATUS markers), then record the derived views together.
    # The pathspec is kept explicit per branch (no $PATHS variable): a bare commit
    # could sweep up a user's partial-commit leftovers, and an assignment naming
    # status.html is not one of the recording forms the view-acceptance check allows.
    MSG="chore(render): regenerate status views (post-commit hook)"
    if [ -f .claude/status-line.sh ] && [ -f .claude/update-readme-status.sh ] && [ -f README.md ]; then
      # Compose first, write only a NON-EMPTY line (a failed compose must not blank
      # the block); the status.html swap above is guarded the same "stale beats broken" way.
      LINE="$(bash .claude/status-line.sh "$TMP_JSON" 2>>"$ERR")"
      [ -n "$LINE" ] && printf '%s\n' "$LINE" | bash .claude/update-readme-status.sh README.md 2>>"$ERR"
      git add status.html README.md 2>>"$ERR" \
        && git commit -q -m "$MSG" -- status.html README.md 2>>"$ERR"
    else
      git add status.html 2>>"$ERR" \
        && git commit -q -m "$MSG" -- status.html 2>>"$ERR"
    fi
    if [ $? -eq 0 ]; then
      echo "[render-hook] status views regenerated and committed — push to publish"
    else
      echo "[render-hook] render succeeded but recording FAILED — not committed:"
      cat "$ERR"
    fi
  else
    echo "[render-hook] render succeeded but recording FAILED — status.html NOT committed:"
    cat "$ERR"
  fi
else
  # Stale beats broken: the previous committed render stays in place.
  echo "[render-hook] render chain refused — status.html NOT updated:"
  cat "$ERR"
fi
rm -f "$TMP_JSON" "$TMP_HTML" "$ERR"
exit 0
SH
  if [ ! -f "$target" ]; then
    cp "$tmp" "$target"
    echo "[setup] installed status-render post-commit hook (.git/hooks/post-commit)"
  elif ! cmp -s "$tmp" "$target"; then
    cp "$tmp" "$target"
    echo "[setup] refreshed status-render post-commit hook (core-owned — drifted from the generator)"
  fi
  chmod +x "$target"
  rm -f "$tmp"
}

# Ensure the plane ignores the fan-out scratch (.lane-reports/) even on --sync to
# an EXISTING plane — the create-mode .gitignore write is skipped when one already
# exists, so a plane scaffolded before this line shipped would never get it
# (UAT-F4 + eval Minor). Idempotent: append only if absent; never rewrites.
ensure_lane_reports_ignored() {
  local gi="$DEST/.gitignore"
  [ -f "$gi" ] || return 0
  grep -qxF '.lane-reports/' "$gi" || {
    printf '.lane-reports/\n' >> "$gi"
    echo "[setup] added .lane-reports/ to the plane's .gitignore (fan-out scratch)"
  }
}

if [ "$MODE" = "sync" ]; then
  write_render_hook
  ensure_lane_reports_ignored
  echo "[setup] --sync complete. Manifest, CLAUDE.md, docs, and feedback left untouched."
  exit 0
fi

# ── First-time scaffolding (create only what's absent — never clobber session state) ──

# Dogfooding manifest: roots.code points back at guv; ceremony: task.
if [ ! -f "$DEST/.claude/project.json" ]; then
  jq -n --arg code "$CODE_REL" '{
    "$schema": "./project.schema.json",
    name: "guv-dev",
    language: "shell",
    packageManager: null,
    roots: { control: ".", code: $code },
    commands: {
      test: "bash .claude/run-core-tests.sh",
      build: null, lint: null, format: null, dev: null, install: null
    },
    scaffoldCheck: ("test -d \"" + $code + "/.claude\""),
    readyCheck: null,
    formatExtensions: ["md","json","sh","yml","yaml"],
    guards: [],
    ceremony: "task",
    views: { status: "status.html" }
  }' > "$DEST/.claude/project.json"
  echo "[setup] wrote dogfooding manifest (roots.code=$CODE_REL, ceremony=task)"
fi

# Control-plane CLAUDE.md — context for the dogfooding session.
if [ ! -f "$DEST/CLAUDE.md" ]; then
  cat > "$DEST/CLAUDE.md" <<SH
# guv Dev — Control Plane

This is the **control plane** for improving guv. guv itself
is the code repo at \`roots.code\` (\`$CODE_REL\`).

- **Behavior & conventions:** \`.claude/rules/\` (\`guv-*.md\` core-owned; add your own unprefixed rules alongside)
- **Memory authority:** the manifest and the latest session handoff are authoritative;
  treat auto memory as hints and never let it override either.
- **Commands, roots, ceremony:** \`.claude/project.json\`. \`commands.test\` runs the
  core's bash suites in the code repo.
- **Execution at scale:** saved workflows in \`.claude/workflows/\` (e.g.
  \`/eval-parallel\`) — fan-out execution only; QA stages use the calibrated
  reviewers by name (\`.claude/rules/guv-workflows.md\`).
- **Where edits go:** improve guv in the **code repo** ($CODE_REL) — that's
  where product commits land. This control plane holds session artifacts only
  (handoffs in \`docs/sessions/\`, guv friction in \`.claude/feedback/\`).
- **After editing guv**, run \`maintainers/setup-control-plane.sh <here> --sync\`
  from the guv repo to pull your changes in before testing them.

## Project facts

- This is \`ceremony: task\` — scoped changes, no phase docs. Use \`/task\` for work.
- Log guv friction with \`/feedback\`; it stays here, never in the template.
SH
  echo "[setup] wrote control-plane CLAUDE.md"
fi

mkdir -p "$DEST/docs/sessions"
[ -f "$DEST/docs/sessions/.gitkeep" ] || : > "$DEST/docs/sessions/.gitkeep"

# Gitignore agent-memory in the control plane (feedback IS committed here — it's the
# dogfooding record).
if [ ! -f "$DEST/.gitignore" ]; then
  # status.json is the manual render chain's intermediate file; status.html is
  # the committed derived artifact, the JSON is not. .lane-reports/ is the
  # fan-out scratch (lane failure reports + collected outputs); it lives in the
  # CONTROL PLANE (the worktrees live in roots.code, which gets the guv-core
  # block via the scaffold), so the plane's own gitignore must carry it (UAT-F4).
  printf '.claude/agent-memory/\n.claude/settings.local.json\n.DS_Store\nstatus.json\n.lane-reports/\n' > "$DEST/.gitignore"
fi

# Init the control plane's own git (its own commit stream), if not already a repo.
if [ ! -d "$DEST/.git" ]; then
  git -C "$DEST" init -q && echo "[setup] git init'd the control plane"
fi
write_render_hook

echo ""
echo "[setup] Control plane ready at: $DEST_ABS"
echo "  roots.code → $CODE_REL (guv)"
echo "  Next:  cd \"$DEST_ABS\" && claude   then  /status"
echo "  Re-sync after guv edits:  bash maintainers/setup-control-plane.sh \"$DEST\" --sync"
