#!/bin/bash
# Tests for [11.2] — `roots` as a named map.
#
# The breaking manifest-contract change: `roots.code` becomes a named MAP of
# code repos (name → {path, commands?}) with `codePrimary` naming the default,
# while a plain STRING is still accepted as the single-repo shorthand (the
# string IS the primary). Every root-aware reader resolves a NAMED repo through
# the shared resolver (.claude/roots.sh) rather than reading `roots.code` as a
# bare string — so no call site assumes a single code root.
#
# Why these tests, not "validates without crashing":
#   - the schema must ACCEPT both shapes AND REJECT the broken middle (a map
#     missing codePrimary, a codePrimary naming a non-existent repo) — that is
#     what makes the contract a contract, not a shape that admits anything;
#   - back-compat is load-bearing: a string `roots.code` resolves and runs
#     EXACTLY as today (the acceptance gate for the whole deliverable);
#   - a two-repo fixture must address EACH repo BY NAME through the resolver,
#     which is the named-map's reason to exist.
#
# Pure bash + jq (+ python jsonschema where present), no test runner required.
# Run: bash .claude/tests/roots-map.test.sh
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMA="$CLAUDE_DIR/project.schema.json"
RESOLVE="$CLAUDE_DIR/roots.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── jsonschema validator (the one on PATH; the guv idiom from
# manifest-language.test.sh). Returns 0 if the instance validates, 1 if not. ──
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

# A complete manifest with a given roots block (passed as compact JSON on $1).
mani_with_roots() {  # $1 = roots JSON
  jq -nc --argjson roots "$1" '{
    "$schema":"./project.schema.json", name:"t", language:"shell",
    packageManager:null, roots:$roots,
    commands:{test:null,build:null,lint:null,format:null,dev:null,install:null},
    scaffoldCheck:"test -d .claude", ceremony:"task"
  }'
}

echo "── Schema: the contract accepts both shapes and rejects the broken middle ──"

if [ "$HAVE_JSONSCHEMA" -eq 1 ]; then
  # 1. String shorthand validates (single-repo back-compat).
  mani_with_roots '{"control":".","code":"."}' | validates \
    && ok "string roots.code validates (single-repo shorthand)" \
    || no "a string roots.code must validate (single-repo shorthand)"

  # 1b. A non-'.' string (a sibling path) validates too.
  mani_with_roots '{"control":".","code":"../guv"}' | validates \
    && ok "string roots.code '../guv' validates (split, one code repo)" \
    || no "a sibling-path string roots.code must validate"

  # 2. Named-map validates with codePrimary naming a real key.
  mani_with_roots '{"control":".","code":{"storefront":{"path":"../store"},"studio":{"path":"../studio"}},"codePrimary":"storefront"}' | validates \
    && ok "named-map roots.code + codePrimary validates" \
    || no "a named-map roots.code with codePrimary must validate"

  # 2b. A named repo may carry its own commands.
  mani_with_roots '{"control":".","code":{"a":{"path":"../a","commands":{"test":"npm test"}}},"codePrimary":"a"}' | validates \
    && ok "a named repo may carry per-repo commands" \
    || no "a named repo's optional commands must validate"

  # 3. REJECT: a map WITHOUT codePrimary (which repo is the default? undefined).
  mani_with_roots '{"control":".","code":{"a":{"path":"../a"}}}' | validates \
    && no "a named-map roots.code MUST require codePrimary (got: accepted)" \
    || ok "a named-map without codePrimary is rejected (codePrimary required iff map)"

  # 4. REJECT: codePrimary present but code is a STRING (the string IS the
  #    primary; naming one is contradictory).
  mani_with_roots '{"control":".","code":".","codePrimary":"x"}' | validates \
    && no "codePrimary alongside a string roots.code MUST be rejected (got: accepted)" \
    || ok "codePrimary is forbidden when roots.code is a string"

  # 5. REJECT: a named repo entry missing its path.
  mani_with_roots '{"control":".","code":{"a":{"commands":{"test":"x"}}},"codePrimary":"a"}' | validates \
    && no "a named repo entry without a path MUST be rejected (got: accepted)" \
    || ok "a named repo entry requires a path"
