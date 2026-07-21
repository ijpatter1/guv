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
#   # Greenfield proactive proposal ([11.5]) — no stack on disk yet; topology
#   # flips on the product CLASS, which is the human's judgment (rule 12 — the
#   # resolver never guesses publishable-vs-internal):
#   bash .claude/resolve-stack.sh --greenfield <name> --class <class>
#     <class> ∈ { publishable | standalone | internal }
#       publishable/standalone → SPLIT: roots.code is the named map
#         { <name>: { path: "../<name>" } } with codePrimary=<name>; the control
#         plane stays '.' and the product lives in its own sibling repo. This is
#         the literal "split by default" claim made true.
#       internal               → SINGLE-REPO: roots.code='.' (the framework files
#         riding along in one tree is harmless for an internal app).
#
# Requires: jq (already a sandbox dependency).

set -euo pipefail

log() { echo "[resolve] $*" >&2; }

# ── Argument parsing ────────────────────────────────────────────────────────
# Two mutually-exclusive modes:
#   1. positional CODE_ROOT (default ".")        — detect-from-files (the [11.4] path)
#   2. --greenfield <name> --class <class>       — proactive proposal ([11.5])
# The greenfield flags are ADDITIVE: a bare positional invocation is byte-for-byte
# the historical behavior, so every existing caller is untouched.
GF_NAME=""
GF_CLASS=""
DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --greenfield) [ $# -ge 2 ] || { log "ERROR: --greenfield needs a product name"; exit 2; }; GF_NAME="$2"; shift 2 ;;
    --class)      [ $# -ge 2 ] || { log "ERROR: --class needs a value (publishable|standalone|internal)"; exit 2; }; GF_CLASS="$2"; shift 2 ;;
    --*)          log "ERROR: unknown flag '$1' — usage: bash .claude/resolve-stack.sh [CODE_ROOT] | --greenfield <name> --class <class>"; exit 2 ;;
    *)            [ -z "$DIR" ] || { log "ERROR: unexpected extra argument '$1'"; exit 2; }; DIR="$1"; shift ;;
  esac
done

# ── Greenfield proactive proposal ([11.5]) ──────────────────────────────────
# Pointed at a GREENFIELD product (no stack files on disk), the resolver proposes
# a topology from the product CLASS rather than from detection: a SPLIT for a
# publishable/standalone artifact (it gets its own public repo, so the framework
# files must not pollute its history), single-repo for an internal app. The class
# is the human's judgment; given it, the proposal is a deterministic transform
# (rule 12 — no model in the loop). Greenfield is always ceremony=phased: an
# init-from-spec build is where structure is legitimately built (the resolver's
# detect path proposes 'onboard' for an existing repo; greenfield overrides it,
# matching /init which sets phased regardless).
if [ -n "$GF_NAME" ] || [ -n "$GF_CLASS" ]; then
  # Both halves are required — the class IS the judgment, so a bare --greenfield
  # with no class is incomplete; silently defaulting the topology is the
  # improvised path rule 15 bans. Refuse loud.
  [ -n "$GF_NAME" ]  || { log "ERROR: --class given without --greenfield <name>"; exit 2; }
  [ -n "$GF_CLASS" ] || { log "ERROR: --greenfield <name> given without --class (publishable|standalone|internal)"; exit 2; }
  [ -z "$DIR" ]      || { log "ERROR: --greenfield is exclusive with a positional CODE_ROOT (greenfield has no stack to detect)"; exit 2; }

  case "$GF_CLASS" in
    publishable|standalone)
      # SPLIT — named-map roots.code ([11.2] forward shape): the product is a
      # sibling repo, codePrimary names it. The control plane stays '.'.
      jq -n --arg name "$GF_NAME" \
        '{
          "$schema": "./project.schema.json",
          name: $name,
          language: "shell",
          packageManager: null,
          roots: { control: ".", code: { ($name): { path: ("../" + $name) } }, codePrimary: $name },
          commands: { test: null, build: null, lint: null, format: null, dev: null, install: null },
          scaffoldCheck: ("test -d \"../" + $name + "/.claude\""),
          readyCheck: null,
          formatExtensions: [],
          guards: [],
          ceremony: "phased"
        }'
      log "Greenfield SPLIT proposed for '$GF_NAME' (class=$GF_CLASS): control plane stays '.', product lives in sibling '../$GF_NAME' (named-map roots.code, codePrimary=$GF_NAME)."
      log "This is the split-by-default proposal — a publishable/standalone product gets its own repo so framework files never pollute its public history."
      ;;
    internal)
      # SINGLE-REPO — roots.code='.', no codePrimary (the schema forbids it when
      # roots.code is a string). Framework files riding along is harmless here.
      jq -n --arg name "$GF_NAME" \
        '{
          "$schema": "./project.schema.json",
          name: $name,
          language: "shell",
          packageManager: null,
          roots: { control: ".", code: "." },
          commands: { test: null, build: null, lint: null, format: null, dev: null, install: null },
          scaffoldCheck: "test -d .claude",
          readyCheck: null,
          formatExtensions: [],
          guards: [],
          ceremony: "phased"
        }'
      log "Greenfield SINGLE-REPO proposed for '$GF_NAME' (class=internal): framework files, docs, and product code share one tree."
      ;;
    *)
      log "ERROR: unknown --class '$GF_CLASS' — expected one of: publishable | standalone | internal"
      exit 2
      ;;
  esac
  log "This is a PROPOSAL. Confirm or override before writing .claude/project.json. language defaults to 'shell' — set it from the chosen stack."
  exit 0
