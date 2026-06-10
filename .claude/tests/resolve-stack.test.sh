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

# ── schema alignment: every emitted key is declared (guards additionalProperties:false) ──
J=$(propose "$ND")
UNKNOWN_TOP=$(comm -23 <(echo "$J" | jq -r 'keys[]' | sort) <(jq -r '.properties|keys[]' "$SCHEMA" | sort))
[ -z "$UNKNOWN_TOP" ] && ok "schema: no undeclared top-level keys" || no "schema: undeclared top-level: $UNKNOWN_TOP"
UNKNOWN_CMD=$(comm -23 <(echo "$J" | jq -r '.commands|keys[]' | sort) <(jq -r '.properties.commands.properties|keys[]' "$SCHEMA" | sort))
[ -z "$UNKNOWN_CMD" ] && ok "schema: no undeclared commands keys" || no "schema: undeclared commands: $UNKNOWN_CMD"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
