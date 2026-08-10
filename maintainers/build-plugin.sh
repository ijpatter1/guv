#!/bin/bash
# Build the Governor (guv) plugin from source — Phase 5 D1.
#
# The committed plugin/ directory is GENERATED, never hand-edited. The single
# source of truth stays in .claude/ (skills, agents, hooks, rules,
# helper scripts, the saved workflow); plugin-only files (manifest, the
# reviewer-readonly guard, the zen and scaffold skills) are authored in
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
#   - hook + helper scripts, rules: byte-identical copies
#     (scripts run with cwd = the project, so .claude/project.json reads stay
#     correct; rules/ are assets the scaffold skill deploys)
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
#   - slash commands: longest name first so /phase-docs is consumed
#     before /phase; the preceding-char guard [^[:alnum:].:-] keeps path
#     segments (docs/manual/task-*.md) and already-namespaced (/guv:task)
#     mentions untouched
#   - agent spawns: the "`<name>` subagent" instruction phrasing and the
#     @-mention form used in agent descriptions
#   - two template-clone topology facts with no plugin counterpart path
# Every name that registers as /<name> for consumers — commands and skills —
# DERIVED from the source tree (a hand-maintained copy of
# this list is exactly the drift this build exists to prevent; plugin.test.sh
# derives its detector the same way). Longest first so /phase-docs is
# consumed before /phase.
slash_names() {
  {
    for d in "$SRC/skills"/*/; do basename "$d"; done
    # plugin-only skills (zen, scaffold, …) register as /guv:<name> too
    for d in "$PSRC/skills"/*/; do basename "$d"; done
  } | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-
}

