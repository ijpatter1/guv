#!/bin/bash
# .claude/resolve-stack.sh
# Stack resolver — sniffs a repo and PROPOSES a project manifest (.claude/project.json).
#
# Detection BOOTSTRAPS the declaration; it never IS the declaration. The proposal is
# printed as JSON to stdout for a human to confirm or override; the confirmed manifest
# is authoritative thereafter. A human-readable summary is printed to stderr.
#
# Usage:
#   bash .claude/resolve-stack.sh [CODE_ROOT]      # CODE_ROOT defaults to "."
#   bash .claude/resolve-stack.sh ../store > /tmp/proposal.json
#
# Requires: jq (already a sandbox dependency).

set -euo pipefail

DIR="${1:-.}"
log() { echo "[resolve] $*" >&2; }

if [ ! -d "$DIR" ]; then
  log "ERROR: '$DIR' is not a directory"
  exit 1
fi

has() { [ -e "$DIR/$1" ]; }
# glob existence (e.g. *.csproj)
hasglob() { compgen -G "$DIR/$1" >/dev/null 2>&1; }

LANGUAGE=""
PACKAGE_MANAGER="null"
SCAFFOLD_CHECK=""
READY_CHECK="null"   # "tools installed/runnable" — distinct from scaffoldCheck; null = none
declare -a GUARDS=()
# command defaults; "null" (literal) means the project has no such step
CMD_TEST="null"; CMD_BUILD="null"; CMD_LINT="null"; CMD_FORMAT="null"; CMD_DEV="null"; CMD_INSTALL="null"
declare -a FMT_EXT=()

# JSON string or literal null
jstr() { if [ "$1" = "null" ]; then printf 'null'; else jq -Rn --arg s "$1" '$s'; fi; }

# ── Detect by manifest/lockfile presence (most specific first) ──────────────
if has package.json; then
  LANGUAGE="node"
  SCAFFOLD_CHECK="test -f package.json"
  READY_CHECK="test -d node_modules"   # deps installed (tools live in node_modules/.bin)
  # package manager from lockfile, then the packageManager field
  if   has pnpm-lock.yaml;     then PM="pnpm"
  elif has yarn.lock;         then PM="yarn"
  elif has bun.lockb;         then PM="bun"
  elif has package-lock.json; then PM="npm"
  else PM=$(jq -r '.packageManager // empty' "$DIR/package.json" 2>/dev/null | sed 's/@.*//'); PM="${PM:-npm}"
  fi
  PACKAGE_MANAGER="$PM"
  CMD_INSTALL="$PM install"   # remediation when node_modules is absent
  # propose commands from package.json scripts
  SCRIPTS=$(jq -r '(.scripts // {}) | keys[]' "$DIR/package.json" 2>/dev/null || true)
  hasscript() { echo "$SCRIPTS" | grep -qx "$1"; }
  runner() { case "$PM" in npm) echo "npm run $1";; *) echo "$PM run $1";; esac; }
  if hasscript test; then case "$PM" in npm) CMD_TEST="npm test";; *) CMD_TEST="$PM test";; esac; fi
  hasscript build && CMD_BUILD="$(runner build)"
  hasscript lint  && CMD_LINT="$(runner lint)"
  hasscript dev   && CMD_DEV="$(runner dev)"
  # formatter: prettier if present as a dep or config
  if jq -e '((.devDependencies // {}) + (.dependencies // {})) | has("prettier")' "$DIR/package.json" >/dev/null 2>&1 \
     || has .prettierrc || has .prettierrc.json || has .prettierrc.js || has prettier.config.js; then
    CMD_FORMAT="npx prettier --write"
  fi
  FMT_EXT=(js jsx ts tsx json css scss md html yml yaml)
  # publish guard unless explicitly private
  if ! jq -e '.private == true' "$DIR/package.json" >/dev/null 2>&1; then GUARDS+=("npm-publish"); fi

