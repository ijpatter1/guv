#!/bin/bash
# Tests for .claude/render-status.sh — the status.json renderer ([6.5] of the
# plan-as-data spec, post-A-001 wording). The renderer consumes [6.6]'s
# status.json ONLY — it never parses the tracker (the A-001 one-parser
# decision); absent or malformed input refuses loud pointing at
# `resolve-ready.sh --json`, never a tracker-parsing fallback (rule 15: the
# designed path, not an invented recovery). The output is ONE self-contained
# status.html: JSON data island, vanilla JS rendering client-side, hand-rolled
# SVG via topological layers, no framework / CDN / build step / server.
#
# What this suite asserts statically: exit codes and refusal text, data-island
# fidelity (island == input, byte-honest escaping), frontier agreement with
# the resolver via the shared JSON (the regression tripwire the acceptance
# demands), self-containment (no fetching constructs), determinism (same JSON
# in -> same bytes out), argument grammar closed at every position, and the
# zero-machine-consumers acceptance grep. What it cannot assert: the
# browser-side DOM result of the island's JS — that is vanilla client-side
# JS by design, and a bash suite does not execute it. The structural halves
# (mode branch present, list path present, edges drawn only from deps) are
# asserted on the template text; visual correctness is a UAT artifact.
# Pure bash + jq + grep, no test runner. Run: bash .claude/tests/render-status.test.sh
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/render-status.sh"
RESOLVER="$(cd "$(dirname "$0")/.." && pwd)/resolve-ready.sh"
CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$CLAUDE_DIR/.." && pwd)"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# The suite (like the script it tests, which refuses by name) needs jq — say
# so instead of dying mid-SETUP with a resolver error that hides the cause.
if ! command -v jq >/dev/null 2>&1; then
  echo "  ✗ SETUP: jq is required (by this suite's fixtures and by render-status.sh itself) — install jq"
  echo ""
  echo "Results: 0 passed, 1 failed"
  exit 1
fi

val() { echo "$2" | grep -E "^$1=" | head -1 | sed "s/^$1=//"; }

# Extract the data island's JSON line and undo the `</` -> `<\/` embedding
# escape (valid JSON either way — the escape exists so tracker text can never
# smuggle a premature </script> into the island).
island() { sed -n '/id="status-data"/{n;p;}' | sed 's|<\\/|</|g'; }

# ── Fixture: a GRAMMAR tracker exercising every status. Hand-computed
# frontier: in_progress=6.2, ready=6.3 (deps ✅), blocked=6.4:6.2,
# serial=6.2 (first 🔄). 6.5 is ❌ descoped; 7.1 sits outside the current
# phase. The renderer gets this AS status.json via the resolver — the suite
# itself exercises the one sanctioned production chain.
cat > "$WORK/own.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 6 — Plan as Data**

## Phase 6 — Plan as Data

- ✅ **[6.1]** Grammar amendment `[deps: none]`
- 🔄 **[6.2]** Resolver `[deps: 6.1]`
- ⬜ **[6.3]** Mutation primitive `[deps: 6.1]`
- ⬜ **[6.4]** Docs sweep `[deps: 6.2]`
- ❌ **[6.5]** Descoped render `[deps: none]`

## Phase 7 — Execution Surfaces

- ⬜ **[7.1]** Plumbing extraction `[deps: none]`
MD

cat > "$WORK/legacy.md" <<'MD'
# Phase Status Tracker

## Phase 1 — Foundation

- ✅ First thing built
- 🔄 Second thing in flight
- ⬜ Third thing waiting
MD

bash "$RESOLVER" "$WORK/own.md" --json > "$WORK/own.json" 2>/dev/null \
  || { echo "  ✗ SETUP: resolver failed on own fixture"; exit 1; }
bash "$RESOLVER" "$WORK/legacy.md" --json > "$WORK/legacy.json" 2>/dev/null \
  || { echo "  ✗ SETUP: resolver failed on legacy fixture"; exit 1; }
SHELL_OUT=$(bash "$RESOLVER" "$WORK/own.md" 2>/dev/null)

