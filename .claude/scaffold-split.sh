#!/bin/bash
# .claude/scaffold-split.sh — CONSUMER-facing split scaffold ([11.5]).
#
# (Slash commands named in this file are guv:-namespaced under a plugin install —
# e.g. /init resolves as /guv:init — so the report's next-step
# hint points at the right command in either install mode.)
#
# Lay down a control-plane / code split for a greenfield publishable or standalone
# product: a SIBLING control plane (<product>-guv) that holds .claude/, docs/, and
# docs/sessions/, plus the product CODE repo provisioned as a guv lane target. This
# is the consumer analog of the MAINTAINER maintainers/setup-control-plane.sh — that
# script lays down a dogfooding plane for guv ITSELF (roots.code points back at guv);
# this one lays down a plane for an arbitrary consumer product, with roots.code a
# named MAP pointing at the sibling code repo ([11.2] forward shape). Until [11.5]
# only the maintainer path could create a sibling plane; this gives a consumer the
# same split layout that resolve-stack.sh's greenfield proposal recommends.
#
# Topology written (the split-by-default shape):
#   <product>-guv/            ← the control plane (cwd for sessions)
#     .claude/                ← guv core (deployed by the plugin's scaffold-shell.sh)
#     docs/ docs/sessions/    ← plan + session artifacts
#     .claude/project.json    ← roots.code = { <product>: { path: "../<product>" } }, codePrimary
#   <product>/                ← the code repo, provisioned via provision-code-repo.sh ([10.10])
#
# The core (skills, agents, hooks, scripts, rules) comes from the plugin, not from
# here — this script writes only the per-plane shell + the split manifest, and
# delegates the code repo's per-repo core to provision-code-repo.sh. So it composes
# the two shipped primitives (scaffold-shell.sh + provision-code-repo.sh) rather than
# re-implementing either.
#
# Usage (cwd = anywhere; the code repo is the positional arg):
#   bash .claude/scaffold-split.sh <code-repo-path> [--name <product>] \
#        [--language <lang>] [--test <cmd>]
#
#   <code-repo-path>   the product's code repo (created if absent). The control
#                      plane is its sibling <product>-guv, named from --name (or the
#                      code repo's basename). The <project>-guv convention is a
#                      CONSTRUCTED default offered here, never a discovery key — no
#                      script finds a plane by name (docs-sweep T6; the manifest is
#                      the sole machine pointer).
#   --name <product>   override the product name (default: basename of the code repo).
#   --language <lang>  language for the code repo's manifest (default: shell).
#   --test <cmd>       commands.test for the code repo's manifest.
#
# Idempotent / no-clobber: an existing control-plane manifest or an existing code-repo
# manifest is KEPT (provision-code-repo.sh enforces the code half; this script enforces
# the plane half). Re-running refreshes the deployed core shell, never the manifests.
#
# Exit: 0 ok · 2 usage · 4 a dependency (scaffold-shell.sh / provision-code-repo.sh)
# could not be located.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .claude/ (this script's dir)
log() { echo "[scaffold-split] $*" >&2; }

usage() {
  echo "usage: bash .claude/scaffold-split.sh <code-repo-path> [--name <product>] [--language <lang>] [--test <cmd>]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
CODE_DIR=""
NAME=""
LANG_="shell"
TEST_CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)     [ $# -ge 2 ] || usage; NAME="$2"; shift 2 ;;
    --language) [ $# -ge 2 ] || usage; LANG_="$2"; shift 2 ;;
    --test)     [ $# -ge 2 ] || usage; TEST_CMD="$2"; shift 2 ;;
    --*)        log "unknown flag '$1'"; usage ;;
    *)          [ -z "$CODE_DIR" ] || { log "unexpected extra argument '$1'"; usage; }; CODE_DIR="$1"; shift ;;
  esac
done
[ -n "$CODE_DIR" ] || usage

