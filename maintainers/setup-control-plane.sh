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
#   --sync     refresh ONLY the copied core (skills/agents/hooks/scripts/
#              guv-* rules/workflows/schema/settings) plus the generated test runner —
#              run-core-tests.sh carries no consumer state, so it is core-owned and
#              regenerated whenever the generator's copy changes (announced; silent when
#              current). Leaves the control plane's manifest, CLAUDE.md, docs, and
#              feedback untouched. Run this after editing guv.
#
#   BOTH modes also write OUTSIDE the control plane when the guv plugin is installed:
#   the plugin cache's guv-owned trees are refreshed from this repo's built plugin/,
#   because a plugin-registered hook runs the CACHE's copy of core, never the plane's.
#   That cache is user-scope, so it is the core every guv project on this machine runs.
#   It is refreshed WHOLE — one vintage, never a blend of release text over source code
#   (a half-refresh once left the greenfield door's routing guard failing open). The
#   refresh names every file it changes or prunes, keeps its delete inside those
#   guv-owned trees, verifies the result by re-reading the cache, and is skipped LOUDLY
#   whenever it cannot establish that the cache is this repo's artifact. See
#   refresh_plugin_cache below.

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
  for item in skills agents hooks tests project.schema.json settings.json \
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
  # Prune guv-owned core artifacts REMOVED upstream. copy_core only adds/replaces
  # what EXISTS in source, so a removal cannot self-heal: the commands/ dir
  # (flattened into skills/ at [8.3] stage 2) and the single-owner scripts bundled
  # into their skills at stage 3 (extract-eval-report, feedback-submit,
  # check-citations) linger in an already-synced consumer, dual-loading the old
  # surface beside the new. EXPLICIT list, never a mirror: a blanket "delete dest
  # not in source" would also delete setup-GENERATED files (run-core-tests.sh) and
  # consumer-owned ones. Append a path here when a future change removes a
  # guv-owned core artifact. (Renames WITHIN a wholesale-replaced dir — skills/,
  # agents/ — are already handled by the rm-rf+cp above; only removals need this.)
  for obsolete in commands extract-eval-report.sh feedback-submit.sh check-citations.sh; do
    if [ -e "$DEST/.claude/$obsolete" ]; then
      rm -rf "$DEST/.claude/$obsolete"
      echo "[setup] pruned obsolete core artifact: .claude/$obsolete (removed upstream)"
    fi
  done
  echo "[setup] synced core → $DEST/.claude/"
}