_namespace_pass() {
  # Qualified mentions are literal ([24.1]): "built-in `/cmd`", "native
  # `/cmd`", "bare `/cmd`" NAME a token rather than invoke a skill — renaming
  # the door onto the built-in's token made the distinction load-bearing (an
  # unprotected pass rewrote mentions of Claude Code's built-in /init into
  # the namespaced form and shipped instructions against the canonical door).
  # Protect the qualified forms with a sentinel before the rewrite loop;
  # restore after. T12b filters the same forms; T12f pins the shipped result.
  local lit; lit=$(printf '\001')
  local args=(-E
    -e "s#(built-in|native|bare) \`/#\\1 \`${lit}#g"
    -e 's|`\.claude/skills/phase-docs/SKILL\.md`|plugin-shipped|g'
    -e 's|\(`\.claude/skills/eval/SKILL\.md`\)|(plugin-shipped)|g')
  local n
  while IFS= read -r n; do
    # '#' delimiter: the pattern itself needs both '/' and the ERE '|'
    args+=(-e "s#(^|[^[:alnum:].:-])/$n(\$|[^[:alnum:]:_-])#\\1/guv:$n\\2#g")
  done < <(slash_names)
  # Namespace EVERY project agent (derived from .claude/agents/) in both its backtick
  # and @ forms — reviewer, and any future agent. Hardcoding a fixed agent list
  # here was the gap that left a new agent's @mention bare under
  # a plugin install (where agents resolve only as guv:<name>).
  local agf agname
  for agf in "$SRC/agents"/*.md; do
    agname=$(basename "$agf" .md)
    args+=(-e "s|\`$agname\` subagent|\`guv:$agname\` subagent|g" -e "s|@$agname|@guv:$agname|g")
  done
  args+=(-e "s#${lit}#/#g")
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
  "$OUT/scripts" "$OUT/rules"

# ── plugin hooks.json: DERIVED from settings.json (one source) ──
# Every hook is wired once, in .claude/settings.json; the build rewrites each
# command's project path ("${CLAUDE_PROJECT_DIR:-$PWD}"/.claude/hooks/X.sh, the
# [19.4] off-root anchor) to the plugin-root path — the \S* strips the whole
# project-mode prefix so the anchor never leaks into the plugin — then
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
           then .command |= gsub("\\S*\\.claude/hooks/"; "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/")
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
# @reviewer — dead pointers in their bare forms under plugin install) and
# the script-path rewrite ([7.1] routed agent procedures through the
# .claude/guv-*.sh helpers — dead paths in a plugin-only project without it).
for a in "$SRC/agents"/*.md; do
  awk '
    /^---$/ { fm++; inhooks=0; inskills=0; print; next }
    fm==1 && /^hooks:/ { inhooks=1; next }
    fm==1 && inhooks && /^[^ ]/ { inhooks=0 }
    inhooks { next }
    # skills: preload entries are guv:-namespaced under a plugin install (the agent
    # preloads guv:<name>, not <name> — else the preload silently no-ops). Bounded to
    # the frontmatter (fm==1) and the skills: block; bare names only (already-prefixed
    # pass through).
    fm==1 && /^skills:/ { inskills=1; print; next }
    fm==1 && inskills && /^[ \t]+-[ \t]+/ { if ($0 !~ /guv:/) sub(/-[ \t]+/, "&guv:"); print; next }
    fm==1 && inskills && /^[^ \t]/ { inskills=0 }
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
# json, and the top-level .claude/ shape docs (any *.shape.md, metering*.md).
# A suite that asserts any of those is a source-shape check, not consumer script
# behavior — it cannot run green in plugin layout no matter how the tree is
# reconstructed, so it is maintainer-only in the same spirit as the named three.
# The directory-grep forms a green consumer suite uses
# (grep -r … .claude/skills 2>/dev/null) do NOT match — the
# patterns require a trailing /<file>.md or /SKILL.md. ship-suite.test.sh derives
# the SAME partition and asserts it both directions, so this rule lives once.
MAINTAINER_ONLY='maintainers/|plugin-src/|\.claude/settings\.json|skills/[a-z][a-z-]*/SKILL\.md|project\.schema\.json|[a-z][a-z-]*\.shape\.md|/metering[a-z-]*\.md'
#
# The match is over the WHOLE file, comments included, and that is a known trap:
# a consumer-relevant suite that merely mentions one of these paths in prose stops
# shipping, and consumer installs lose the coverage. It happened on 2026-07-27
# (battery-result.test.sh, 24 shipped suites silently became 23). Reading only the
# code is NOT the fix — measured the same day, it would newly ship three suites
# (build-fanout, door-vocabulary, lane-builder) that assert source-only surfaces
# and fail in plugin layout, so their exclusion is correct even though the reason
# recorded for it is not. What made the trap expensive was SILENCE, so the loop
# below announces what it dropped; the classifier is unchanged. Friction
# 2026-07-27T05:03:02Z-691324996 holds the real fix (an explicit marker per suite).
mkdir -p "$OUT/tests"
SHIPPED_N=0
EXCLUDED_SUITES=""
for t in "$SRC/tests"/*.test.sh; do
  b="$(basename "$t")"
  # the ship-suite self-test IS the shipping machinery's own guard — it builds
  # the plugin and asserts the partition, so it never ships into the plugin
  case "$b" in ship-suite.test.sh) continue ;; esac
  grep -qE "$MAINTAINER_ONLY" "$t" && { EXCLUDED_SUITES="$EXCLUDED_SUITES $b"; continue; }
  cp "$t" "$OUT/tests/$b"
  SHIPPED_N=$((SHIPPED_N + 1))
done
EXCLUDED_N=$(printf '%s' "$EXCLUDED_SUITES" | wc -w | tr -d ' ')
echo "[build] test suites: $SHIPPED_N shipped, $EXCLUDED_N maintainer-only (not shipped):$EXCLUDED_SUITES"

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
# Pure bash + jq. Run: bash <plugin>/tests/run-plugin-tests.sh [--only <pattern>]
set -u

# --only <pattern> ([22.1]): run just the shipped suites whose basename matches
# the glob PATTERN. The reconstruction below is always FULL (the filter gates
# suite execution, never the rebuild), so a placement probe run under --only
# still inspects the complete reconstructed tree. A pattern that matches no
# suite fails LOUD at the filter — never a vacuous green.
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      shift
      { [ $# -gt 0 ] && [ -n "$1" ]; } || { echo "run-plugin-tests: --only requires a non-empty pattern" >&2; exit 2; }
      ONLY="$1"; shift ;;
    *) echo "run-plugin-tests: unknown argument: $1 (supported: --only <pattern>)" >&2; exit 2 ;;
  esac
done

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$PLUGIN/scripts"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
TESTS="$PLUGIN/tests"
RULES="$PLUGIN/rules"
AGENTS="$PLUGIN/agents"

if [ ! -d "$SCRIPTS" ] || [ ! -f "$HOOKS_JSON" ]; then
  echo "run-plugin-tests: not a plugin tree (missing scripts/ or hooks/hooks.json): $PLUGIN" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REC="$WORK/.claude"
mkdir -p "$REC/hooks" "$REC/tests" "$REC/rules" "$REC/agents"

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

# agent definitions ship as plugin assets too, same shape as rules above. This is
# not symmetry for its own sake: battery-result.test.sh T15 pins the CONSUMER-INSTALL
# contract in agent prose (this recorder's `read` exits 3 in every plugin install,
# and a reviewer without that guidance files a phantom "unverified" finding forever).
# The copy that matters for that contract is the SHIPPED one, so reconstructing
# agents/ here is what points the probe at the artifact a consumer actually loads
# rather than at the maintainer's source tree. Added 2026-07-27 after T15 landed
# green in source layout and red here — its four probes were all reading a path
# this reconstruction never created.
[ -d "$AGENTS" ] && cp "$AGENTS"/*.md "$REC/agents/" 2>/dev/null || true

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

# ── gate integrity ([15.1]): the plugin battery shares the core runner's three
# coupled guards, so a shipped suite that hangs, errors to stderr, or reports a
# stdout-only failure can never show green here either.
#  (a) per-suite timeout — a hung shipped suite fails LOUD with a named timeout
#      (rc 124), never a silent stall; a missing timeout binary degrades to an
#      announced unbounded run (Rule 15).
#  (b) bounded parallel pool + deterministic aggregation — EVERY suite runs
#      concurrently (≤ POOL_JOBS), each into its own out/err/rc; a final pass
#      replays them in sorted name order so wall-clock drops toward the slowest
#      while output + verdict stay deterministic.
#
#      There is no serial carve here, and — unlike the core runner — no
#      hermeticity fingerprint either, both for the same reason: this battery has
#      NO live source tree to protect. The suites are copied into the
#      reconstructed $REC tree above, so a suite's own $(dirname "$0")/.. resolves
#      to that scratch copy and a fixture planted at a "fixed path" lands inside a
#      throwaway directory. The core runner's guard exists because its suites run
#      against the real repo; that hazard has no analogue on this side.
#
#      (A carve naming plugin.test.sh + ship-suite.test.sh used to be mirrored here
#      "in lockstep" with the core runner, per maintainers/BATTERY-HERMETICITY.md.
#      It was dropped because it was INERT: neither suite ships — check
#      plugin/tests/ — so the membership test never matched. The core runner still
#      carves those two, now for a scheduling reason rather than a hermeticity one;
#      this copy needs no mirror, and the "three lockstep copies" framing was
#      always wrong by one.)
#  (c) no exit-masking / no stdout-only blindness — the gate fails a suite on ANY
#      of: nonzero rc, ANY stderr byte, or a failure-shaped stdout verdict (a ✗
#      line or "Results: N passed, M failed" with M>0) even at exit 0. The runner's
#      final statement is its exit on the aggregated verdict.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
fi
SUITE_TIMEOUT="${PLUGIN_TEST_TIMEOUT:-300}"
[ -z "$TIMEOUT_BIN" ] && echo "[run-plugin-tests] no timeout/gtimeout on PATH — suites run UNBOUNDED (a hang will not be caught; install coreutils to restore the per-suite timeout guard)"
POOL_JOBS="${PLUGIN_TEST_JOBS:-}"
if [ -z "$POOL_JOBS" ]; then
  POOL_JOBS=$( { command -v nproc >/dev/null 2>&1 && nproc; } \
            || { command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu; } \
            || echo 4 )
fi
case "$POOL_JOBS" in ''|*[!0-9]*) POOL_JOBS=4 ;; esac
[ "$POOL_JOBS" -lt 1 ] && POOL_JOBS=1

# collect the reconstructed suites in stable sorted order — the spine of the
# launch list and the aggregation pass
SUITES=()
while IFS= read -r t; do SUITES+=("$t"); done < <(
  for t in "$REC/tests"/*.test.sh; do [ -e "$t" ] && printf '%s\n' "$t"; done | LC_ALL=C sort
)

# apply the --only filter ([22.1]): keep the matching basenames. Zero matches is
# a loud failure, never a vacuous green — a typo'd pattern silently running zero
# suites would let every --only consumer's proof pass on nothing.
if [ -n "$ONLY" ]; then
  KEEP=()
  for t in "${SUITES[@]}"; do
    # shellcheck disable=SC2254 — $ONLY is deliberately an unquoted glob pattern
    case "$(basename "$t")" in $ONLY) KEEP+=("$t") ;; esac
  done
  if [ "${#KEEP[@]}" -eq 0 ]; then
    echo "run-plugin-tests: --only '$ONLY' matched no shipped suite" >&2
    exit 2
  fi
  SUITES=("${KEEP[@]}")
fi

run_one() {  # $1 = suite path  $2 = scratch key
  local t="$1" key="$2"
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" -k 5 "$SUITE_TIMEOUT" bash "$t" \
      >"$WORK/$key.out" 2>"$WORK/$key.err"
  else
    bash "$t" >"$WORK/$key.out" 2>"$WORK/$key.err"
  fi
  printf '%s\n' "$?" > "$WORK/$key.rc"
}

# bounded pool — every suite, at most $POOL_JOBS in flight. No carve: the suites
# run out of the reconstructed $REC tree, so there is no shared live source tree
# for them to collide over.
running=0
for i in "${!SUITES[@]}"; do
  run_one "${SUITES[$i]}" "rps-$i" &
  running=$((running + 1))
  if [ "$running" -ge "$POOL_JOBS" ]; then
    wait -n 2>/dev/null || wait
    running=$((running - 1))
  fi
done
wait

# deterministic SERIAL aggregation under the identical gate
PASS_SUITES=0; FAIL_SUITES=0; FAILED_NAMES=""
for i in "${!SUITES[@]}"; do
  t="${SUITES[$i]}"; b="$(basename "$t")"
  echo "── $b ──"
  cat "$WORK/rps-$i.out" 2>/dev/null
  rc=$(cat "$WORK/rps-$i.rc" 2>/dev/null || echo 1)
  suite_failed=0
  if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
    echo "[timeout] $b TIMED OUT after ${SUITE_TIMEOUT}s (rc=$rc) — failing the run (a hang, not slowness)"
    suite_failed=1
  elif [ "$rc" != "0" ]; then
    suite_failed=1
  fi
  if [ -s "$WORK/rps-$i.err" ]; then
    echo "[stderr] $b wrote to stderr — failing the run:"
    cat "$WORK/rps-$i.err"
    suite_failed=1
  fi
  if grep -q '✗' "$WORK/rps-$i.out" 2>/dev/null \
     || grep -qE 'Results:[[:space:]]*[0-9]+[[:space:]]*passed,[[:space:]]*[1-9][0-9]*[[:space:]]*failed' "$WORK/rps-$i.out" 2>/dev/null; then
    echo "[stdout] $b reported a FAILURE on stdout while exit was $rc — failing the run"
    suite_failed=1
  fi
  if [ "$suite_failed" -eq 0 ]; then
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
# the verdict IS the exit, and nothing follows it (no trailing-command masking)
exit "$([ "$FAIL_SUITES" -eq 0 ] && echo 0 || echo 1)"
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

echo "Built plugin at $OUT"