# ── Locate the plugin's scaffold-shell.sh (deploys the per-plane core shell) ──
# Resolution order: an explicit override (testability), then ${CLAUDE_PLUGIN_ROOT}
# (the plugin install — this is how a consumer actually runs), then a sibling
# committed plugin/ tree (the source-tree / dogfooding case). A loud stop if none
# is found rather than scaffolding a plane with no core (rule 15).
find_scaffold_shell() {
  local c
  if [ -n "${SCAFFOLD_SHELL_SH:-}" ]; then echo "$SCAFFOLD_SHELL_SH"; return 0; fi
  for c in \
    "${CLAUDE_PLUGIN_ROOT:-}/scripts/scaffold-shell.sh" \
    "$HERE/../plugin/scripts/scaffold-shell.sh" \
    "$HERE/../maintainers/plugin-src/scripts/scaffold-shell.sh"; do
    [ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}
SCAFFOLD_SHELL="$(find_scaffold_shell)" || {
  log "ERROR: could not locate scaffold-shell.sh (set CLAUDE_PLUGIN_ROOT, or run from a tree carrying plugin/)."
  exit 4
}

PROVISION="$HERE/provision-code-repo.sh"
[ -f "$PROVISION" ] || { log "ERROR: provision-code-repo.sh not found beside this script ($PROVISION)"; exit 4; }

# ── Resolve the product name + the control-plane sibling path ────────────────
# The code repo is created if absent (greenfield) so its basename + parent are
# resolvable; the plane is its <product>-guv sibling.
mkdir -p "$CODE_DIR"
CODE_ABS="$(cd "$CODE_DIR" && pwd)"
CODE_BASE="$(basename "$CODE_ABS")"        # the code repo's REAL on-disk basename
[ -n "$NAME" ] || NAME="$CODE_BASE"
PARENT="$(cd "$CODE_ABS/.." && pwd)"
PLANE="$PARENT/$NAME-guv"
# roots.code's PATH must point at the code repo's real location, not at a sibling
# named after --name: provision-code-repo.sh provisions the repo IN PLACE (it never
# moves/renames it), so the plane reaches it via its real basename. --name controls
# only the product/plane name (the <name>-guv dir, the map key, codePrimary); the
# path tracks the real repo. The plane is the code repo's sibling under $PARENT, so
# the relative path is ../<real basename>. (When --name is omitted, NAME==CODE_BASE
# and this collapses to the historical ../<name>.)
CODE_REL="../$CODE_BASE"
log "Product '$NAME': code repo at $CODE_ABS, control plane at $PLANE (the <product>-guv convention); roots.code → $CODE_REL."

# ── 1. Deploy the per-plane shell into the control plane via the plugin ──────
# scaffold-shell.sh runs with cwd = the plane and lays down .claude/ (schema,
# settings, rules), the doc skeletons, docs/sessions/, and .gitignore. It never
# writes the manifest — that is this script's split-specific job (next step).
mkdir -p "$PLANE"
( cd "$PLANE" && bash "$SCAFFOLD_SHELL" ) >&2 || { log "ERROR: scaffold-shell.sh failed in $PLANE"; exit 4; }

# ── 2. Write the split manifest into the control plane (deploy-once) ─────────
# roots.code is the named MAP pointing at the sibling code repo, codePrimary names
# it — the same shape resolve-stack.sh's greenfield publishable proposal emits, and
# the schema's forward [11.2] contract. ceremony=phased (greenfield builds structure).
# DEPLOY-ONCE: never clobber an existing plane manifest (a consumer's confirmed
# topology + filled-in commands are theirs).
MANIFEST="$PLANE/.claude/project.json"
if [ -f "$MANIFEST" ]; then
  log "control-plane manifest exists at $MANIFEST — kept (no clobber)."
else
  if [ -n "$TEST_CMD" ]; then test_json=$(printf '%s' "$TEST_CMD" | jq -Rs .); else test_json=null; fi
  jq -n --arg name "$NAME" --arg coderel "$CODE_REL" --arg lang "$LANG_" --argjson test "$test_json" '{
    "$schema": "./project.schema.json",
    name: $name,
    language: $lang,
    packageManager: null,
    roots: { control: ".", code: { ($name): { path: $coderel } }, codePrimary: $name },
    commands: { test: $test, build: null, lint: null, format: null, dev: null, install: null },
    scaffoldCheck: ("test -d \"" + $coderel + "/.claude\""),
    readyCheck: null,
    formatExtensions: [],
    guards: [],
    ceremony: "phased"
  }' > "$MANIFEST"
  log "wrote split manifest (roots.code → named map { $NAME: { path: \"$CODE_REL\" } }, codePrimary=$NAME, ceremony=phased)."
fi

# ── 3. Provision the code repo as a guv lane target ([10.10]) ────────────────
# A publishable product's code repo is not itself a guv install, so the lane
# machinery's per-repo core (a ceremony=task manifest + the guv-core .gitignore
# block) is written by provision-code-repo.sh. Idempotent/no-clobber there too:
# an already-provisioned code repo is the already-done degenerate, left untouched.
prov_args=("$CODE_ABS" --language "$LANG_")
[ -n "$TEST_CMD" ] && prov_args+=(--test "$TEST_CMD")
bash "$PROVISION" "${prov_args[@]}" >&2 || { log "ERROR: provision-code-repo.sh failed for $CODE_ABS"; exit 4; }

# ── Report ───────────────────────────────────────────────────────────────────
log ""
log "Split scaffold complete:"
log "  control plane: $PLANE   (roots.code → $CODE_REL)"
log "  code repo:     $CODE_ABS   (provisioned as a guv lane target)"
log "  Next:  cd \"$PLANE\" && claude   then  /init <spec>  (writes the phase docs over the split manifest)"
echo "$PLANE"
exit 0