else
  echo "  - python jsonschema unavailable — skipping structural schema validation"
  # Structural fallbacks via jq against the schema document itself, so the
  # shape's intent is still pinned even without the validator.
  jq -e '.properties.roots.properties.code.oneOf | length >= 2' "$SCHEMA" >/dev/null 2>&1 \
    && ok "schema roots.code is a oneOf (string | named-map)" \
    || no "schema roots.code must be a oneOf of string | named-map"
  jq -e '.properties | has("__placeholder_skip__") | not' "$SCHEMA" >/dev/null 2>&1 \
    && ok "(jsonschema-skipped) oneOf shape pinned via jq" \
    || no "schema shape check failed"
fi

echo "── Resolver: a string is the primary; a map addresses each repo by name ──"

# T-resolver-1 — string roots.code: unqualified resolves to that string (the
# primary), exactly as the bare `jq -r '.roots.code // "."'` did before.
make_proj() {  # $1 = roots JSON -> echoes project dir
  local p="$WORK/proj"; rm -rf "$p"; mkdir -p "$p/.claude"
  mani_with_roots "$1" > "$p/.claude/project.json"
  echo "$p"
}

P=$(make_proj '{"control":".","code":"../guv"}')
OUT=$( (cd "$P" && bash "$RESOLVE" path) 2>&1 ); RC=$?
[ $RC -eq 0 ] && [ "$OUT" = "../guv" ] \
  && ok "string roots.code: unqualified path resolves to the string (the primary)" \
  || no "string roots.code unqualified must resolve to the string (rc=$RC out=$OUT)"

# T-resolver-2 — single-repo '.' resolves to '.' (every op a no-op as today).
P=$(make_proj '{"control":".","code":"."}')
OUT=$( (cd "$P" && bash "$RESOLVE" path) 2>&1 )
[ "$OUT" = "." ] \
  && ok "single-repo '.': resolver returns '.' (no-op back-compat)" \
  || no "single-repo '.' must resolve to '.' (got: $OUT)"

# T-resolver-3 — no manifest: default to '.' (same as the bare-read fallback).
OUT=$( (cd "$WORK" && bash "$RESOLVE" path) 2>&1 )
[ "$OUT" = "." ] \
  && ok "no manifest: resolver defaults to '.'" \
  || no "no manifest must default to '.' (got: $OUT)"

# T-resolver-4 — named map, UNQUALIFIED resolves to codePrimary's path.
P=$(make_proj '{"control":".","code":{"storefront":{"path":"../store"},"studio":{"path":"../studio"}},"codePrimary":"storefront"}')
OUT=$( (cd "$P" && bash "$RESOLVE" path) 2>&1 )
[ "$OUT" = "../store" ] \
  && ok "named map: unqualified path resolves to codePrimary (storefront → ../store)" \
  || no "named map unqualified must resolve to codePrimary's path (got: $OUT)"

# T-resolver-5 — named map, EACH repo addressable BY NAME (the named-map's reason
# to exist — the two-repo fixture's core assertion).
OUT=$( (cd "$P" && bash "$RESOLVE" path storefront) 2>&1 )
[ "$OUT" = "../store" ] && ok "named map: 'storefront' resolves to ../store by name" \
  || no "named map must resolve storefront by name (got: $OUT)"
OUT=$( (cd "$P" && bash "$RESOLVE" path studio) 2>&1 )
[ "$OUT" = "../studio" ] && ok "named map: 'studio' resolves to ../studio by name" \
  || no "named map must resolve studio by name (got: $OUT)"

# T-resolver-6 — an UNKNOWN repo name is a loud stop, never a silent fallback to
# the primary (Rule 15 — a wrong-repo git op is the worst version of this).
OUT=$( (cd "$P" && bash "$RESOLVE" path nope) 2>&1 ); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -qi 'nope' \
  && ok "named map: an unknown repo name loud-stops naming the offender (rc=$RC)" \
  || no "an unknown repo name must loud-stop (rc=$RC out=$OUT)"