fi

# Detect-from-files path ([11.4] and earlier): CODE_ROOT defaults to ".".
DIR="${DIR:-.}"

if [ ! -d "$DIR" ]; then
  log "ERROR: '$DIR' is not a directory"
  exit 1
fi

# TARGET is the directory whose STACK we resolve; ROOT_CODE is what we propose for
# roots.code (relative to the control plane = DIR). For a single repo these are the
# same place: TARGET=DIR, ROOT_CODE=".". For a control-plane/code split ([11.4])
# DIR is the stackless control plane and TARGET is its sibling code repo, so the
# stack is sniffed from the sibling while ROOT_CODE points at it.
TARGET="$DIR"
ROOT_CODE="."

has() { [ -e "$TARGET/$1" ]; }
# glob existence (e.g. *.csproj)
hasglob() { compgen -G "$TARGET/$1" >/dev/null 2>&1; }

# Does the given directory carry a recognizable code stack? (a manifest/lockfile any
# of the language branches below keys on). Used to tell a real code repo from a
# stackless control plane, without duplicating the per-language probe logic.
has_stack() {
  local d="$1"
  [ -e "$d/package.json" ] || [ -e "$d/pyproject.toml" ] || [ -e "$d/requirements.txt" ] \
    || [ -e "$d/Cargo.toml" ] || [ -e "$d/go.mod" ] || [ -e "$d/Gemfile" ] \
    || [ -e "$d/pom.xml" ] || [ -e "$d/build.gradle" ] || [ -e "$d/build.gradle.kts" ] \
    || [ -e "$d/mix.exs" ] \
    || compgen -G "$d/*.csproj" >/dev/null 2>&1 || compgen -G "$d/*.sln" >/dev/null 2>&1
}

