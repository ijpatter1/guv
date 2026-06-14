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
mkdir -p "$WORK/empty"
( bash "$RESOLVER" "$WORK/empty" >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "no-stack: exit 2" || no "no-stack: expected exit 2"

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