# ── De-duplicate hook registration when the guv PLUGIN is also installed ([19.5]) ──
# A control plane that installs the guv plugin AND syncs the core gets every hook
# registered TWICE — once plugin-mode (the plugin's hooks.json) and once project-mode
# (this synced settings.json) — so each fires twice, producing the double metering
# write. The plugin's hooks.json is the SINGLE authoritative registration when the
# plugin is present; the synced settings.json then defers by shipping hooks-free,
# exactly as build-plugin.sh already does for the plugin's own shell/settings.json
# (jq 'del(.hooks)'). Detection reads the user-level plugin database — the guv plugin
# installs at USER scope (installed_plugins.json), with no per-plane marker to key on;
# GUV_PLUGINS_DB overrides the path for tests. Rule 15 designed degradation: an
# absent/unparseable DB, or one with no guv entry, KEEPS the hooks (today's behavior —
# a plane WITHOUT the plugin needs its project-mode hooks; a detection failure must
# never manufacture a hookless plane, the one new breakage). Detection is a positive
# signal only; the safe default is to leave registration as it is.
dedup_hook_registration() {
  local sj="$DEST/.claude/settings.json"
  [ -f "$sj" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # Nothing to strip if the synced settings.json carries no hooks block at all.
  jq -e 'has("hooks")' "$sj" >/dev/null 2>&1 || return 0
  # The plugin DB: explicit override → CLAUDE_CONFIG_DIR → ~/.claude. Absent file or
  # no guv-family key ("<plugin>@<marketplace>", e.g. guv@guv) → plugin not authoritative.
  local db="${GUV_PLUGINS_DB:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json}"
  [ -f "$db" ] || return 0
  jq -e '(.plugins // {}) | keys[] | select(startswith("guv@"))' "$db" >/dev/null 2>&1 || return 0
  # Plugin is installed → it owns hook registration. Strip the synced settings.json
  # hooks block (surgical: del(.hooks) leaves permissions and every other key intact).
  local tmp; tmp=$(mktemp) || return 0
  if jq 'del(.hooks)' "$sj" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$sj"
    echo "[setup] guv plugin installed — synced settings.json shipped hooks-free (the plugin's hooks.json is the authoritative registration; prevents the --sync+plugin double-fire / double metering write)"
  else
    rm -f "$tmp"
  fi
}

# ── Refresh the installed plugin CACHE when it drifts from source (the [19.5] half) ──
# The dedup above hands hook registration to the plugin. That also makes the plugin's
# OWN copy of core the one every hook RUNS: session-start.sh (like every hook entry
# point) resolves its BASE from its own dirname, so a plugin-registered hook executes
# ${CLAUDE_PLUGIN_ROOT}/scripts/*, never the plane's freshly synced .claude/*. Left
# alone, create and --sync both deliver fixed scripts into a directory no hook reads
# while the release-frozen cache goes on running the defect — silently, because cache
# and source report the SAME plugin version even when their content has diverged.
#
# Observed live (2026-07-26): a budget-gate.sh initiative-windowing fix landed in source
# 2026-07-21; the cached pre-fix gate kept firing a spurious BREACH at every session
# entry, and that banner's own text invites the operator to raise the budget setpoint —
# a phantom overage presented as a decision to make. Ten scripts had drifted, meter.sh
# among them, so a just-landed metering fix would also have metered through stale code.
# This is the other half of [19.5]: having made the plugin authoritative, we must not
# leave it stale. (No new deliverable ID is minted here — [19.5] is the cause, cited.)
#
# SCOPE — every guv-owned content tree, ONE vintage, no mixing. A first cut of this fix
# refreshed only what the plugin literally executes (scripts/, hooks/, workflows/) and
# froze the rest at the release, on the theory that skills/ and rules/ are "read by name"
# and that leaving them preserved DOGFOODING.md's dual-load comparison. Both halves of
# that theory were wrong, and the second one shipped a live fail-open regression before
# review caught it:
#
#   * "Read by name" is false. scaffold-shell.sh sets SHELL_DIR="$PLUGIN_ROOT/shell" and
#     RULES_DIR="$PLUGIN_ROOT/rules" — an executed script reading those trees by path,
#     the same pattern that put scripts/ in scope.
#   * A mixed cache is INCOHERENT, not conservative. Release skill text calls source
#     scripts, and a skill's contract is an interface: [24.1] renamed the greenfield
#     door, so the frozen skill ran `route.sh --for <its old name>` against a refreshed
#     router that knows only the new one. The router exited 2 — which that skill documents
#     as "router unavailable, proceed with scaffolding". The [8.1] routing guard degraded
#     to FAIL-OPEN on a live machine. A stale cache is at least self-consistent; a
#     half-refreshed one is a vintage that was never built, shipped, or tested.
#
# So the cache carries source or it carries the release, never a blend (Rule 7 — pick
# one, don't average). A genuine release-vs-source comparison needs a tagged checkout or
# a second install, which is where it always had to come from.
#
# .claude-plugin/ is the ONE deliberate exclusion, for two reasons that survive the
# above: it holds the manifest this function reads to CONFIRM the cache's identity
# (overwriting it would make that check self-fulfilling on every run after the first),
# and the cache path is version-keyed, so copying a bumped plugin.json into a .../0.10.0/
# directory would contradict the plugin DB's own record.
#
# What keeps the delete off Claude Code's ground is the prune being TREE-SCOPED — the
# walk only ever enters a named tree — NOT the number of trees named. .in_use/ (per-
# session PID locks) and every other cache-ROOT entry are siblings of these trees, so
# they are unreachable whether this list holds three names or eight.
GUV_CACHE_TREES="agents hooks rules scripts shell skills tests workflows"
# Set by refresh_plugin_cache, read by refresh_one_plugin_cache. Declared here with a
# default rather than passed: it is one fact about the SOURCE, computed once for every
# cache, and `set -u` must not depend on a `local` leaking through dynamic scope.
GUV_PLUGIN_BEHIND=""
#
# BLAST RADIUS, stated because it is wider than the command's name suggests: the plugin
# cache is USER-scope. Refreshing it changes what every guv-governed project on this
# machine runs, not just $DEST — including projects that installed the release and never
# asked for unreleased core. That is why the report names the path and says so out loud.
#
# Rule 15 — the ONLY thing that authorizes a write outside the project is a positive
# signal, and the DB alone is not one: a guv-family entry names a path, and the cache's
# OWN plugin.json must then agree that it is the artifact this repo builds. Every rung
# that cannot establish that DISCLOSES and writes nothing — a missing built plugin, a
# guv entry with no installPath, a relative path, an absent directory, a foreign
# manifest, an unenumerable source tree. Three rungs are silent: no plugin DB and no guv
# entry both mean the plugin is simply not installed here — the ordinary state of a
# consumer plane, and not news — while no jq means the check could not RUN, and is silent
# only because every other jq-dependent step in this script degrades the same way. This
# verifies a cache; it never provisions one.

_cache_tree_files() {   # <root> <tree> → tree-prefixed relative paths, deterministic order
  [ -d "$1/$2" ] || return 0
  ( cd "$1/$2" 2>/dev/null && find . -type f ! -name '.DS_Store' -print 2>/dev/null ) \
    | sed "s|^\./|$2/|" | LC_ALL=C sort
}

_cache_drift() {        # files the built plugin ships that the cache has wrong or missing
  local built=$1 cache=$2 t f
  for t in $GUV_CACHE_TREES; do
    _cache_tree_files "$built" "$t" | while IFS= read -r f; do
      cmp -s "$built/$f" "$cache/$f" 2>/dev/null || echo "$f"
    done
  done
}

# Is the BUILT plugin itself behind .claude/? This refresh copies plugin/ into the cache,
# so a stale plugin/ makes a coherent-but-old cache and the operator is never told: cache
# drift is measured against plugin/, so when plugin/ is the thing that is behind, drift
# reads ZERO and every advisory tied to it is suppressed — silence exactly where the
# hazard is. Measured directly instead, on the surfaces build-plugin.sh copies VERBATIM —
# ALL of them, which the first cut of this function did not do while its comment claimed
# it did (found at review; the gaps landed on shell/, the very tree the scope widening
# had just brought into the cache for the first time):
#
#   .claude/*.sh, .claude/hooks/*.sh          -> scripts/
#   maintainers/plugin-src/scripts/*.sh       -> scripts/          (plugin-only sources)
#   maintainers/plugin-src/skills/*/SKILL.md  -> skills/<name>/    (authored, NOT rewritten)
#   .claude/rules/guv-*.md                    -> rules/
#   .claude/skills/<name>/<bundle>/**         -> skills/<name>/<bundle>/**
#   CLAUDE.template.md, README.template.md, Makefile, .gitignore (-> gitignore),
#     .claude/project.schema.json, .claude/settings.sandbox-example.json,
#     sandbox/*, docs/{REQUIREMENTS,ARCHITECTURE,PHASE_STATUS}.md   -> shell/
#   plugin/tests/*.test.sh                    <- .claude/tests/    (reversed; see below)
#
# EXCLUDED on purpose, named so the omissions read as decisions and not oversights:
#   - core .claude/skills/ and .claude/agents/ BODIES, and .claude/workflows/: the builder
#     rewrites frontmatter, paths and namespaces, so a byte diff there means nothing.
#     (Their bundled subdirs above ARE checked — those are copied byte-identical.)
#   - .claude-plugin/plugin.json: outside GUV_CACHE_TREES, so no refresh ever carries it.
#   - shell/settings.json and hooks/hooks.json: DERIVED by jq, not copied. Handled on
#     their own terms below, because comparing them to source bytes answers nothing.
#   - DELETIONS, in either direction. This detector walks SOURCES and asks whether each
#     one's built copy matches; a source that no longer exists is walked by nothing, so
#     its built copy survives as an orphan and is never named. The check answers "is
#     every source's output current", not "is the built tree exactly the sources" — a
#     rebuild is what removes an orphan, and only a rebuild proves the tree. Named here
#     so the gap reads as a known limit rather than a detector that missed something.
_stale_pair() {   # <source-file> <built-root> <built-relative>; names it when behind or missing
  # A vanished source returns clean, NOT stale — see the DELETIONS exclusion above.
  [ -e "$1" ] || return 0
  if [ -e "$2/$3" ] && cmp -s "$1" "$2/$3" 2>/dev/null; then return 0; fi
  echo "$3"
}
_hook_scripts() { # <settings.json|hooks.json> → basenames of every wired hook command
  jq -r '[.hooks | .. | objects | select(has("command")) | .command] | .[]' "$1" 2>/dev/null \
    | sed 's|.*/||' | LC_ALL=C sort -u
}
_built_plugin_stale() {  # <built> → source-relative names whose built copy differs or is missing
  local built=$1 f rel
  for f in "$GUV_DIR/.claude/"*.sh "$GUV_DIR/.claude/hooks/"*.sh \
           "$GUV_DIR/maintainers/plugin-src/scripts/"*.sh; do
    _stale_pair "$f" "$built" "scripts/$(basename "$f")"
  done
  for f in "$GUV_DIR/.claude/rules/"guv-*.md; do
    _stale_pair "$f" "$built" "rules/$(basename "$f")"
  done
  for f in "$GUV_DIR/maintainers/plugin-src/skills/"*/SKILL.md; do
    [ -e "$f" ] || continue
    _stale_pair "$f" "$built" "skills/$(basename "$(dirname "$f")")/SKILL.md"
  done
  # Skill-bundled assets. The builder cp -R's ANY subdir of a skill byte-identical (the
  # [8.3] single-owner bundle), so the walk has to be as wide as the copy — not scripts/
  # only and not *.sh only, which is all it looked at before.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel=${f#"$GUV_DIR/.claude/"}
    _stale_pair "$f" "$built" "$rel"
  done <<EOF
$(find "$GUV_DIR/.claude/skills" -mindepth 3 -type f ! -name '.DS_Store' 2>/dev/null)
EOF
  # shell/ — the scaffold payload. Every file here is deployed verbatim into every project
  # guv scaffolds, and shell/ is read on the executed path (scaffold-shell.sh derives
  # SHELL_DIR from its own dirname), so a stale copy ships silently into real repos.
  _stale_pair "$GUV_DIR/CLAUDE.template.md"  "$built" "shell/CLAUDE.template.md"
  _stale_pair "$GUV_DIR/README.template.md"  "$built" "shell/README.template.md"
  _stale_pair "$GUV_DIR/Makefile"            "$built" "shell/Makefile"
  _stale_pair "$GUV_DIR/.gitignore"          "$built" "shell/gitignore"
  _stale_pair "$GUV_DIR/.claude/project.schema.json"           "$built" "shell/project.schema.json"
  _stale_pair "$GUV_DIR/.claude/settings.sandbox-example.json" "$built" "shell/settings.sandbox-example.json"
  for f in "$GUV_DIR/sandbox/"*; do
    [ -f "$f" ] && _stale_pair "$f" "$built" "shell/sandbox/$(basename "$f")"
  done
  for f in REQUIREMENTS ARCHITECTURE PHASE_STATUS; do
    _stale_pair "$GUV_DIR/docs/$f.md" "$built" "shell/docs/$f.md"
  done
  # The two DERIVED outputs, both cut from .claude/settings.json by jq in one build run.
  # shell/settings.json is `del(.hooks)` — re-deriving that is one call and forks no
  # meaningful logic, so it gets an exact check. hooks.json's derivation is a dozen lines
  # of walk/rewrite/inject, and copying it here would be the hand-maintained second copy
  # the builder's own comment warns against; so check instead the surface that comment
  # NAMES — the [9.2] dead-hook class: every hook script settings.json wires must reach
  # the built hooks.json. A SUBSET test, not equality, because the builder legitimately
  # injects one extra (reviewer-readonly.sh, the plugin-only guard). Residual stated
  # rather than implied: a matcher-only or ordering-only edit moves neither set and is
  # NOT detected — rebuild after touching settings.json rather than trusting this to
  # catch every shape of edit.
  if [ -e "$GUV_DIR/.claude/settings.json" ]; then
    if [ -e "$built/shell/settings.json" ] \
       && jq 'del(.hooks)' "$GUV_DIR/.claude/settings.json" 2>/dev/null \
          | cmp -s - "$built/shell/settings.json" 2>/dev/null; then :; else
      echo "shell/settings.json"
    fi
    if [ -n "$(comm -23 <(_hook_scripts "$GUV_DIR/.claude/settings.json") \
                        <(_hook_scripts "$built/hooks/hooks.json"))" ]; then
      echo "hooks/hooks.json"
    fi
  fi
  # Tests walk the other way. The builder ships a FILTERED subset (MAINTAINER_ONLY
  # suites stay source-side), so source->built would report every held-back suite as
  # drift; built->source asks only "is each suite that DOES ship current", which needs
  # no copy of the filter's logic to be right. What that direction CANNOT see, stated
  # because the choice is what hides it: a NEWLY added shipping-eligible suite has no
  # built entry to iterate, so plugin/ is behind and this stays quiet. The walk grades
  # the suites that ship, not the decision about which ones should — adding a suite
  # means rebuilding, and nothing here will remind you.
  for f in "$built/tests/"*.test.sh; do
    [ -e "$f" ] || continue
    _stale_pair "$GUV_DIR/.claude/tests/$(basename "$f")" "$built" "tests/$(basename "$f")"
  done
}

_cache_stale() {        # files the cache carries that source has dropped (removed upstream)
  local built=$1 cache=$2 t f
  for t in $GUV_CACHE_TREES; do
    # A tree source no longer ships at all is left alone rather than emptied: that is a
    # restructure, not a removal, and this function may not tell them apart.
    [ -d "$built/$t" ] || continue
    _cache_tree_files "$cache" "$t" | while IFS= read -r f; do
      [ -e "$built/$f" ] || echo "$f"
    done
  done
}

refresh_one_plugin_cache() {
  local built=$1 cache=$2
  case "$cache" in
    /*) ;;
    *)  echo "[setup] plugin cache NOT verified — the plugin DB records a RELATIVE installPath '$cache'; refusing to resolve it against whatever directory this ran from"
        return 0 ;;
  esac
  if [ ! -d "$cache" ]; then
    echo "[setup] plugin cache NOT verified — the plugin DB records installPath '$cache' but nothing is there; hook-invoked core is running from a copy this sync could not inspect"
    return 0
  fi
  # Identity, and only as much of it as a name match can carry. 'guv@* and the directory
  # exists' is what the DB CLAIMS; the manifest is what the artifact itself SAYS. Matching
  # them stops the write when the recorded installPath actually holds some other plugin —
  # a mis-keyed DB entry, a hand-edited path, a cache root reused. What it does NOT
  # establish is provenance: a fork also declares the name "guv", so a fork's cache and
  # upstream's are indistinguishable here, and no version or source-URL check is made.
  # That residual is accepted deliberately — the alternative is refusing to refresh the
  # fork case, which is the case this whole path exists to serve.
  local bn cn
  bn=$(jq -r '.name // empty' "$built/.claude-plugin/plugin.json" 2>/dev/null)
  cn=$(jq -r '.name // empty' "$cache/.claude-plugin/plugin.json" 2>/dev/null)
  if [ -z "$bn" ] || [ "$bn" != "$cn" ]; then
    echo "[setup] plugin cache NOT verified — '$cache' declares plugin name '${cn:-<none>}' but this repo builds '${bn:-<none>}'; refusing to overwrite a plugin this repo does not build"
    return 0
  fi
  # "Could not enumerate" and "already current" both look like an empty diff, and the
  # whole point of this function is that a silence must not read as a verification.
  local nbuilt t
  nbuilt=$(for t in $GUV_CACHE_TREES; do _cache_tree_files "$built" "$t"; done | wc -l | tr -d ' ')
  if [ "${nbuilt:-0}" -eq 0 ]; then
    echo "[setup] plugin cache NOT verified — could not enumerate any of ($GUV_CACHE_TREES) under $built; treating '$cache' as UNCHECKED rather than current"
    return 0
  fi
  # WHICH files, not how many: a stale meter and a stale gate are different problems,
  # and the operator is owed the names to know what was actually running. The list is
  # never truncated — the first refresh after a long gap is the longest AND the one
  # where the names matter most.
  local drift stale
  drift=$(_cache_drift "$built" "$cache")
  stale=$(_cache_stale "$built" "$cache")
  [ -n "$drift" ] || [ -n "$stale" ] || return 0   # current — stay quiet, so the signal keeps meaning something
  echo "[setup] PLUGIN CACHE DRIFT — hook-invoked core was STALE; refreshing $cache"
  echo "        (user-scope: this is the core EVERY guv project on this machine runs)"
  echo "        (source is the BUILT plugin, plugin/; whether that build is itself current is reported once, above)"
  [ -n "$drift" ] && printf '%s\n' "$drift" | sed 's|^|  drifted: |'
  [ -n "$stale" ] && printf '%s\n' "$stale" | sed 's|^|  removed upstream: |'
  # Overlay what source ships, then prune what source dropped. Both stay inside the
  # guv-owned trees named by GUV_CACHE_TREES; nothing walks the cache root, where Claude
  # Code's own .in_use/ session locks live. That containment comes from the walks being
  # tree-SCOPED, not from how many trees are listed — which is why widening the list from
  # three to eight left the locks exactly as unreachable as before.
  local cp_failed=""
  for t in $GUV_CACHE_TREES; do
    [ -d "$built/$t" ] || continue
    mkdir -p "$cache/$t" 2>/dev/null
    cp -R "$built/$t/." "$cache/$t/" || cp_failed="yes"
  done
  if [ -n "$stale" ]; then
    printf '%s\n' "$stale" | while IFS= read -r f; do [ -n "$f" ] && rm -f "$cache/$f"; done
    for t in $GUV_CACHE_TREES; do
      [ -d "$cache/$t" ] && find "$cache/$t" -mindepth 1 -type d -empty -delete 2>/dev/null
    done
  fi
  for t in $GUV_CACHE_TREES; do
    [ -d "$cache/$t" ] && find "$cache/$t" -name '.DS_Store' -delete 2>/dev/null
  done
  # VERIFY, don't claim. cp -R is documented to keep going after an error, so its exit
  # status cannot carry this: re-run the same comparison and report what is left.
  local rdrift rstale verified=yes
  rdrift=$(_cache_drift "$built" "$cache")
  rstale=$(_cache_stale "$built" "$cache")
  [ -z "$rdrift" ] && [ -z "$rstale" ] || verified=no
  # Provenance, written AFTER the verify and carrying its outcome. The DB's
  # gitCommitSha/lastUpdated described the RELEASE and are false once overlaid, so this
  # marker is the only record of which source the cache now carries — and a marker that
  # asserted a refresh before the check that can contradict it would be the same
  # claim-don't-verify mistake the block above exists to avoid. It sits at the cache root,
  # outside the walked trees, so it is never its own prune candidate. It records dirty
  # state because this loop exists to move UNRELEASED work: a bare HEAD sha would name a
  # commit that does not describe what was copied.
  # Both flags are spelled out yes/no rather than left empty for the good state: this file
  # is read by catting it, and an absent value is indistinguishable from a check that
  # never ran — the one reading where "fine" and "unmeasured" must not look alike.
  local dirty=no behind=no
  [ -n "$(git -C "$GUV_DIR" status --porcelain -- plugin 2>/dev/null)" ] && dirty=yes
  [ -n "$GUV_PLUGIN_BEHIND" ] && behind=yes
  if ! { echo "# hand-refreshed from guv source by maintainers/setup-control-plane.sh"
         echo "source_repo=$GUV_DIR"
         echo "source_commit=$(git -C "$GUV_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
         echo "source_plugin_dirty=$dirty"
         echo "source_plugin_behind_claude=$behind"
         echo "refreshed_trees=$GUV_CACHE_TREES"
         echo "refreshed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
         echo "verified=$verified"
       } > "$cache/.guv-source-refresh" 2>/dev/null; then
    echo "[setup] WARNING — could not write $cache/.guv-source-refresh; this cache now carries unreleased source with no record of which"
  fi
  if [ "$verified" = yes ]; then
    echo "[setup] verified: hook-invoked core at $cache now matches the BUILT plugin across ($GUV_CACHE_TREES)"
  else
    echo "[setup] plugin cache refresh INCOMPLETE — '$cache' is now MIXED VINTAGE${cp_failed:+ (a copy failed; see the cp error above)}; these still differ from source:"
    [ -n "$rdrift" ] && printf '%s\n' "$rdrift" | sed 's|^|  still stale: |'
    [ -n "$rstale" ] && printf '%s\n' "$rstale" | sed 's|^|  still present, removed upstream: |'
  fi
}

refresh_plugin_cache() {
  command -v jq >/dev/null 2>&1 || return 0
  local db="${GUV_PLUGINS_DB:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json}"
  [ -f "$db" ] || return 0
  # The same marketplace-agnostic guv@* predicate the dedup uses (fork robustness).
  local guv_entries paths built c
  guv_entries=$(jq -r '[(.plugins // {}) | to_entries[] | select(.key | startswith("guv@"))] | length' "$db" 2>/dev/null)
  case "$guv_entries" in ''|0) return 0 ;; esac    # guv not installed here — not news
  paths=$(jq -r '(.plugins // {}) | to_entries[]
                 | select(.key | startswith("guv@"))
                 | .value[]? | .installPath // empty' "$db" 2>/dev/null)
  if [ -z "$paths" ]; then
    echo "[setup] plugin cache NOT verified — the plugin DB carries a guv entry but records no installPath; hook-invoked core is running from a copy this sync could not locate"
    return 0
  fi
  built="$GUV_DIR/plugin"
  if [ ! -d "$built" ]; then
    echo "[setup] plugin cache NOT verified — no built plugin at $built (run maintainers/build-plugin.sh first); hook-invoked core keeps running the installed cache"
    return 0
  fi
  # Say this BEFORE any cache is compared, because it is the case cache drift cannot see.
  # Proceeding is the designed rung, not a shortcut: plugin/ is a real build, so the cache
  # still lands on ONE coherent vintage — just not the newest source. Refusing would leave
  # it on an older vintage still, which is the defect this whole path exists to end.
  GUV_PLUGIN_BEHIND=$(_built_plugin_stale "$built")
  if [ -n "$GUV_PLUGIN_BEHIND" ]; then
    echo "[setup] BUILT PLUGIN IS BEHIND .claude/ — refreshing caches from a STALE build"
    echo "        (run: bash maintainers/build-plugin.sh — then re-run this sync)"
    printf '%s\n' "$GUV_PLUGIN_BEHIND" | sed 's|^|  not rebuilt since edited: |'
  fi
  # EVERY recorded install, not the first: user- and local-scope entries coexist, and so
  # do several guv@<marketplace> keys. Refreshing one and staying quiet about the rest
  # would declare parity for a cache that is not the one running.
  printf '%s\n' "$paths" | LC_ALL=C sort -u | while IFS= read -r c; do
    [ -n "$c" ] && refresh_one_plugin_cache "$built" "$c"
  done
}

copy_core
dedup_hook_registration   # [19.5] — single authoritative hook registration path
refresh_plugin_cache      # [19.5] other half — the authoritative copy must not be stale

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
  local target="$DEST/.claude/run-core-tests.sh" legacy="$DEST/.claude/run-harness-tests.sh" tmp
  # Refresh-only on --sync, with one migration exception. A consumer synced
  # before the [8.3] rename carries the OLD runner name (run-harness-tests.sh)
  # and no run-core-tests.sh — it DID have a runner, so the "never had one" skip
  # must not freeze it at the old name. When the legacy runner is present, fall
  # through to write run-core-tests.sh (and prune the old name below). Only a
  # consumer with NEITHER runner is genuinely runner-less (consumer-project shape).
  if [ ! -f "$target" ] && [ ! -f "$legacy" ] && [ "$MODE" = "sync" ]; then
    return 0
  fi
  tmp=$(mktemp)
  cat > "$tmp" <<'SH'
#!/bin/bash
# Run the core's bash test suites from the code repo (roots.code).
#
# Gate integrity ([15.1]) — this battery can NEVER report green over a suite that
# did not pass. Three coupled guards:
#  (a) PER-SUITE TIMEOUT — each suite runs under `timeout` so a true hang fails
#      LOUD with a NAMED timeout (rc 124), distinguishable from sandbox slowness,
#      never a silent stall (Rule 15). No timeout binary on PATH is a designed,
#      ANNOUNCED degradation: the suite runs unbounded rather than breaking.
#  (b) SERIAL CARVE + BOUNDED PARALLEL POOL + HERMETICITY GUARD + DETERMINISTIC
#      AGGREGATION — two named suites run one-at-a-time first, the rest run
#      concurrently (≤ CORE_TEST_JOBS at once), each writing its own out/err/rc; a
#      final pass then replays them IN SORTED NAME ORDER under the identical gate,
#      so wall-clock drops toward the slowest while the output and verdict stay
#      deterministic.
#
#      TWO SEPARATE MECHANISMS, DO NOT CONFLATE THEM. The carve and the guard were
#      once the same thing and are no longer:
#
#      The GUARD is the correctness half. Parallelism is only sound if the suites
#      are hermetic, so the runner checks for the RESIDUE a non-hermetic suite
#      leaves: it fingerprints the code repo before the first suite and again
#      after the last, and FAILS THE RUN if the tree moved. It covers ALL suites,
#      including ones not yet written — which is what the old hand-maintained
#      quarantine list could never do, and it had already gone stale silently.
#
#      BE EXACT ABOUT WHAT IT PROVES — the audit doc overstated this once and told
#      suite authors the machine would remember for them (corrected 2026-07-27).
#      Before-vs-after catches a write that PERSISTS, not a write that HAPPENS: a
#      suite that plants a fixture and removes it on the way out leaves
#      before == after and sails through. That is the shape every real offender
#      had — each carried an rm -f and an EXIT trap. So hermeticity is still
#      something the suite AUTHOR provides; this guard turns forgotten residue
#      into a loud red instead of somebody else's flake three runs later. Same
#      family, narrower scope: the fingerprint is git-visible change, so writes
#      under gitignored paths in the repo are invisible to it too.
#      Full accounting: maintainers/BATTERY-HERMETICITY.md.
#
#      The CARVE is the scheduling half, and it is now justified by MEASUREMENT
#      rather than by hermeticity. Its rationale lives at the SERIAL_SET definition
#      below with the numbers; the short version is that the pool is saturated, so
#      folding the two heaviest suites into it inflates every suite rather than
#      filling idle lanes. Removing the carve was tried and reverted: it bought 65s
#      of wall clock and cost the battery's verdict.
#
#      The guard is WHOLE-BATTERY, not per-suite, and that limit is deliberate:
#      under a parallel pool the suites overlap, so a tree change cannot be
#      attributed to one of them. Per-suite attribution would require running every
#      suite serially, which is the whole cost the pool exists to avoid. The guard
#      proves "no suite wrote"; the porcelain diff it prints on a breach names the
#      paths, which in practice identifies the culprit.
#
#      It also closes a hole in the (A2) recorded verdict, and the wiring is the
#      load-bearing part: left to itself `record` would fingerprint the tree a
#      THIRD time, after aggregation and the census, so a tree edited in that
#      window would be recorded under a hash describing a state no suite ran
#      against — and a downstream `read` would call it VERIFIED. So the AFTER
#      fingerprint is PASSED to `record` rather than recomputed there. The
#      recorded provenance is the exact hash this guard compared, which is what
#      makes before == after mean anything for the record.
#  (c) NO EXIT-MASKING / NO STDOUT-ONLY BLINDNESS — the gate fails a suite on ANY
#      of: nonzero rc, ANY stderr byte, OR a failure-shaped STDOUT verdict (a ✗
#      line, or "Results: N passed, M failed" with M>0) even when the suite lied
#      with exit 0 (roots-map.test.sh writes its ✗ to stdout — a buggy suite that
#      forgot its exit code must still be caught). The runner's FINAL statement is
#      its exit on the aggregated status: nothing follows it, so a trailing
#      post-runner command can never mask the verdict.
#
# A green summary above a parse error is how a vacuous guard slipped two review
# gates (session-2026-06-11-003) — every leg of the gate is enforced HERE, not by
# reading discipline.
# Core-owned: regenerated by setup-control-plane.sh (create and --sync) —
# local edits will be overwritten; improve the generator instead.
#
# Usage: bash .claude/run-core-tests.sh [--only <pattern>]
set -u

# ── --only <pattern>: the focused-suite path ──
# Run just the suites whose BASENAME matches the glob PATTERN. Mirrors the plugin
# runner's flag (maintainers/build-plugin.sh), one seam over, including the rule
# that keeps it honest: a pattern matching NO suite fails LOUD (exit 2, naming the
# pattern) rather than running zero suites and reporting green. A vacuous filtered
# green would let every "it passes under --only" claim be a proof about the empty
# set — worse than having no filter at all.
#
# An unrecognized argument is equally loud. Silently swallowing it is how a person
# believes they ran one suite while the machine ran all of them; that is the
# recorded misread in friction 2026-07-18T17:37:57Z-2084922661, not a hypothetical.
#
# The FULL battery remains the gate at session close. This flag is for the fix
# loop, where the per-suite census printed at the end of a full run shows most
# suites finishing in seconds while every iteration pays for all of them.
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      shift
      { [ $# -gt 0 ] && [ -n "$1" ]; } || { echo "run-core-tests: --only requires a non-empty pattern" >&2; exit 2; }
      ONLY="$1"; shift ;;
    *) echo "run-core-tests: unknown argument: $1 (supported: --only <pattern>)" >&2; exit 2 ;;
  esac
done

# Resolve the code repo through the shared [11.2] resolver — roots.code may be a
# named map, so a bare string read would point the suite glob at the map object.
# The resolver returns the PRIMARY's path (the suites are the dogfooding battery,
# which targets the primary). roots.sh ships beside this runner under .claude/.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/roots.sh"
CODE=$(roots_code_path) || { echo "run-core-tests: could not resolve a code repo from the manifest" >&2; exit 4; }

# ── fix (a): resolve the per-suite timeout command (designed degradation) ──
# CORE_TEST_TIMEOUT overrides the default bound. A missing binary is announced,
# not silently dropped.
#
# DO NOT re-derive this bound from a list of suite names in a comment. The last
# one said the SERIAL_SET plugin-builders were the slowest (plugin.test.sh ~190s,
# ship-suite.test.sh 99s after its [22.1] --only cut) and had gone stale by more
# than 2x in headroom terms: three consecutive censuses in 2026-07 put
# setup-control-plane.test.sh at 353/363/395s and budget-gate.test.sh at
# 275/278/297s — both in the POOL, neither in the carve, and plugin.test.sh had
# fallen to seventh. The runner now PRINTS the census on every run (Prong C), so
# read that instead of trusting this paragraph.
#
# The carve is why this bound holds at all: measured without it, the same
# setup-control-plane.test.sh ran past 600s and was killed (255s standalone). The
# ceiling and the pool shape are coupled — changing one re-opens the other.
#
# What the bound has to satisfy: it must exceed the slowest suite's POOL time
# (the timeout wraps each suite as it runs under contention, so pool timings are
# the right basis, not isolated ones) by enough margin to absorb a slow or loaded
# machine, without growing so large that a real hang goes unnoticed for minutes.
# The [22.1] lesson is the calibration point: 258s under a 300s bound — 1.16x —
# was a latent flake that fired. 600s against the 395s worst sample is 1.52x.
# That is defensible but it is NOT the "generous headroom" the old comment
# claimed, and the trend is the wrong way (budget-gate.test.sh went from 62 to
# 104 assertion sites on 2026-07-24 alone). If the census's top line crosses
# ~450s, raise this bound or trim that suite — do not let it drift into the
# 1.16x band that already burned us once.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
fi
SUITE_TIMEOUT="${CORE_TEST_TIMEOUT:-600}"
if [ -z "$TIMEOUT_BIN" ]; then
  echo "[run-core-tests] no timeout/gtimeout on PATH — suites run UNBOUNDED (a hang will not be caught; install coreutils to restore the per-suite timeout guard)"
fi

# ── fix (b): bounded parallel pool — each suite writes its own out/err/rc ──
# CORE_TEST_JOBS bounds concurrency; default to the CPU count (capped) so the
# pool is bounded, not a fork bomb. Each suite gets an isolated scratch triple.
JOBS="${CORE_TEST_JOBS:-}"
if [ -z "$JOBS" ]; then
  JOBS=$( { command -v nproc >/dev/null 2>&1 && nproc; } \
       || { command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu; } \
       || echo 4 )
fi
case "$JOBS" in ''|*[!0-9]*) JOBS=4 ;; esac
[ "$JOBS" -lt 1 ] && JOBS=1

WORKDIR=$(mktemp -d) || { echo "run-core-tests: mktemp failed" >&2; exit 4; }
trap 'rm -rf "$WORKDIR"' EXIT

# Run one suite into its own out/err/rc triple (keyed by a sanitized basename).
# A timeout kill surfaces as rc 124 (or 137 on SIGKILL after the kill-after grace)
# — both are nonzero, so the gate fails loud; the aggregation pass names it.
run_one() {  # $1 = suite path  $2 = scratch key
  local t="$1" key="$2" rc started ended
  started=$(date +%s)
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" -k 5 "$SUITE_TIMEOUT" bash "$t" \
      >"$WORKDIR/$key.out" 2>"$WORKDIR/$key.err"
  else
    bash "$t" >"$WORKDIR/$key.out" 2>"$WORKDIR/$key.err"
  fi
  rc=$?
  printf '%s\n' "$rc" > "$WORKDIR/$key.rc"
  ended=$(date +%s)
  printf '%s\n' "$((ended - started))" > "$WORKDIR/$key.dur"
  # PROGRESS goes to the RUNNER's stderr — deliberately NOT into $key.err, which is
  # the suite's captured stream that gate (c) fails on any byte of. Announcing here
  # rather than in the aggregation pass is the whole point: the aggregation cannot
  # start until every suite is done, which is exactly the window that used to be
  # silent. Whole seconds (no awk, no float): the NOTO fixture's PATH whitelist is
  # the floor for what this runner may depend on, and sub-second precision buys
  # nothing on a battery measured in minutes.
  printf '[run-core-tests] done %s (%ss)\n' "$(basename "$t")" "$((ended - started))" >&2
}

# ── fix (b), scheduling half: the SERIAL CARVE ──
# These two suites run strictly one at a time, ahead of the pool. This carve was
# ORIGINALLY a hermeticity quarantine (they wrote the shared live source tree);
# Prong B made them hermetic and the guard below now checks that property directly,
# so the quarantine reason is gone. The carve stayed for a DIFFERENT, measured
# reason: the pool is saturated, and these are the two suites that suffer most from
# contention.
#
# Measured both ways on the same machine (guv 41282d2 vs d1be3dd):
#
#                      carved   in-pool
#   plugin.test.sh      207s ->  571s   2.76x
#   ship-suite.test.sh  112s ->  330s   2.95x
#
# Folding them into a 14-way pool that had no idle lanes did not fill spare
# capacity — it took time from every other suite. Aggregate suite-seconds went
# 3860 -> 5733 (+48%) for a 65s (7.9%) wall-clock gain, and the extra contention
# pushed setup-control-plane.test.sh past the 600s per-suite ceiling and
# continuation-checkpoint.test.sh past a 10s deadline inside the checkpoint hook.
# The battery went from 71/0 to 66/5, all five failures contention rather than
# logic. 65s on a gate that runs once or twice a session does not buy that.
#
# So: a scheduling carve, not a safety one. The selection criterion is now
# measurable — carve a suite when its pool time is a large multiple of its serial
# time AND it is big enough for that multiple to matter. Re-read the census the
# runner prints (Prong C) before adding or removing a name; do not reason about it
# from this comment.
SERIAL_SET=" plugin.test.sh ship-suite.test.sh "

# Collect the suites in a stable, sorted order — the deterministic spine of both
# the launch list and the aggregation pass. The serial carve is applied at launch
# time below (the SERIAL_SET membership test), so collection stays one list.
SUITES=()
while IFS= read -r t; do SUITES+=("$t"); done < <(
  for t in "$CODE"/.claude/tests/*.test.sh; do [ -e "$t" ] && printf '%s\n' "$t"; done | LC_ALL=C sort
)

if [ "${#SUITES[@]}" -eq 0 ]; then
  echo "run-core-tests: no suites found under $CODE/.claude/tests/" >&2
  exit 4
fi

# Apply --only AFTER collection and after the empty-glob guard above: the two zero
# cases are different failures and must not share a message. "No suites found under
# .claude/tests/" means the tree is wrong; "--only matched no suite" means the
# pattern is wrong. Collapsing them would send someone hunting for a missing
# directory over a typo'd glob.
if [ -n "$ONLY" ]; then
  KEEP=()
  for t in "${SUITES[@]}"; do
    # shellcheck disable=SC2254 — $ONLY is deliberately an unquoted glob pattern
    case "$(basename "$t")" in $ONLY) KEEP+=("$t") ;; esac
  done
  if [ "${#KEEP[@]}" -eq 0 ]; then
    echo "run-core-tests: --only '$ONLY' matched no suite under $CODE/.claude/tests/" >&2
    exit 2
  fi
  SUITES=("${KEEP[@]}")
fi

# Announce the run's SHAPE before any suite starts. Completion lines alone leave the
# silence exactly where it does the most damage — at startup, before anything has
# landed. That is precisely the window in which friction entry
# 2026-07-18T17:37:57Z-2084922661 was filed: a contended battery killed as a
# suspected single-suite hang. Knowing what is running is what distinguishes "slow"
# from "stuck".
#
# Under --only the line names the filter, because the count alone is ambiguous: "3
# suites" from a filtered run and "3 suites" from a repo that only has three look
# identical, and the whole point of the loud-zero-match rule is that a person can
# always tell what actually ran.
if [ -n "$ONLY" ]; then
  printf '[run-core-tests] running %s suites matching --only %s (filtered; the FULL battery is still the gate at session close)\n' \
    "${#SUITES[@]}" "$ONLY" >&2
else
  printf '[run-core-tests] running %s suites: serial carve first (%s), then the rest at %s-way parallelism\n' \
    "${#SUITES[@]}" "$(echo $SERIAL_SET)" "$JOBS" >&2
fi

# ── fix (b): the HERMETICITY GUARD, first half — the BEFORE fingerprint ──
# Taken after the suite list is settled and before any suite starts, so the window
# it covers is exactly "the battery ran". battery-result.sh owns the hash so this
# runner, `record` and `read` all compare the SAME function's output; a second
# hand-rolled copy here would drift and silently stop agreeing.
#
# DESIGNED DEGRADATION (rule 15): where the fingerprint cannot be taken — the code
# repo is not a git repo, or battery-result.sh is absent — the guard ANNOUNCES that
# it is not checking and the battery proceeds. It degrades toward running the
# suites, never toward claiming a hermeticity proof nobody produced. The exit-4
# contract (empty stdout) is what makes the two cases distinguishable here.
#
# THE GUARD IS FOUR CHECKS, NOT ONE, and the three beside the fingerprint are not
# redundant. The fingerprint is content-only by design so a recorded verdict
# survives being committed (battery-result.sh explains why at length) — but that
# design gives up everything in the "disturbs the repo, moves no byte" family, and
# each member is real residue in a developer's repo:
#   - `git commit`    moves no working-tree byte -> the HEAD check catches it.
#   - `git add`       moves no working-tree byte -> the porcelain comparison catches
#     it. This leg was MISSING for one unreleased revision, because the content-only
#     rewrite dropped `git status --porcelain` from the fingerprint and nothing
#     picked it back up; a QA eval caught it on 2026-07-27 before it shipped.
#   - `git switch -c` moves no working-tree byte, no HEAD *commit* (the new branch
#     points at the same one) and nothing in porcelain -> the symbolic-ref capture
#     is the only leg that can see it. A suite that mis-resolves the repo and
#     branches in the live tree leaves the developer on a branch they never chose.
#
# WHAT IS STILL OUTSIDE, said out loud because the previous version of this comment
# claimed its enumeration was closed and was wrong (guv eval, 2026-07-27 — the
# finding was not the hole, it was that the hole was UNWRITTEN; rule 15 tolerates a
# named limit and not a silent one): deleting an UNRELATED branch, creating a tag,
# and `git config` all still pass every leg. They are left uncovered deliberately —
# each needs its own capture, none of them changes what a subsequent commit or
# checkout does to the developer's working tree, and the guard is a tripwire for
# suites that wander, not a general-purpose repo audit.
#
# The split is the point: the RECORD asks "does this verdict still describe these
# bytes", the GUARD asks "did the suites disturb the tree". Staging, committing and
# branching are all disturbances and none is a byte, which is exactly why they live
# here and not there. T11j3 pins the commit leg; T11j4 the staging leg; T11j5 the
# ref leg.
HERM_BEFORE=""
HERM_HEAD_BEFORE=""
HERM_REF_BEFORE=""
if [ -f "$HERE/battery-result.sh" ]; then
  HERM_BEFORE=$(bash "$HERE/battery-result.sh" fingerprint 2>/dev/null) || HERM_BEFORE=""
fi
if [ -n "$HERM_BEFORE" ]; then
  HERM_HEAD_BEFORE=$(git -C "$CODE" rev-parse HEAD 2>/dev/null || echo "")
  # DETACHED is a real state, not a read failure: `symbolic-ref` exits nonzero on a
  # detached HEAD, and collapsing that to "" would make detaching (or re-attaching)
  # mid-run compare equal to an unreadable repo. Naming it keeps both transitions
  # visible to the comparison below.
  HERM_REF_BEFORE=$(git -C "$CODE" symbolic-ref -q HEAD 2>/dev/null || echo "DETACHED")
  git -C "$CODE" status --porcelain > "$WORKDIR/herm.before" 2>/dev/null || true
else
  printf '[run-core-tests] hermeticity NOT CHECKED — could not fingerprint %s (not a git repo, or battery-result.sh is absent). The suites still run; nothing is verifying that they leave the source tree alone.\n' \
    "$CODE" >&2
fi

# Serial carve FIRST — sequential foreground runs (no &) guarantee non-overlap.
# Placed AFTER the BEFORE fingerprint deliberately: the guard's window has to cover
# every suite, and the carved ones run before the pool. Taking the fingerprint here
# instead would leave these two outside the check.
for i in "${!SUITES[@]}"; do
  case "$SERIAL_SET" in *" $(basename "${SUITES[$i]}") "*)
    # Announced on START, not only on completion: these two are the long poles and
    # they run alone, so this is the one place a start line buys real information.
    # The pool suites are not announced on start — a burst of $JOBS lines at once
    # is noise, and their completions arrive steadily enough to show liveness.
    printf '[run-core-tests] start %s (serial carve)\n' "$(basename "${SUITES[$i]}")" >&2
    run_one "${SUITES[$i]}" "$i" ;;
  esac
done

# Launch the remainder under a bounded pool: at most $JOBS in flight. The guard
# above is what makes the parallelism sound (it verifies hermeticity for ALL
# suites); the carve above is what keeps the pool from thrashing.
running=0
for i in "${!SUITES[@]}"; do
  case "$SERIAL_SET" in *" $(basename "${SUITES[$i]}") "*) continue ;; esac
  run_one "${SUITES[$i]}" "$i" &
  running=$((running + 1))
  if [ "$running" -ge "$JOBS" ]; then
    wait -n 2>/dev/null || wait
    running=$((running - 1))
  fi
done
wait

# ── the HERMETICITY GUARD, second half — the AFTER fingerprint ──
# Taken immediately after the last suite exits, before the aggregation pass (which
# reads $WORKDIR and never touches $CODE). Compared below, once `fail` exists, so
# the single-verdict-variable discipline is preserved.
HERM_AFTER=""
HERM_HEAD_AFTER=""
HERM_REF_AFTER=""
if [ -n "$HERM_BEFORE" ]; then
  HERM_AFTER=$(bash "$HERE/battery-result.sh" fingerprint 2>/dev/null) || HERM_AFTER=""
  HERM_HEAD_AFTER=$(git -C "$CODE" rev-parse HEAD 2>/dev/null || echo "")
  HERM_REF_AFTER=$(git -C "$CODE" symbolic-ref -q HEAD 2>/dev/null || echo "DETACHED")
  git -C "$CODE" status --porcelain > "$WORKDIR/herm.after" 2>/dev/null || true
fi

# ── fix (b)+(c): deterministic SERIAL aggregation under the IDENTICAL gate ──
# Replay suites in sorted order; apply the gate (nonzero rc OR any stderr byte OR
# a failure-shaped stdout verdict). One verdict variable; the runner's exit IS it.
fail=0
# nfail counts FAILING SUITES for the [A2] recorded verdict. It is bookkeeping
# only: `fail` remains the single verdict variable and every assignment to it
# below is untouched, so the [15.1] gate behaves identically with or without it.
# sfail is the per-suite marker — a suite can trip several gate legs at once and
# must still count once.
nfail=0
# ASSERTION totals, in the unit a QA report actually quotes. nfail/${#SUITES[@]}
# are SUITE counts, and recording only those made every downstream report describe
# this battery as "71 passing" when it runs ~2,500 assertions (guv eval,
# 2026-07-27). The per-suite "Results: N passed, M failed" line is already parsed
# by gate leg (c-stdout) below; areport counts how many suites produced one, so a
# partial sum is never passed off as a total.
apass=0; afail=0; areport=0
for i in "${!SUITES[@]}"; do
  t="${SUITES[$i]}"
  name="$(basename "$t")"
  sfail=0
  echo "== $name =="
  cat "$WORKDIR/$i.out" 2>/dev/null
  rc=$(cat "$WORKDIR/$i.rc" 2>/dev/null || echo 1)

  # (a) timeout: 124 (timed out) / 137 (SIGKILL after -k grace) — name it loud.
  if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
    echo "[timeout] $name TIMED OUT after ${SUITE_TIMEOUT}s (rc=$rc) — failing the run (a hang, not sandbox slowness)"
    fail=1; sfail=1
  elif [ "$rc" != "0" ]; then
    echo "[rc] $name exited nonzero (rc=$rc) — failing the run"
    fail=1; sfail=1
  fi

  # (c-stderr) any stderr byte fails the run.
  if [ -s "$WORKDIR/$i.err" ]; then
    echo "[stderr] $name wrote to stderr — failing the run:"
    cat "$WORKDIR/$i.err"
    fail=1; sfail=1
  fi

  # (c-stdout) a failure-shaped STDOUT verdict fails the run even if rc=0: a ✗
  # assertion line, or a "Results: N passed, M failed" with M>0. This closes the
  # stdout-only-blindness hole — a suite that reports its own failure but forgets
  # to exit nonzero can no longer show green. The 0-failed verdict and ✓ glyph
  # are NOT matched (no false positive on a clean run).
  if grep -q '✗' "$WORKDIR/$i.out" 2>/dev/null \
     || grep -qE 'Results:[[:space:]]*[0-9]+[[:space:]]*passed,[[:space:]]*[1-9][0-9]*[[:space:]]*failed' "$WORKDIR/$i.out" 2>/dev/null; then
    echo "[stdout] $name reported a FAILURE on stdout while exit was $rc — failing the run (stdout-only failures are not green)"
    fail=1; sfail=1
  fi

  [ "$sfail" = "1" ] && nfail=$((nfail + 1))

  # Assertion tally. Reads the LAST Results line (a suite that prints a per-section
  # tally still ends with its own total). Stdout-only and gate-free: this touches
  # neither `fail` nor `sfail`, so the [15.1] verdict is byte-for-byte what it was
  # before the tally existed.
  rline=$(grep -oE 'Results:[[:space:]]*[0-9]+[[:space:]]*passed,[[:space:]]*[0-9]+[[:space:]]*failed' "$WORKDIR/$i.out" 2>/dev/null | tail -1)
  if [ -n "$rline" ]; then
    areport=$((areport + 1))
    apass=$(( apass + $(printf '%s' "$rline" | grep -oE '[0-9]+[[:space:]]*passed' | grep -oE '^[0-9]+') ))
    afail=$(( afail + $(printf '%s' "$rline" | grep -oE '[0-9]+[[:space:]]*failed' | grep -oE '^[0-9]+') ))
  fi
done

# A total is a total or it is nothing. If any suite printed no Results line, the
# sum covers an unknown fraction of the battery, so it is withheld rather than
# recorded as if it covered all of it — the same refusal shape as everything else
# in this record.
if [ "$areport" -ne "${#SUITES[@]}" ]; then
  A_PASS=""; A_FAIL=""
else
  A_PASS="$apass"; A_FAIL="$afail"
fi

# ── fix (b): the HERMETICITY VERDICT ──
# A moved tree fails the run. Two things can move it, and the operator has to be
# able to tell them apart, so the porcelain diff is printed rather than just the
# fact of a mismatch:
#   1. A SUITE WROTE to the live source tree. That is the defect this guard exists
#      for — it is the fixture-collision flake class that the serial carve used to
#      contain by quarantine.
#   2. A PERSON (or another agent) edited the tree mid-battery. Also a genuine
#      failure, not a false red: the suites read a tree that changed underneath
#      them, so the verdict describes no single state and is not interpretable.
#      Silently passing that is how an untested tree acquires a green stamp.
#
# On stdout, with the other gate legs — a breach belongs in the aggregated record,
# not only in the progress stream. This assignment to `fail` sits BEFORE the exit
# like every other one; nothing follows the exit ([15.1] exit-masking).
#
# The porcelain diff names paths that APPEARED or VANISHED. A content-only edit to
# an already-modified file moves the fingerprint but shows no line here — said out
# loud because an empty diff under a real breach would otherwise read as a bug in
# the guard rather than as the narrower thing it is.
if [ -n "$HERM_BEFORE" ] \
   && { [ "$HERM_AFTER" != "$HERM_BEFORE" ] \
        || [ "$HERM_HEAD_AFTER" != "$HERM_HEAD_BEFORE" ] \
        || [ "$HERM_REF_AFTER" != "$HERM_REF_BEFORE" ] \
        || ! cmp -s "$WORKDIR/herm.before" "$WORKDIR/herm.after"; }; then
  echo "[hermeticity] THE CODE REPO MOVED WHILE THE BATTERY RAN — failing the run."
  echo "  tree:  $CODE"
  if [ "$HERM_HEAD_AFTER" != "$HERM_HEAD_BEFORE" ]; then
    echo "  HEAD moved: $HERM_HEAD_BEFORE -> $HERM_HEAD_AFTER"
    echo "  Something COMMITTED into this repo while the battery ran. The content hash"
    echo "  does not see a commit (it is content-only so a verdict survives being"
    echo "  committed), so this check is the one that caught it."
  fi
  # The porcelain leg. It exists because the content hash gave up the index when it
  # went content-only, which silently retired coverage the old composite fingerprint
  # carried: a suite running `git add` in the developer's live repo changes what
  # their next `git commit` sweeps up, and for one unreleased revision that breached
  # nothing at all (guv eval, 2026-07-27). Staging IS disturbing the tree, so it
  # belongs to the guard's question even though it is deliberately outside the
  # record's — the record cannot take it back without making the ordinary
  # `git add -A && git commit` invalidate every verdict.
  # The ref leg. Reported BEFORE the index leg because a branch switch leaves
  # porcelain identical, so the index message below would otherwise be the only
  # thing printed and would name the wrong cause.
  if [ "$HERM_REF_AFTER" != "$HERM_REF_BEFORE" ]; then
    echo "  the checked-out REF moved: $HERM_REF_BEFORE -> $HERM_REF_AFTER"
    echo "  Something ran \`git switch\`/\`git checkout\` in this repo. The new ref can point at"
    echo "  the SAME commit, so the content hash, the HEAD check and the porcelain comparison"
    echo "  are all blind to it; this symbolic-ref capture is the one that caught it. Whoever"
    echo "  owns this checkout is now on a branch they did not choose."
  fi
  # The porcelain leg is only entitled to blame the index when porcelain ACTUALLY
  # moved. It used to infer that from "content and HEAD both held still", which was
  # sound while those were the only other legs and stopped being sound the moment
  # the ref leg landed — a branch switch holds content and HEAD still too.
  if [ "$HERM_AFTER" = "$HERM_BEFORE" ] && [ "$HERM_HEAD_AFTER" = "$HERM_HEAD_BEFORE" ] \
     && ! cmp -s "$WORKDIR/herm.before" "$WORKDIR/herm.after"; then
    echo "  the INDEX moved while content and HEAD stayed put — something ran \`git add\`"
    echo "  (or \`git rm --cached\`) in this repo. No byte changed, so neither the content"
    echo "  hash nor the HEAD check can see it; this porcelain comparison is the one that did."
  fi
  if [ -z "$HERM_AFTER" ]; then
    echo "  the AFTER fingerprint could not be taken at all (the repo became unreadable mid-run)."
  elif [ "$HERM_AFTER" != "$HERM_BEFORE" ]; then
    echo "  paths that appeared/vanished (a content-only edit to an already-dirty file moves the"
    echo "  fingerprint without showing up below):"
    diff "$WORKDIR/herm.before" "$WORKDIR/herm.after" 2>/dev/null | sed 's/^/    /'
  fi
  echo "  Either a suite wrote to the live source tree (a hermeticity defect — suites must"
  echo "  build and plant in their own mktemp scratch), or the tree was edited while the"
  echo "  battery ran (in which case no single tree state was tested — re-run on a settled tree)."
  fail=1
fi

# Per-suite wall-clock, slowest first, on stderr. This is RETAINED measurement, not
# just progress: sizing the focused-suite path and the hermeticity change needs the
# suite-time DISTRIBUTION, and the standing lesson ([22.1] Q3) is that a modeled
# distribution was ~4x wrong and only measurement caught it.
#
# These are POOL timings — suites overlap under the bounded pool, so a number here
# includes contention from its neighbours. They name the long poles honestly; they
# are NOT isolated per-suite costs, and an isolated census must run suites alone.
# Said in the output rather than only here, because an unqualified number in a
# terminal becomes a quoted fact three sessions later.
#
# Ordering: this sits BEFORE the exit and writes ONLY to stderr. It cannot alter
# $fail and cannot mask a suite failure — the [15.1] exit-masking invariant below
# is that nothing follows the exit, and nothing does.
{
  echo "[run-core-tests] per-suite wall-clock, slowest first (POOL timings — suites overlap, so these name the long poles but are NOT isolated costs):"
  for i in "${!SUITES[@]}"; do
    printf '%s %s\n' "$(cat "$WORKDIR/$i.dur" 2>/dev/null || echo 0)" "$(basename "${SUITES[$i]}")"
  done | sort -rn | while read -r d n; do printf '  %5ss  %s\n' "$d" "$n"; done
} >&2

# Record this run's verdict together with a fingerprint of the tree it covered
# (Prong A2), so a QA stage can consume THIS battery instead of paying ~800s for
# its own. Guarded so it can never affect the verdict: it runs in a subshell, all
# of its output goes to the runner's stderr, and its exit status is discarded —
# `fail` is computed above and nothing here may touch it ([15.1] exit-masking).
#
# Failure to record is a DESIGNED degradation, not an error: a consumer with no
# usable record refuses and runs the battery itself, which is precisely today's
# behavior. The degradation direction is toward doing the work, never toward a
# green nobody verified.
#
# A --only RUN DOES NOT RECORD. `read` already refuses a filtered verdict as "not
# a whole-tree proof", which is the safe direction — but recording one first is
# not: it OVERWRITES a still-valid whole-tree green, so the very loop this flag
# exists to make cheap (fix, --only, eval) would hand the next QA stage a ~800s
# bill it did not owe. Leaving the previous record in place costs nothing, because
# its own fingerprint check is what decides whether it still describes this tree —
# if the fix moved the tree, it refuses on its own and correctly.
#
# The AFTER fingerprint is passed in rather than left to `record` to recompute (see
# the guard's comment above). When the guard degraded and took no fingerprint,
# HERM_AFTER is empty and `record` computes its own — the record is still written,
# just without the guard's hash behind it.
if [ -f "$HERE/battery-result.sh" ] && [ -z "$ONLY" ]; then
  ( bash "$HERE/battery-result.sh" record \
      "$fail" "${#SUITES[@]}" "$(( ${#SUITES[@]} - nfail ))" "$nfail" \
      "" "$HERM_AFTER" "$A_PASS" "$A_FAIL" ) >&2 || true
elif [ -n "$ONLY" ]; then
  printf '[run-core-tests] --only run: verdict NOT recorded (a filtered result must not overwrite a whole-tree one)\n' >&2
fi

# The runner's verdict IS its exit status, and NOTHING follows it: a trailing
# post-runner command cannot mask a suite failure (the [15.1] exit-masking hole).
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
  # Migrate away the pre-[8.3] runner name: once run-core-tests.sh is in place the
  # old run-harness-tests.sh is an orphan (dual runners) — remove it, loud. The
  # consumer's project.json commands.test that still names the old runner is
  # consumer-owned (not synced) and is the one manual step the CHANGELOG flags.
  if [ -f "$legacy" ]; then
    rm -f "$legacy"
    echo "[setup] migrated runner: removed obsolete .claude/run-harness-tests.sh (now run-core-tests.sh)"
  fi
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
  core's bash suites in the code repo — the whole battery. While iterating use
  \`bash .claude/run-core-tests.sh --only '<glob>'\` (records nothing — a filtered
  run is not a verdict) and read the last whole-tree verdict with
  \`bash .claude/battery-result.sh read\` (provenance-checked; refuses once the tree
  moves). Full battery once, before committing — and never edit the tree while one
  runs; the hermeticity fingerprint will red it.
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
