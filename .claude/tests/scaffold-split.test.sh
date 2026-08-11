#!/bin/bash
# Tests for .claude/scaffold-split.sh — the CONSUMER-facing split scaffold ([11.5]).
#
# The deliverable: a consumer-facing path lays down a control-plane / code SPLIT for
# a greenfield publishable/standalone product — until now only the maintainer
# setup-control-plane.sh could create a sibling plane. The script composes the two
# shipped primitives (scaffold-shell.sh deploys the plane's core shell;
# provision-code-repo.sh writes the code repo's per-repo core) and writes the split
# manifest with the named-map roots resolve-stack.sh's greenfield proposal recommends.
#
# Why these tests, not "runs without error": the WHOLE point is that the split layout
# is produced with the CORRECT named-map roots — a sibling control plane holding
# .claude/+docs+sessions AND the code repo provisioned BY provision-code-repo.sh. A
# script that created the plane but left roots.code='.' (single-repo), or wrote the
# plane but never provisioned the code repo, passes a shallow run test and fails the
# discriminators below. Back-compat: a single-repo scaffold (the existing scaffold +
# provision paths) is untouched — asserted via the unchanged sibling-suite results.
#
# Drives a BUILT plugin tree for scaffold-shell.sh (like scaffold.test.sh) — a
# consumer fork without maintainers/ cannot build one, so skip cleanly.
# Pure bash + jq + git, no test runner required.
# Run: bash .claude/tests/scaffold-split.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/.claude/scaffold-split.sh"
SCHEMA="$ROOT/.claude/project.schema.json"
SPLIT_BUILD="${SCAFFOLD_SPLIT_BUILD_SCRIPT:-$ROOT/maintainers/build-plugin.sh}"
SPLIT_TMP=""
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# T1 — the script ships. Everything else drives it; bail loudly if absent.
if [ -f "$SCRIPT" ]; then
  ok "scaffold-split.sh ships in .claude/"
else
  no "missing: $SCRIPT"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# The scaffold half needs scaffold-shell.sh from a BUILT plugin tree ([32.5] —
# the committed plugin/ is the frozen release artifact, so driving it would test
# the last release's script against today's sources). A fork without
# maintainers/ cannot build one; skip cleanly, never fail. The battery's runner
# exports GUV_BUILT_PLUGIN so one build serves every suite that needs one.
# The BUILDER's absence is what means "consumer fork", so it gates first — the
# shared tree must not satisfy a probe that removed the builder. A build that
# FAILS is its own rung, never the fork rung.
if [ ! -f "$SPLIT_BUILD" ]; then
  PLUGIN=""
elif [ -n "${GUV_BUILT_PLUGIN:-}" ] && [ -d "${GUV_BUILT_PLUGIN:-}" ]; then
  PLUGIN="$GUV_BUILT_PLUGIN"
else
  SPLIT_TMP=$(mktemp -d)
  PLUGIN="$SPLIT_TMP/plugin"
  if ! bash "$SPLIT_BUILD" --out "$PLUGIN" >/dev/null 2>&1; then
    no "build-plugin.sh FAILED — cannot exercise scaffold-shell.sh (a broken build, not a consumer fork)"
    echo ""; echo "Results: $PASS passed, $FAIL failed"
    rm -rf "$SPLIT_TMP"
    exit 1
  fi
fi
SCAFFOLD_SHELL="$PLUGIN/scripts/scaffold-shell.sh"
if [ -z "$PLUGIN" ] || [ ! -f "$SCAFFOLD_SHELL" ]; then
  echo "  - no build available (consumer fork) — scaffold-shell.sh unavailable, suite skips"
  [ -n "$SPLIT_TMP" ] && rm -rf "$SPLIT_TMP"
  echo ""
  echo "Results: $PASS passed, 0 failed"
  exit 0
fi

WORK=$(mktemp -d)
trap '[ -n "$SPLIT_TMP" ] && rm -rf "$SPLIT_TMP"; [ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# jsonschema validator (the guv idiom) — present-or-skip.
HAVE_JSONSCHEMA=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' 2>/dev/null; then
  HAVE_JSONSCHEMA=1
