#!/bin/bash
# Tests for [10.2] — manifest language truthfulness and a correct test command.
# A bash/jq/git project must be able to declare `language: shell`, which maps to
# the plain base image with NO language-specific firewall set. Guv's own manifest
# and the one setup-control-plane.sh generates must read `shell`, not the inherited
# `node`, and guv's commands.test must be the first-class bash runner, not `npm test`.
# Pure bash + jq, no test runner required. Run: bash .claude/tests/manifest-language.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"          # repo root (this file lives in .claude/tests/)
SCHEMA="$ROOT/.claude/project.schema.json"
MANIFEST="$ROOT/.claude/project.json"
MAKEFILE="$ROOT/Makefile"
FIREWALL="$ROOT/sandbox/init-firewall.sh"
SETUP="$ROOT/maintainers/setup-control-plane.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# ── T1 — the schema's language enum admits `shell` ─────────────────────────
# Acceptance: "the schema validates a manifest declaring language: shell". The
# enum is the gate (additionalProperties is false, so an undeclared value is
# rejected); assert `shell` is a member.
jq -e '.properties.language.enum | index("shell") != null' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema language enum includes shell" \
  || no "schema language enum must include shell"

# T1b — full structural validation: a complete manifest declaring language:shell
# must satisfy the schema (validate via python jsonschema, the one validator on
# PATH; assert the enum check is what's exercised by also rejecting a bogus value).
if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' 2>/dev/null; then
  MANI=$(jq -nc '{
    "$schema":"./project.schema.json", name:"shellproj", language:"shell",
    packageManager:null, roots:{control:".",code:"."},
    commands:{test:null,build:null,lint:null,format:null,dev:null,install:null},
    scaffoldCheck:"test -f Makefile", ceremony:"task"
  }')
  echo "$MANI" | python3 -c '
import json,sys,jsonschema
schema=json.load(open(sys.argv[1])); inst=json.load(sys.stdin)
jsonschema.validate(inst, schema)
' "$SCHEMA" 2>/dev/null \
    && ok "a full manifest with language:shell validates against the schema" \
    || no "a full manifest with language:shell must validate against the schema"
  # negative control: a bogus language must be REJECTED, proving the enum gate is live
  echo "$MANI" | jq '.language="cobol"' | python3 -c '
import json,sys,jsonschema
schema=json.load(open(sys.argv[1])); inst=json.load(sys.stdin)
try:
    jsonschema.validate(inst, schema); sys.exit(1)
except jsonschema.ValidationError:
    sys.exit(0)
' "$SCHEMA" 2>/dev/null \
    && ok "an undeclared language (cobol) is rejected (enum gate is live)" \
    || no "the enum gate must reject an undeclared language value"
else
  echo "  - python jsonschema unavailable — skipping structural validation (enum check above stands)"
fi

# ── T2 — base-image resolution maps shell → the plain Debian-slim image ─────
# Acceptance: "the base-image and firewall resolution maps shell to the plain
# image with no language firewall". The Makefile is the base-image resolver; it
# must carry a `shell)` case that selects the plain (language-runtime-free)
# image, distinct from the node fallback the `*)` arm uses. Extract the
# Makefile's `case "$(LANGUAGE)" in … esac` body and evaluate the real arms
# against LANGUAGE=shell (so the assertion tracks the actual case arm, not a
# re-implementation). $(LANGUAGE) (make) → $LANGUAGE (shell).
RESOLVED_IMG=$(
  LANGUAGE=shell
  # Pull the case body out of the make recipe: strip the `BASE_IMAGE ?= $(shell `
  # prefix down to `case`, drop the trailing `)` after `esac`, translate the make
  # variable $(LANGUAGE) → $LANGUAGE, and drop line-continuation backslashes.
  CASE_BLOCK=$(awk '/case "\$\(LANGUAGE\)" in/{p=1} p{print} /esac/{if(p)exit}' "$MAKEFILE" \
    | sed -E 's/^[^c]*case /case /; s/^([[:space:]]*esac\)).*/esac/; s/\$\(LANGUAGE\)/$LANGUAGE/g; s/\\[[:space:]]*$//')
  eval "$CASE_BLOCK" 2>/dev/null
)
case "$RESOLVED_IMG" in
  node:*|"" )
    no "Makefile must map language:shell to a plain image, got '${RESOLVED_IMG:-<empty>}' (falling through to node)" ;;
  * )
    # plain image: a Debian-slim base with no language runtime baked in.
    echo "$RESOLVED_IMG" | grep -qiE 'debian.*slim' \
      && ok "Makefile maps language:shell to the plain Debian-slim image ($RESOLVED_IMG)" \
      || no "language:shell should map to a plain debian-slim image, got '$RESOLVED_IMG'"
    ;;
esac

# ── T3 — firewall resolution: shell adds NO registry domains ───────────────
# Acceptance: "no language firewall" for shell. init-firewall.sh's case on
# LANGUAGE must give `shell` an EMPTY registry set — not fall through to the
# `*)` arm that defaults to npm. Derive the resolved registry set by sourcing
# only the case block against LANGUAGE=shell.
FW_REG=$(
  LANGUAGE=shell
  REGISTRY_DOMAINS=()
  # Extract the case statement (LANGUAGE) ... esac and evaluate it in isolation.
  CASE_BLOCK=$(awk '/^case "\$LANGUAGE" in/{p=1} p{print} /^esac/{if(p)exit}' "$FIREWALL")
  eval "$CASE_BLOCK" 2>/dev/null
  echo "${REGISTRY_DOMAINS[*]:-}"
)
if [ -z "$FW_REG" ]; then
  ok "firewall maps language:shell to an empty registry set (no language firewall)"
