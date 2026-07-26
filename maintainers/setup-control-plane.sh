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
#   the plugin cache's scripts/, hooks/ and workflows/ are refreshed from this repo's
#   built plugin/, because a plugin-registered hook runs the CACHE's copy of core, never
#   the plane's. That cache is user-scope, so it is the core every guv project on this
#   machine runs. Trees read by NAME (skills/, agents/, rules/) are left at the release
#   on purpose. The refresh names every file it changes or prunes, keeps its delete
#   inside those three guv-owned trees, verifies the result by re-reading the cache, and
#   is skipped LOUDLY whenever it cannot establish that the cache is this repo's
#   artifact. See refresh_plugin_cache below.

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
# SCOPE — three trees, and deliberately not the whole plugin. The defect is that the
# plugin path EXECUTES stale code, so the fix reaches exactly what executes: every hook
# command in hooks.json is ${CLAUDE_PLUGIN_ROOT}/scripts/*, hooks.json itself IS the
# authoritative registration since [19.5], and skill/agent bodies invoke
# ${CLAUDE_PLUGIN_ROOT}/scripts/* and /workflows/*. skills/, agents/, rules/, shell/,
# tests/ and .claude-plugin/ are READ BY NAME, not executed from source, and leaving
# them at the release is what preserves the dual-load comparison DOGFOODING.md
# documents — bare names are the plane's synced copy, /guv: names are the release.
# Narrowing is also what keeps the prune below inside guv-owned ground: these three
# trees are wholly ours, so a delete can never reach .in_use/ (Claude Code's per-session
# PID locks), .DS_Store at the cache root, or anything else Claude Code put there.
GUV_CACHE_TREES="scripts hooks workflows"
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
# manifest, an unenumerable source tree. Only two rungs are silent, and each means the
# guv plugin is simply not installed here (no jq, no plugin DB / no guv entry) — the
# ordinary state of a consumer plane, and not news. This verifies a cache; it never
# provisions one.

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
  # Identity. 'guv@* and the directory exists' is what the DB claims; the manifest is
  # what the artifact itself says. A maintainer with the RELEASE installed and a FORK
  # checked out at $GUV_DIR would otherwise have the release silently overwritten — and
  # since the prune landed, partly deleted — across every guv project on the machine.
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
  echo "        (source is the BUILT plugin, plugin/ — rebuild first if you have edited .claude/ since the last build)"
  [ -n "$drift" ] && printf '%s\n' "$drift" | sed 's|^|  drifted: |'
  [ -n "$stale" ] && printf '%s\n' "$stale" | sed 's|^|  removed upstream: |'
  # Overlay what source ships, then prune what source dropped. Both stay inside the
  # three guv-owned trees; nothing walks the cache root, where Claude Code's own
  # .in_use/ session locks live.
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
  # Provenance: the DB's gitCommitSha/lastUpdated described the RELEASE and are false
  # once overlaid, so leave a marker saying which source this cache now carries. It sits
  # at the cache root, outside the walked trees, so it is never its own prune candidate.
  # The marker records dirty state because this loop exists to move UNRELEASED work: a
  # bare HEAD sha would name a commit that does not describe what was copied.
  local dirty=no
  [ -n "$(git -C "$GUV_DIR" status --porcelain -- plugin 2>/dev/null)" ] && dirty=yes
  if ! { echo "# hand-refreshed from guv source by maintainers/setup-control-plane.sh"
         echo "source_repo=$GUV_DIR"
         echo "source_commit=$(git -C "$GUV_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
         echo "source_plugin_dirty=$dirty"
         echo "refreshed_trees=$GUV_CACHE_TREES"
         echo "refreshed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
       } > "$cache/.guv-source-refresh" 2>/dev/null; then
    echo "[setup] WARNING — could not write $cache/.guv-source-refresh; this cache now carries unreleased source with no record of which"
  fi
  # VERIFY, don't claim. cp -R is documented to keep going after an error, so its exit
  # status cannot carry this: re-run the same comparison and report what is left.
  local rdrift rstale
  rdrift=$(_cache_drift "$built" "$cache")
  rstale=$(_cache_stale "$built" "$cache")
  if [ -z "$rdrift" ] && [ -z "$rstale" ]; then
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
#  (b) BOUNDED PARALLEL POOL + SERIAL CARVE + DETERMINISTIC AGGREGATION — most
#      suites run concurrently (≤ CORE_TEST_JOBS at once), each writing its own
#      out/err/rc; a final pass then replays them IN SORTED NAME ORDER under the
#      identical gate, so wall-clock drops toward the slowest while the output and
#      verdict stay deterministic. NOT every suite is hermetic: the audit
#      ([15.1] — maintainers/BATTERY-HERMETICITY.md) found two suites that write
#      to / build from the SHARED LIVE SOURCE TREE at fixed (non-mktemp) paths —
#      plugin.test.sh plants throwaway fixtures into the repo's .claude/ and
#      builds reading it; ship-suite.test.sh builds the plugin reading that same
#      source. Run concurrently they corrupt each other's build (planted fixtures
#      / a skill-name-collision exit 2) → an intermittently flaky battery. Those
#      suites (SERIAL_SET) are carved OUT of the pool and run ONE AT A TIME; the
#      genuinely-hermetic remainder stays parallel.
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
set -u
# Resolve the code repo through the shared [11.2] resolver — roots.code may be a
# named map, so a bare string read would point the suite glob at the map object.
# The resolver returns the PRIMARY's path (the suites are the dogfooding battery,
# which targets the primary). roots.sh ships beside this runner under .claude/.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/roots.sh"
CODE=$(roots_code_path) || { echo "run-core-tests: could not resolve a code repo from the manifest" >&2; exit 4; }

