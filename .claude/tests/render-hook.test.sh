#!/bin/bash
# Tests for the [6.7] self-aware regeneration surface: the harness-owned
# post-commit hook that setup-control-plane.sh installs into a control
# plane's .git/hooks/, the schema-validated `views` manifest entry, and the
# publishing docs. The contract, per the A-001 insert:
#   - a commit touching the tracker yields a fresh committed render; the
#     follow-up render commit touches only the render target, so the trigger
#     check is itself the recursion break
#   - the hook is convenience, NEVER a dependency: jq absent, chain absent,
#     resolver refusal, detached HEAD — every rung degrades to a loud notice
#     and a clean exit; manual render always works with the hook absent
#   - `views` in project.json DESCRIBES the surface and never routes: no
#     execution path reads it, asserted by grep
#   - the Pages publishing path is documented where control-plane topology
#     is taught, with the access-control framing
# Pure bash + git + jq, no test runner. Run: bash .claude/tests/render-hook.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAL_SCRIPT="$ROOT/maintainers/setup-control-plane.sh"
CLAUDE_DIR="$ROOT/.claude"

# Maintainer tooling — a consumer repo that deleted maintainers/ still ships
# this suite, so skip cleanly instead of failing.
if [ ! -f "$REAL_SCRIPT" ]; then
  echo "  - maintainers/setup-control-plane.sh not present — skipping (consumer repo)"
  echo ""
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "  ✗ SETUP: jq is required (by the render chain this suite exercises) — install jq"
  echo ""
  echo "Results: 0 passed, 1 failed"
  exit 1
fi

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# ── Fixture harness: the real setup script plus the real render chain, so
# the hook the fixture control plane receives exercises the real machinery.
H="$WORK/harness"
mkdir -p "$H/maintainers" "$H/.claude/commands" "$H/.claude/skills" "$H/.claude/hooks"
cp "$REAL_SCRIPT" "$H/maintainers/"
cp "$CLAUDE_DIR/resolve-ready.sh" "$CLAUDE_DIR/render-status.sh" "$H/.claude/"
cp "$CLAUDE_DIR/project.schema.json" "$H/.claude/" 2>/dev/null || true

CP="$WORK/cp"
bash "$H/maintainers/setup-control-plane.sh" "$CP" > "$WORK/setup.log" 2>&1 \
  || { echo "  ✗ SETUP: control-plane create failed: $(cat "$WORK/setup.log")"; exit 1; }
git -C "$CP" config user.email t@t && git -C "$CP" config user.name t

HOOK="$CP/.git/hooks/post-commit"