else
  no "language:shell must add no registry domains, got: $FW_REG"
fi
# Negative control: the npm default still fires for an unrecognized language,
# proving the shell arm is a real, distinct case and not a relaxation of the default.
FW_DEFAULT=$(
  LANGUAGE=totally-unknown-lang
  REGISTRY_DOMAINS=()
  CASE_BLOCK=$(awk '/^case "\$LANGUAGE" in/{p=1} p{print} /^esac/{if(p)exit}' "$FIREWALL")
  eval "$CASE_BLOCK" 2>/dev/null
  echo "${REGISTRY_DOMAINS[*]:-}"
)
echo "$FW_DEFAULT" | grep -q 'registry.npmjs.org' \
  && ok "an unrecognized language still defaults to npm (shell is a distinct arm)" \
  || no "the default npm fallback must remain for unrecognized languages"

# ── T4 — guv's own manifest reads language:shell, not node ─────────────────
# Acceptance: "guv's manifest ... read shell, not node".
[ "$(jq -r '.language' "$MANIFEST")" = "shell" ] \
  && ok "guv's .claude/project.json declares language:shell" \
  || no "guv's .claude/project.json must declare language:shell (got $(jq -r '.language' "$MANIFEST"))"

# T4b — truthfulness end to end: the deliverable is "manifest language
# truthfulness", and a manifest that declares `shell` while sibling fields still
# invoke npm against a repo with no package.json is the exact vestige the
# deliverable names. guv has no package.json (it is a bash/jq/git project), so an
# npm package manager, npm-invoking commands, a package.json scaffoldCheck, a
# node_modules readyCheck, or an npm-publish guard would each be untruthful.
# Pin them so a half-revert (language fixed, vestiges restored) fails loudly.
[ ! -f "$ROOT/package.json" ] \
  && ok "guv has no package.json (a bash/jq/git project — npm fields would be vestigial)" \
  || no "guv unexpectedly has a package.json — re-evaluate the truthfulness assertions below"
[ "$(jq -r '.packageManager' "$MANIFEST")" = "null" ] \
  && ok "guv's packageManager is null (no package manager applies)" \
  || no "guv's packageManager must be null on a shell project (got $(jq -r '.packageManager' "$MANIFEST"))"
VEST=$(jq -r '[.commands.build, .commands.lint, .commands.format, .commands.dev,
               .commands.install, .scaffoldCheck, .readyCheck] | map(select(. != null)) | .[]' "$MANIFEST" \
        | grep -iwE 'npm|npx|package\.json|node_modules' || true)
[ -z "$VEST" ] \
  && ok "guv's manifest carries no npm/package.json/node_modules vestige in its commands or checks" \
  || no "guv's manifest still carries npm vestiges against a repo with no package.json: $VEST"
jq -e '(.guards // []) | index("npm-publish") == null' "$MANIFEST" >/dev/null \
  && ok "guv's guards do not include npm-publish (no npm publish in a shell project)" \
  || no "guv's guards must not include npm-publish on a shell project"

# ── T5 — guv's commands.test is the bash runner, no npm ────────────────────
# Acceptance: "commands.test runs the bash suite with no npm invocation".
TESTCMD=$(jq -r '.commands.test' "$MANIFEST")
echo "$TESTCMD" | grep -qE '\.claude/tests/\*\.test\.sh' \
  && ok "guv's commands.test runs the .claude/tests/*.test.sh suite" \
  || no "guv's commands.test must run the .claude/tests/*.test.sh bash suite (got: $TESTCMD)"
echo "$TESTCMD" | grep -qiw 'npm' \
  && no "guv's commands.test must not invoke npm (got: $TESTCMD)" \
  || ok "guv's commands.test invokes no npm"
# T5b — the stderr-capture gate must survive in commands.test. The whole point of
# replacing `npm test` was to match the runner CI uses (template-clean.yml), which
# fails a suite that writes to stderr — a vacuous guard that slipped two review
# gates is exactly what that gate exists to catch. A regression that kept the glob
# but dropped `2>"$err"` / `[ -s "$err" ]` would pass the checks above and silently
# lose the stderr firewall; assert both halves of the mechanism are present.
echo "$TESTCMD" | grep -qE '2>"\$err"' \
  && echo "$TESTCMD" | grep -qE '\[ -s "\$err" \]' \
  && ok "guv's commands.test keeps the stderr-capture gate (2>\$err + [ -s \$err ])" \
  || no "guv's commands.test must keep the stderr-capture gate (got: $TESTCMD)"

# ── T6 — the manifest setup-control-plane.sh generates reads shell, not node ─
# Acceptance: "the manifest setup-control-plane.sh generates ... read shell".
# Grep the generator's hardcoded jq literal for the language value.
GEN_LANG=$(awk '/jq -n/,/> "\$DEST\/.claude\/project.json"/' "$SETUP" \
  | grep -E 'language:' | head -1 | sed -E 's/.*language:[[:space:]]*"([^"]*)".*/\1/')
[ "$GEN_LANG" = "shell" ] \
  && ok "setup-control-plane.sh generates a manifest with language:shell" \
  || no "setup-control-plane.sh must generate language:shell (got '${GEN_LANG:-<none>}')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
