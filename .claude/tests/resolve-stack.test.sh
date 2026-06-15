#!/bin/bash
# Tests for .claude/resolve-stack.sh — detect-to-propose stack manifest.
# Pure bash + jq, no test runner required. Run: bash .claude/tests/resolve-stack.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # .claude/
RESOLVER="$ROOT/resolve-stack.sh"
SCHEMA="$ROOT/project.schema.json"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

propose() { bash "$RESOLVER" "$1" 2>/dev/null; }            # → JSON on stdout
field() { echo "$1" | jq -r "$2"; }

# jsonschema validator (the one on PATH; the guv idiom from manifest-language /
# roots-map tests). The greenfield split proposal must validate against the
# named-map allOf, not just "have the right fields" — so we check it when the
# validator is present and skip cleanly when it isn't.
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

# ── node (pnpm lockfile + scripts + prettier) ──────────────────────────────
ND="$WORK/node"; mkdir -p "$ND"
cat > "$ND/package.json" <<'JSON'
{"name":"web","private":false,"scripts":{"test":"vitest","build":"tsc","dev":"vite"},"devDependencies":{"prettier":"^3"}}
JSON
touch "$ND/pnpm-lock.yaml"
J=$(propose "$ND")
[ "$(field "$J" .language)" = node ]                 && ok "node: language" || no "node: language ($(field "$J" .language))"
[ "$(field "$J" .packageManager)" = pnpm ]           && ok "node: pnpm from lockfile" || no "node: packageManager"
[ "$(field "$J" .readyCheck)" = "test -d node_modules" ] && ok "node: readyCheck" || no "node: readyCheck ($(field "$J" .readyCheck))"
[ "$(field "$J" .commands.install)" = "pnpm install" ]   && ok "node: commands.install" || no "node: install ($(field "$J" .commands.install))"
[ "$(field "$J" .commands.test)" = "pnpm test" ]     && ok "node: commands.test from script" || no "node: test ($(field "$J" .commands.test))"
echo "$J" | jq -e '.guards | index("npm-publish")' >/dev/null && ok "node: npm-publish guard (not private)" || no "node: guard"

# ── python (uv lockfile, distributable) ────────────────────────────────────
PY="$WORK/py"; mkdir -p "$PY"
printf '[project]\nname="svc"\n' > "$PY/pyproject.toml"; touch "$PY/uv.lock"
J=$(propose "$PY")
[ "$(field "$J" .language)" = python ]               && ok "python: language" || no "python: language"
[ "$(field "$J" .packageManager)" = uv ]             && ok "python: uv from lockfile" || no "python: pm"
[ "$(field "$J" .readyCheck)" = "test -d .venv" ]    && ok "python: readyCheck .venv" || no "python: readyCheck"
[ "$(field "$J" .commands.install)" = "uv sync" ]    && ok "python: install uv sync" || no "python: install ($(field "$J" .commands.install))"
[ "$(field "$J" .commands.build)" = null ]           && ok "python: build null (interpreted)" || no "python: build"
echo "$J" | jq -e '.guards | index("pypi-publish")' >/dev/null && ok "python: pypi-publish guard" || no "python: guard"

# ── rust (no readyCheck / no install expected) ─────────────────────────────
RS="$WORK/rs"; mkdir -p "$RS"; printf '[package]\nname="c"\n' > "$RS/Cargo.toml"
J=$(propose "$RS")
[ "$(field "$J" .language)" = rust ]                 && ok "rust: language" || no "rust: language"
[ "$(field "$J" .readyCheck)" = null ]               && ok "rust: readyCheck null (tools global)" || no "rust: readyCheck"
[ "$(field "$J" .commands.install)" = null ]         && ok "rust: install null" || no "rust: install"