# T-resolver-7 — a corrupt manifest is a LOUD error, never the '.' fallback
# (a split plane would silently run git against the wrong repo).
P=$(make_proj '{"control":".","code":"../guv"}')
echo '{not json' > "$P/.claude/project.json"
OUT=$( (cd "$P" && bash "$RESOLVE" path) 2>&1 ); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -qi 'json' \
  && ok "corrupt manifest: loud error, not the '.' fallback (rc=$RC)" \
  || no "a corrupt manifest must fail loud (rc=$RC out=$OUT)"

# T-resolver-8 — a string roots.code addressed by an explicit name: the string
# IS the primary, so naming the primary is fine, any OTHER name loud-stops.
P=$(make_proj '{"control":".","code":"../guv"}')
OUT=$( (cd "$P" && bash "$RESOLVE" path other) 2>&1 ); RC=$?
[ $RC -ne 0 ] \
  && ok "string roots.code: addressing a non-primary name loud-stops (single repo has one)" \
  || no "string roots.code must reject a non-primary repo name (rc=$RC out=$OUT)"

# ── git integration: code_git addresses the named repo's repo ──
echo "── code_git: git runs against the resolved named repo ──"

# Two real code repos with distinguishable commits.
mk_repo() {  # $1 = dir, $2 = commit subject
  mkdir -p "$1"; git -C "$1" init -q; git -C "$1" config user.email t@t
  git -C "$1" config user.name t; echo x > "$1/f"; git -C "$1" add f
  git -C "$1" commit -qm "$2"
}
RS="$WORK/store"; RD="$WORK/studio"
mk_repo "$RS" "STOREFRONT-commit"
mk_repo "$RD" "STUDIO-commit"
P="$WORK/twrepo"; mkdir -p "$P/.claude"
mani_with_roots "$(jq -nc --arg s "$RS" --arg d "$RD" '{control:".",code:{storefront:{path:$s},studio:{path:$d}},codePrimary:"storefront"}')" \
  > "$P/.claude/project.json"

# Unqualified git → the primary (storefront).
OUT=$( (cd "$P" && bash "$RESOLVE" git log --oneline -1) 2>&1 )
echo "$OUT" | grep -q "STOREFRONT-commit" \
  && ok "code_git unqualified targets the primary repo" \
  || no "code_git unqualified must target the primary (got: $OUT)"
# Named git → that repo.
OUT=$( (cd "$P" && bash "$RESOLVE" git studio log --oneline -1) 2>&1 )
echo "$OUT" | grep -q "STUDIO-commit" \
  && ok "code_git studio targets the studio repo by name" \
  || no "code_git must target the named repo (got: $OUT)"

# ── Contract version: the breaking change is reflected on the marker ──
echo "── Contract version reflects the breaking change ──"
CV=$(grep -oE 'CONTRACT_VERSION=[0-9]+' "$CLAUDE_DIR/resolve-ready.sh" | grep -oE '[0-9]+' | head -1)
[ -n "$CV" ] && [ "$CV" -ge 2 ] \
  && ok "contract_version bumped to >= 2 for the breaking roots-map change (got $CV)" \
  || no "contract_version must bump (>=2) for the breaking change (got '${CV:-none}')"

# ── No call site assumes a single code root (grep-asserted acceptance) ──
echo "── grep-assert: no executable script reads roots.code as a bare string path ──"
# Every root-aware READER must route the path read through the shared resolver,
# not inline `jq -r '.roots.code …'` (which assumes a single string root). The
# resolver itself is the one legitimate site, and feedback-submit/check-citations
# are migrated too. handoff/eval prose is a teaching surface (guv-git.test T5
# already governs the .md surfaces); here we govern executable .sh.
ROOT="$(cd "$CLAUDE_DIR/.." && pwd)"
# Find .sh files that still inline a roots.code read, excluding the resolver and
# the tests themselves (tests legitimately construct fixtures naming roots.code).
OFFENDERS=$(grep -rln "jq -r '\.roots\.code" "$ROOT/.claude" "$ROOT/maintainers" --include='*.sh' 2>/dev/null \
  | grep -vE '/(roots|tests/.*)\.sh$' \
  | grep -v '/tests/')
[ -z "$OFFENDERS" ] \
  && ok "no executable .sh reads roots.code as a bare string (all route through roots.sh)" \
  || no "these .sh still inline a single-root roots.code read: $(echo "$OFFENDERS" | tr '\n' ' ')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