# ── T1 — happy path: one HTML document on stdout, exit 0.
HTML=$(bash "$SCRIPT" "$WORK/own.json" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "render: exit 0 on resolver-produced status.json" \
  || no "render must exit 0 on valid input (rc=$RC: $(echo "$HTML" | head -2))"
echo "$HTML" | head -1 | grep -q '^<!DOCTYPE html>' \
  && ok "render: output is an HTML document (doctype first)" \
  || no "output must start with <!DOCTYPE html> (got: $(echo "$HTML" | head -1))"
[ "$(echo "$HTML" | grep -c '<html')" -eq 1 ] && [ "$(echo "$HTML" | grep -c '</html>')" -eq 1 ] \
  && ok "render: exactly one document" || no "expected exactly one <html>…</html>"

# ── T2 — data-island fidelity: the island IS the input, structurally.
ISLAND=$(echo "$HTML" | island)
echo "$ISLAND" | jq -e . >/dev/null 2>&1 \
  && ok "island: parses as valid JSON" || no "data island must be valid JSON"
[ "$(echo "$ISLAND" | jq -S .)" = "$(jq -S . "$WORK/own.json")" ] \
  && ok "island: structurally equal to the input status.json" \
  || no "island must carry the input JSON unmodified (jq -S diff non-empty)"

# ── T3 — the acceptance tripwire: rendered frontier == resolver's frontier.
# Agreement is structural via the shared JSON; asserted anyway so a regression
# in either half of the chain trips here.
[ "$(echo "$ISLAND" | jq -r '.frontier.ready | join(" ")')" = "$(val ready "$SHELL_OUT")" ] \
  && ok "tripwire: island ready == resolver ready" \
  || no "island frontier.ready must equal the resolver's ready="
[ "$(echo "$ISLAND" | jq -r '.frontier.in_progress | join(" ")')" = "$(val in_progress "$SHELL_OUT")" ] \
  && ok "tripwire: island in_progress == resolver in_progress" \
  || no "island frontier.in_progress must equal the resolver's in_progress="
[ "$(echo "$ISLAND" | jq -r '.frontier.blocked | map(.id + ":" + .blocked_by) | join(" ")')" = "$(val blocked "$SHELL_OUT")" ] \
  && ok "tripwire: island blocked == resolver blocked (id:root)" \
  || no "island frontier.blocked must equal the resolver's blocked="
[ "$(echo "$ISLAND" | jq -r '.frontier.serial // ""')" = "$(val serial "$SHELL_OUT")" ] \
  && ok "tripwire: island serial == resolver serial" \
  || no "island frontier.serial must equal the resolver's serial="

# ── T4 — self-contained: no fetching construct of any kind. The only
# tolerated URL literal is the SVG namespace constant (an identifier the
# browser never fetches).
echo "$HTML" | grep -Eiq '<script[^>]*src=|<link|<img|<iframe|@import|url\(|fetch\(|XMLHttpRequest|import\(|navigator\.sendBeacon' \
  && no "output must contain no fetching constructs (script src/link/img/iframe/@import/url()/fetch/XHR/dynamic import/beacon)" \
  || ok "self-contained: no fetching constructs"
EXTERNAL=$(echo "$HTML" | grep -Eo 'https?://[^"'"'"' ]*' | grep -v 'www\.w3\.org/2000/svg' || true)
[ -z "$EXTERNAL" ] \
  && ok "self-contained: no URL literals beyond the SVG namespace constant" \
  || no "unexpected URL literal(s): $EXTERNAL"

# ── T5 — the view's vocabulary: all four statuses are styled, the ready
# frontier is visually distinguished as its own thing, and the in-page JS
# builds SVG namespaced (hand-rolled DAG, no framework).
for cls in done in_progress todo descoped; do
  echo "$HTML" | grep -q "status-$cls" \
    && ok "vocabulary: status class 'status-$cls' present" \
    || no "template must style status '$cls' (expected token status-$cls)"
done
echo "$HTML" | grep -q 'is-ready' \
  && ok "vocabulary: ready-frontier distinction present (is-ready)" \
  || no "ready frontier must be visually distinguished (expected token is-ready)"
echo "$HTML" | grep -q 'createElementNS' \
  && ok "vocabulary: SVG built via createElementNS (hand-rolled, client-side)" \
  || no "DAG must be hand-rolled SVG built client-side (createElementNS)"
echo "$HTML" | grep -Eq "createElement\(['\"]ol['\"]\)" \
  && ok "vocabulary: LEGACY ordered-list path present in the renderer JS" \
  || no "LEGACY branch must render an ordered list (createElement('ol'))"
echo "$HTML" | grep -q 'is-blocked' \
  && ok "vocabulary: blocked nodes carry a standing visual mark (is-blocked)" \
  || no "blocked deliverables must be marked without requiring hover (expected token is-blocked)"
echo "$HTML" | grep -q "'next:'" \
  && ok "vocabulary: LEGACY strip shows the one real signal (next:)" \
  || no "LEGACY frontier strip must render next: instead of empty GRAMMAR fields"
[ "$(echo "$HTML" | grep -c 'buildLegend(')" -eq 3 ] \
  && ok "vocabulary: legend built in both mode branches (one definition, two calls)" \
  || no "buildLegend must be defined once and called from both LEGACY and DAG paths"

# ── T5b — the renderer JS parses as JavaScript. The page renders client-side
# by design, so the bash suite cannot execute it — but a syntax error that
# blanks every render is catchable here. node is NOT a harness runtime dep:
# skip cleanly (loudly) if absent, same idiom as evaluate-parallel.test.sh.
# Deeper DOM-level verification lives in maintainers/render-smoke.js (dev
# tool, run manually).
if command -v node >/dev/null 2>&1; then
  echo "$HTML" | awk '/^<script>$/{f=1;next} /^<\/script>$/{f=0} f' > "$WORK/inline.js"
  [ -s "$WORK/inline.js" ] && node --check "$WORK/inline.js" >/dev/null 2>&1 \
    && ok "renderer JS parses as JavaScript (node --check)" \
    || no "node --check failed — the in-page renderer has a syntax error"
else
  echo "  - node not installed — skipping renderer-JS syntax check"
fi

# ── T6 — LEGACY input: exit 0, island mode LEGACY, deps honestly empty
# (degrade gracefully — edges are never invented from document order).
LHTML=$(bash "$SCRIPT" "$WORK/legacy.json" 2>&1); LRC=$?
[ "$LRC" -eq 0 ] && ok "legacy: exit 0" || no "LEGACY input must render (rc=$LRC)"
LISLAND=$(echo "$LHTML" | island)
[ "$(echo "$LISLAND" | jq -r '.mode')" = "LEGACY" ] \
  && ok "legacy: island mode=LEGACY" || no "island must carry mode LEGACY"
echo "$LISLAND" | jq -e '[.deliverables[].deps] | all(. == [])' >/dev/null 2>&1 \
  && ok "legacy: island deps all empty — no edges to draw, none invented" \
  || no "LEGACY island must carry empty deps arrays only"

# ── T7 — determinism: same JSON in, same bytes out. (Determinism is GIVEN
# the input — the generation timestamp lives in the JSON, not the template,
# so regenerating status.json legitimately changes the render.)
bash "$SCRIPT" "$WORK/own.json" > "$WORK/r1.html" 2>/dev/null
bash "$SCRIPT" "$WORK/own.json" > "$WORK/r2.html" 2>/dev/null
cmp -s "$WORK/r1.html" "$WORK/r2.html" \
  && ok "determinism: byte-identical renders for identical input" \
  || no "two renders of the same status.json must be byte-identical"

# ── T8 — absent input refuses loud and points at the designed producer.
# NEVER a tracker-parsing fallback: the resolver is the grammar's only
# implementation, and this script consuming the tracker would be a second.
E=$(bash "$SCRIPT" "$WORK/nope.json" 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 4 ] && ok "absent: exit 4 on missing input file" \
  || no "missing input must exit 4 (rc=$RC)"
echo "$E" | grep -q "resolve-ready.sh" && echo "$E" | grep -q -- "--json" \
  && ok "absent: refusal points at resolve-ready.sh --json (the designed path)" \
  || no "refusal must name the producer: resolve-ready.sh --json (got: $E)"
rm -f "$WORK/status.json"
E2=$(cd "$WORK" && bash "$SCRIPT" 2>&1 >/dev/null); RC2=$?
[ "$RC2" -eq 4 ] && echo "$E2" | grep -q "status.json" \
  && ok "absent: no-arg default is ./status.json, refusal names it" \
  || no "no-arg form must default to status.json and exit 4 when absent (rc=$RC2: $E2)"

# ── T9 — malformed input refuses loud: not-JSON and wrong-shape both exit 5
# with the problem named. A renderer must not render garbage quietly.
echo "this is not json" > "$WORK/garbage.json"
E=$(bash "$SCRIPT" "$WORK/garbage.json" 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 5 ] && echo "$E" | grep -qi "not valid JSON" \
  && ok "malformed: non-JSON exits 5, problem named" \
  || no "non-JSON input must exit 5 naming the problem (rc=$RC: $E)"
echo '{"unrelated": true}' > "$WORK/shape.json"
E=$(bash "$SCRIPT" "$WORK/shape.json" 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 5 ] && echo "$E" | grep -q "mode" \
  && ok "malformed: wrong shape exits 5 naming the missing field" \
  || no "shape violation must exit 5 naming what's missing (rc=$RC: $E)"
# Valid JSON that is not an object must fail CLOSED — jq field access errors
# on arrays and scalars, and a swallowed jq error must read as a shape
# violation, never as a pass (the broken-page-under-exit-0 class).
for nonobj in '[1,2,3]' '42'; do
  printf '%s\n' "$nonobj" > "$WORK/nonobj.json"
  E=$(bash "$SCRIPT" "$WORK/nonobj.json" 2>&1 >/dev/null); RC=$?
  [ "$RC" -eq 5 ] && echo "$E" | grep -qi "object" \
    && ok "malformed: non-object JSON ($nonobj) exits 5 — the shape gate fails closed" \
    || no "non-object JSON $nonobj must exit 5 naming the problem (rc=$RC: $E)"
done
# A concatenated multi-document stream: per-document checks key to the LAST
# document and would pass — the gate counts documents slurped instead.
cat "$WORK/own.json" "$WORK/own.json" > "$WORK/twodocs.json"
E=$(bash "$SCRIPT" "$WORK/twodocs.json" 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 5 ] && echo "$E" | grep -q "2 JSON documents" \
  && ok "malformed: multi-document stream exits 5 naming the count" \
  || no "two concatenated documents must exit 5, not ship an unparseable island (rc=$RC: $E)"

# ── T10 — argument grammar closed at every position (allow-list = the
# documented grammar: one optional positional, nothing else).
E=$(bash "$SCRIPT" --bogus 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 2 ] && echo "$E" | grep -q -- "--bogus" \
  && ok "grammar: flag-shaped \$1 refuses loud (exit 2, offender named)" \
  || no "unknown flag must exit 2 naming itself (rc=$RC: $E)"
E=$(bash "$SCRIPT" "$WORK/own.json" extra 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 2 ] && echo "$E" | grep -q "extra" \
  && ok "grammar: second positional refuses loud" \
  || no "a second argument must exit 2 naming itself (rc=$RC: $E)"
E=$(bash "$SCRIPT" "$WORK/own.json" --json 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 2 ] \
  && ok "grammar: flag-shaped \$2 refuses loud (nothing is silently ignored)" \
  || no "a flag in position 2 must exit 2 (rc=$RC: $E)"

# ── T11 — jq is the guarded dependency, refused loud before any output
# (the silently-empty-render failure class).
E=$(PATH=/nonexistent /bin/bash "$SCRIPT" "$WORK/own.json" 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 2 ] && echo "$E" | grep -qi "requires jq" \
  && ok "deps: missing jq refuses loud (exit 2, dependency named)" \
  || no "missing jq must exit 2 naming the dependency (rc=$RC: $E)"

# ── T12 — island escaping: tracker text can never close the island early.
# Hand-crafted JSON is legitimate here — the contract is the shape, and the
# escape must hold for ANY text the grammar might carry.
jq '.deliverables[1].text = "evil </script><script>alert(1)</script> text"' \
  "$WORK/own.json" > "$WORK/evil.json"
EHTML=$(bash "$SCRIPT" "$WORK/evil.json" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "escape: hostile text still renders (exit 0)" \
  || no "hostile text must not break the render (rc=$RC)"
RAW_ISLAND=$(echo "$EHTML" | sed -n '/id="status-data"/{n;p;}')
echo "$RAW_ISLAND" | grep -q '</script>' \
  && no "raw island must carry no literal </script> — the escape failed" \
  || ok "escape: no literal </script> inside the island"
CLOSES=$(echo "$EHTML" | grep -c '</script>')
[ "$CLOSES" -eq 2 ] \
  && ok "escape: exactly the two real script closers survive" \
  || no "expected exactly 2 </script> closers (got $CLOSES)"
[ "$(echo "$EHTML" | island | jq -S .)" = "$(jq -S . "$WORK/evil.json")" ] \
  && ok "escape: hostile island round-trips intact" \
  || no "escaped island must still equal the input JSON"

# ── T13 — zero machine consumers (acceptance): nothing in any command, hook,
# skill, or test READS the render's output. Invoke-vs-consume is the
# distinction that must survive [6.7]: a hook that INVOKES render-status.sh
# (and redirects INTO status.html) is the designed regeneration path; a line
# that reads status.html as input is a machine consumer of a view and a
# violation. Exemption is by file path (the renderer's own copies, this
# suite, and the [6.7] hook suite that exercises fixture renders), not by
# line content — an invoking line elsewhere that also reads status.html back
# is caught. Legal mentions outside those files are the non-read forms the
# [6.7] regeneration hook uses — write-redirects, mv-to, git add/commit
# (recording, not reading), chmod (mode, not content), and echo
# announcements — each guarded against a same-line `<` read; plus comment
# lines, human doc prose under maintainers/*.md (neither executes), and the
# manifest `views` declaration literal (declares the surface, reads nothing).
# Anything else is a consumer.
CONSUMERS=$(grep -rn 'status\.html' \
    "$CLAUDE_DIR/commands" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/skills" \
    "$CLAUDE_DIR/agents" "$CLAUDE_DIR/rules" "$CLAUDE_DIR/workflows" \
    "$CLAUDE_DIR/tests" "$CLAUDE_DIR"/*.sh \
    "$ROOT/maintainers" "$ROOT/Makefile" "$ROOT/plugin" 2>/dev/null \
  | grep -Ev '^[^:]*/(render-status(\.test)?\.sh|render-hook\.test\.sh):' \
  | grep -Ev '^[^:]*/maintainers/[^:]*\.md:' \
  | grep -Ev '>[[:space:]]*[^[:space:]]*status\.html' \
  | grep -Ev '(mv |git add |git commit |chmod [0-9]+ |echo )[^<]*status\.html' \
  | grep -Ev '^[^:]*:[0-9]+:[[:space:]]*#' \
  | grep -Ev 'views: \{ status: "status\.html" \}' \
  || true)
[ -z "$CONSUMERS" ] \
  && ok "view: zero machine consumers of status.html (invoke/write-only mentions tolerated)" \
  || no "something consumes the render's output — a view must never be a source: $CONSUMERS"
PARSERS=$(grep -n 'status\.html' "$CLAUDE_DIR/render-status.sh" 2>/dev/null \
  | grep -Ev '^[0-9]+:[[:space:]]*#' || true)
[ -z "$PARSERS" ] \
  && ok "view: the renderer itself never reads status.html back (rebuilt, never line-merged)" \
  || no "render-status.sh must never read its own output: $PARSERS"

# ── T14 — the renderer never parses the tracker: no tracker-grammar regex,
# no tracker path, no marker glyphs anywhere in the script. This is the
# one-parser decision made grep-fast.
TRACKER_TOUCH=$(grep -nE 'PHASE_STATUS|deps:|⬜|✅|🔄|❌' "$CLAUDE_DIR/render-status.sh" 2>/dev/null \
  | grep -Ev '^[0-9]+:#' || true)
[ -z "$TRACKER_TOUCH" ] \
  && ok "one-parser: render-status.sh carries no tracker grammar (markers, tokens, tracker path)" \
  || no "the renderer must never parse the tracker: $TRACKER_TOUCH"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