# Is the given stackless .claude/ dir a guv CONTROL PLANE (its code lives in a
# sibling, so a split exists)? Two recognized signals, OR'd — both STRUCTURAL,
# never name-based (the manifest/marker is the machine pointer; name discovery is
# banned, docs-sweep T6):
#   (1) the UNIVERSAL manifest signal — .claude/project.json declares roots.code
#       pointing somewhere OTHER than '.' (resolved via the shared roots.sh, so a
#       string OR a named-map roots.code both work). This is the signal BOTH the
#       maintainer (setup-control-plane.sh: roots.code="../guv") AND the consumer
#       (scaffold-split.sh: roots.code={name:{path:"../name"}}) scaffolds write —
#       a single-repo plane has roots.code='.' and never matches, so it cannot
#       over-fire. This is the [11.5]-fix half: a consumer-scaffolded split, which
#       carries the manifest but NOT run-core-tests.sh, is now detectable.
#   (2) the legacy MARKER signal — .claude/run-core-tests.sh. setup-control-plane.sh
#       writes this into every dogfooding plane and into no code repo; it predates
#       the manifest signal and is kept for back-compat (a maintainer plane created
#       before this change, and the marker-based test/UAT fixtures, still detect
#       even with no manifest on disk).
ROOTS_SH="$(cd "$(dirname "$0")" && pwd)/roots.sh"
is_control_plane() {
  local d="$1" code
  [ -d "$d/.claude" ] || return 1
  # (2) legacy marker — cheap, no jq, keeps marker-only fixtures detecting.
  [ -f "$d/.claude/run-core-tests.sh" ] && return 0
  # (1) universal manifest signal: roots.code resolves to a non-'.' path. roots.sh
  # is the sole shape-aware resolver (string vs named map); a bad/absent manifest
  # or a single-repo '.' is NOT a control plane (it returns 1 / '.').
  [ -f "$ROOTS_SH" ] && [ -f "$d/.claude/project.json" ] || return 1
  code=$(ROOTS_MANIFEST="$d/.claude/project.json" bash "$ROOTS_SH" path 2>/dev/null) || return 1
  [ -n "$code" ] && [ "$code" != "." ]
}

# ── Control-plane / code split detection ([11.4], [11.5]) ───────────────────
# A control plane (created by setup-control-plane.sh OR the consumer scaffold-
# split.sh) carries the guv core in .claude/ but has NO code stack of its own —
# its code lives in a SIBLING repo. Pointed at such a control root the resolver
# would otherwise exit 2 (no stack here). Detect the split deterministically from
# STRUCTURE, never from the dir's NAME (name-based discovery is banned, docs-sweep
# T6 — the manifest/marker is the sole machine pointer). is_control_plane() above
# carries the two recognized structural signals (the universal manifest signal +
# the legacy marker); both maintainer and consumer planes match, a single-repo
# never does. That a split EXISTS is the signal; the code repo is then the SIBLING
# that carries a stack. To stay deterministic (rule 12 — no judgment) we retarget
# only when EXACTLY ONE sibling bears a stack; zero or several is ambiguous and
# falls through to the exit-2 loud stop (rule 15) rather than guessing. A DIR with
# its own stack is a single repo and never enters this branch (the has_stack guard),
# so a stack-bearing repo that merely sits beside others is untouched.
DIR_ABS="$(cd "$DIR" && pwd)"
if ! has_stack "$DIR" && is_control_plane "$DIR"; then
  # Find the sibling(s) that carry a code stack. Iterate immediate siblings of the
  # control plane (its parent's children, minus itself) — a structural scan, not a
  # name match. Collect every stack-bearing sibling so we can require exactly one.
  PARENT="$(cd "$DIR_ABS/.." && pwd)"
  declare -a CODE_SIBS=()
  for sib in "$PARENT"/*/; do
    sib="${sib%/}"
    [ "$sib" = "$DIR_ABS" ] && continue          # skip the control plane itself
    has_stack "$sib" && CODE_SIBS+=("$sib")
  done
  if [ "${#CODE_SIBS[@]}" -eq 1 ]; then
    SIBLING="${CODE_SIBS[0]}"
    TARGET="$SIBLING"
    # roots.code is the relative path from the control plane to the code repo —
    # the same shape setup-control-plane.sh writes (os.path.relpath).
    ROOT_CODE="../$(basename "$SIBLING")"
    log "Detected a control-plane/code split: '$(basename "$DIR_ABS")' is a stackless control plane (a split manifest or the run-core-tests.sh marker is present); resolving the stack from sibling code repo '$(basename "$SIBLING")'."
  fi
fi

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
  else PM=$(jq -r '.packageManager // empty' "$TARGET/package.json" 2>/dev/null | sed 's/@.*//'); PM="${PM:-npm}"
  fi
  PACKAGE_MANAGER="$PM"
  CMD_INSTALL="$PM install"   # remediation when node_modules is absent
  # propose commands from package.json scripts
  SCRIPTS=$(jq -r '(.scripts // {}) | keys[]' "$TARGET/package.json" 2>/dev/null || true)
  hasscript() { echo "$SCRIPTS" | grep -qx "$1"; }
  runner() { case "$PM" in npm) echo "npm run $1";; *) echo "$PM run $1";; esac; }
  if hasscript test; then case "$PM" in npm) CMD_TEST="npm test";; *) CMD_TEST="$PM test";; esac; fi
  hasscript build && CMD_BUILD="$(runner build)"
  hasscript lint  && CMD_LINT="$(runner lint)"
  hasscript dev   && CMD_DEV="$(runner dev)"
  # formatter: prettier if present as a dep or config
  if jq -e '((.devDependencies // {}) + (.dependencies // {})) | has("prettier")' "$TARGET/package.json" >/dev/null 2>&1 \
     || has .prettierrc || has .prettierrc.json || has .prettierrc.js || has prettier.config.js; then
    CMD_FORMAT="npx prettier --write"
  fi
  FMT_EXT=(js jsx ts tsx json css scss md html yml yaml)
  # publish guard unless explicitly private
  if ! jq -e '.private == true' "$TARGET/package.json" >/dev/null 2>&1; then GUARDS+=("npm-publish"); fi