elif has pyproject.toml || has requirements.txt; then
  LANGUAGE="python"
  if has uv.lock;     then PACKAGE_MANAGER="uv";     CMD_INSTALL="uv sync"
  elif has poetry.lock; then PACKAGE_MANAGER="poetry"; CMD_INSTALL="poetry install"
  else PACKAGE_MANAGER="pip"; CMD_INSTALL="pip install -r requirements.txt"; fi
  has pyproject.toml && SCAFFOLD_CHECK="test -f pyproject.toml" || SCAFFOLD_CHECK="test -f requirements.txt"
  READY_CHECK="test -d .venv"   # tools typically live in a project venv; adjust if global
  CMD_TEST="pytest"
  CMD_BUILD="null"          # interpreted — no build step
  CMD_LINT="ruff check ."
  CMD_FORMAT="ruff format"  # auto-format hook appends the file path
  FMT_EXT=(py pyi md json yml yaml toml)
  # publish guard if it declares a distributable project
  if has pyproject.toml && grep -qE '^\[project\]|^\[tool\.poetry\]' "$DIR/pyproject.toml" 2>/dev/null; then GUARDS+=("pypi-publish"); fi

elif has Cargo.toml; then
  LANGUAGE="rust"; PACKAGE_MANAGER="cargo"
  SCAFFOLD_CHECK="test -f Cargo.toml"
  CMD_TEST="cargo test"; CMD_BUILD="cargo build"; CMD_LINT="cargo clippy"
  CMD_FORMAT="rustfmt"      # per-file; cargo fmt is whole-project
  FMT_EXT=(rs)
  grep -qE '^\[package\]' "$DIR/Cargo.toml" 2>/dev/null && GUARDS+=("cargo-publish")

elif has go.mod; then
  LANGUAGE="go"; PACKAGE_MANAGER="go"
  SCAFFOLD_CHECK="test -f go.mod"
  CMD_TEST="go test ./..."; CMD_BUILD="go build ./..."; CMD_LINT="go vet ./..."
  CMD_FORMAT="gofmt -w"
  FMT_EXT=(go)

elif has Gemfile; then
  LANGUAGE="ruby"; PACKAGE_MANAGER="bundler"
  SCAFFOLD_CHECK="test -f Gemfile"
  CMD_INSTALL="bundle install"
  CMD_TEST="bundle exec rspec"; CMD_LINT="bundle exec rubocop"
  CMD_FORMAT="bundle exec rubocop -A"   # auto-correct a single file
  FMT_EXT=(rb)
  hasglob "*.gemspec" && GUARDS+=("gem-publish")

elif has pom.xml; then
  LANGUAGE="jvm"; PACKAGE_MANAGER="maven"
  SCAFFOLD_CHECK="test -f pom.xml"
  CMD_TEST="mvn test"; CMD_BUILD="mvn package"
  FMT_EXT=(java kt)

elif has build.gradle || has build.gradle.kts; then
  LANGUAGE="jvm"; PACKAGE_MANAGER="gradle"
  has build.gradle.kts && SCAFFOLD_CHECK="test -f build.gradle.kts" || SCAFFOLD_CHECK="test -f build.gradle"
  CMD_TEST="./gradlew test"; CMD_BUILD="./gradlew build"
  FMT_EXT=(java kt)

elif hasglob "*.csproj" || hasglob "*.sln"; then
  LANGUAGE="dotnet"; PACKAGE_MANAGER="dotnet"
  SCAFFOLD_CHECK="ls *.csproj >/dev/null 2>&1 || ls *.sln >/dev/null 2>&1"
  CMD_TEST="dotnet test"; CMD_BUILD="dotnet build"; CMD_FORMAT="dotnet format"
  CMD_INSTALL="dotnet restore"
  FMT_EXT=(cs)