fi
validates() {  # stdin = instance JSON; exit 0 iff it validates against SCHEMA
  python3 -c '
import json,sys,jsonschema
schema=json.load(open(sys.argv[1])); inst=json.load(sys.stdin)
try:
    jsonschema.validate(inst, schema); sys.exit(0)
except jsonschema.ValidationError:
    sys.exit(1)
' "$SCHEMA" 2>/dev/null
}

# A greenfield code repo (git-init'd so provision-code-repo.sh can commit into it).
mkcoderepo() {  # $1 = dir
  mkdir -p "$1/src"; printf 'echo hi\n' > "$1/src/app.sh"
  git -C "$1" init -q >/dev/null 2>&1
  git -C "$1" config user.email t@t >/dev/null 2>&1
  git -C "$1" config user.name t >/dev/null 2>&1
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" commit -qm init >/dev/null 2>&1
}

# Run the script with scaffold-shell.sh pinned to the committed plugin (so the test
# doesn't depend on CLAUDE_PLUGIN_ROOT being set in the environment).
run_split() { SCAFFOLD_SHELL_SH="$SCAFFOLD_SHELL" bash "$SCRIPT" "$@"; }

# ── T2 — a greenfield publishable product produces the split layout ──────────
PROD="$WORK/proj1/widget"; mkcoderepo "$PROD"
PLANE="$WORK/proj1/widget-guv"
ERR="$WORK/e2"
run_split "$PROD" --language node --test "npm test" >/dev/null 2>"$ERR"
RC=$?
[ "$RC" -eq 0 ] && ok "split scaffold exits 0" || no "split scaffold exited $RC"
# (informational stderr is expected here and is asserted to be benign in T2b)

# (a) the SIBLING control plane is laid down with .claude/, docs, sessions
SPLIT_OK=1
[ -d "$PLANE/.claude" ]            || { no "control plane missing .claude/"; SPLIT_OK=0; }
[ -f "$PLANE/.claude/project.json" ] || { no "control plane missing the manifest"; SPLIT_OK=0; }
[ -d "$PLANE/docs" ]              || { no "control plane missing docs/"; SPLIT_OK=0; }
[ -d "$PLANE/docs/sessions" ]     || { no "control plane missing docs/sessions/"; SPLIT_OK=0; }
[ -f "$PLANE/.claude/project.schema.json" ] || { no "control plane missing the deployed schema"; SPLIT_OK=0; }
[ "$SPLIT_OK" -eq 1 ] && ok "control plane laid down (.claude/ + manifest + docs + sessions + schema)"

# (b) the split manifest carries the CORRECT named-map roots — the deliverable's core
M="$PLANE/.claude/project.json"
[ "$(jq -r '.roots.code | type' "$M" 2>/dev/null)" = object ] \
  && ok "manifest roots.code is a named map (not single-repo '.')" \
  || no "manifest roots.code must be a named map (got '$(jq -c '.roots.code' "$M" 2>/dev/null)')"
[ "$(jq -r '.roots.codePrimary' "$M" 2>/dev/null)" = widget ] \
  && ok "manifest codePrimary names the product (widget)" \
  || no "manifest codePrimary must be 'widget' (got '$(jq -r '.roots.codePrimary' "$M" 2>/dev/null)')"
[ "$(jq -r '.roots.code.widget.path' "$M" 2>/dev/null)" = "../widget" ] \
  && ok "manifest code repo path is the sibling ../widget" \
  || no "manifest code path must be '../widget' (got '$(jq -r '.roots.code.widget.path' "$M" 2>/dev/null)')"
[ "$(jq -r '.roots.control' "$M" 2>/dev/null)" = "." ] \
  && ok "manifest roots.control stays '.'" \
  || no "manifest roots.control must be '.' (got '$(jq -r '.roots.control' "$M" 2>/dev/null)')"