# Write a well-formed GRAMMAR tracker into the fixture plane.
tracker() {
  mkdir -p "$CP/docs"
  cat > "$CP/docs/PHASE_STATUS.md" <<MD
# Phase Status Tracker

> **Current Phase: 1 — Fixture**

## Phase 1 — Fixture

- ✅ **[1.1]** First thing \`[deps: none]\`
- $1 **[1.2]** Second thing \`[deps: 1.1]\`
MD
}

# ── T1 — create mode installs the hook: executable, harness-owned, names
# its generator (the write_runner ownership convention).
[ -f "$HOOK" ] && ok "create: post-commit hook installed" \
  || no "create mode must install .git/hooks/post-commit"
[ -x "$HOOK" ] && ok "create: hook is executable" || no "hook must be executable"
grep -q 'Harness-owned' "$HOOK" 2>/dev/null \
  && ok "create: hook carries the Harness-owned marker" \
  || no "hook must be marked harness-owned (ownership convention)"
grep -q 'setup-control-plane.sh' "$HOOK" 2>/dev/null \
  && ok "create: hook names its generator" \
  || no "hook must say improve-the-generator, naming setup-control-plane.sh"
echo "$(cat "$WORK/setup.log")" | grep -qi 'post-commit' \
  && ok "create: installation announced" || no "create must announce the hook install"
# Pristine copy for assertions that must survive the later drift/foreign-hook
# fixtures (T8/T9 mutate $HOOK).
cp "$HOOK" "$WORK/generated-hook" 2>/dev/null

# ── T2 — the acceptance: a commit touching the tracker yields a fresh,
# COMMITTED render, and the follow-up commit breaks recursion by touching
# only the render target.
tracker "⬜"
( cd "$CP" && git add -A && git commit -qm "docs: tracker" ) > "$WORK/c1.log" 2>&1
[ -f "$CP/status.html" ] && ok "regen: tracker commit yields a fresh render" \
  || no "status.html must exist after a tracker-touching commit"
N=$(git -C "$CP" rev-list --count HEAD 2>/dev/null)
[ "$N" -eq 2 ] && ok "regen: exactly one follow-up render commit (recursion broken)" \
  || no "expected docs commit + render commit = 2 (got $N — recursion or no-op)"
LAST=$(git -C "$CP" log -1 --pretty=%s)
echo "$LAST" | grep -q 'render' \
  && ok "regen: HEAD is the render commit" || no "HEAD must be the render commit (got: $LAST)"
[ "$(git -C "$CP" diff-tree --no-commit-id --name-only -r HEAD)" = "status.html" ] \
  && ok "regen: render commit touches only the render target" \
  || no "render commit must touch status.html alone"
ISLAND=$(sed -n 2>/dev/null '/id="status-data"/{n;p;}' "$CP/status.html" | sed 's|<\\/|</|g')
[ "$(echo "$ISLAND" | jq -r '.frontier.ready | join(" ")')" = "1.2" ] \
  && ok "regen: rendered frontier matches the fixture tracker (ready=1.2)" \
  || no "render must be of the committed tracker (expected ready=1.2)"

# ── T3 — a commit not touching the tracker leaves the render alone.
cp "$CP/status.html" "$WORK/before.html" 2>/dev/null
( cd "$CP" && echo x > note.txt && git add note.txt && git commit -qm "chore: note" ) >/dev/null 2>&1
cmp -s "$CP/status.html" "$WORK/before.html" \
  && ok "scope: non-tracker commit leaves the render untouched" \
  || no "a non-tracker commit must not regenerate"
[ "$(git -C "$CP" log -1 --pretty=%s)" = "chore: note" ] \
  && ok "scope: no spurious render commit" || no "no render commit may follow a non-tracker commit"

# ── T4 — a tracker update refreshes the render (the new state is in the island).
tracker "✅"
( cd "$CP" && git add -A && git commit -qm "docs: 1.2 done" ) >/dev/null 2>&1
ISLAND=$(sed -n 2>/dev/null '/id="status-data"/{n;p;}' "$CP/status.html" | sed 's|<\\/|</|g')
[ "$(echo "$ISLAND" | jq -r '.frontier.ready | join(" ")')" = "" ] \
  && [ "$(echo "$ISLAND" | jq -r '.deliverables[1].status')" = "done" ] \
  && ok "regen: tracker update is reflected in the committed render" \
  || no "render must track the tracker (expected 1.2 done, empty ready)"

# ── T5 — resolver refusal: a malformed tracker must NOT replace the render,
# and the refusal is loud in the commit output.
cp "$CP/status.html" "$WORK/before.html" 2>/dev/null
cat > "$CP/docs/PHASE_STATUS.md" <<'MD'
## Phase 1 — Fixture

- ⬜ **[1.1]** Duplicate `[deps: none]`
- ⬜ **[1.1]** Duplicate `[deps: none]`
MD
( cd "$CP" && git add -A && git commit -m "docs: break tracker" ) > "$WORK/c5.log" 2>&1
cmp -s "$CP/status.html" "$WORK/before.html" \
  && ok "refusal: malformed tracker never replaces the render (stale beats broken)" \
  || no "a refused resolve must leave the previous render in place"
grep -qi 'NOT updated\|NOT regenerated' "$WORK/c5.log" \
  && ok "refusal: loud notice in the commit output" \
  || no "the hook must say loudly that the render was not updated (got: $(cat "$WORK/c5.log"))"
[ "$(git -C "$CP" log -1 --pretty=%s)" = "docs: break tracker" ] \
  && ok "refusal: no render commit on refusal" || no "no render commit may follow a refused render"
tracker "✅"
( cd "$CP" && git add -A && git commit -qm "docs: restore tracker" ) >/dev/null 2>&1

# ── T6 — jq absent: the hook degrades to a loud notice, no commit, exit 0.
# A minimal PATH (git/bash/coreutils, no jq) exercises the guard for real.
BIN="$WORK/bin"; mkdir -p "$BIN"
for tool in git bash grep sed mktemp mv rm cat chmod uname basename dirname sh; do
  p=$(command -v "$tool" 2>/dev/null) && ln -s "$p" "$BIN/$tool"
done
# Land a tracker-touching commit WITHOUT firing the real hook (empty hooks
# dir), so the manual restricted-PATH run below exercises the jq guard on a
# HEAD that genuinely triggers.
mkdir -p "$WORK/nohooks"
tracker "⬜"
( cd "$CP" && git add -A && git -c core.hooksPath="$WORK/nohooks" commit -qm "docs: staged for jq test" ) >/dev/null 2>&1
NBEFORE=$(git -C "$CP" rev-list --count HEAD)
OUT=$(cd "$CP" && PATH="$BIN" bash .git/hooks/post-commit 2>&1); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -qi 'jq' \
  && ok "degrade: jq absent — loud notice naming jq, clean exit" \
  || no "jq-absent hook run must notice loudly and exit 0 (rc=$RC: $OUT)"
[ "$(git -C "$CP" rev-list --count HEAD)" -eq "$NBEFORE" ] \
  && ok "degrade: jq absent — no commit created" || no "no commit may be created without jq"

# ── T6b — recording failure: the render succeeds but git add refuses (the
# target is gitignored AND untracked — ignore rules don't apply to tracked
# files, so untrack it first) — the success banner must NOT print; the
# failure is loud and no commit lands. The unconditional-success-banner class.
( cd "$CP" && git rm -q --cached status.html ) 2>/dev/null
cp "$CP/.gitignore" "$WORK/gitignore.orig" 2>/dev/null
echo "status.html" > "$CP/.gitignore"
tracker "✅"
( cd "$CP" && git add -A && git commit -m "docs: ignored target" ) > "$WORK/c6b.log" 2>&1
grep -qi 'recording FAILED' "$WORK/c6b.log" \
  && ok "degrade: recording failure is loud (no false success banner)" \
  || no "a failed git add/commit must say recording FAILED (got: $(tail -3 "$WORK/c6b.log"))"
grep -qi 'push to publish' "$WORK/c6b.log" \
  && no "the success banner printed on a failed recording" \
  || ok "degrade: success banner withheld on recording failure"
[ "$(git -C "$CP" log -1 --pretty=%s)" = "docs: ignored target" ] \
  && ok "degrade: no render commit on recording failure" \
  || no "no render commit may land when recording fails"
# Restore the generated .gitignore — later tests should run against the
# plane shape a real control plane has.
cp "$WORK/gitignore.orig" "$CP/.gitignore" 2>/dev/null || rm -f "$CP/.gitignore"

# ── T6c — render chain absent: loud notice naming the chain, no commit.
mv "$CP/.claude/render-status.sh" "$WORK/render-status.sh.bak"
tracker "⬜"
( cd "$CP" && git add -A && git commit -m "docs: chainless" ) > "$WORK/c6c.log" 2>&1
grep -qi 'render chain absent' "$WORK/c6c.log" \
  && ok "degrade: chain absent — loud notice naming the chain" \
  || no "a missing renderer must be named loudly (got: $(tail -2 "$WORK/c6c.log"))"
[ "$(git -C "$CP" log -1 --pretty=%s)" = "docs: chainless" ] \
  && ok "degrade: chain absent — no render commit" \
  || no "no render commit may land without the chain"
mv "$WORK/render-status.sh.bak" "$CP/.claude/render-status.sh"

# ── T6d — detached HEAD: never auto-commit there — silent clean skip even on
# a tracker-touching HEAD (the trigger check passes first by construction:
# T6c's HEAD touched the tracker).
( cd "$CP" && git checkout -q --detach ) 2>/dev/null
DOUT=$(cd "$CP" && bash .git/hooks/post-commit 2>&1); DRC=$?
DN=$(git -C "$CP" rev-list --count HEAD)
( cd "$CP" && git checkout -q - ) 2>/dev/null
[ "$DRC" -eq 0 ] && [ -z "$DOUT" ] \
  && ok "degrade: detached HEAD — silent clean skip" \
  || no "detached HEAD must skip silently with exit 0 (rc=$DRC: $DOUT)"
[ "$(git -C "$CP" rev-list --count HEAD)" -eq "$DN" ] \
  && ok "degrade: detached HEAD — no commit created" \
  || no "no commit may be created on a detached HEAD"

# ── T7 — the acceptance: manual render works with the hook absent.
rm -f "$HOOK"
tracker "✅"
( cd "$CP" && git add -A && git commit -qm "docs: hookless" ) >/dev/null 2>&1
[ "$(git -C "$CP" log -1 --pretty=%s)" = "docs: hookless" ] \
  && ok "hookless: no regeneration without the hook (convenience, not dependency)" \
  || no "with the hook removed nothing may auto-commit"
( cd "$CP" \
  && bash .claude/resolve-ready.sh docs/PHASE_STATUS.md --json > status.json \
  && bash .claude/render-status.sh status.json > status.html ) 2>/dev/null \
  && grep -q 'status-data' "$CP/status.html" \
  && ok "hookless: manual render works through the documented chain" \
  || no "manual render must work with the hook absent"
rm -f "$CP/status.json"

# ── T8 — sync semantics mirror the runner: refresh-if-present (announced),
# never created fresh on --sync (the template-clone consumer protection).
echo "#!/bin/bash" > "$HOOK"; echo "# Harness-owned (drifted fixture)" >> "$HOOK"
bash "$H/maintainers/setup-control-plane.sh" "$CP" --sync > "$WORK/sync1.log" 2>&1
grep -q 'Harness-owned' "$HOOK" && grep -q 'post-commit' "$WORK/sync1.log" \
  && grep -qi 'refreshed' "$WORK/sync1.log" \
  && ok "sync: drifted harness-owned hook refreshed, announced" \
  || no "--sync must refresh a drifted harness-owned hook and say so"
rm -f "$HOOK"
bash "$H/maintainers/setup-control-plane.sh" "$CP" --sync > "$WORK/sync2.log" 2>&1
[ ! -f "$HOOK" ] \
  && ok "sync: absent hook is NOT created on --sync (consumer protection)" \
  || no "--sync must never hand a project a git hook it didn't have"

# ── T9 — a foreign (non-harness-owned) hook is never clobbered, in either mode.
printf '#!/bin/bash\n# my own hook\n' > "$HOOK"; chmod +x "$HOOK"
bash "$H/maintainers/setup-control-plane.sh" "$CP" --sync > "$WORK/sync3.log" 2>&1
grep -q 'my own hook' "$HOOK" \
  && ok "ownership: foreign post-commit hook left untouched on --sync" \
  || no "--sync must never overwrite a hook it does not own"
CP2="$WORK/cp2"
bash "$H/maintainers/setup-control-plane.sh" "$CP2" > /dev/null 2>&1
git -C "$CP2" config user.email t@t && git -C "$CP2" config user.name t
printf '#!/bin/bash\n# my own hook\n' > "$CP2/.git/hooks/post-commit"
bash "$H/maintainers/setup-control-plane.sh" "$CP2" > "$WORK/create2.log" 2>&1
grep -q 'my own hook' "$CP2/.git/hooks/post-commit" \
  && grep -qi 'not harness-owned\|left untouched' "$WORK/create2.log" \
  && ok "ownership: foreign hook survives re-create, refusal announced" \
  || no "create must not clobber a foreign hook, and must say so"

# ── T10 — the views manifest entry: schema-declared, optional, closed.
SCHEMA="$CLAUDE_DIR/project.schema.json"
jq -e '.properties.views | .type == "object" and .additionalProperties == false
  and (.properties.status.type == "string")' "$SCHEMA" >/dev/null 2>&1 \
  && ok "views: schema declares the closed optional views entry" \
  || no "project.schema.json must declare views {status: string}, additionalProperties false"
jq -e '.required | index("views") | not' "$SCHEMA" >/dev/null 2>&1 \
  && ok "views: entry is optional (not required)" || no "views must not be required"
echo "$(jq -r '.properties.views.description // ""' "$SCHEMA")" | grep -qi 'never\|descri' \
  && ok "views: schema description states describes-never-routes" \
  || no "the schema must teach that views is descriptive only"

# The generated dogfooding manifest declares the surface and still validates
# against the schema's own constraint set (required ⊆ keys, keys ⊆ properties)
# — computed FROM the schema, both with and without the entry.
validate() {  # $1 = manifest path → 0 valid / 1 invalid (top level + views shape)
  jq -e --slurpfile s "$SCHEMA" '
    ($s[0]) as $sch
    | ($sch.required - (keys)) == []
    and ((keys) - ($sch.properties | keys)) == []
    and (if has("views") then
          (.views | type) == "object"
          and ((.views | keys) - ($sch.properties.views.properties | keys)) == []
          and ([.views[] | type == "string"] | all)
        else true end)
  ' "$1" >/dev/null 2>&1
}
jq -e '.views.status == "status.html"' "$CP/.claude/project.json" >/dev/null 2>&1 \
  && ok "views: generated dogfooding manifest declares status.html" \
  || no "the generated control-plane manifest must carry views.status"
validate "$CP/.claude/project.json" \
  && ok "views: manifest WITH views validates against the schema's constraints" \
  || no "views-bearing manifest must validate"
jq 'del(.views)' "$CP/.claude/project.json" > "$WORK/no-views.json"
validate "$WORK/no-views.json" \
  && ok "views: manifest WITHOUT views validates (entry optional)" \
  || no "views-free manifest must remain valid"
jq '.viewz = {}' "$WORK/no-views.json" > "$WORK/typo.json"
validate "$WORK/typo.json" \
  && no "a typo'd top-level key must fail validation (additionalProperties false)" \
  || ok "views: unknown top-level key refused by the constraint set"
jq '.views = {bogus: "x.html"}' "$WORK/no-views.json" > "$WORK/subkey.json"
validate "$WORK/subkey.json" \
  && no "an unknown views subkey must fail validation" \
  || ok "views: unknown views subkey refused (closed object)"
jq '.views = {status: 123}' "$WORK/no-views.json" > "$WORK/badtype.json"
validate "$WORK/badtype.json" \
  && no "a non-string views.status must fail validation" \
  || ok "views: non-string status refused (type-checked, not just key-checked)"
jq '.views = []' "$WORK/no-views.json" > "$WORK/badviews.json"
validate "$WORK/badviews.json" \
  && no "an array views must fail validation" \
  || ok "views: non-object views refused"

# ── T11 — describes, never routes: no execution path reads the views entry.
ROUTES=$(grep -rn '\.views' \
    "$CLAUDE_DIR"/*.sh "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/commands" \
    "$CLAUDE_DIR/skills" "$CLAUDE_DIR/workflows" \
    "$ROOT/maintainers" "$ROOT/plugin/scripts" "$ROOT/Makefile" 2>/dev/null || true)
[ -z "$ROUTES" ] \
  && ok "views: no execution path reads .views — it describes, never routes" \
  || no "something routes on the views entry: $ROUTES"
grep -q 'views' "$CLAUDE_DIR/render-status.sh" \
  && no "the renderer must not know the views entry exists" \
  || ok "views: the renderer is views-blind (target comes from the caller)"

# ── T12 — the publishing path is taught where control-plane topology is
# taught, with the access-control framing and the convenience-not-dependency
# degradation.
DOG="$ROOT/maintainers/DOGFOODING.md"
grep -qi 'GitHub Pages' "$DOG" \
  && ok "docs: Pages path present in the topology doc" \
  || no "DOGFOODING.md must document the Pages publishing path"
grep -qi 'repo access' "$DOG" && grep -qi 'push is the deploy' "$DOG" \
  && ok "docs: access-control framing present (repo access / push is the deploy)" \
  || no "the access-control framing must be stated, not implied"
grep -qi 'convenience' "$DOG" \
  && ok "docs: hook taught as convenience, never a dependency" \
  || no "the docs must teach the manual-render degradation"
# The visibility caveat is load-bearing: private-repo Pages sites are PUBLIC
# on non-Enterprise plans. The framing alone, unhedged, is a privacy footgun
# — this pin keeps the correction from being reverted by spec-faithful edits.
# Pinned by the FACT phrase (its consequence stated in full), not word
# presence — a rewrite that negates the fact cannot keep this sentence.
grep -qi 'publishes your tracker to the open internet' "$DOG" \
  && grep -q 'Enterprise Cloud' "$DOG" \
  && ok "docs: Pages visibility caveat pinned by fact (public off Enterprise Cloud)" \
  || no "the docs must state the consequence: enabling Pages on a private non-Enterprise plane publishes the tracker"
# The same claim must not survive on the consumer-shipped surface: the schema
# description carries no access-control or publishing advice (the wrong home
# for a hosting claim — that lives in the topology doc with the caveat).
grep -qi 'access control' "$SCHEMA" \
  && no "the consumer-shipped schema must not carry the access-control claim" \
  || ok "docs: schema description carries no access-control claim (class swept)"

# ── T13 — the hook never parses tracker CONTENT: naming the tracker PATH for
# its trigger and for the resolver call is the designed shape; marker glyphs
# or deps tokens anywhere in the generator (which embeds the hook) would be
# a second grammar implementation.
grep -qE '⬜|✅|🔄|❌|deps:' "$REAL_SCRIPT" "$WORK/generated-hook" 2>/dev/null \
  && no "the hook/generator must not carry tracker grammar (one parser)" \
  || ok "one-parser: hook touches the tracker only as a path, never as content"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