elif has mix.exs; then
  LANGUAGE="elixir"; PACKAGE_MANAGER="mix"
  SCAFFOLD_CHECK="test -f mix.exs"
  CMD_TEST="mix test"; CMD_BUILD="mix compile"; CMD_FORMAT="mix format"
  CMD_INSTALL="mix deps.get"
  FMT_EXT=(ex exs)

else
  log "Could not detect a known stack in '$DIR'."
  log "Looked for: package.json, pyproject.toml/requirements.txt, Cargo.toml, go.mod,"
  log "            Gemfile, pom.xml/build.gradle, *.csproj/*.sln, mix.exs."
  log "Declare the manifest by hand from .claude/project.schema.json."
  exit 2
fi

# ── Ceremony: adopt an already-phased repo, don't impose onboard over it ([10.7]).
# An existing repo that already carries a live phase plan is not pre-scaffold —
# onboarding scaffold over it would clobber the plan. Detection keys on the
# tracker GRAMMAR, not a filename guess: resolve-ready.sh reports mode=GRAMMAR
# only for a DAG-grammar tracker (a LEGACY token-free tracker, or none at all,
# stays onboard — the unchanged path). The resolver is the single grammar oracle
# (never re-parse the tracker here); if it is absent we degrade to onboard.
CEREMONY="onboard"
RESOLVER="$(cd "$(dirname "$0")" && pwd)/resolve-ready.sh"
if [ -f "$RESOLVER" ]; then
  if bash "$RESOLVER" "$DIR/docs/PHASE_STATUS.md" 2>/dev/null \
       | grep -qx 'mode=GRAMMAR'; then
    CEREMONY="phased"
  fi
fi

# ── Build the proposed manifest JSON ────────────────────────────────────────
FMT_JSON=$(printf '%s\n' "${FMT_EXT[@]}" | jq -R . | jq -s .)
GUARDS_JSON=$(if [ ${#GUARDS[@]} -eq 0 ]; then echo '[]'; else printf '%s\n' "${GUARDS[@]}" | jq -R . | jq -s .; fi)

jq -n \
  --arg name "$(basename "$(cd "$DIR" && pwd)")" \
  --arg language "$LANGUAGE" \
  --argjson packageManager "$(jstr "$PACKAGE_MANAGER")" \
  --argjson test "$(jstr "$CMD_TEST")" \
  --argjson build "$(jstr "$CMD_BUILD")" \
  --argjson lint "$(jstr "$CMD_LINT")" \
  --argjson format "$(jstr "$CMD_FORMAT")" \
  --argjson dev "$(jstr "$CMD_DEV")" \
  --argjson install "$(jstr "$CMD_INSTALL")" \
  --arg scaffoldCheck "$SCAFFOLD_CHECK" \
  --argjson readyCheck "$(jstr "$READY_CHECK")" \
  --argjson formatExtensions "$FMT_JSON" \
  --argjson guards "$GUARDS_JSON" \
  --arg ceremony "$CEREMONY" \
  '{
    "$schema": "./project.schema.json",
    name: $name,
    language: $language,
    packageManager: $packageManager,
    roots: { control: ".", code: "." },
    commands: { test: $test, build: $build, lint: $lint, format: $format, dev: $dev, install: $install },
    scaffoldCheck: $scaffoldCheck,
    readyCheck: $readyCheck,
    formatExtensions: $formatExtensions,
    guards: $guards,
    ceremony: $ceremony
  }'

log "Proposed: language=$LANGUAGE packageManager=$PACKAGE_MANAGER guards=[${GUARDS[*]:-}]"
log "This is a PROPOSAL. Confirm or override before writing .claude/project.json."
log "roots default to single-repo ('.'); set roots.code for a control-plane split."
if [ "$CEREMONY" = "phased" ]; then
  log "ceremony=phased — a live DAG-grammar tracker was detected at $DIR/docs/PHASE_STATUS.md; adopt the existing plan (resume/start-phase), do not impose onboard scaffold."
else
  log "ceremony defaults to 'onboard'; /init-project (/guv:init-project under the plugin) should set it to 'phased'."
fi