elif has pyproject.toml || has requirements.txt; then
  LANGUAGE="python"
  if has uv.lock;     then PACKAGE_MANAGER="uv";     CMD_INSTALL="uv sync"
  elif has poetry.lock; then PACKAGE_MANAGER="poetry"; CMD_INSTALL="poetry install"
  else
    PACKAGE_MANAGER="pip"
    # Detect pyproject-vs-requirements rather than assuming requirements.txt: a bare
    # pip repo with only a pyproject installs from it (`-e .`), not from a file it lacks.
    if has requirements.txt; then CMD_INSTALL="pip install -r requirements.txt"
    else                          CMD_INSTALL="pip install -e ."; fi
  fi
  has pyproject.toml && SCAFFOLD_CHECK="test -f pyproject.toml" || SCAFFOLD_CHECK="test -f requirements.txt"
  READY_CHECK="test -d .venv"   # tools typically live in a project venv; adjust if global
  CMD_TEST="pytest"
  CMD_BUILD="null"          # interpreted — no build step
  # Propose ruff only when it is actually configured — report what the scan finds, not a
  # guess. Absent ruff config, leave lint/format unset (their "null" default) rather than
  # naming a linter the repo doesn't use.
  if has ruff.toml || has .ruff.toml \
     || { has pyproject.toml && grep -qE '^\[tool\.ruff(\.|\])' "$TARGET/pyproject.toml" 2>/dev/null; }; then  # bare [tool.ruff] or any [tool.ruff.*] subtable
    CMD_LINT="ruff check ."
    CMD_FORMAT="ruff format"  # auto-format hook appends the file path
  fi
  FMT_EXT=(py pyi md json yml yaml toml)
  # publish guard if it declares a distributable project
  if has pyproject.toml && grep -qE '^\[project\]|^\[tool\.poetry\]' "$TARGET/pyproject.toml" 2>/dev/null; then GUARDS+=("pypi-publish"); fi