# ── no recognizable stack → exit 2 ─────────────────────────────────────────
# A bare directory — no stack of its own AND no control-plane marker — is still the
# undetectable case (exit 2). The split detection below must NOT swallow this:
# it keys on a real control-plane STRUCTURE (a stackless .claude/ plane carrying
# the run-core-tests.sh marker beside a single stack-bearing sibling), not on
# "stackless" alone and not on the dir's name.
mkdir -p "$WORK/empty"
( bash "$RESOLVER" "$WORK/empty" >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "no-stack: exit 2" || no "no-stack: expected exit 2"

# ── control-plane / code split detection ([11.4]) ───────────────────────────
# A control plane (setup-control-plane.sh's <project>-guv) carries the guv core in
# .claude/ but has NO code stack of its own — the code lives in a sibling repo.
# Pointed at the control root, the resolver used to either exit 2 (no stack here)
# or — pointed at the sibling — propose roots.code='.' (single-repo, blind to the
# split). It must instead detect the split: resolve the stack FROM the sibling, and
# emit roots.code pointing at it with commands resolved from it.
#
# Detection is STRUCTURAL, never name-based: the resolver may not re-derive the
# <project>-guv convention by name (docs-sweep T6 — the manifest is the sole
# machine pointer). The structural marker is .claude/run-core-tests.sh, which
# setup-control-plane.sh writes into every control plane and into no code repo.
# The fixture is faithful to that: a control plane is a stackless .claude/ dir
# carrying that marker, beside exactly one stack-bearing sibling.
mk_control_plane() { mkdir -p "$1/.claude"; : > "$1/.claude/run-core-tests.sh"; }  # the structural marker
SPLIT="$WORK/split"; mkdir -p "$SPLIT/widget"; mk_control_plane "$SPLIT/widget-guv"
printf '[package]\nname="widget"\n' > "$SPLIT/widget/Cargo.toml"     # the code half (a real stack)
# the control half: a marked, stackless .claude/ plane
J=$(propose "$SPLIT/widget-guv")
# (a) NOT exit 2 — the split is detected, a proposal is produced
[ -n "$J" ] && ok "split: control root yields a proposal (not exit 2)" \
  || no "split: control root produced no proposal (regressed to exit 2)"
# (b) roots.code points at the sibling code repo, NOT '.'
[ "$(field "$J" .roots.code)" = "../widget" ] \
  && ok "split: roots.code → sibling (../widget), not '.'" \
  || no "split: roots.code must be '../widget' (got '$(field "$J" .roots.code)')"
# (c) roots.control stays the control plane itself ('.')
[ "$(field "$J" .roots.control)" = "." ] \
  && ok "split: roots.control stays '.'" \
  || no "split: roots.control must be '.' (got '$(field "$J" .roots.control)')"
# (d) commands are resolved from the SIBLING's stack (rust), not absent
[ "$(field "$J" .language)" = rust ] \
  && ok "split: language resolved from sibling (rust)" \
  || no "split: language must be rust from sibling (got '$(field "$J" .language)')"
[ "$(field "$J" .commands.test)" = "cargo test" ] \
  && ok "split: commands.test resolved from sibling (cargo test)" \
  || no "split: commands.test must be 'cargo test' from sibling (got '$(field "$J" .commands.test)')"
# (e) the split proposal still validates: no undeclared keys, roots present
echo "$J" | jq -e '.roots | has("control") and has("code")' >/dev/null \
  && ok "split: roots object well-formed" || no "split: roots object malformed"
UNKNOWN_SPLIT=$(comm -23 <(echo "$J" | jq -r 'keys[]' | sort) <(jq -r '.properties|keys[]' "$SCHEMA" | sort))
[ -z "$UNKNOWN_SPLIT" ] && ok "split: no undeclared top-level keys" || no "split: undeclared top-level: $UNKNOWN_SPLIT"

# (f) a GENUINE single-repo with a stack of its own is unchanged — roots.code='.'.
# This is the discriminator: detection must NOT fire just because a sibling
# exists; it fires only for a stackless control plane. A repo that HAS a stack
# resolves itself, single-repo, exactly as today (the rust/node/python cases
# above already assert roots.code via the schema default '.', re-pinned here).
[ "$(field "$(propose "$RS")" .roots.code)" = "." ] \
  && ok "single-repo: stack-bearing repo stays roots.code='.' (split detection does not over-fire)" \
  || no "single-repo: a stack-bearing repo must stay roots.code='.' (got '$(field "$(propose "$RS")" .roots.code)')"

# (g) detection is STRUCTURAL, not NAME-based — the load-bearing discriminator.
# A '-guv'-named dir that LACKS the run-core-tests.sh marker must NOT be treated
# as a control plane (it would exit 2); and a control plane bearing the marker
# must be detected REGARDLESS of its name. A regression to name-parsing fails one
# of these two.
#   (g1) '-guv' name but no marker → undetectable (exit 2), not a false split.
NAMED="$WORK/named-nomarker"; mkdir -p "$NAMED/thing" "$NAMED/thing-guv/.claude"
printf '[package]\nname="thing"\n' > "$NAMED/thing/Cargo.toml"
( bash "$RESOLVER" "$NAMED/thing-guv" >/dev/null 2>&1 ); [ $? -eq 2 ] \
  && ok "split: '-guv' name without the marker does NOT fire (structural, not name-based)" \
  || no "split: a '-guv' name alone must not be treated as a control plane (exit 2 expected)"
#   (g2) marker present but NON-'-guv' name → still detected (name is irrelevant).
PLAIN="$WORK/plain-marker"; mkdir -p "$PLAIN/app"; mk_control_plane "$PLAIN/ops"
printf '[package]\nname="app"\n' > "$PLAIN/app/Cargo.toml"
JG=$(propose "$PLAIN/ops")
[ "$(field "$JG" .roots.code)" = "../app" ] \
  && ok "split: marker on a non-'-guv'-named dir is still detected (roots.code=../app)" \
  || no "split: detection must key on the marker, not the name (got roots.code '$(field "$JG" .roots.code)')"

# ── greenfield proactive split proposal ([11.5]) ────────────────────────────
# [11.4] detects an EXISTING split (both repos on disk). [11.5] adds the
# PROACTIVE proposal: pointed at a GREENFIELD product (no stack files yet), the
# resolver proposes a split for a publishable/standalone product and single-repo
# for an internal app. The class is a JUDGMENT the human supplies (rule 12 — the
# resolver never guesses publishable-vs-internal); given the class, the proposal
# is deterministic. The signal is --greenfield <name> --class <class>.
#
# Why these tests, not "emits something": the WHOLE deliverable is that the SAME
# resolver, handed the same greenfield product, flips its roots proposal on the
# class — a split (named-map roots, codePrimary set, code path = ../<name>) for
# publishable/standalone and single-repo (roots.code='.') for internal. A change
# that proposed split for both classes, or single-repo for both, passes a shallow
# "runs" test and fails the discriminators below.

# (a) publishable greenfield → split: named-map roots.code with codePrimary,
# the code repo a sibling (../<name>), control stays '.'. This is the literal
# "split by default" claim made true.
JG=$(bash "$RESOLVER" --greenfield widget --class publishable 2>/dev/null)
[ -n "$JG" ] && ok "greenfield publishable: a proposal is produced (not exit 2)" \
  || no "greenfield publishable: produced no proposal"
[ "$(field "$JG" '.roots.code | type')" = object ] \
  && ok "greenfield publishable: roots.code is a named map (the [11.2] forward shape)" \
  || no "greenfield publishable: roots.code must be a named map (got type '$(field "$JG" '.roots.code | type')')"
[ "$(field "$JG" '.roots.codePrimary')" = widget ] \
  && ok "greenfield publishable: codePrimary names the product (widget)" \
  || no "greenfield publishable: codePrimary must be 'widget' (got '$(field "$JG" '.roots.codePrimary')')"
[ "$(field "$JG" '.roots.code.widget.path')" = "../widget" ] \
  && ok "greenfield publishable: code repo is the sibling ../widget" \
  || no "greenfield publishable: code path must be '../widget' (got '$(field "$JG" '.roots.code.widget.path')')"
[ "$(field "$JG" '.roots.control')" = "." ] \
  && ok "greenfield publishable: control stays '.'" \
  || no "greenfield publishable: control must be '.' (got '$(field "$JG" '.roots.control')')"
[ "$(field "$JG" '.name')" = widget ] \
  && ok "greenfield publishable: name is the product name" \
  || no "greenfield publishable: name must be 'widget' (got '$(field "$JG" '.name')')"
[ "$(field "$JG" '.ceremony')" = phased ] \
  && ok "greenfield publishable: ceremony=phased (greenfield builds structure)" \
  || no "greenfield publishable: ceremony must be 'phased' (got '$(field "$JG" '.ceremony')')"

# (b) standalone is the same class as publishable → split (both get the sibling).
JS=$(bash "$RESOLVER" --greenfield mylib --class standalone 2>/dev/null)
[ "$(field "$JS" '.roots.code | type')" = object ] \
  && [ "$(field "$JS" '.roots.code.mylib.path')" = "../mylib" ] \
  && ok "greenfield standalone: same as publishable → split (../mylib)" \
  || no "greenfield standalone: must propose a split like publishable (got roots.code '$(field "$JS" .roots.code)')"

# (c) internal greenfield → single-repo: roots.code='.', NO codePrimary. This is
# the discriminator — the class genuinely changes the proposal.
JI=$(bash "$RESOLVER" --greenfield internalapp --class internal 2>/dev/null)
[ "$(field "$JI" '.roots.code')" = "." ] \
  && ok "greenfield internal: roots.code='.' (single-repo, the class flip discriminator)" \
  || no "greenfield internal: roots.code must be '.' for an internal app (got '$(field "$JI" .roots.code)')"
[ "$(field "$JI" '.roots.codePrimary')" = null ] \
  && ok "greenfield internal: no codePrimary (string roots.code forbids it — schema if/then)" \
  || no "greenfield internal: codePrimary must be absent for single-repo (got '$(field "$JI" .roots.codePrimary)')"

# (d) the split proposal VALIDATES against the schema — including the named-map
# allOf (codePrimary required iff roots.code is a map, and it must be a key of
# the map). A regression that emitted a map without codePrimary, or a codePrimary
# naming a non-existent repo, fails the schema here, not at a consumer.
if [ "$HAVE_JSONSCHEMA" -eq 1 ]; then
  printf '%s' "$JG" | validates \
    && ok "greenfield publishable: split proposal validates against the schema (named-map allOf)" \
    || no "greenfield publishable: split proposal must validate against project.schema.json"
  printf '%s' "$JI" | validates \
    && ok "greenfield internal: single-repo proposal validates against the schema" \
    || no "greenfield internal: single-repo proposal must validate against project.schema.json"
else
  echo "  - jsonschema unavailable — greenfield schema-validation checks skipped"
fi

# (e) no undeclared keys on the split proposal (additionalProperties:false guard,
# same as the detected-stack proposals above) — covers the named-map branch.
UNKNOWN_GF=$(comm -23 <(echo "$JG" | jq -r 'keys[]' | sort) <(jq -r '.properties|keys[]' "$SCHEMA" | sort))
[ -z "$UNKNOWN_GF" ] && ok "greenfield: split proposal has no undeclared top-level keys" || no "greenfield: undeclared top-level: $UNKNOWN_GF"

# (f) an unknown --class is a loud stop (exit 2), never a silent default to one
# topology — guessing the topology on a typo is the improvised path rule 15 bans.
( bash "$RESOLVER" --greenfield widget --class bogus >/dev/null 2>&1 ); [ $? -eq 2 ] \
  && ok "greenfield: unknown --class → exit 2 (loud stop, no silent topology default)" \
  || no "greenfield: an unknown --class must exit 2, not guess a topology"

# (g) --greenfield without --class is incomplete → exit 2 (the class is the whole
# judgment; defaulting it silently is what this deliverable exists to make explicit).
( bash "$RESOLVER" --greenfield widget >/dev/null 2>&1 ); [ $? -eq 2 ] \
  && ok "greenfield: missing --class → exit 2 (the class is required, never defaulted)" \
  || no "greenfield: --greenfield without --class must exit 2"

# (h) back-compat: the greenfield flags are ADDITIVE — a bare positional invocation
# (detect-from-files) is byte-for-byte unchanged. The rust fixture re-proposed here
# must be identical with and without the new code paths in the file.
[ "$(field "$(propose "$RS")" .roots.code)" = "." ] \
  && [ "$(field "$(propose "$RS")" .language)" = rust ] \
  && ok "back-compat: bare positional detect-from-files unchanged by the greenfield path" \
  || no "back-compat: the greenfield flags must not alter detect-from-files proposals"

# ── ceremony detection ([10.7]): onboard adopts an already-phased repo ───────
# The resolver keys ceremony on the TARGET repo's tracker grammar, not a
# filename guess — a live DAG-grammar PHASE_STATUS.md routes to `phased`
# (adopt the existing plan); no phase docs, or a pre-grammar token-free
# (LEGACY) tracker, stays `onboard`.

# (a) no phase docs → onboard (the unchanged path — node fixture has no docs/)
[ "$(field "$(propose "$ND")" .ceremony)" = onboard ] \
  && ok "ceremony: no phase docs → onboard (unchanged path)" \
  || no "ceremony: no-phase-docs repo must propose onboard (got $(field "$(propose "$ND")" .ceremony))"

# (b) live DAG-grammar tracker → phased (adopt, don't impose onboard scaffold)
PH="$WORK/phased"; mkdir -p "$PH/docs"
printf '[package]\nname="planned"\n' > "$PH/Cargo.toml"
printf '## Phase 1\n- ⬜ **[1.1]** lay the foundation `[deps: none]`\n- ✅ **[1.2]** prior work `[deps: 1.1]`\n' > "$PH/docs/PHASE_STATUS.md"
[ "$(field "$(propose "$PH")" .ceremony)" = phased ] \
  && ok "ceremony: live DAG-grammar tracker → phased (adopt existing plan)" \
  || no "ceremony: already-phased repo must propose phased (got $(field "$(propose "$PH")" .ceremony))"

# (c) LEGACY token-free tracker → onboard (not the DAG grammar; don't adopt)
LG="$WORK/legacy"; mkdir -p "$LG/docs"
printf '[package]\nname="legacy"\n' > "$LG/Cargo.toml"
printf '## Phase 1\n- ⬜ Build the thing\n- ✅ Did a thing\n' > "$LG/docs/PHASE_STATUS.md"
[ "$(field "$(propose "$LG")" .ceremony)" = onboard ] \
  && ok "ceremony: pre-grammar (LEGACY) tracker → onboard (not DAG grammar)" \
  || no "ceremony: LEGACY tracker must stay onboard (got $(field "$(propose "$LG")" .ceremony))"

# (d) MALFORMED tracker (DAG IDs present but a broken deps token, resolver exit 5)
# → onboard ceremony (schema-valid default) AND a loud MALFORMED warning on
# stderr. This is the "clearly mid-plan-but-broken" repo that route.sh's exit-5
# loud stop never sees (route.sh keys on an existing manifest; a no-manifest
# onboard never reaches it), so the resolver must not silently scaffold over it
# (rule 15). The stderr warning is what makes this mutation-killing — a naive
# silent fall-through (treating exit 5 like exit 4) passes the ceremony check but
# fails the warning assertion.
ML="$WORK/malformed"; mkdir -p "$ML/docs"
printf '[package]\nname="midplan"\n' > "$ML/Cargo.toml"
printf '## Phase 1\n- ⬜ **[1.1]** broken token `[deps: bogus]`\n' > "$ML/docs/PHASE_STATUS.md"
[ "$(field "$(propose "$ML")" .ceremony)" = onboard ] \
  && ok "ceremony: MALFORMED tracker → onboard (schema-valid default, not phased)" \
  || no "ceremony: MALFORMED tracker must stay onboard (got $(field "$(propose "$ML")" .ceremony))"
bash "$RESOLVER" "$ML" 2>&1 >/dev/null | grep -qi 'MALFORMED' \
  && ok "ceremony: MALFORMED tracker emits a loud warning (no silent overwrite)" \
  || no "ceremony: MALFORMED tracker must warn loudly on stderr (rule 15)"

# ── schema alignment: every emitted key is declared (guards additionalProperties:false) ──
J=$(propose "$ND")
UNKNOWN_TOP=$(comm -23 <(echo "$J" | jq -r 'keys[]' | sort) <(jq -r '.properties|keys[]' "$SCHEMA" | sort))
[ -z "$UNKNOWN_TOP" ] && ok "schema: no undeclared top-level keys" || no "schema: undeclared top-level: $UNKNOWN_TOP"
UNKNOWN_CMD=$(comm -23 <(echo "$J" | jq -r '.commands|keys[]' | sort) <(jq -r '.properties.commands.properties|keys[]' "$SCHEMA" | sort))
[ -z "$UNKNOWN_CMD" ] && ok "schema: no undeclared commands keys" || no "schema: undeclared commands: $UNKNOWN_CMD"

# The phased branch ([10.7]) is a distinct emission path — assert IT too aligns
# (same key shape, and the ceremony it emits is in the schema enum). A future
# divergence in the phased branch's JSON shape, or a ceremony value the schema
# rejects, fails here rather than at a consumer.
JP=$(propose "$PH")
UNKNOWN_TOP_PH=$(comm -23 <(echo "$JP" | jq -r 'keys[]' | sort) <(jq -r '.properties|keys[]' "$SCHEMA" | sort))
[ -z "$UNKNOWN_TOP_PH" ] && ok "schema: phased proposal has no undeclared top-level keys" || no "schema: phased undeclared top-level: $UNKNOWN_TOP_PH"
jq -e --arg c "$(field "$JP" .ceremony)" '.properties.ceremony.enum | index($c)' "$SCHEMA" >/dev/null \
  && ok "schema: phased proposal's ceremony is in the schema enum" || no "schema: ceremony '$(field "$JP" .ceremony)' not in schema enum"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