# ── fix (a): resolve the per-suite timeout command (designed degradation) ──
# CORE_TEST_TIMEOUT overrides the default bound. The slowest suites are the
# SERIAL_SET plugin-builders (plugin.test.sh ~190s; ship-suite.test.sh measured
# 258s before its [22.1] --only cut, 99s after) — 600s leaves generous headroom
# for sandbox slowness without masking a true hang (258s against the old 300s
# bound was a latent flake, [22.1]). A missing binary is announced, not silently
# dropped.
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
  local t="$1" key="$2"
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" -k 5 "$SUITE_TIMEOUT" bash "$t" \
      >"$WORKDIR/$key.out" 2>"$WORKDIR/$key.err"
  else
    bash "$t" >"$WORKDIR/$key.out" 2>"$WORKDIR/$key.err"
  fi
  printf '%s\n' "$?" > "$WORKDIR/$key.rc"
}

# ── fix (b): the AUDITED serial set (the shared-live-source-tree writers) ──
# These suites mutate / build from the repo's live .claude/ at fixed paths, so
# they MUST NOT overlap each other or any other suite. Audit + rationale:
# maintainers/BATTERY-HERMETICITY.md. A new suite that writes to the shared live
# tree is enrolled by adding its basename here (one edit, mirrored in the plugin
# runner and the CI loop's comment — the three copies stay in lockstep).
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

# Serial carve FIRST: the shared-live-tree suites run strictly one at a time,
# before the pool, so neither they nor the pool ever touch the live source tree
# concurrently. (Sequential foreground runs — no & — guarantee non-overlap.)
for i in "${!SUITES[@]}"; do
  case "$SERIAL_SET" in *" $(basename "${SUITES[$i]}") "*) run_one "${SUITES[$i]}" "$i" ;; esac
done

# Launch the HERMETIC remainder under a bounded pool: at most $JOBS in flight.
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

# ── fix (b)+(c): deterministic SERIAL aggregation under the IDENTICAL gate ──
# Replay suites in sorted order; apply the gate (nonzero rc OR any stderr byte OR
# a failure-shaped stdout verdict). One verdict variable; the runner's exit IS it.
fail=0
for i in "${!SUITES[@]}"; do
  t="${SUITES[$i]}"
  name="$(basename "$t")"
  echo "== $name =="
  cat "$WORKDIR/$i.out" 2>/dev/null
  rc=$(cat "$WORKDIR/$i.rc" 2>/dev/null || echo 1)

  # (a) timeout: 124 (timed out) / 137 (SIGKILL after -k grace) — name it loud.
  if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
    echo "[timeout] $name TIMED OUT after ${SUITE_TIMEOUT}s (rc=$rc) — failing the run (a hang, not sandbox slowness)"
    fail=1
  elif [ "$rc" != "0" ]; then
    echo "[rc] $name exited nonzero (rc=$rc) — failing the run"
    fail=1
  fi

  # (c-stderr) any stderr byte fails the run.
  if [ -s "$WORKDIR/$i.err" ]; then
    echo "[stderr] $name wrote to stderr — failing the run:"
    cat "$WORKDIR/$i.err"
    fail=1
  fi

  # (c-stdout) a failure-shaped STDOUT verdict fails the run even if rc=0: a ✗
  # assertion line, or a "Results: N passed, M failed" with M>0. This closes the
  # stdout-only-blindness hole — a suite that reports its own failure but forgets
  # to exit nonzero can no longer show green. The 0-failed verdict and ✓ glyph
  # are NOT matched (no false positive on a clean run).
  if grep -q '✗' "$WORKDIR/$i.out" 2>/dev/null \
     || grep -qE 'Results:[[:space:]]*[0-9]+[[:space:]]*passed,[[:space:]]*[1-9][0-9]*[[:space:]]*failed' "$WORKDIR/$i.out" 2>/dev/null; then
    echo "[stdout] $name reported a FAILURE on stdout while exit was $rc — failing the run (stdout-only failures are not green)"
    fail=1
  fi
done

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