elif has Cargo.toml; then
  LANGUAGE="rust"; PACKAGE_MANAGER="cargo"
  SCAFFOLD_CHECK="test -f Cargo.toml"
  CMD_TEST="cargo test"; CMD_BUILD="cargo build"; CMD_LINT="cargo clippy"
  CMD_FORMAT="rustfmt"      # per-file; cargo fmt is whole-project
  FMT_EXT=(rs)
  grep -qE '^\[package\]' "$TARGET/Cargo.toml" 2>/dev/null && GUARDS+=("cargo-publish")

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
#
# The resolver's EXIT CODE separates "no live plan" from "broken live plan":
# exit 4 (no tracker) and a LEGACY/GRAMMAR success (exit 0) are clean signals;
# exit 5 is a MALFORMED tracker — **[N.M]** IDs present but a token broken, i.e.
# clearly mid-plan-but-broken. A no-manifest repo never reaches route.sh's
# exit-5 loud stop (route.sh keys on an existing manifest; pre-scaffold defers to
# onboard), so onboard is the only layer that sees this state. We do NOT silently
# scaffold over it: ceremony stays the schema-valid `onboard` default, but a loud
# stderr warning names the broken-but-planned tracker so the operator confirms
# deliberately rather than clobbering a plan the resolver could not read
# (rule 15 — a designed loud stop, mirroring route.sh's MALFORMED refusal).
CEREMONY="onboard"
MALFORMED_TRACKER=""
RESOLVER="$(cd "$(dirname "$0")" && pwd)/resolve-ready.sh"
if [ -f "$RESOLVER" ]; then
  # The resolver exits non-zero for no-tracker (4) and MALFORMED (5); capture its
  # code without tripping `set -e` (the && true / || RRC=$? guard keeps the line's
  # own status 0 while RRC carries the resolver's exit).
  # In a split the plan lives in the CODE repo (TARGET), not the control plane;
  # for a single repo TARGET==DIR, so this is the same tracker as before.
  RRC=0
  RES=$(bash "$RESOLVER" "$TARGET/docs/PHASE_STATUS.md" 2>/dev/null) && true || RRC=$?
  if [ "$RRC" -eq 0 ] && printf '%s\n' "$RES" | grep -qx 'mode=GRAMMAR'; then
    CEREMONY="phased"
  elif [ "$RRC" -eq 5 ]; then
    MALFORMED_TRACKER="$TARGET/docs/PHASE_STATUS.md"
  fi
fi

# In a split, every command and check runs with cwd = the control plane (DIR), not
# the code repo (TARGET) — the manifest contract (schema, roots.code doc). So the
# scaffoldCheck ("does the project exist") must look under roots.code, not cwd: a
# bare `test -f Cargo.toml` would always fail from the control plane. Mirror
# setup-control-plane.sh's split manifest, which keys scaffoldCheck on the code
# repo. Single repo (ROOT_CODE='.') leaves the detected check untouched.
if [ "$ROOT_CODE" != "." ] && [ -n "$SCAFFOLD_CHECK" ]; then
  SCAFFOLD_CHECK="test -d \"$ROOT_CODE/.claude\" && (cd \"$ROOT_CODE\" && { $SCAFFOLD_CHECK; })"
fi

# ── Build the proposed manifest JSON ────────────────────────────────────────
FMT_JSON=$(printf '%s\n' "${FMT_EXT[@]}" | jq -R . | jq -s .)
GUARDS_JSON=$(if [ ${#GUARDS[@]} -eq 0 ]; then echo '[]'; else printf '%s\n' "${GUARDS[@]}" | jq -R . | jq -s .; fi)

jq -n \
  --arg name "$(basename "$(cd "$TARGET" && pwd)")" \
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
  --arg code "$ROOT_CODE" \
  '{
    "$schema": "./project.schema.json",
    name: $name,
    language: $language,
    packageManager: $packageManager,
    roots: { control: ".", code: $code },
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
  log "ceremony=phased — a live DAG-grammar tracker was detected at $TARGET/docs/PHASE_STATUS.md; adopt the existing plan (next/phase), do not impose onboard scaffold."
elif [ -n "$MALFORMED_TRACKER" ]; then
  log "WARNING: a phase tracker exists at $MALFORMED_TRACKER but is MALFORMED — it carries **[N.M]** IDs yet the resolver cannot parse it (run 'bash .claude/resolve-ready.sh $MALFORMED_TRACKER' to see the offenders). This repo is clearly mid-plan-but-broken, NOT pre-scaffold. ceremony stays 'onboard' so a proposal is still produced, but DO NOT scaffold over it: fix the tracker and re-run, or confirm deliberately that onboarding should clobber the broken plan (rule 15 — refuse-and-report over a silent overwrite)."
else
  log "ceremony defaults to 'onboard'; /init (/guv:init under the plugin) should set it to 'phased'."
fi