[ "$(jq -r '.ceremony' "$M" 2>/dev/null)" = phased ] \
  && ok "manifest ceremony=phased (greenfield builds structure)" \
  || no "manifest ceremony must be 'phased' (got '$(jq -r '.ceremony' "$M" 2>/dev/null)')"
[ "$(jq -r '.language' "$M" 2>/dev/null)" = node ] \
  && ok "manifest language from --language (node)" \
  || no "manifest language must be 'node' from --language (got '$(jq -r '.language' "$M" 2>/dev/null)')"

# (c) the manifest VALIDATES against the schema — the named-map allOf (codePrimary
# required iff roots.code is a map, and it names a key of the map).
if [ "$HAVE_JSONSCHEMA" -eq 1 ]; then
  jq -c . "$M" | validates \
    && ok "split manifest validates against project.schema.json (named-map allOf)" \
    || no "split manifest must validate against the schema"
else
  echo "  - jsonschema unavailable — split-manifest schema validation skipped"
fi

# (d) the CODE repo is provisioned BY provision-code-repo.sh — a ceremony=task
# manifest. This is the deliverable's "plus the code repo provisioned via
# provision-code-repo.sh ([10.10])" — without it the split is half-built (a
# plane whose commands route into an unprovisioned repo). The gitignore half
# retired with the lane cluster at [32.3].
[ -f "$PROD/.claude/project.json" ] \
  && ok "code repo has a provisioned manifest" \
  || no "code repo missing the provisioned manifest (provision-code-repo.sh not run)"
[ "$(jq -r '.ceremony' "$PROD/.claude/project.json" 2>/dev/null)" = task ] \
  && ok "code repo manifest ceremony=task (provision-code-repo.sh's shape)" \
  || no "code repo manifest ceremony must be 'task'"
grep -qF '.worktrees/' "$PROD/.gitignore" 2>/dev/null \
  && no "code repo .gitignore still carries the lane-era guv-core block ([32.3] regressed)" \
  || ok "code repo .gitignore carries no lane-era block ([32.3])"

# T2b — stderr is informational only ([scaffold-split]/[scaffold]/provision banners),
# never an unannounced error. The stderr gate fails on ANY stderr, so this script's
# diagnostics go to stderr by design and the suite must tolerate them — but a line
# that is NOT one of the known informational prefixes is a real error and fails.
UNEXPECTED=$(grep -vE '^\[scaffold-split\]|^\[scaffold\]|^provision:|^$' "$ERR" || true)
[ -z "$UNEXPECTED" ] \
  && ok "stderr is informational only (no unexpected error lines)" \
  || no "scaffold-split emitted unexpected stderr: $UNEXPECTED"

# ── T3 — idempotent / no-clobber: a re-run keeps both manifests ──────────────
# A consumer's confirmed plane manifest (commands filled in) and the provisioned
# code manifest are theirs — a second run refreshes the deployed core shell but must
# never rewrite either manifest.
printf '%s\n' "$(jq '.commands.test = "MINE"' "$M")" > "$M"   # simulate a consumer edit
run_split "$PROD" --language node --test "npm test" >/dev/null 2>"$WORK/e3"
[ "$(jq -r '.commands.test' "$M" 2>/dev/null)" = MINE ] \
  && ok "re-run keeps the consumer-edited plane manifest (deploy-once, no clobber)" \
  || no "re-run clobbered the plane manifest"

# ── T4 — class flip parity: the manifest scaffold-split writes matches the
# roots resolve-stack.sh proposes for the SAME publishable product. The two
# surfaces of the deliverable (proposal + scaffold) must agree on the named-map
# shape, or a consumer who confirms the proposal then runs the scaffold gets a
# different manifest than they approved. ──
RESOLVE="$ROOT/.claude/resolve-stack.sh"
if [ -f "$RESOLVE" ]; then
  PROP=$(bash "$RESOLVE" --greenfield widget --class publishable 2>/dev/null)
  PROP_ROOTS=$(echo "$PROP" | jq -S '.roots')
  SCAF_ROOTS=$(jq -S '.roots' "$WORK/proj1/widget-guv/.claude/project.json" 2>/dev/null)
  # Re-derive the scaffold's pristine roots from a fresh run (T3 edited commands,
  # not roots, but be explicit): compare roots only.
  [ "$PROP_ROOTS" = "$SCAF_ROOTS" ] \
    && ok "scaffold roots == resolve-stack greenfield-publishable proposal roots (the two surfaces agree)" \
    || no "scaffold roots and the proposal roots diverge:\n    proposal: $PROP_ROOTS\n    scaffold: $SCAF_ROOTS"
else
  no "resolve-stack.sh missing — cannot check proposal/scaffold parity"
fi

# ── T5 — usage: no positional code-repo path → exit 2 (loud, not a silent default) ──
( run_split >/dev/null 2>&1 ); [ $? -eq 2 ] \
  && ok "no code-repo argument → exit 2 (usage)" \
  || no "missing code-repo argument must exit 2"

# ── T6 — --name overrides the product NAME only; roots.code's PATH tracks the
# REAL code repo. The code repo here sits at proj2/code but --name is 'gadget', so
# the plane is proj2/gadget-guv. --name must drive the plane name + map key +
# codePrimary, but the path must point at the actual repo (proj2/code) — NOT at a
# non-existent ../gadget sibling. provision-code-repo.sh provisions in place; it
# never renames the repo to match --name, so a path of "../gadget" would resolve to
# a directory that does not exist and break scaffoldCheck permanently. ──
PROD2="$WORK/proj2/code"; mkcoderepo "$PROD2"
PLANE2="$WORK/proj2/gadget-guv"
run_split "$PROD2" --name gadget >/dev/null 2>/dev/null
M2="$PLANE2/.claude/project.json"
[ -f "$M2" ] && [ "$(jq -r '.roots.codePrimary' "$M2" 2>/dev/null)" = gadget ] \
  && ok "--name overrides the product name (plane=gadget-guv, codePrimary=gadget)" \
  || no "--name must drive the plane name + codePrimary (got plane $(dirname "$(dirname "$M2")"), codePrimary '$(jq -r '.roots.codePrimary' "$M2" 2>/dev/null)')"
# Resolve roots.code.gadget.path RELATIVE TO THE PLANE and confirm it lands on the
# REAL code repo (proj2/code), not a phantom ../gadget. This is the discriminator
# for the path-vs-name bug: a path derived from --name fails here, one derived from
# the real basename passes.
CODE_PATH=$(jq -r '.roots.code.gadget.path' "$M2" 2>/dev/null)
RESOLVED=""; [ -n "$CODE_PATH" ] && [ "$CODE_PATH" != null ] && RESOLVED="$(cd "$PLANE2" 2>/dev/null && cd "$CODE_PATH" 2>/dev/null && pwd)"
PROD2_ABS="$(cd "$PROD2" && pwd)"
[ -n "$RESOLVED" ] && [ "$RESOLVED" = "$PROD2_ABS" ] \
  && ok "roots.code.gadget.path resolves to the REAL code repo, not a ../gadget phantom (path=$CODE_PATH)" \
  || no "roots.code.gadget.path must resolve to the real code repo $PROD2_ABS (path='$CODE_PATH' resolved to '${RESOLVED:-<nonexistent>}')"
# scaffoldCheck must key on that same real path — a check pointing at ../gadget can
# never pass (the dir does not exist), so the plane would read as un-scaffolded forever.
SCAFFOLD_CHECK=$(jq -r '.scaffoldCheck' "$M2" 2>/dev/null)
( cd "$PLANE2" && eval "$SCAFFOLD_CHECK" ) >/dev/null 2>&1 \
  && ok "scaffoldCheck passes from the plane (keys on the real code repo's .claude/)" \
  || no "scaffoldCheck must pass from the plane (got '$SCAFFOLD_CHECK')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
